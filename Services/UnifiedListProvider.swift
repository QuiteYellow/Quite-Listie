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
}


struct UnifiedList: Identifiable, Hashable {
    let id: String
    let source: ListSource
    var summary: ShoppingListSummary

    var originalFileId: String?
    var isReadOnly: Bool = false

    /// If non-nil, this file is unavailable and cannot be opened
    var unavailableBookmark: UnavailableBookmark?
    var isUnavailable: Bool { unavailableBookmark != nil }

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

    var allLists: [UnifiedList] = []
    var saveStatus: [String: SaveStatus] = [:]

    // REACTIVE label caches
    var externalLabels: [URL: [ShoppingLabel]] = [:]
    var nextcloudLabels: [String: [ShoppingLabel]] = [:]  // keyed by remotePath

    var isDownloadingFile = false
    var currentlyLoadingFile: String? = nil
    var loadingProgress: (current: Int, total: Int) = (0, 0)
    var isInitialLoad: Bool = true

    private var autosaveTasks: [String: Task<Void, Never>] = [:]
    private var activeSyncs: Set<String> = []

    enum SaveStatus { case saved, saving, unsaved, failed(String) }

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

    /// Writes a document to the appropriate backend cache and triggers autosave.
    private func cacheDocument(_ doc: ListDocument, for list: UnifiedList) async {
        switch list.source {
        case .privateICloud(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            await FileStore.shared.updateCache(doc, at: url)
            triggerAutosave(for: list, document: doc)
        case .external(let url):
            await FileStore.shared.updateCache(doc, at: url)
            triggerAutosave(for: list, document: doc)
        case .nextcloud(_, let remotePath):
            await NextcloudManager.shared.updateCache(doc, remotePath: remotePath)
            triggerAutosave(for: list, document: doc)
        }
    }

    /// Caches label array into the per-backend reactive dictionary.
    private func cacheLabels(_ labels: [ShoppingLabel], for list: UnifiedList) {
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
            if case .nextcloud(let accountId, let path) = $0.source, path == remotePath {
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
                do {
                    let listId = url.deletingPathExtension().lastPathComponent
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
                    AppLogger.fileStore.error("Failed to load private list \(url, privacy: .public): \(error, privacy: .public)")
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

                let placeholderSummary = ShoppingListSummary(
                    id: runtimeId, name: fileName, modifiedAt: Date(), icon: "exclamationmark.triangle"
                )
                let unavailableBookmark = UnavailableBookmark(
                    id: url.path, originalPath: url.path,
                    reason: .bookmarkInvalid(error), fileName: fileName, folderName: folderName
                )
                unified.append(UnifiedList(
                    id: runtimeId, source: .external(url),
                    summary: placeholderSummary, originalFileId: nil,
                    isReadOnly: true, unavailableBookmark: unavailableBookmark
                ))
            }
        }

        currentlyLoadingFile = nil
        loadingProgress = (0, 0)
        isInitialLoad = false

        // Unavailable external files
        let unavailableBookmarks = await FileStore.shared.getUnavailableBookmarks()
        for bookmark in unavailableBookmarks {
            let runtimeId = "unavailable:\(bookmark.id)"
            let placeholderSummary = ShoppingListSummary(
                id: runtimeId, name: bookmark.fileName, modifiedAt: Date(),
                icon: bookmark.reason.icon
            )
            unified.append(UnifiedList(
                id: runtimeId, source: .privateICloud(runtimeId),
                summary: placeholderSummary, originalFileId: nil,
                isReadOnly: true, unavailableBookmark: bookmark
            ))
        }

        // Nextcloud lists
        unified.append(contentsOf: await loadNextcloudLists())

        allLists = unified.sorted {
            $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending
        }
        for list in unified where saveStatus[list.id] == nil {
            saveStatus[list.id] = .saved
        }

        Task { await EventKitManager.shared.syncIfEnabled(provider: self) }
    }

    // MARK: - Nextcloud list loading

    private static let nextcloudFilesKey = "com.listie.nextcloud-files"

    /// Loads all known Nextcloud files from UserDefaults + fetches their summaries.
    private func loadNextcloudLists() async -> [UnifiedList] {
        let records = loadNextcloudFileRecords()
        guard !records.isEmpty else { return [] }

        var result: [UnifiedList] = []
        for record in records {
            let accountId  = record["accountId"] ?? ""
            let remotePath = record["remotePath"] ?? ""
            guard !accountId.isEmpty, !remotePath.isEmpty else { continue }

            let runtimeId = "nextcloud:\(accountId):\(remotePath)"
            do {
                let doc = try await NextcloudManager.shared.openFile(remotePath: remotePath)
                var summary = doc.list
                summary.id = runtimeId
                nextcloudLabels[remotePath] = doc.labels
                result.append(UnifiedList(
                    id: runtimeId,
                    source: .nextcloud(accountId: accountId, remotePath: remotePath),
                    summary: summary,
                    originalFileId: doc.list.id,
                    isReadOnly: false
                ))
            } catch {
                AppLogger.nextcloud.warning("[NC] Failed to load \(remotePath, privacy: .public): \(error, privacy: .public)")
                let fileName = remotePath.split(separator: "/").last.map(String.init) ?? remotePath
                let displayName = fileName.replacingOccurrences(of: ".listie", with: "")
                let serverHost = accountId.components(separatedBy: "@").last ?? accountId
                let reason: UnavailableBookmark.UnavailabilityReason
                if case NCError.notFound = error {
                    reason = .fileNotFound
                } else {
                    reason = .bookmarkInvalid(error)
                }
                let bookmark = UnavailableBookmark(
                    id: runtimeId,
                    originalPath: remotePath,
                    reason: reason,
                    fileName: displayName,
                    folderName: serverHost
                )
                let placeholderSummary = ShoppingListSummary(
                    id: runtimeId, name: displayName,
                    modifiedAt: Date(), icon: "cloud"
                )
                result.append(UnifiedList(
                    id: runtimeId,
                    source: .nextcloud(accountId: accountId, remotePath: remotePath),
                    summary: placeholderSummary,
                    originalFileId: nil,
                    isReadOnly: true,
                    unavailableBookmark: bookmark
                ))
            }
        }
        return result
    }

    /// Opens a Nextcloud file and adds it to `allLists`.
    func openNextcloudFile(remotePath: String) async throws -> String {
        guard let creds = await NextcloudManager.shared.credentials else {
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

    func fetchItems(for list: UnifiedList) async throws -> [ShoppingItem] {
        if list.summary.id == ExampleData.welcomeListId { return ExampleData.welcomeItems }
        let document = try await openDocument(for: list)
        return document.items
    }

    func addItem(_ item: ShoppingItem, to list: UnifiedList) async throws {
        var document = try await openDocument(for: list)
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
                // hasFileChanged throws NCError.notFound if the file was deleted/moved on the server
                let hasChanged = try await NextcloudManager.shared.hasFileChanged(remotePath: remotePath)
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
        for list in allLists where !list.isReadOnly {
            do { try await syncIfNeeded(for: list) }
            catch { AppLogger.sync.warning("Sync skipped for \(list.id, privacy: .public): \(error, privacy: .public)") }
        }
    }

    func syncAllExternalLists() async { await syncAllLists() }

    func updateItem(_ item: ShoppingItem, in list: UnifiedList) async throws {
        var document = try await openDocument(for: list)
        if let index = document.items.firstIndex(where: { $0.id == item.id }) {
            document.items[index] = item
            await cacheDocument(document, for: list)
        }
    }

    func deleteItem(_ item: ShoppingItem, from list: UnifiedList) async throws {
        if item.reminderDate != nil { ReminderManager.cancelReminder(for: item) }

        var document = try await openDocument(for: list)
        if let index = document.items.firstIndex(where: { $0.id == item.id }) {
            document.items[index].isDeleted = true
            document.items[index].deletedAt = Date()
            document.items[index].modifiedAt = Date()
            document.items[index].reminderDate = nil
            await cacheDocument(document, for: list)
        }
    }

    func fetchDeletedItems(for list: UnifiedList) async throws -> [ShoppingItem] {
        let document = try await openDocument(for: list)
        return document.items.filter { $0.isDeleted }
    }

    func restoreItem(_ item: ShoppingItem, in list: UnifiedList) async throws {
        var document = try await openDocument(for: list)
        if let index = document.items.firstIndex(where: { $0.id == item.id }) {
            document.items[index].isDeleted = false
            document.items[index].deletedAt = nil
            document.items[index].modifiedAt = Date()
            await cacheDocument(document, for: list)
        }
    }

    func permanentlyDeleteItem(_ item: ShoppingItem, from list: UnifiedList) async throws {
        var document = try await openDocument(for: list)
        document.items.removeAll { $0.id == item.id }
        await cacheDocument(document, for: list)
    }

    // MARK: - Labels

    func fetchLabels(for list: UnifiedList) async throws -> [ShoppingLabel] {
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

    func createLabel(_ label: ShoppingLabel, for list: UnifiedList) async throws {
        var document = try await openDocument(for: list)
        document.labels.append(label)
        document.list.modifiedAt = Date()
        cacheLabels(document.labels, for: list)
        await cacheDocument(document, for: list)
    }

    func updateLabel(_ label: ShoppingLabel, for list: UnifiedList) async throws {
        AppLogger.labels.debug("[updateLabel] Starting update for label: \(label.name, privacy: .public)")

        var document = try await openDocument(for: list)
        AppLogger.labels.debug("[updateLabel] Document has \(document.labels.count, privacy: .public) labels")

        if let index = document.labels.firstIndex(where: { $0.id == label.id }) {
            document.labels[index] = label
            document.list.modifiedAt = Date()
            cacheLabels(document.labels, for: list)
            try await saveFile(document, for: list)
            AppLogger.labels.info("[updateLabel] Label saved successfully")
        } else {
            AppLogger.labels.warning("[updateLabel] Label not found in document!")
        }
    }

    func deleteLabel(_ label: ShoppingLabel, from list: UnifiedList) async throws {
        AppLogger.labels.debug("[deleteLabel] Starting delete for label: \(label.name, privacy: .public)")

        var document = try await openDocument(for: list)
        AppLogger.labels.debug("[deleteLabel] Document has \(document.labels.count, privacy: .public) labels before delete")

        document.labels.removeAll { $0.id == label.id }
        document.list.modifiedAt = Date()
        cacheLabels(document.labels, for: list)
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

    func updateList(_ list: UnifiedList, name: String, icon: String?, hiddenLabels: [String]?, labelOrder: [String]? = nil) async throws {
        AppLogger.general.debug("[updateList] Loading document...")
        var document = try await openDocument(for: list)
        AppLogger.general.debug("[updateList] Document has \(document.labels.count, privacy: .public) labels, \(document.items.count, privacy: .public) items")

        document.list.name = name
        document.list.icon = icon
        document.list.hiddenLabels = hiddenLabels
        document.list.labelOrder = labelOrder
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

    private func triggerAutosave(for list: UnifiedList, document: ListDocument) {
        autosaveTasks[list.id]?.cancel()

        autosaveTasks[list.id] = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { saveStatus[list.id] = .saving }

            do {
                try await saveFile(document, for: list)
            } catch {
                await MainActor.run { saveStatus[list.id] = .failed(error.localizedDescription) }
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
                try await NextcloudManager.shared.saveFile(docToSave, to: remotePath)
                await MainActor.run { saveStatus[list.id] = .saved }
                AppLogger.nextcloud.info("[NC] Save successful: \(remotePath, privacy: .public)")
                // Reload the list view in case saveFile merged in server-side changes
                NotificationCenter.default.post(name: .externalListChanged, object: list.id)
                Task { await EventKitManager.shared.syncIfEnabled(provider: self) }
            } catch {
                await MainActor.run { saveStatus[list.id] = .failed(error.localizedDescription) }
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
                            saveStatus[list.id] = .failed("File is read-only. Changes discarded.")
                        }
                        NotificationCenter.default.post(name: .externalListChanged, object: list.id)
                    } catch {
                        AppLogger.fileStore.error("Failed to reload clean version: \(error, privacy: .public)")
                    }
                } else {
                    await MainActor.run { saveStatus[list.id] = .failed(error.localizedDescription) }
                }
            } else {
                await MainActor.run { saveStatus[list.id] = .failed(error.localizedDescription) }
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
