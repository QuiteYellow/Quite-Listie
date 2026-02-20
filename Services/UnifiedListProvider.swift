//
//  UnifiedListProvider.swift
//  Listie.md
//
//  Unified provider that handles both private (iCloud container) and external files seamlessly
//

import Foundation
import SwiftUI
import os

enum ListSource: Hashable {
    /// Private list stored in the app's iCloud container (or local fallback)
    case privateICloud(String)  // List ID

    /// External file selected by the user from Files app
    case external(URL)

    /// Convert to FileSource for use with FileStore
    var asFileSource: FileSource {
        switch self {
        case .privateICloud(let listId):
            return .privateList(listId)
        case .external(let url):
            return .externalFile(url)
        }
    }
}

extension Notification.Name {
    static let externalFileChanged = Notification.Name("externalFileChanged")
    static let externalListChanged = Notification.Name("externalListChanged")
    static let listSettingsChanged = Notification.Name("listSettingsChanged")
    static let storageLocationChanged = Notification.Name("storageLocationChanged")
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

    /// Whether this is a private list (in app's iCloud container)
    var isPrivate: Bool {
        if case .privateICloud = source { return true }
        return false
    }

    /// Whether this is an external file (user-selected)
    var isExternal: Bool {
        if case .external = source { return true }
        return false
    }

    /// Get the list ID for private lists
    var privateListId: String? {
        if case .privateICloud(let listId) = source { return listId }
        return nil
    }

    static func == (lhs: UnifiedList, rhs: UnifiedList) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
class UnifiedListProvider: ObservableObject {
    
    @Published var allLists: [UnifiedList] = []
    @Published var saveStatus: [String: SaveStatus] = [:]
    
    // REACTIVE cache for external labels
    @Published var externalLabels: [URL: [ShoppingLabel]] = [:]
    
    @Published var isDownloadingFile = false
    @Published var currentlyLoadingFile: String? = nil
    @Published var loadingProgress: (current: Int, total: Int) = (0, 0)
    @Published var isInitialLoad: Bool = true  // Only show loading UI on first load

    private var autosaveTasks: [String: Task<Void, Never>] = [:]

    private var activeSyncs: Set<String> = []  // Track which lists are currently syncing
    
    enum SaveStatus { case saved, saving, unsaved, failed(String) }
    
    // MARK: - Load Lists

    func loadAllLists() async {
        // Single-pass: refresh bookmark availability AND get resolved URLs in one call
        // (eliminates the old pattern of resolving bookmarks 3x on startup)
        let externalURLs = await FileStore.shared.refreshBookmarkAvailability()

        var unified: [UnifiedList] = []
        var seenExternalURLs: Set<String> = []

        // Private lists (from iCloud container or local fallback)
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

        // Add welcome list (read-only example)
        unified.append(UnifiedList(
            id: ExampleData.welcomeListId,
            source: .privateICloud(ExampleData.welcomeListId),
            summary: ExampleData.welcomeList,
            originalFileId: nil,
            isReadOnly: true
        ))

        // External lists (user-selected files) — URLs already resolved above
        let totalFiles = externalURLs.count
        var currentFileIndex = 0

        for url in externalURLs {
            guard !seenExternalURLs.contains(url.path) else { continue }
            seenExternalURLs.insert(url.path)

            // Update loading progress (only on initial load)
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

                // Check if file is writable
                let isReadOnly = !FileStore.isFileWritable(at: url)

                unified.append(UnifiedList(
                    id: runtimeId,
                    source: .external(url),
                    summary: modifiedSummary,
                    originalFileId: document.list.id,
                    isReadOnly: isReadOnly
                ))

                // PRELOAD reactive label cache
                externalLabels[url] = document.labels

            } catch {
                AppLogger.fileStore.error("Failed to load external file \(url, privacy: .public): \(error, privacy: .public)")
                // NOTE: Don't call closeFile here - that would remove the bookmark permanently
                // We want to keep the bookmark so the user can retry later

                // Add as unavailable so it shows in the sidebar with an error
                let fileName = url.deletingPathExtension().lastPathComponent
                let folderName = url.deletingLastPathComponent().lastPathComponent
                let runtimeId = "unavailable:\(url.path)"

                let placeholderSummary = ShoppingListSummary(
                    id: runtimeId,
                    name: fileName,
                    modifiedAt: Date(),
                    icon: "exclamationmark.triangle",
                    hiddenLabels: nil
                )

                // Create an unavailable bookmark to track the error
                let unavailableBookmark = UnavailableBookmark(
                    id: url.path,
                    originalPath: url.path,
                    reason: .bookmarkInvalid(error),
                    fileName: fileName,
                    folderName: folderName
                )

                unified.append(UnifiedList(
                    id: runtimeId,
                    source: .external(url),
                    summary: placeholderSummary,
                    originalFileId: nil,
                    isReadOnly: true,
                    unavailableBookmark: unavailableBookmark
                ))
            }

        }

