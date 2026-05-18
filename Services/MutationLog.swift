//
//  MutationLog.swift
//  Listie.md
//
//  Durable, file-backed queue of pending writes for offline-first edits.
//
//  Layer 4 of the sync resilience work. The existing `pendingUploads` UserDefaults set
//  in NextcloudManager handles the NC-specific case at file granularity; this log
//  generalises to item-level operations across all backends (NC, iCloud, external) and
//  survives app kills. It is intentionally append-only on the hot path with periodic
//  rewrites for compaction — atomic-rename writes ensure no partial-file corruption.
//
//  Currently gated behind the `useLocalFirstMutations` UserDefaults flag (default off).
//  When enabled, mutation entry points (updateItem, deleteItem, completeItemFromNotification,
//  etc.) enqueue an entry here in addition to the existing write path. The replay logic
//  drains the log when the network is reachable. Disabled paths fall through to the
//  pre-Layer-4 retry queues unchanged.
//

import Foundation
import os

/// One queued write operation. Identified by `id` so concurrent retries can dedupe.
struct MutationEntry: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let listId: String
    let listSource: ListSourceKey
    let op: Operation
    var attemptCount: Int
    var lastAttemptedAt: Date?
    var lastError: String?

    enum ListSourceKey: Codable {
        case privateICloud(listId: String)
        case external(path: String)
        case nextcloud(accountId: String, remotePath: String)
    }

    enum Operation: Codable {
        /// Persist the entire current document. Cheap because the document is already
        /// in cache; this is the primary op we need to fix the headline bug.
        case persistDocument(payload: Data)
        /// Advance a repeating reminder to the next occurrence. Sentinel for richer
        /// future field-level operations; for now persistDocument covers the same ground.
        case advanceReminder(itemId: UUID, newDate: Date)
    }

    init(listId: String, listSource: ListSourceKey, op: Operation) {
        self.id = UUID()
        self.createdAt = Date()
        self.listId = listId
        self.listSource = listSource
        self.op = op
        self.attemptCount = 0
        self.lastAttemptedAt = nil
        self.lastError = nil
    }
}

actor MutationLog {
    static let shared = MutationLog()

    /// Feature flag gating Layer 4 mutation routing. Default off for TestFlight rollout;
    /// flip to true to enable local-first mutations in regions outside the headline bug fix.
    static let featureFlagKey = "useLocalFirstMutations"
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: featureFlagKey)
    }

    private let logURL: URL
    private var entries: [MutationEntry] = []
    private var isLoaded: Bool = false

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDir = appSupport.appendingPathComponent("MutationLog", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        self.logURL = logDir.appendingPathComponent("log.json")
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard FileManager.default.fileExists(atPath: logURL.path),
              let data = try? Data(contentsOf: logURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([MutationEntry].self, from: data) {
            entries = decoded
            AppLogger.sync.info("[MutationLog] Loaded \(decoded.count) pending mutation(s) from disk")
        }
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else {
            AppLogger.sync.error("[MutationLog] Failed to encode log")
            return
        }
        // Atomic rename: write to temp file, then move into place.
        let tempURL = logURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: logURL.path) {
                _ = try? FileManager.default.replaceItem(at: logURL, withItemAt: tempURL, backupItemName: nil, options: [], resultingItemURL: nil)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: logURL)
            }
        } catch {
            AppLogger.sync.error("[MutationLog] Failed to persist log: \(error, privacy: .public)")
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    // MARK: - Public API

    /// Append a new mutation entry. Cheap (a single file write).
    func enqueue(_ entry: MutationEntry) {
        loadIfNeeded()
        entries.append(entry)
        saveToDisk()
        AppLogger.sync.info("[MutationLog] Enqueued mutation for list \(entry.listId, privacy: .public) (queue depth: \(self.entries.count, privacy: .public))")
    }

    /// Returns all current entries. Caller is responsible for retry semantics.
    func snapshot() -> [MutationEntry] {
        loadIfNeeded()
        return entries
    }

    /// Mark an entry as successfully replayed and remove it.
    func markCompleted(_ entryId: UUID) {
        loadIfNeeded()
        let before = entries.count
        entries.removeAll { $0.id == entryId }
        if entries.count != before {
            saveToDisk()
        }
    }

    /// Record a failed attempt — increments attempt counter and stores the last error.
    /// Entries are kept in the log for the next retry pass.
    func recordAttempt(for entryId: UUID, error: Error?) {
        loadIfNeeded()
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[index].attemptCount += 1
        entries[index].lastAttemptedAt = Date()
        entries[index].lastError = error?.localizedDescription
        saveToDisk()
    }

    /// Returns the current queue depth without loading the full set. Used by Layer 5
    /// observability to show pending mutation counts in the Recent Changes view.
    func depth() -> Int {
        loadIfNeeded()
        return entries.count
    }

    /// Number of pending entries for a specific list. Used by the per-list sync
    /// status chip so it shows "Pending sync" instead of "Synced" when local edits
    /// haven't been pushed yet (e.g. airplane mode).
    func depth(for listId: String) -> Int {
        loadIfNeeded()
        return entries.filter { $0.listId == listId }.count
    }

    /// Clears the log. Use for testing or after a destructive sign-out.
    func clear() {
        entries.removeAll()
        isLoaded = true
        try? FileManager.default.removeItem(at: logURL)
    }
}

// MARK: - Bridge helpers

extension MutationEntry.ListSourceKey {
    /// Builds a ListSourceKey from a UnifiedList's source. Used at enqueue time.
    static func from(_ source: ListSource) -> MutationEntry.ListSourceKey {
        switch source {
        case .privateICloud(let listId):
            return .privateICloud(listId: listId)
        case .external(let url):
            return .external(path: url.path)
        case .nextcloud(let accountId, let remotePath):
            return .nextcloud(accountId: accountId, remotePath: remotePath)
        }
    }
}
