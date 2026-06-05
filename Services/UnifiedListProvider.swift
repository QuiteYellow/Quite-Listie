//
//  UnifiedListProvider.swift
//  Listie.md
//
//  Unified provider that handles private (iCloud), external files, and Nextcloud seamlessly.
//

import Foundation
import SwiftUI
import os

enum ListSource: Hashable {
    /// Private list stored in the app's iCloud container (or local fallback)
    case privateICloud(String)  // List ID

    /// External file selected by the user from Files app
    case external(URL)

    /// File stored on a Nextcloud server
    case nextcloud(accountId: String, remotePath: String)

    /// Convert to FileSource for use with FileStore. Returns nil for Nextcloud lists.
    var asFileSource: FileSource? {
        switch self {
        case .privateICloud(let listId):  return .privateList(listId)
        case .external(let url):          return .externalFile(url)
        case .nextcloud:                  return nil
        }
    }
}

extension Notification.Name {
    static let externalFileChanged      = Notification.Name("externalFileChanged")
    static let externalListChanged      = Notification.Name("externalListChanged")
    static let listSettingsChanged      = Notification.Name("listSettingsChanged")
    static let storageLocationChanged   = Notification.Name("storageLocationChanged")
    /// Posted by NextcloudManager when a background sync discovers a file no longer exists on the server.
    /// userInfo: ["remotePath": String]
    static let nextcloudFileNotFound    = Notification.Name("nextcloudFileNotFound")
    /// Posted by NextcloudManager when a previously-queued upload succeeds (e.g. retried
    /// by NWPathMonitor after the network came back). Lets UI reactively clear the
    /// "Pending sync" cloud-slash without waiting for a manual refresh.
    /// userInfo: ["remotePath": String]
    static let nextcloudPendingUploadDrained = Notification.Name("nextcloudPendingUploadDrained")
}


struct UnifiedList: Identifiable, Hashable {
    let id: String
    let source: ListSource
    var summary: ListSummary

    var originalFileId: String?
    var isReadOnly: Bool = false

    /// If non-nil, this file is unavailable and cannot be opened
    var unavailableBookmark: UnavailableBookmark?
    var isUnavailable: Bool { unavailableBookmark != nil }

    /// True when the list has a bookmark whose underlying error is confirmed-permanent
    /// (file deleted, in trash). These lists belong in the "Unavailable" sidebar section
    /// and are correctly read-only. Compare with `hasTransientSyncError` which represents
    /// recoverable network/session/download issues — those lists stay usable from cache.
    var isPermanentlyUnavailable: Bool {
        unavailableBookmark?.reason.severity == .permanent
    }

    /// True when the list has a transient sync issue (network down, NC session stale,
    /// iCloud file not yet downloaded). The list should still display its cached items
    /// and accept edits — the issue surfaces as a small sync chip, not a blocking banner.
    var hasTransientSyncError: Bool {
        unavailableBookmark?.reason.severity == .transient
    }

    var externalURL: URL? {
        if case .external(let url) = source { return url }
        return nil
    }

    var isPrivate: Bool {
        if case .privateICloud = source { return true }
        return false
    }

    var isExternal: Bool {
        if case .external = source { return true }
        return false
    }

    var isNextcloud: Bool {
        if case .nextcloud = source { return true }
        return false
    }

    var privateListId: String? {
        if case .privateICloud(let listId) = source { return listId }
        return nil
    }

    var nextcloudRemotePath: String? {
        if case .nextcloud(_, let remotePath) = source { return remotePath }
        return nil
    }

    static func == (lhs: UnifiedList, rhs: UnifiedList) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@Observable
@MainActor
class UnifiedListProvider {

    static let shared = UnifiedListProvider()

    var allLists: [UnifiedList] = []
    var saveStatus: [String: SaveStatus] = [:]

    // REACTIVE label caches
    var externalLabels: [URL: [ListLabel]] = [:]
    var nextcloudLabels: [String: [ListLabel]] = [:]  // keyed by remotePath

    var isDownloadingFile = false
    var currentlyLoadingFile: String? = nil
    var loadingProgress: (current: Int, total: Int) = (0, 0)
    var isInitialLoad: Bool = true

    /// Lists currently serving cached data because the server was unreachable.
    /// Cleared automatically when sync succeeds.
    var syncPendingListIDs: Set<String> = []

    /// True while recovering NC credentials/session after deep sleep.
    /// The sidebar shows a loading banner instead of transient errors during this phase.
    var isRecoveringSession: Bool = false

    private var autosaveTasks: [String: Task<Void, Never>] = [:]
    private var activeSyncs: Set<String> = []

    init() {
        // Listen for background-drain notifications so the per-list "Pending sync"
        // indicator clears reactively when NWPathMonitor (or a background sync)
        // successfully uploads a previously-queued file. Without this hook, the
        // cloud-slash chip stayed on until the user manually refreshed.
        //
        // The Task self-terminates when this provider deallocates (weak self), so
        // we don't need a deinit-hosted cancel — the next notification breaks the loop.
        Task { @MainActor [weak self] in
            let stream = NotificationCenter.default.notifications(
                named: .nextcloudPendingUploadDrained
            )
            for await note in stream {
                guard let self else { break }
                guard let remotePath = note.userInfo?["remotePath"] as? String else { continue }
                self.handlePendingUploadDrained(remotePath: remotePath)
            }
        }
    }

    private func handlePendingUploadDrained(remotePath: String) {
        guard let list = allLists.first(where: {
            if case .nextcloud(_, let path) = $0.source { return path == remotePath }
            return false
        }) else { return }
        // Clear pending/syncFailed but never touch saveFailed (real local-write loss)
        // or `.saving`/`.unsaved` (an active edit in flight).
        switch saveStatus[list.id] ?? .saved {
        case .pendingSync, .syncFailed:
            saveStatus[list.id] = .saved
            AppLogger.nextcloud.info("[NC] Cleared pending status for \(list.summary.name, privacy: .public) — background upload succeeded")
        case .saved, .saving, .unsaved, .saveFailed:
            break
        }
    }

    /// Per-list save/sync state. Five user-meaningful cases:
    /// - `.saved`        — local cache and server agree
    /// - `.saving`       — write in progress
    /// - `.unsaved`      — user has typed something the autosave hasn't picked up yet
    /// - `.pendingSync`  — saved locally; upload queued (network down / unreachable)
    /// - `.syncFailed`   — server rejected the write (auth, permission, conflict). Won't auto-recover.
    /// - `.saveFailed`   — couldn't write to local cache (extremely rare; real data risk)
    enum SaveStatus: Equatable {
        case saved
        case saving
        case unsaved
        case pendingSync
        case syncFailed(String)
        case saveFailed(String)

        /// Backwards-compat alias. Old call sites that emit `.failed(message)` continue to
        /// compile; treated identically to `.syncFailed` at every consumer.
        static func failed(_ message: String) -> SaveStatus { .syncFailed(message) }
    }

    /// Classifies an error thrown during a save into the appropriate `SaveStatus` case.
    /// Network failures map to `.pendingSync` (data is safe in cache, retry queued).
    /// Anything else maps to `.syncFailed` (won't auto-recover; needs attention).
    nonisolated static func classifySaveError(_ error: Error) -> SaveStatus {
        if let nc = error as? NCError {
            switch nc {
            case .notConnected, .networkError:
                return .pendingSync
            case .notFound:
                return .syncFailed(nc.localizedDescription)
            }
        }
        // URLError covers transport-level issues from any backend
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .pendingSync
        }
        return .syncFailed(error.localizedDescription)
    }

    // MARK: - Document helpers