        // Clear loading state and mark initial load complete
        currentlyLoadingFile = nil
        loadingProgress = (0, 0)
        isInitialLoad = false

        // Unavailable external files - show in sidebar with warning
        let unavailableBookmarks = await FileStore.shared.getUnavailableBookmarks()
        for bookmark in unavailableBookmarks {
            let runtimeId = "unavailable:\(bookmark.id)"

            // Create a placeholder summary for the unavailable file
            let placeholderSummary = ShoppingListSummary(
                id: runtimeId,
                name: bookmark.fileName,
                modifiedAt: Date(),
                icon: bookmark.reason.icon,
                hiddenLabels: nil
            )

            unified.append(UnifiedList(
                id: runtimeId,
                source: .privateICloud(runtimeId),  // Use privateICloud as placeholder since we can't resolve the URL
                summary: placeholderSummary,
                originalFileId: nil,
                isReadOnly: true,
                unavailableBookmark: bookmark
            ))
        }
        
        allLists = unified.sorted { list1, list2 in
            list1.summary.name.localizedCaseInsensitiveCompare(list2.summary.name) == .orderedAscending
        }

        // Initialize save status
        for list in unified where saveStatus[list.id] == nil {
            saveStatus[list.id] = .saved
        }

        // Sync reminder items to native calendar
        Task {
            await EventKitManager.shared.syncIfEnabled(provider: self)
        }
    }
    
    // MARK: - External File Opening

    /// Opens an external file, handling conflicts and selection
    /// Returns the ID of the list to select, or nil if there was a conflict
    func openExternalFile(at url: URL) async throws -> String? {
        // Check if already open
        if let existing = allLists.first(where: {
            if case .external(let existingURL) = $0.source {
                return existingURL.path == url.path
            }
            return false
        }) {
            AppLogger.general.info("File already open: \(existing.summary.name, privacy: .public)")
            return existing.id
        }

        // Show loading indicator
        isDownloadingFile = true
        defer { isDownloadingFile = false }

        // Open the file (this saves the bookmark)
        let source = FileSource.externalFile(url)
        let document = try await FileStore.shared.openFile(from: source)

        // Check for ID conflicts with private lists
        let privateLists = allLists.filter { $0.isPrivate }
        if privateLists.contains(where: { $0.summary.id == document.list.id }) {
            AppLogger.general.warning("ID conflict detected for: \(document.list.name, privacy: .public)")
            await FileStore.shared.closeFile(at: url)
            throw NSError(domain: "UnifiedListProvider", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ID conflict",
                "url": url,
                "document": document
            ])
        }

        // Create the new unified list
        let runtimeId = "external:\(url.path)"
        var modifiedSummary = document.list
        modifiedSummary.id = runtimeId
        let isReadOnly = !FileStore.isFileWritable(at: url)

        let newList = UnifiedList(
            id: runtimeId,
            source: .external(url),
            summary: modifiedSummary,
            originalFileId: document.list.id,
            isReadOnly: isReadOnly
        )

        // Add to allLists directly (no need to reload everything!)
        allLists.append(newList)
        externalLabels[url] = document.labels
        saveStatus[runtimeId] = .saved

