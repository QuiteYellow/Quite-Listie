//
//  DiskCacheManager.swift
//  Listie.md
//
//  Manages Tier 2 persistent disk cache for instant app launch
//  and graceful fallback when files are unavailable.
//
//  Write path: Tier 3 (file/iCloud) succeeds → copy to Tier 2
//  Read path:  Tier 1 miss → Tier 2 (read-only) → Tier 3 loads → unlock editing
//

import Foundation
import CryptoKit

/// Wrapper around ListDocument for disk cache persistence
struct CacheSnapshot: Codable {
    let snapshotVersion: Int
    let sourceType: String      // "private" or "external"
    let sourceKey: String       // list ID or URL path
    let snapshotDate: Date
    let document: ListDocument
}

actor DiskCacheManager {
    static let shared = DiskCacheManager()

    private var baseDirectory: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("ListSnapshots", isDirectory: true)
    }

    private var privateDirectory: URL {
        baseDirectory.appendingPathComponent("private", isDirectory: true)
    }

    private var externalDirectory: URL {
        baseDirectory.appendingPathComponent("external", isDirectory: true)
    }

    // MARK: - Write Operations

    /// Saves a snapshot after a successful Tier 3 write or load
    func saveSnapshot(_ document: ListDocument, for source: FileSource) {
        do {
            let url = snapshotURL(for: source)
            try ensureDirectoryExists(url.deletingLastPathComponent())

            let snapshot = CacheSnapshot(
                snapshotVersion: 1,
                sourceType: source.isPrivate ? "private" : "external",
                sourceKey: sourceKey(for: source),
                snapshotDate: Date(),
                document: document
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)

            print("📸 [DiskCache] Saved snapshot for \(document.list.name)")
        } catch {
            print("⚠️ [DiskCache] Failed to save snapshot: \(error)")
        }
    }

    // MARK: - Read Operations

    /// Loads a cached snapshot if one exists. Returns nil if missing or corrupt.
    func loadSnapshot(for source: FileSource) -> ListDocument? {
        let url = snapshotURL(for: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(CacheSnapshot.self, from: data)
            print("📸 [DiskCache] Loaded snapshot for \(snapshot.document.list.name)")
            return snapshot.document
        } catch {
            print("⚠️ [DiskCache] Corrupt snapshot, removing: \(error)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // MARK: - Cleanup Operations

    /// Removes the snapshot for a specific source
    func removeSnapshot(for source: FileSource) {
        let url = snapshotURL(for: source)
        try? FileManager.default.removeItem(at: url)
        print("🗑️ [DiskCache] Removed snapshot at \(url.lastPathComponent)")
    }

    /// Removes all snapshots for private lists (called during migration)
    func clearPrivateListSnapshots() {
        try? FileManager.default.removeItem(at: privateDirectory)
        print("🧹 [DiskCache] Cleared all private list snapshots")
    }

    /// Removes all snapshots
    func clearAllSnapshots() {
        try? FileManager.default.removeItem(at: baseDirectory)
        print("🧹 [DiskCache] Cleared all snapshots")
    }

    // MARK: - Internal Helpers

    private func snapshotURL(for source: FileSource) -> URL {
        switch source {
        case .privateList(let listId):
            return privateDirectory.appendingPathComponent("\(listId).json")
        case .externalFile(let url):
            let hash = sha256(url.path)
            return externalDirectory.appendingPathComponent("\(hash).json")
        }
    }

    private func sourceKey(for source: FileSource) -> String {
        switch source {
        case .privateList(let listId):
            return listId
        case .externalFile(let url):
            return url.path
        }
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