    /// Opens a ListDocument from whatever backend owns this list.
    private func openDocument(for list: UnifiedList, forceReload: Bool = false) async throws -> ListDocument {
        switch list.source {
        case .nextcloud(_, let remotePath):
            return try await NextcloudManager.shared.openFile(remotePath: remotePath, forceReload: forceReload)
        default:
            guard let source = list.source.asFileSource else {
                throw NSError(domain: "UnifiedListProvider", code: 99,
                              userInfo: [NSLocalizedDescriptionKey: "Unhandled list source"])
            }
            return try await FileStore.shared.openFile(from: source, forceReload: forceReload)
        }
    }

    /// Cache-first read for write operations. Returns the cached document immediately
    /// when available, falling through to the network/disk path only as a last resort.
    /// Use for write flows (updateItem/addItem/etc.) so an offline notification "Complete"
    /// action can still advance a repeating reminder when the server is unreachable.
    /// Layer 4: writes downstream go through the existing `pendingUploads` retry queue
    /// (NextcloudManager) and NSFileCoordinator queueing (iCloud), so the write itself
    /// never blocks on network either.
    private func openDocumentForMutation(for list: UnifiedList) async throws -> ListDocument {
        if let cached = await openDocumentForDisplay(for: list) {
            return cached
        }
        return try await openDocument(for: list)
    }