        AppLogger.general.info("Opened and selected: \(newList.summary.name, privacy: .public)")
        return newList.id
    }
    
    // MARK: - Items

    func fetchItems(for list: UnifiedList) async throws -> [ShoppingItem] {
        // Handle welcome list (read-only example)
        if list.summary.id == ExampleData.welcomeListId {
            return ExampleData.welcomeItems
        }

        let document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        return document.items
    }
    
    func addItem(_ item: ShoppingItem, to list: UnifiedList) async throws {
        var document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        document.items.append(item)

        switch list.source {
        case .privateICloud(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            await FileStore.shared.updateCache(document, at: url)
            triggerAutosave(for: list, document: document)
        case .external(let url):
            await FileStore.shared.updateCache(document, at: url)
            triggerAutosave(for: list, document: document)
        }
    }
    
    /// Syncs a list if the file has changed
    func syncIfNeeded(for list: UnifiedList) async throws {
        // Prevent duplicate syncs for same list
        guard !activeSyncs.contains(list.id) else {
            AppLogger.sync.debug("[Sync] Already syncing \(list.summary.name, privacy: .public), skipping")
            return
        }

        let fileSource = list.source.asFileSource

        if await FileStore.shared.hasFileChanged(for: fileSource) {
            AppLogger.sync.debug("File changed, syncing: \(list.summary.name, privacy: .public)")

            activeSyncs.insert(list.id)
            defer { activeSyncs.remove(list.id) }

            let mergedDoc = try await FileStore.shared.syncFile(from: fileSource)

            // Update cache and UI based on source type
            switch list.source {
            case .privateICloud(let listId):
                let url = await iCloudContainerManager.shared.fileURL(for: listId)
                await FileStore.shared.updateCache(mergedDoc, at: url)
            case .external(let url):
                await FileStore.shared.updateCache(mergedDoc, at: url)
                externalLabels[url] = mergedDoc.labels
            }

            // Update the list in allLists
            if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                var updatedList = allLists[index]
                updatedList.summary = mergedDoc.list
                updatedList.summary.id = list.id  // Keep runtime ID
                allLists[index] = updatedList
            }

            // Reconcile reminders after sync — cancel stale, schedule missing
            await ReminderManager.reconcile(
                items: mergedDoc.items,
                listName: list.summary.name,
                listId: list.id
            )

            objectWillChange.send()
        }
    }

    /// Checks all lists for changes and syncs if needed
    func syncAllLists() async {
        for list in allLists where !list.isReadOnly {
            do {
                try await syncIfNeeded(for: list)
            } catch {
                AppLogger.sync.warning("Sync skipped for \(list.id, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Legacy method for backward compatibility
    func syncAllExternalLists() async {
        await syncAllLists()
    }
    
    func updateItem(_ item: ShoppingItem, in list: UnifiedList) async throws {
        var document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        if let index = document.items.firstIndex(where: { $0.id == item.id }) {
            document.items[index] = item

            switch list.source {
            case .privateICloud(let listId):
                let url = await iCloudContainerManager.shared.fileURL(for: listId)
                await FileStore.shared.updateCache(document, at: url)
                triggerAutosave(for: list, document: document)
            case .external(let url):
                await FileStore.shared.updateCache(document, at: url)
                triggerAutosave(for: list, document: document)
            }
        }
    }
    
    func deleteItem(_ item: ShoppingItem, from list: UnifiedList) async throws {
        // Cancel any pending reminder for this item
        if item.reminderDate != nil {
            ReminderManager.cancelReminder(for: item)
        }

        var document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        if let index = document.items.firstIndex(where: { $0.id == item.id }) {
            document.items[index].isDeleted = true
            document.items[index].deletedAt = Date()
            document.items[index].modifiedAt = Date()
            document.items[index].reminderDate = nil

            switch list.source {
            case .privateICloud(let listId):
                let url = await iCloudContainerManager.shared.fileURL(for: listId)
                await FileStore.shared.updateCache(document, at: url)
                triggerAutosave(for: list, document: document)
            case .external(let url):
                await FileStore.shared.updateCache(document, at: url)
                triggerAutosave(for: list, document: document)
            }
        }
    }

    func fetchDeletedItems(for list: UnifiedList) async throws -> [ShoppingItem] {
        let document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        return document.items.filter { $0.isDeleted }
    }

    func restoreItem(_ item: ShoppingItem, in list: UnifiedList) async throws {
        var document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        if let index = document.items.firstIndex(where: { $0.id == item.id }) {
            document.items[index].isDeleted = false
            document.items[index].deletedAt = nil
            document.items[index].modifiedAt = Date()

            switch list.source {
            case .privateICloud(let listId):
                let url = await iCloudContainerManager.shared.fileURL(for: listId)
                await FileStore.shared.updateCache(document, at: url)
                triggerAutosave(for: list, document: document)
            case .external(let url):
                await FileStore.shared.updateCache(document, at: url)
                triggerAutosave(for: list, document: document)
            }
        }
    }

    func permanentlyDeleteItem(_ item: ShoppingItem, from list: UnifiedList) async throws {
        var document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        document.items.removeAll { $0.id == item.id }

        switch list.source {
        case .privateICloud(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            await FileStore.shared.updateCache(document, at: url)
            triggerAutosave(for: list, document: document)
        case .external(let url):
            await FileStore.shared.updateCache(document, at: url)
            triggerAutosave(for: list, document: document)
        }
    }

    
    // MARK: - Labels

    func fetchLabels(for list: UnifiedList) async throws -> [ShoppingLabel] {
        // Handle welcome list (read-only example)
        if list.summary.id == ExampleData.welcomeListId {
            return ExampleData.welcomeLabels
        }

        // Return cached labels for external files if available (prevents stale reads)
        if case .external(let url) = list.source, let cached = externalLabels[url] {
            return cached
        }

        let document = try await FileStore.shared.openFile(from: list.source.asFileSource)

        // Cache labels for external files
        if case .external(let url) = list.source {
            externalLabels[url] = document.labels
        }

        return document.labels
    }

    func createLabel(_ label: ShoppingLabel, for list: UnifiedList) async throws {
        var document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        document.labels.append(label)
        document.list.modifiedAt = Date()

        switch list.source {
        case .privateICloud(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            await FileStore.shared.updateCache(document, at: url)
            triggerAutosave(for: list, document: document)
        case .external(let url):
            await FileStore.shared.updateCache(document, at: url)
            triggerAutosave(for: list, document: document)
            externalLabels[url] = document.labels
        }
    }

    func updateLabel(_ label: ShoppingLabel, for list: UnifiedList) async throws {
        AppLogger.labels.debug("[updateLabel] Starting update for label: \(label.name, privacy: .public)")

        var document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        AppLogger.labels.debug("[updateLabel] Document has \(document.labels.count, privacy: .public) labels")

        if let index = document.labels.firstIndex(where: { $0.id == label.id }) {
            document.labels[index] = label
            document.list.modifiedAt = Date()

            switch list.source {
            case .privateICloud(let listId):
                let url = await iCloudContainerManager.shared.fileURL(for: listId)
                await FileStore.shared.updateCache(document, at: url)
                AppLogger.labels.debug("[updateLabel] Saving document with updated label...")
                try await saveFile(document, for: list)
                AppLogger.labels.info("[updateLabel] Label saved successfully")
            case .external(let url):
                await FileStore.shared.updateCache(document, at: url)
                AppLogger.labels.debug("[updateLabel] Saving document with updated label...")
                try await saveFile(document, for: list)
                externalLabels[url] = document.labels
                AppLogger.labels.info("[updateLabel] Label saved successfully")
            }
        } else {
            AppLogger.labels.warning("[updateLabel] Label not found in document!")
        }
    }

    func deleteLabel(_ label: ShoppingLabel, from list: UnifiedList) async throws {
        AppLogger.labels.debug("[deleteLabel] Starting delete for label: \(label.name, privacy: .public)")

        var document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        AppLogger.labels.debug("[deleteLabel] Document has \(document.labels.count, privacy: .public) labels before delete")

        document.labels.removeAll { $0.id == label.id }
        AppLogger.labels.debug("[deleteLabel] Document has \(document.labels.count, privacy: .public) labels after delete")

        document.list.modifiedAt = Date()

        switch list.source {
        case .privateICloud(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            await FileStore.shared.updateCache(document, at: url)
            AppLogger.labels.debug("[deleteLabel] Saving document...")
            try await saveFile(document, for: list)
            AppLogger.labels.info("[deleteLabel] Label deleted successfully")
        case .external(let url):
            await FileStore.shared.updateCache(document, at: url)
            AppLogger.labels.debug("[deleteLabel] Saving document...")
            try await saveFile(document, for: list)
            externalLabels[url] = document.labels
            AppLogger.labels.info("[deleteLabel] Label deleted successfully")
        }
    }

    func updateLabelOrder(_ order: [String], for list: UnifiedList) async throws {
        var document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        document.list.labelOrder = order
        document.list.modifiedAt = Date()

        switch list.source {
        case .privateICloud(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            await FileStore.shared.updateCache(document, at: url)
            try await saveFile(document, for: list)
        case .external(let url):
            await FileStore.shared.updateCache(document, at: url)
            try await saveFile(document, for: list)
        }
    }

    // MARK: - List Management

    func updateList(_ list: UnifiedList, name: String, icon: String?, hiddenLabels: [String]?, labelOrder: [String]? = nil) async throws {
        AppLogger.general.debug("[updateList] Loading document...")
        var document = try await FileStore.shared.openFile(from: list.source.asFileSource)
        AppLogger.general.debug("[updateList] Document has \(document.labels.count, privacy: .public) labels, \(document.items.count, privacy: .public) items")

        document.list.name = name
        document.list.icon = icon
        document.list.hiddenLabels = hiddenLabels
        document.list.labelOrder = labelOrder
        document.list.modifiedAt = Date()

        switch list.source {
        case .privateICloud(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            await FileStore.shared.updateCache(document, at: url)
            AppLogger.general.debug("[updateList] Saving document...")
            try await saveFile(document, for: list)

            // Update allLists
            if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                var updatedList = allLists[index]
                updatedList.summary = document.list
                allLists[index] = updatedList
            }
            AppLogger.general.info("[updateList] List updated successfully")

        case .external(let url):
            await FileStore.shared.updateCache(document, at: url)
            AppLogger.general.debug("[updateList] Saving document with \(document.labels.count, privacy: .public) labels...")
            try await saveFile(document, for: list)
            AppLogger.general.info("[updateList] List updated successfully")
        }
    }

    func deleteList(_ list: UnifiedList) async throws {
        switch list.source {
        case .privateICloud(let listId):
            try await FileStore.shared.deletePrivateList(listId)
        case .external(let url):
            await FileStore.shared.closeFile(at: url)
            externalLabels.removeValue(forKey: url)
        }
        allLists.removeAll { $0.id == list.id }
        saveStatus.removeValue(forKey: list.id)
    }

    /// Removes an unavailable bookmark from the list
    func removeUnavailableList(_ list: UnifiedList) async {
        guard let bookmark = list.unavailableBookmark else { return }
        await FileStore.shared.removeUnavailableBookmark(bookmark)
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

    /// Unified save method for both private and external lists
    private func saveFile(_ document: ListDocument, for list: UnifiedList) async throws {
        AppLogger.fileStore.debug("[saveFile] Saving document with \(document.labels.count, privacy: .public) labels, \(document.items.count, privacy: .public) items")

        var docToSave = document

        // Restore original file ID for external files
        if let originalId = list.originalFileId {
            docToSave.list.id = originalId
        }

        do {
            try await FileStore.shared.saveFile(docToSave, to: list.source.asFileSource)
            await MainActor.run { saveStatus[list.id] = .saved }
            AppLogger.fileStore.info("[saveFile] Save successful")

            // Sync reminder items to native calendar after every successful save
            Task {
                await EventKitManager.shared.syncIfEnabled(provider: self)
            }
        } catch {
            let nsError = error as NSError
            AppLogger.fileStore.error("Save error: \(error, privacy: .public)")
            AppLogger.fileStore.debug("Domain: \(nsError.domain, privacy: .public)")
            AppLogger.fileStore.debug("Code: \(nsError.code, privacy: .public)")
            AppLogger.fileStore.debug("Description: \(nsError.localizedDescription, privacy: .public)")

            // For external files, check if file became read-only
            if case .external(let url) = list.source {
                let isWritable = FileStore.isFileWritable(at: url)
                AppLogger.fileStore.debug("File is writable: \(isWritable, privacy: .public)")

                if !isWritable {
                    AppLogger.fileStore.warning("File became read-only, reverting changes and reloading from disk")

                    do {
                        // Reload clean version from disk
                        let cleanDocument = try await FileStore.shared.openFile(from: list.source.asFileSource, forceReload: true)

                        // Update cache with clean version
                        await FileStore.shared.updateCache(cleanDocument, at: url)

                        // Update reactive label cache
                        await MainActor.run {
                            externalLabels[url] = cleanDocument.labels
                        }

                        // Mark list as read-only and update summary
                        if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                            var updatedList = allLists[index]
                            updatedList.isReadOnly = true
                            updatedList.summary = cleanDocument.list
                            updatedList.summary.id = list.id  // Keep runtime ID
                            allLists[index] = updatedList
                            AppLogger.fileStore.info("Marked list as read-only and updated")
                        }

                        // Update save status
                        await MainActor.run {
                            saveStatus[list.id] = .failed("File is read-only. Changes discarded.")
                        }

                        // Post notification to refresh views
                        NotificationCenter.default.post(name: .externalListChanged, object: list.id)
                        objectWillChange.send()

                        AppLogger.fileStore.info("Successfully reverted to clean version")
                    } catch {
                        AppLogger.fileStore.error("Failed to reload clean version: \(error, privacy: .public)")
                    }
                } else {
                    await MainActor.run {
                        saveStatus[list.id] = .failed(error.localizedDescription)
                    }
                }
            } else {
                await MainActor.run {
                    saveStatus[list.id] = .failed(error.localizedDescription)
                }
            }

            throw error
        }
    }
    
    // MARK: - Helper

    func reloadList(_ list: UnifiedList) async {
        do {
            let document = try await FileStore.shared.openFile(from: list.source.asFileSource, forceReload: true)
            if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                var updatedList = list
                updatedList.summary = document.list
                updatedList.summary.id = list.id // Keep runtime ID
                allLists[index] = updatedList

                // Update labels cache for external files
                if case .external(let url) = list.source {
                    externalLabels[url] = document.labels
                }
            }
            objectWillChange.send()
        } catch {
            AppLogger.fileStore.error("Failed to reload list: \(error, privacy: .public)")
        }
    }
    
    func checkExternalFilesForChanges() async {
        await syncAllExternalLists()
    }
    
    func prepareExport(for list: UnifiedList) async throws -> ListDocument {
        // Fetch all data
        let items = try await fetchItems(for: list)
        let labels = try await fetchLabels(for: list)
        
        // Use original ID if available (for external lists)
        var exportList = list.summary
        if let originalId = list.originalFileId {
            exportList.id = originalId
        }
        
        // Create and return document
        return ListDocument(
            list: exportList,
            items: items,
            labels: labels
        )
    }
    
    // MARK: - Auto-cleanup

    /// Permanently deletes items that have been in recycle bin for more than 30 days
    func cleanupOldDeletedItems(for list: UnifiedList) async {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        
        do {
            let deletedItems = try await fetchDeletedItems(for: list)
            
            for item in deletedItems {
                // If deletedAt is nil (old items before this feature), use modifiedAt
                let deletionDate = item.deletedAt ?? item.modifiedAt
                
                if deletionDate < thirtyDaysAgo {
                    AppLogger.items.debug("Auto-deleting old item: \(item.note, privacy: .public) (deleted \(deletionDate, privacy: .public))")
                    do {
                        try await permanentlyDeleteItem(item, from: list)
                    } catch {
                        AppLogger.items.warning("Failed to auto-delete item \(item.id, privacy: .public): \(error, privacy: .public)")
                    }
                }
            }
        } catch {
            AppLogger.items.error("Failed to cleanup old items: \(error, privacy: .public)")
        }
    }
}