    /// Writes a document to the appropriate backend cache and triggers autosave.
    /// Pass `immediate: true` to skip the 500ms debounce — used by notification-action
    /// flows where the app may be suspended before the debounce timer fires.
    private func cacheDocument(_ doc: ListDocument, for list: UnifiedList, immediate: Bool = false) async {
        switch list.source {
        case .privateICloud(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            await FileStore.shared.updateCache(doc, at: url)
            triggerAutosave(for: list, document: doc, immediate: immediate)
        case .external(let url):
            await FileStore.shared.updateCache(doc, at: url)
            triggerAutosave(for: list, document: doc, immediate: immediate)
        case .nextcloud(_, let remotePath):
            await NextcloudManager.shared.updateCache(doc, remotePath: remotePath)
            triggerAutosave(for: list, document: doc, immediate: immediate)
        }
        await enqueueMutationIfEnabled(doc, for: list)
    }

    /// Layer 4: durable record of edits, complementary to the existing autosave path.
    /// Default off via `MutationLog.isEnabled`. When on, every mutation appends a
    /// `persistDocument` entry; replay runs alongside the existing pendingUploads
    /// retry queue. Failure modes are independent — both layers must fail to lose data.
    private func enqueueMutationIfEnabled(_ doc: ListDocument, for list: UnifiedList) async {
        guard MutationLog.isEnabled else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let payload = try? encoder.encode(doc) else {
            AppLogger.sync.warning("[MutationLog] Failed to encode document for list \(list.id, privacy: .public)")
            return
        }
        let entry = MutationEntry(
            listId: list.id,
            listSource: .from(list.source),
            op: .persistDocument(payload: payload)
        )
        await MutationLog.shared.enqueue(entry)
    }

    /// Updates the document cache for the appropriate backend without triggering autosave.
    /// Use before an immediate `saveFile` call so merge logic sees the latest document.
    private func updateDocumentCache(_ doc: ListDocument, for list: UnifiedList) async {
        switch list.source {
        case .privateICloud(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            await FileStore.shared.updateCache(doc, at: url)
        case .external(let url):
            await FileStore.shared.updateCache(doc, at: url)
        case .nextcloud(_, let remotePath):
            await NextcloudManager.shared.updateCache(doc, remotePath: remotePath)
        }
    }

    /// Caches label array into the per-backend reactive dictionary.
    private func cacheLabels(_ labels: [ListLabel], for list: UnifiedList) {
        switch list.source {
        case .external(let url):
            externalLabels[url] = labels
        case .nextcloud(_, let remotePath):
            nextcloudLabels[remotePath] = labels
        default:
            break
        }
    }

    // MARK: - Nextcloud file-not-found notification

    /// Called when `NextcloudManager`'s background sync detects a file is gone from the server.
    func handleNextcloudFileNotFound(remotePath: String) {
        guard let index = allLists.firstIndex(where: {
            if case .nextcloud(_, let path) = $0.source, path == remotePath {
                return true
            }
            return false
        }) else { return }

        let list = allLists[index]
        guard case .nextcloud(let accountId, _) = list.source else { return }
        let serverHost = accountId.components(separatedBy: "@").last ?? accountId
        let fileName = remotePath.split(separator: "/").last.map(String.init) ?? remotePath
        let bookmark = UnavailableBookmark(
            id: list.id, originalPath: remotePath, reason: .fileNotFound,
            fileName: fileName.replacingOccurrences(of: ".listie", with: ""),
            folderName: serverHost
        )
        var updated = allLists[index]
        updated.isReadOnly = true
        updated.unavailableBookmark = bookmark
        allLists[index] = updated
        AppLogger.nextcloud.warning("[NC] Marked unavailable (background sync): \(remotePath, privacy: .public)")
    }

    // MARK: - Load Lists

    func loadAllLists() async {
        let externalURLs = await FileStore.shared.refreshBookmarkAvailability()

        var unified: [UnifiedList] = []
        var seenExternalURLs: Set<String> = []

        // Private lists (iCloud container or local fallback)
        do {
            let privateListURLs = try await FileStore.shared.getPrivateListURLs()

            for url in privateListURLs {
                let listId = url.deletingPathExtension().lastPathComponent
                do {
                    let source = FileSource.privateList(listId)
                    let document = try await FileStore.shared.openFile(from: source)

                    unified.append(UnifiedList(
                        id: listId,
                        source: .privateICloud(listId),
                        summary: document.list,
                        originalFileId: nil,
                        isReadOnly: false
                    ))
                } catch {
                    // Don't silently drop iCloud lists that fail to load — that's how repeating
                    // reminders disappear after deep sleep. Surface them as transient-unavailable
                    // so the UI shows a "downloading…" placeholder and Layer 2's cache fallback
                    // serves any last-known content. Layer 1's ScenePhase hook retries on activate.
                    AppLogger.fileStore.error("Failed to load private list \(url, privacy: .public): \(error, privacy: .public)")
                    let fileName = url.deletingPathExtension().lastPathComponent
                    let bookmark = UnavailableBookmark(
                        id: listId, originalPath: url.path,
                        reason: .iCloudNotDownloaded,
                        fileName: fileName, folderName: "iCloud"
                    )
                    unified.append(UnifiedList(
                        id: listId,
                        source: .privateICloud(listId),
                        summary: ListSummary(id: listId, name: fileName, modifiedAt: Date(), icon: "icloud.and.arrow.down"),
                        originalFileId: nil,
                        isReadOnly: false,           // transient — Layer 2's cache + retry keep it usable
                        unavailableBookmark: bookmark
                    ))
                    // Kick off an async re-download so the list rehydrates without user action
                    Task {
                        _ = try? await FileStore.shared.openFile(from: .privateList(listId))
                        NotificationCenter.default.post(name: .externalListChanged, object: listId)
                    }
                }
            }
        } catch {
            AppLogger.fileStore.error("Failed to discover private lists: \(error, privacy: .public)")
        }

        // Welcome list (read-only example)
        unified.append(UnifiedList(
            id: ExampleData.welcomeListId,
            source: .privateICloud(ExampleData.welcomeListId),
            summary: ExampleData.welcomeList,
            originalFileId: nil,
            isReadOnly: true
        ))

        // External lists
        let totalFiles = externalURLs.count
        var currentFileIndex = 0

        for url in externalURLs {
            guard !seenExternalURLs.contains(url.path) else { continue }
            seenExternalURLs.insert(url.path)

            currentFileIndex += 1
            if isInitialLoad {
                let fileName = url.deletingPathExtension().lastPathComponent
                currentlyLoadingFile = fileName
                loadingProgress = (currentFileIndex, totalFiles)
            }

            do {
                let source = FileSource.externalFile(url)
                let document = try await FileStore.shared.openFile(from: source)
                let runtimeId = "external:\(url.path)"

                var modifiedSummary = document.list
                modifiedSummary.id = runtimeId
                let isReadOnly = !FileStore.isFileWritable(at: url)

                unified.append(UnifiedList(
                    id: runtimeId,
                    source: .external(url),
                    summary: modifiedSummary,
                    originalFileId: document.list.id,
                    isReadOnly: isReadOnly
                ))
                externalLabels[url] = document.labels

            } catch {
                AppLogger.fileStore.error("Failed to load external file \(url, privacy: .public): \(error, privacy: .public)")
                let fileName = url.deletingPathExtension().lastPathComponent
                let folderName = url.deletingLastPathComponent().lastPathComponent
                let runtimeId = "unavailable:\(url.path)"

                let placeholderSummary = ListSummary(
                    id: runtimeId, name: fileName, modifiedAt: Date(), icon: "exclamationmark.triangle"
                )
                let bookmark = UnavailableBookmark(
                    id: url.path, originalPath: url.path,
                    reason: .bookmarkInvalid(error), fileName: fileName, folderName: folderName
                )
                // Transient errors don't lock the list — Layer 2's cache-first read and
                // Layer 4's mutation log keep it usable. Only permanent reasons set isReadOnly.
                let readOnly = bookmark.reason.severity == .permanent
                unified.append(UnifiedList(
                    id: runtimeId, source: .external(url),
                    summary: placeholderSummary, originalFileId: nil,
                    isReadOnly: readOnly, unavailableBookmark: bookmark
                ))
            }
        }

        currentlyLoadingFile = nil
        loadingProgress = (0, 0)
        // isInitialLoad stays true until NC loading completes

        // Unavailable external files
        let unavailableBookmarks = await FileStore.shared.getUnavailableBookmarks()
        for bookmark in unavailableBookmarks {
            let runtimeId = "unavailable:\(bookmark.id)"
            let placeholderSummary = ListSummary(
                id: runtimeId, name: bookmark.fileName, modifiedAt: Date(),
                icon: bookmark.reason.icon
            )
            // Same rule: transient errors don't force read-only — the user may still
            // want to interact, and the cache layer plus mutation log keep things safe.
            let readOnly = bookmark.reason.severity == .permanent
            unified.append(UnifiedList(
                id: runtimeId, source: .privateICloud(runtimeId),
                summary: placeholderSummary, originalFileId: nil,
                isReadOnly: readOnly, unavailableBookmark: bookmark
            ))
        }

        // Preserve any already-loaded NC lists so the sidebar doesn't flash empty
        unified.append(contentsOf: allLists.filter { $0.isNextcloud })

        // Publish local lists immediately — sidebar renders without waiting for NC
        let localSorted = unified.sorted {
            $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending
        }
        allLists = localSorted
        for list in localSorted where saveStatus[list.id] == nil {
            saveStatus[list.id] = .saved
        }

        // Load NC lists progressively — each updates allLists as it arrives
        await loadNextcloudListsProgressively()

        Task { await EventKitManager.shared.syncIfEnabled(provider: self) }
    }

    // MARK: - Nextcloud list loading

    private static let nextcloudFilesKey = "com.listie.nextcloud-files"

    /// Loads all known Nextcloud files from UserDefaults, updating `allLists` as each arrives.
    /// Assumes `allLists` already contains preserved NC entries from the previous load.
    private func loadNextcloudListsProgressively() async {
        let records = loadNextcloudFileRecords()
        guard !records.isEmpty else {
            allLists.removeAll { $0.isNextcloud }
            isInitialLoad = false
            return
        }

        var loadedIds: Set<String> = []
        var currentIndex = 0
        let total = records.count

        for record in records {
            currentIndex += 1
            let accountId  = record["accountId"] ?? ""
            let remotePath = record["remotePath"] ?? ""
            guard !accountId.isEmpty, !remotePath.isEmpty else { continue }

            let runtimeId = "nextcloud:\(accountId):\(remotePath)"
            loadedIds.insert(runtimeId)

            let displayNameForProgress = remotePath.split(separator: "/").last
                .map { String($0).replacingOccurrences(of: ".listie", with: "") } ?? remotePath
            currentlyLoadingFile = displayNameForProgress
            loadingProgress = (currentIndex, total)

            let newEntry: UnifiedList
            do {
                let doc = try await NextcloudManager.shared.openFile(remotePath: remotePath)
                var summary = doc.list
                summary.id = runtimeId
                nextcloudLabels[remotePath] = doc.labels
                newEntry = UnifiedList(
                    id: runtimeId,
                    source: .nextcloud(accountId: accountId, remotePath: remotePath),
                    summary: summary,
                    originalFileId: doc.list.id,
                    isReadOnly: false
                )
            } catch {
                AppLogger.nextcloud.warning("[NC] Failed to load \(remotePath, privacy: .public): \(error, privacy: .public)")
                // For transient network errors, keep the existing cached entry visible
                if case NCError.notFound = error {} else if allLists.contains(where: { $0.id == runtimeId }) {
                    continue
                }

                // For transient errors (not 404), try disk cache before marking unavailable.
                // After an app kill the memCache is empty, but disk cache may still be valid.
                if case NCError.notFound = error {} else {
                    if let diskDoc = await NextcloudManager.shared.openFileFromDiskCache(remotePath: remotePath) {
                        AppLogger.nextcloud.info("[NC] Using disk cache after transient error for \(remotePath, privacy: .public)")
                        var summary = diskDoc.list
                        summary.id = runtimeId
                        nextcloudLabels[remotePath] = diskDoc.labels
                        newEntry = UnifiedList(
                            id: runtimeId,
                            source: .nextcloud(accountId: accountId, remotePath: remotePath),
                            summary: summary,
                            originalFileId: diskDoc.list.id,
                            isReadOnly: false
                        )

                        if let index = allLists.firstIndex(where: { $0.id == runtimeId }) {
                            allLists[index] = newEntry
                        } else {
                            allLists.append(newEntry)
                            allLists.sort { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }
                        }
                        saveStatus[runtimeId] = .saved
                        syncPendingListIDs.insert(runtimeId)
                        loadedIds.insert(runtimeId)
                        continue
                    }
                }

                let fileName = remotePath.split(separator: "/").last.map(String.init) ?? remotePath
                let displayName = fileName.replacingOccurrences(of: ".listie", with: "")
                let serverHost = accountId.components(separatedBy: "@").last ?? accountId
                let reason: UnavailableBookmark.UnavailabilityReason
                if case NCError.notFound = error { reason = .fileNotFound } else { reason = .bookmarkInvalid(error) }
                let bookmark = UnavailableBookmark(
                    id: runtimeId, originalPath: remotePath, reason: reason,
                    fileName: displayName, folderName: serverHost
                )
                // Only permanent failures (confirmed 404 etc.) lock the list. Transient errors
                // — network down, session stale, server returning 5xx — leave the list editable
                // so Layer 4's mutation log can queue offline writes.
                let readOnly = bookmark.reason.severity == .permanent
                newEntry = UnifiedList(
                    id: runtimeId,
                    source: .nextcloud(accountId: accountId, remotePath: remotePath),
                    summary: ListSummary(id: runtimeId, name: displayName, modifiedAt: Date(), icon: "cloud"),
                    originalFileId: nil,
                    isReadOnly: readOnly,
                    unavailableBookmark: bookmark
                )
            }

            if let index = allLists.firstIndex(where: { $0.id == runtimeId }) {
                allLists[index] = newEntry
            } else {
                allLists.append(newEntry)
                allLists.sort { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }
            }
            saveStatus[runtimeId] = .saved
        }

        // Remove stale NC entries (files removed from UserDefaults while app was running)
        allLists.removeAll { $0.isNextcloud && !loadedIds.contains($0.id) }

        // Check server reachability — if unreachable, mark all loaded NC lists as sync-pending
        // so the user sees a subtle offline indicator instead of stale data with no warning.
        if !loadedIds.isEmpty {
            let reachable = await NextcloudManager.shared.isServerReachable()
            if !reachable {
                for id in loadedIds {
                    syncPendingListIDs.insert(id)
                }
                AppLogger.nextcloud.info("[NC] Server unreachable — marked \(loadedIds.count) list(s) as sync-pending")
            }
        }

        currentlyLoadingFile = nil
        loadingProgress = (0, 0)
        isInitialLoad = false
    }

    /// Opens a Nextcloud file and adds it to `allLists`.
    func openNextcloudFile(remotePath: String) async throws -> String {
        guard let creds = await NextcloudManager.shared.currentCredentials() else {
            throw NCError.notConnected
        }
        let accountId = creds.accountId

        // Check if already open
        let runtimeId = "nextcloud:\(accountId):\(remotePath)"
        if allLists.contains(where: { $0.id == runtimeId }) {
            return runtimeId
        }

        isDownloadingFile = true
        defer { isDownloadingFile = false }

        let doc = try await NextcloudManager.shared.openFile(remotePath: remotePath)

        let privateLists = allLists.filter { $0.isPrivate }
        if privateLists.contains(where: { $0.summary.id == doc.list.id }) {
            throw NSError(domain: "UnifiedListProvider", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ID conflict"
            ])
        }

        if let existing = allLists.first(where: {
            guard !$0.isPrivate, !$0.isPermanentlyUnavailable, let origId = $0.originalFileId else { return false }
            return origId == doc.list.id
        }) {
            throw NSError(domain: "UnifiedListProvider", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Duplicate list ID",
                "existingListId": existing.id,
                "existingListName": existing.summary.name
            ])
        }

        var summary = doc.list
        summary.id = runtimeId
        nextcloudLabels[remotePath] = doc.labels

        let newList = UnifiedList(
            id: runtimeId,
            source: .nextcloud(accountId: accountId, remotePath: remotePath),
            summary: summary,
            originalFileId: doc.list.id,
            isReadOnly: false
        )
        allLists.append(newList)
        saveStatus[runtimeId] = .saved

        // Persist so it reloads on next launch
        var records = loadNextcloudFileRecords()
        let record = ["accountId": accountId, "remotePath": remotePath]
        if !records.contains(where: { $0["remotePath"] == remotePath }) {
            records.append(record)
            saveNextcloudFileRecords(records)
        }

        AppLogger.nextcloud.info("[NC] Opened: \(remotePath, privacy: .public)")
        return runtimeId
    }

    // UserDefaults helpers for persisted Nextcloud file list
    private func loadNextcloudFileRecords() -> [[String: String]] {
        guard let data = UserDefaults.standard.data(forKey: Self.nextcloudFilesKey),
              let records = try? JSONDecoder().decode([[String: String]].self, from: data) else {
            return []
        }
        return records
    }

    private func saveNextcloudFileRecords(_ records: [[String: String]]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.nextcloudFilesKey)
        }
    }

    private func removeNextcloudFileRecord(remotePath: String) {
        var records = loadNextcloudFileRecords()
        records.removeAll { $0["remotePath"] == remotePath }
        saveNextcloudFileRecords(records)
    }

    // MARK: - External File Opening

    #if !targetEnvironment(macCatalyst)
    static func isURLFromSupportedIOSSource(_ url: URL) -> Bool {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let path = url.path
        let isUbiquitous = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false

        AppLogger.fileStore.debug("[SourceCheck] path=\(path, privacy: .public)")
        AppLogger.fileStore.debug("[SourceCheck] isUbiquitousItem=\(isUbiquitous, privacy: .public)")
        AppLogger.fileStore.debug("[SourceCheck] containsCloudDocs=\(path.contains("com~apple~CloudDocs"), privacy: .public)")
        AppLogger.fileStore.debug("[SourceCheck] containsAppleProvider=\(path.contains("File Provider Storage/com.apple."), privacy: .public)")
        AppLogger.fileStore.debug("[SourceCheck] containsFileProviderStorage=\(path.contains("File Provider Storage"), privacy: .public)")

        if path.contains("File Provider Storage") {
            if path.contains("File Provider Storage/com.apple.") ||
               path.contains("File Provider Storage/com-apple-") {
                AppLogger.fileStore.info("[SourceCheck] ALLOWED — Apple system file provider")
                return true
            }
            AppLogger.fileStore.warning("[SourceCheck] BLOCKED — third-party file provider")
            return false
        }
        if isUbiquitous {
            AppLogger.fileStore.info("[SourceCheck] ALLOWED — iCloud ubiquitous item")
            return true
        }
        if path.contains("com~apple~CloudDocs") {
            AppLogger.fileStore.info("[SourceCheck] ALLOWED — iCloud Drive path")
            return true
        }
        AppLogger.fileStore.info("[SourceCheck] ALLOWED — no file provider in path")
        return true
    }
    #endif

    func openExternalFile(at url: URL) async throws -> String? {
        #if !targetEnvironment(macCatalyst)
        if !Self.isURLFromSupportedIOSSource(url) {
            throw NSError(
                domain: "UnifiedListProvider", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported file source on iOS"]
            )
        }
        #endif

        if let existing = allLists.first(where: {
            if case .external(let existingURL) = $0.source { return existingURL.path == url.path }
            return false
        }) {
            AppLogger.general.info("File already open: \(existing.summary.name, privacy: .public)")
            return existing.id
        }

        isDownloadingFile = true
        defer { isDownloadingFile = false }

        let source = FileSource.externalFile(url)
        let document = try await FileStore.shared.openFile(from: source)

        let privateLists = allLists.filter { $0.isPrivate }
        if privateLists.contains(where: { $0.summary.id == document.list.id }) {
            AppLogger.general.warning("ID conflict detected for: \(document.list.name, privacy: .public)")
            await FileStore.shared.closeFile(at: url)
            throw NSError(domain: "UnifiedListProvider", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ID conflict",
                "url": url, "document": document
            ])
        }

        if let existing = allLists.first(where: {
            guard !$0.isPrivate, !$0.isPermanentlyUnavailable, let origId = $0.originalFileId else { return false }
            return origId == document.list.id
        }) {
            AppLogger.general.warning("Duplicate list ID detected for: \(document.list.name, privacy: .public)")
            await FileStore.shared.closeFile(at: url)
            throw NSError(domain: "UnifiedListProvider", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Duplicate list ID",
                "existingListId": existing.id,
                "existingListName": existing.summary.name
            ])
        }

        let runtimeId = "external:\(url.path)"
        var modifiedSummary = document.list
        modifiedSummary.id = runtimeId
        let isReadOnly = !FileStore.isFileWritable(at: url)

        let newList = UnifiedList(
            id: runtimeId, source: .external(url),
            summary: modifiedSummary, originalFileId: document.list.id, isReadOnly: isReadOnly
        )
        allLists.append(newList)
        externalLabels[url] = document.labels
        saveStatus[runtimeId] = .saved

        AppLogger.general.info("Opened and selected: \(newList.summary.name, privacy: .public)")
        return newList.id
    }

    // MARK: - Items

    func fetchItems(for list: UnifiedList) async throws -> [ListItem] {
        if list.summary.id == ExampleData.welcomeListId { return ExampleData.welcomeItems }
        let document = try await openDocument(for: list)
        return document.items
    }

    /// Cache-first read for display purposes. Never blocks on network or sync, never
    /// throws. Returns whatever the local cache has; if no cache, kicks off an async
    /// load and returns an empty array. The Today view and reminder enumeration must
    /// use this — they need to keep working even when the server is unreachable or
    /// a list is in transient-unavailable state.
    func fetchItemsForDisplay(for list: UnifiedList) async -> [ListItem] {
        if list.summary.id == ExampleData.welcomeListId { return ExampleData.welcomeItems }
        return await openDocumentForDisplay(for: list)?.items ?? []
    }

    /// Like `fetchItemsForDisplay` but distinguishes "cache exists and is empty" from
    /// "cache miss (couldn't read)". Returns `nil` on cache miss. Reminder reconciliation
    /// uses this signal to avoid cancelling pending notifications for lists whose
    /// state we don't actually know (see `ReminderManager.reconcileWithBudget`).
    func fetchItemsForReconcile(for list: UnifiedList) async -> [ListItem]? {
        if list.summary.id == ExampleData.welcomeListId { return ExampleData.welcomeItems }
        return await openDocumentForDisplay(for: list)?.items
    }

    /// Whether the list's local cache is "live" — verified against the source of truth
    /// and not lagging behind any pending local mutation.
    ///
    /// A list is live iff:
    ///   - it isn't in `syncPendingListIDs` (the last server probe succeeded), AND
    ///   - for Nextcloud lists, there's no pending upload waiting to drain.
    ///
    /// Reminder reconciliation uses this signal to decide which lists' cached state
    /// is trustworthy enough to drive cancellation. A non-live cache may still be
    /// missing a reminder the user just set (disk write in flight, server roundtrip
    /// not yet completed, fresh process with empty memCache), so cancelling pending
    /// notifications based on it can silently drop a reminder the OS has scheduled.
    func isCacheLive(for list: UnifiedList) async -> Bool {
        if syncPendingListIDs.contains(list.id) { return false }
        if case .nextcloud(_, let remotePath) = list.source {
            if await NextcloudManager.shared.hasPendingUpload(remotePath: remotePath) {
                return false
            }
        }
        return true
    }

    /// Cache-first label read. Non-throwing companion to `fetchItemsForDisplay`.
    func fetchLabelsForDisplay(for list: UnifiedList) async -> [ListLabel] {
        if list.summary.id == ExampleData.welcomeListId { return ExampleData.welcomeLabels }
        if case .external(let url) = list.source, let cached = externalLabels[url] {
            return cached
        }
        if case .nextcloud(_, let remotePath) = list.source, let cached = nextcloudLabels[remotePath] {
            return cached
        }
        guard let doc = await openDocumentForDisplay(for: list) else { return [] }
        cacheLabels(doc.labels, for: list)
        return doc.labels
    }

    /// Sync-then-read for edit flows. Use when the caller needs the freshest version
    /// available (e.g. about to write). Falls back to whatever's cached if sync fails,
    /// so editors don't refuse to open lists during transient errors.
    func fetchItemsForEdit(for list: UnifiedList) async throws -> [ListItem] {
        try? await syncIfNeeded(for: list)
        return try await fetchItems(for: list)
    }

    /// Returns a document from local caches only (in-memory → on-disk → nil).
    /// Schedules an async refresh in the background; UI observers receive an
    /// `externalListChanged` notification when the refresh completes.
    private func openDocumentForDisplay(for list: UnifiedList) async -> ListDocument? {
        switch list.source {
        case .nextcloud(_, let remotePath):
            if let doc = await NextcloudManager.shared.openFileFromAnyCache(remotePath: remotePath) {
                Task { try? await self.syncIfNeeded(for: list) }
                return doc
            }
            // No cache yet — schedule a load, return empty for this read
            Task { try? await self.syncIfNeeded(for: list) }
            return nil

        case .privateICloud(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            if let cached = await FileStore.shared.getLastKnownDocument(at: url) {
                return cached
            }
            if let onDisk = await FileStore.shared.openFileFromDisk(at: url) {
                return onDisk
            }
            Task {
                _ = try? await FileStore.shared.openFile(from: .privateList(listId))
                NotificationCenter.default.post(name: .externalListChanged, object: list.id)
            }
            return nil

        case .external(let url):
            if let cached = await FileStore.shared.getLastKnownDocument(at: url) {
                return cached
            }
            if let onDisk = await FileStore.shared.openFileFromDisk(at: url) {
                return onDisk
            }
            Task {
                _ = try? await FileStore.shared.openFile(from: .externalFile(url))
                NotificationCenter.default.post(name: .externalListChanged, object: list.id)
            }
            return nil
        }
    }

    func addItem(_ item: ListItem, to list: UnifiedList) async throws {
        var document = try await openDocumentForMutation(for: list)
        document.items.append(item)
        await cacheDocument(document, for: list)
    }

    func syncIfNeeded(for list: UnifiedList) async throws {
        guard !activeSyncs.contains(list.id) else {
            AppLogger.sync.debug("[Sync] Already syncing \(list.summary.name, privacy: .public), skipping")
            return
        }

        // Nextcloud sync path
        if case .nextcloud(let accountId, let remotePath) = list.source {
            let hasPending = await NextcloudManager.shared.hasPendingUpload(remotePath: remotePath)
            do {
                // checkFileChanged throws NCError.notFound if the file was deleted/moved on the server
                let changeResult = try await NextcloudManager.shared.checkFileChanged(remotePath: remotePath)
                // Only clear sync-pending when the server actually responded
                if changeResult != .unreachable {
                    syncPendingListIDs.remove(list.id)
                }
                let hasChanged = changeResult == .changed
                guard hasPending || hasChanged else { return }

                AppLogger.sync.debug("[Sync] Nextcloud sync needed for \(list.summary.name, privacy: .public) (pending=\(hasPending), changed=\(hasChanged))")
                activeSyncs.insert(list.id)
                defer { activeSyncs.remove(list.id) }

                let mergedDoc = try await NextcloudManager.shared.syncFile(remotePath: remotePath)
                await NextcloudManager.shared.updateCache(mergedDoc, remotePath: remotePath)
                nextcloudLabels[remotePath] = mergedDoc.labels

                if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                    var updatedList = allLists[index]
                    updatedList.summary = mergedDoc.list
                    updatedList.summary.id = list.id
                    allLists[index] = updatedList
                }
                await ReminderManager.reconcile(items: mergedDoc.items, listName: list.summary.name, listId: list.id)
                // Notify the open list view to reload with the latest merged content
                NotificationCenter.default.post(name: .externalListChanged, object: list.id)
            } catch NCError.notFound {
                // File was deleted or moved on the server — mark as unavailable in the sidebar
                if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                    let serverHost = accountId.components(separatedBy: "@").last ?? accountId
                    let fileName = remotePath.split(separator: "/").last.map(String.init) ?? remotePath
                    let bookmark = UnavailableBookmark(
                        id: list.id, originalPath: remotePath, reason: .fileNotFound,
                        fileName: fileName.replacingOccurrences(of: ".listie", with: ""),
                        folderName: serverHost
                    )
                    var updated = allLists[index]
                    updated.isReadOnly = true
                    updated.unavailableBookmark = bookmark
                    allLists[index] = updated
                    AppLogger.nextcloud.warning("[NC] File removed from server, marked unavailable: \(remotePath, privacy: .public)")
                }
            }
            // Other errors (network, auth) are swallowed — transient failures shouldn't mark as unavailable
            return
        }

        // FileStore sync path (privateICloud + external)
        guard let fileSource = list.source.asFileSource else { return }

        if await FileStore.shared.hasFileChanged(for: fileSource) {
            AppLogger.sync.debug("File changed, syncing: \(list.summary.name, privacy: .public)")
            activeSyncs.insert(list.id)
            defer { activeSyncs.remove(list.id) }

            let mergedDoc = try await FileStore.shared.syncFile(from: fileSource)

            switch list.source {
            case .privateICloud(let listId):
                let url = await iCloudContainerManager.shared.fileURL(for: listId)
                await FileStore.shared.updateCache(mergedDoc, at: url)
            case .external(let url):
                await FileStore.shared.updateCache(mergedDoc, at: url)
                externalLabels[url] = mergedDoc.labels
            default: break
            }

            if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                var updatedList = allLists[index]
                updatedList.summary = mergedDoc.list
                updatedList.summary.id = list.id
                allLists[index] = updatedList
            }
            await ReminderManager.reconcile(items: mergedDoc.items, listName: list.summary.name, listId: list.id)
        }
    }

    func syncAllLists() async {
        // Re-establish the NextcloudKit URLSession — iOS may have invalidated it
        // during extended suspension (deep sleep). This is a no-op if not connected.
        let hasNCLists = allLists.contains { $0.isNextcloud }
        if hasNCLists { isRecoveringSession = true }

        await NextcloudManager.shared.reactivateSession()

        // First, retry any unavailable Nextcloud lists — they may have been marked unavailable
        // due to transient errors (network down, app killed while offline, etc.)
        await retryUnavailableNextcloudLists()

        if hasNCLists { isRecoveringSession = false }

        // Layer 4: replay any pending mutations that were captured offline. Runs alongside
        // the existing pendingUploads retry queue (NextcloudManager) — both layers can
        // attempt the same upload independently; whichever succeeds first wins.
        await drainMutationLogIfEnabled()

        for list in allLists where !list.isReadOnly {
            do { try await syncIfNeeded(for: list) }
            catch { AppLogger.sync.warning("Sync skipped for \(list.id, privacy: .public): \(error, privacy: .public)") }
        }
    }

    /// Layer 4: replay queued mutations. Called from `syncAllLists` when the app foregrounds
    /// or sync is explicitly triggered. Default-off via the feature flag; safe to leave on
    /// because each entry's `persistDocument` op goes through the same merge logic as a
    /// direct edit (NextcloudManager.saveFile / FileStore.saveFile both perform ETag/version
    /// merges before writing).
    func drainMutationLogIfEnabled() async {
        guard MutationLog.isEnabled else { return }
        let pending = await MutationLog.shared.snapshot()
        guard !pending.isEmpty else { return }
        AppLogger.sync.info("[MutationLog] Replaying \(pending.count) pending mutation(s)")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for entry in pending {
            guard let list = allLists.first(where: { $0.id == entry.listId }) else {
                // The list is gone (user deleted or it became permanently unavailable).
                // Drop the entry — no destination to replay to.
                await MutationLog.shared.markCompleted(entry.id)
                continue
            }
            switch entry.op {
            case .persistDocument(let payload):
                guard let doc = try? decoder.decode(ListDocument.self, from: payload) else {
                    AppLogger.sync.warning("[MutationLog] Failed to decode payload for \(entry.id, privacy: .public)")
                    await MutationLog.shared.recordAttempt(for: entry.id, error: NSError(domain: "MutationLog", code: 1))
                    continue
                }
                do {
                    try await saveFile(doc, for: list)
                    await MutationLog.shared.markCompleted(entry.id)
                } catch {
                    await MutationLog.shared.recordAttempt(for: entry.id, error: error)
                }
            case .advanceReminder:
                // Sentinel — the document-level persist already covers this path for now.
                await MutationLog.shared.markCompleted(entry.id)
            }
        }
    }

    func syncAllExternalLists() async { await syncAllLists() }

    /// Attempts to recover Nextcloud lists that were marked unavailable due to transient errors.
    /// Skips lists that were unavailable because the file was deleted on the server (.fileNotFound).
    private func retryUnavailableNextcloudLists() async {
        let unavailableNC = allLists.filter { list in
            guard list.isUnavailable, list.isNextcloud else { return false }
            // Don't retry files confirmed deleted on the server
            if let reason = list.unavailableBookmark?.reason, case .fileNotFound = reason { return false }
            return true
        }
        guard !unavailableNC.isEmpty else { return }

        AppLogger.nextcloud.info("[NC] Retrying \(unavailableNC.count) unavailable Nextcloud list(s)")

        for list in unavailableNC {
            guard case .nextcloud(let accountId, let remotePath) = list.source else { continue }
            do {
                let doc = try await NextcloudManager.shared.openFile(remotePath: remotePath, forceReload: true)
                var summary = doc.list
                summary.id = list.id
                nextcloudLabels[remotePath] = doc.labels
                if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                    allLists[index] = UnifiedList(
                        id: list.id,
                        source: .nextcloud(accountId: accountId, remotePath: remotePath),
                        summary: summary,
                        originalFileId: doc.list.id,
                        isReadOnly: false
                    )
                    saveStatus[list.id] = .saved
                    AppLogger.nextcloud.info("[NC] Recovered unavailable list: \(list.summary.name, privacy: .public)")
                }
            } catch {
                AppLogger.nextcloud.debug("[NC] Retry still failing for \(list.summary.name, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    func updateItem(_ item: ListItem, in list: UnifiedList, immediate: Bool = false) async throws {
        var document = try await openDocumentForMutation(for: list)
        if let index = document.items.firstIndex(where: { $0.id == item.id }) {
            document.items[index] = item
            await cacheDocument(document, for: list, immediate: immediate)
        }
    }

    /// Awaits the most recent autosave Task for this list, blocking until the save
    /// (or queue-for-retry) completes. Notification-action flows call this after
    /// `updateItem(..., immediate: true)` to ensure the upload is attempted — or at
    /// minimum landed in `pendingUploads` — before iOS suspends the process.
    func awaitPendingSave(for list: UnifiedList) async {
        await autosaveTasks[list.id]?.value
    }

    func deleteItem(_ item: ListItem, from list: UnifiedList) async throws {
        if item.reminderDate != nil { ReminderManager.cancelReminder(for: item) }

        var document = try await openDocumentForMutation(for: list)
        if let index = document.items.firstIndex(where: { $0.id == item.id }) {
            document.items[index].isDeleted = true
            document.items[index].deletedAt = Date()
            document.items[index].modifiedAt = Date()
            document.items[index].lastChangeField = "deleted"
            document.items[index].reminderDate = nil
            await cacheDocument(document, for: list)
        }
    }

    func fetchDeletedItems(for list: UnifiedList) async throws -> [ListItem] {
        let document = try await openDocumentForMutation(for: list)
        return document.items.filter { $0.isDeleted }
    }

    func restoreItem(_ item: ListItem, in list: UnifiedList) async throws {
        var document = try await openDocumentForMutation(for: list)
        if let index = document.items.firstIndex(where: { $0.id == item.id }) {
            document.items[index].isDeleted = false
            document.items[index].deletedAt = nil
            document.items[index].modifiedAt = Date()
            document.items[index].lastChangeField = "restored"
            await cacheDocument(document, for: list)
        }
    }

    func permanentlyDeleteItem(_ item: ListItem, from list: UnifiedList) async throws {
        var document = try await openDocumentForMutation(for: list)
        document.items.removeAll { $0.id == item.id }
        await cacheDocument(document, for: list)
    }

    // MARK: - Labels

    func fetchLabels(for list: UnifiedList) async throws -> [ListLabel] {
        if list.summary.id == ExampleData.welcomeListId { return ExampleData.welcomeLabels }

        // Return cached labels if available
        if case .external(let url) = list.source, let cached = externalLabels[url] {
            return cached
        }
        if case .nextcloud(_, let remotePath) = list.source, let cached = nextcloudLabels[remotePath] {
            return cached
        }

        let document = try await openDocument(for: list)
        cacheLabels(document.labels, for: list)
        return document.labels
    }

    /// Returns all share presets stored on the list's document, including tombstones.
    /// Callers that only want active presets should filter `!$0.isDeleted` themselves.
    func fetchSharePresets(for list: UnifiedList) async throws -> [SharePreset] {
        if list.summary.id == ExampleData.welcomeListId { return [] }
        let document = try await openDocument(for: list)
        return document.sharePresets
    }

    func createLabel(_ label: ListLabel, for list: UnifiedList) async throws {
        var document = try await openDocument(for: list)
        document.labels.append(label)
        document.deletedLabelIDs.removeAll { $0 == label.id }
        document.list.modifiedAt = Date()
        cacheLabels(document.labels, for: list)
        await cacheDocument(document, for: list)
    }

    func updateLabel(_ label: ListLabel, for list: UnifiedList) async throws {
        AppLogger.labels.debug("[updateLabel] Starting update for label: \(label.name, privacy: .public)")

        var document = try await openDocument(for: list)
        AppLogger.labels.debug("[updateLabel] Document has \(document.labels.count, privacy: .public) labels")

        if let index = document.labels.firstIndex(where: { $0.id == label.id }) {
            document.labels[index] = label
            document.list.modifiedAt = Date()
            cacheLabels(document.labels, for: list)
            // Update document cache before saving so any merge logic sees the new label,
            // not the stale pre-edit version (fixes Nextcloud Stage-1 merge discarding edits).
            await updateDocumentCache(document, for: list)
            try await saveFile(document, for: list)
            AppLogger.labels.info("[updateLabel] Label saved successfully")
        } else {
            AppLogger.labels.warning("[updateLabel] Label not found in document!")
        }
    }

    func deleteLabel(_ label: ListLabel, from list: UnifiedList) async throws {
        AppLogger.labels.debug("[deleteLabel] Starting delete for label: \(label.name, privacy: .public)")

        var document = try await openDocument(for: list)
        AppLogger.labels.debug("[deleteLabel] Document has \(document.labels.count, privacy: .public) labels before delete")

        document.labels.removeAll { $0.id == label.id }
        if !document.deletedLabelIDs.contains(label.id) {
            document.deletedLabelIDs.append(label.id)
        }
        document.list.modifiedAt = Date()
        cacheLabels(document.labels, for: list)
        // Update document cache before saving so any merge logic sees the deletion,
        // not the stale pre-delete version (fixes Nextcloud Stage-1 merge restoring deleted labels).
        await updateDocumentCache(document, for: list)
        try await saveFile(document, for: list)
        AppLogger.labels.info("[deleteLabel] Label deleted successfully")
    }

    func updateLabelOrder(_ order: [String], for list: UnifiedList) async throws {
        var document = try await openDocument(for: list)
        document.list.labelOrder = order
        document.list.modifiedAt = Date()
        try await saveFile(document, for: list)
    }

    // MARK: - List Management

    func updateList(_ list: UnifiedList, name: String, icon: String?, hiddenLabels: [String]?, labelOrder: [String]? = nil, enableMapData: Bool? = nil) async throws {
        AppLogger.general.debug("[updateList] Loading document...")
        var document = try await openDocument(for: list)
        AppLogger.general.debug("[updateList] Document has \(document.labels.count, privacy: .public) labels, \(document.items.count, privacy: .public) items")

        document.list.name = name
        document.list.icon = icon
        document.list.hiddenLabels = hiddenLabels
        document.list.labelOrder = labelOrder
        // Only update enableMapData when explicitly passed by the caller.
        // nil (the default) means "this caller doesn't manage this field — leave it unchanged."
        // ListSettingsView always passes true or false; other callers (WelcomeView, etc.) pass nil.
        if let enableMapData {
            document.list.enableMapData = enableMapData ? true : nil  // store false as nil for JSON compactness
        }
        document.list.modifiedAt = Date()

        if case .privateICloud = list.source {
            let listId = list.privateListId!
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            await FileStore.shared.updateCache(document, at: url)
            try await saveFile(document, for: list)
            if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                var updatedList = allLists[index]
                updatedList.summary = document.list
                allLists[index] = updatedList
            }
        } else {
            await cacheDocument(document, for: list)
            try await saveFile(document, for: list)
        }
        AppLogger.general.info("[updateList] List updated successfully")
    }

    /// Replace the saved share presets for a list and persist.
    /// Does not bump `document.list.modifiedAt` — presets carry their own per-row
    /// `modifiedAt` and merge independently of summary fields.
    func updateSharePresets(_ list: UnifiedList, presets: [SharePreset]) async throws {
        var document = try await openDocument(for: list)
        document.sharePresets = presets

        if case .privateICloud = list.source {
            let listId = list.privateListId!
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            await FileStore.shared.updateCache(document, at: url)
            try await saveFile(document, for: list)
        } else {
            await cacheDocument(document, for: list)
            try await saveFile(document, for: list)
        }
    }

    func deleteList(_ list: UnifiedList) async throws {
        switch list.source {
        case .privateICloud(let listId):
            try await FileStore.shared.deletePrivateList(listId)
        case .external(let url):
            await FileStore.shared.closeFile(at: url)
            externalLabels.removeValue(forKey: url)
        case .nextcloud(_, let remotePath):
            await NextcloudManager.shared.removeLocalCache(remotePath: remotePath)
            removeNextcloudFileRecord(remotePath: remotePath)
            nextcloudLabels.removeValue(forKey: remotePath)
        }
        allLists.removeAll { $0.id == list.id }
        saveStatus.removeValue(forKey: list.id)
    }

    func removeUnavailableList(_ list: UnifiedList) async {
        guard list.unavailableBookmark != nil else { return }
        if case .nextcloud(_, let remotePath) = list.source {
            await NextcloudManager.shared.removeLocalCache(remotePath: remotePath)
            removeNextcloudFileRecord(remotePath: remotePath)
        } else {
            guard let bookmark = list.unavailableBookmark else { return }
            await FileStore.shared.removeUnavailableBookmark(bookmark)
        }
        allLists.removeAll { $0.id == list.id }
    }

    // MARK: - Autosave

    private func triggerAutosave(for list: UnifiedList, document: ListDocument, immediate: Bool = false) {
        autosaveTasks[list.id]?.cancel()

        autosaveTasks[list.id] = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
            }
            await MainActor.run { saveStatus[list.id] = .saving }

            do {
                try await saveFile(document, for: list)
            } catch {
                // `saveFile` has already classified the error and set the right status
                // (pendingSync / syncFailed / saveFailed). Just log here — overwriting
                // would lose the classification.
                AppLogger.fileStore.warning("[autosave] save threw: \(error, privacy: .public)")
            }
        }
    }

    /// Unified save method that dispatches to the correct backend.
    private func saveFile(_ document: ListDocument, for list: UnifiedList) async throws {
        AppLogger.fileStore.debug("[saveFile] Saving document with \(document.labels.count, privacy: .public) labels, \(document.items.count, privacy: .public) items")

        var docToSave = document
        if let originalId = list.originalFileId {
            docToSave.list.id = originalId
        }

        // Nextcloud: delegate to NextcloudManager (offline-first)
        if case .nextcloud(_, let remotePath) = list.source {
            do {
                let outcome = try await NextcloudManager.shared.saveFile(docToSave, to: remotePath)
                let resolved: SaveStatus = (outcome == .uploaded) ? .saved : .pendingSync
                await MainActor.run { saveStatus[list.id] = resolved }
                AppLogger.nextcloud.info("[NC] Save \(outcome == .uploaded ? "uploaded" : "queued", privacy: .public): \(remotePath, privacy: .public)")
                // Reload the list view in case saveFile merged in server-side changes
                NotificationCenter.default.post(name: .externalListChanged, object: list.id)
                Task { await EventKitManager.shared.syncIfEnabled(provider: self) }
            } catch {
                // Classify: network/transient → pendingSync (data safe in cache),
                // anything else → syncFailed (won't auto-recover; needs attention).
                let status = Self.classifySaveError(error)
                await MainActor.run { saveStatus[list.id] = status }
                throw error
            }
            return
        }

        // FileStore path
        guard let fileSource = list.source.asFileSource else { return }

        do {
            try await FileStore.shared.saveFile(docToSave, to: fileSource)
            await MainActor.run { saveStatus[list.id] = .saved }
            AppLogger.fileStore.info("[saveFile] Save successful")
            Task { await EventKitManager.shared.syncIfEnabled(provider: self) }
        } catch {
            let nsError = error as NSError
            AppLogger.fileStore.error("Save error: \(error, privacy: .public)")
            AppLogger.fileStore.debug("Domain: \(nsError.domain, privacy: .public)")
            AppLogger.fileStore.debug("Code: \(nsError.code, privacy: .public)")

            if case .external(let url) = list.source {
                let isWritable = FileStore.isFileWritable(at: url)
                if !isWritable {
                    AppLogger.fileStore.warning("File became read-only, reverting changes and reloading from disk")
                    do {
                        let cleanDocument = try await FileStore.shared.openFile(from: .externalFile(url), forceReload: true)
                        await FileStore.shared.updateCache(cleanDocument, at: url)
                        await MainActor.run {
                            externalLabels[url] = cleanDocument.labels
                        }
                        if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                            var updatedList = allLists[index]
                            updatedList.isReadOnly = true
                            updatedList.summary = cleanDocument.list
                            updatedList.summary.id = list.id
                            allLists[index] = updatedList
                        }
                        await MainActor.run {
                            // Actual data loss — the user's edit was discarded because the file
                            // became read-only mid-flight. This is the strongest error state.
                            saveStatus[list.id] = .saveFailed("File is read-only. Changes discarded.")
                        }
                        NotificationCenter.default.post(name: .externalListChanged, object: list.id)
                    } catch {
                        AppLogger.fileStore.error("Failed to reload clean version: \(error, privacy: .public)")
                    }
                } else {
                    // FileStore (iCloud / external) write threw: local write didn't succeed.
                    // This is genuinely data-at-risk because there's no NC-style pendingUploads
                    // queue to retry from — NSFileCoordinator handles iCloud transport opaquely.
                    await MainActor.run { saveStatus[list.id] = .saveFailed(error.localizedDescription) }
                }
            } else {
                await MainActor.run { saveStatus[list.id] = .saveFailed(error.localizedDescription) }
            }
            throw error
        }
    }

    // MARK: - Helper

    func reloadList(_ list: UnifiedList) async {
        do {
            let document = try await openDocument(for: list, forceReload: true)
            if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                var updatedList = list
                updatedList.summary = document.list
                updatedList.summary.id = list.id
                allLists[index] = updatedList
                cacheLabels(document.labels, for: list)
            }
        } catch {
            AppLogger.fileStore.error("Failed to reload list: \(error, privacy: .public)")
        }
    }

    func checkExternalFilesForChanges() async { await syncAllExternalLists() }

    /// Returns true when the list has local edits that haven't been pushed to the
    /// remote yet — used by the per-list sync chip to distinguish "synced" from
    /// "pending sync" (e.g. user edited in airplane mode).
    /// - For NextCloud: checks `NextcloudManager.pendingUploads`
    /// - For all sources: checks the Layer 4 mutation log
    func hasPendingSync(for list: UnifiedList) async -> Bool {
        // NC: the upload retry queue is the source of truth for offline writes
        if case .nextcloud(_, let remotePath) = list.source {
            if await NextcloudManager.shared.hasPendingUpload(remotePath: remotePath) {
                return true
            }
        }
        // Mutation log (when enabled): per-source pending writes for any backend
        if MutationLog.isEnabled,
           await MutationLog.shared.depth(for: list.id) > 0 {
            return true
        }
        // Save-status set during a save attempt may also indicate work in flight
        switch saveStatus[list.id] ?? .saved {
        case .saving, .unsaved, .pendingSync, .syncFailed, .saveFailed:
            return true
        case .saved:
            return false
        }
    }

    /// Layer 5: lightweight health snapshot. Counts lists by state, mutation log depth,
    /// and per-source availability. Logged as a structured event so Console.app filters
    /// can answer "after the user backgrounded the app for X hours, what did state look
    /// like on resume?" without an attached debugger.
    func runHealthCheck() async {
        let total = allLists.count
        let nc = allLists.filter { $0.isNextcloud }.count
        let iCloud = allLists.filter { $0.isPrivate }.count
        let external = allLists.filter { $0.isExternal }.count
        let permanent = allLists.filter { $0.isPermanentlyUnavailable }.count
        let transient = allLists.filter { $0.hasTransientSyncError }.count
        let mutationDepth = await MutationLog.shared.depth()

        AppLogger.background.info(
            "event=\(SyncEvent.healthCheckRan, privacy: .public) total=\(total) nextcloud=\(nc) icloud=\(iCloud) external=\(external) permanent_unavailable=\(permanent) transient_unavailable=\(transient) mutation_log_depth=\(mutationDepth)"
        )
    }

    /// Layer 5: combined state snapshot from all managers. Used by the long-press debug
    /// action on a list's sync chip — copies a single multi-line string to the pasteboard
    /// for the user to paste into a bug report. Cheap; safe to call from main thread.
    func combinedStateSnapshot() async -> String {
        let nc = await NextcloudManager.shared.stateSnapshot()
        let iCloud = await iCloudContainerManager.shared.stateSnapshot()
        let listsSummary = allLists.map { list -> String in
            let kind: String
            switch list.source {
            case .nextcloud: kind = "NC"
            case .privateICloud: kind = "iCloud"
            case .external: kind = "external"
            }
            let state: String
            if list.isPermanentlyUnavailable { state = "permanent_unavailable" }
            else if list.hasTransientSyncError { state = "transient_sync_error" }
            else if list.isReadOnly { state = "read_only" }
            else { state = "ok" }
            return "  - [\(kind)] \(list.summary.name) — \(state)"
        }.joined(separator: "\n")

        return """
        \(nc)

        \(iCloud)

        [Lists] \(allLists.count) total
        \(listsSummary)
        """
    }

    func prepareExport(for list: UnifiedList) async throws -> ListDocument {
        let items = try await fetchItems(for: list)
        let labels = try await fetchLabels(for: list)
        var exportList = list.summary
        if let originalId = list.originalFileId { exportList.id = originalId }
        return ListDocument(list: exportList, items: items, labels: labels)
    }

    // MARK: - Auto-cleanup

    func cleanupOldDeletedItems(for list: UnifiedList) async {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

        do {
            let deletedItems = try await fetchDeletedItems(for: list)
            for item in deletedItems {
                let deletionDate = item.deletedAt ?? item.modifiedAt
                if deletionDate < thirtyDaysAgo {
                    AppLogger.items.debug("Auto-deleting old item: \(item.note, privacy: .public) (deleted \(deletionDate, privacy: .public))")
                    do { try await permanentlyDeleteItem(item, from: list) }
                    catch { AppLogger.items.warning("Failed to auto-delete item \(item.id, privacy: .public): \(error, privacy: .public)") }
                }
            }
        } catch {
            AppLogger.items.error("Failed to cleanup old items: \(error, privacy: .public)")
        }
    }
}
