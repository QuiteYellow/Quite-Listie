//
//  UnifiedListProvider.swift
//  Listie.md
//
//  Unified provider that handles both local storage and external files seamlessly
//

import Foundation
import SwiftUI

enum ListSource {
    case local
    case external(URL)
}

extension Notification.Name {
    static let externalFileChanged = Notification.Name("externalFileChanged")
    static let externalListChanged = Notification.Name("externalListChanged")
    static let listSettingsChanged = Notification.Name("listSettingsChanged")
}


struct UnifiedList: Identifiable, Hashable {
    let id: String
    let source: ListSource
    var summary: ShoppingListSummary
    
    var originalFileId: String?
    
    var isReadOnly: Bool = false
    
    var externalURL: URL? {
        if case .external(let url) = source { return url }
        return nil
    }
    
    var isExternal: Bool { if case .external = source { return true } else { return false } }
    
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
    
    private var autosaveTasks: [String: Task<Void, Never>] = [:]
    
    private var activeSyncs: Set<String> = []  // Track which lists are currently syncing
    
    enum SaveStatus { case saved, saving, unsaved, failed(String) }
    
    // MARK: - Load Lists
    
    func loadAllLists() async {
        var unified: [UnifiedList] = []
        var seenExternalURLs: Set<String> = []
        
        // Local lists
        do {
            let localLists = try await LocalOnlyProvider.shared.fetchShoppingLists()
            for list in localLists {
                let isReadOnly = list.id == "example-welcome-list" // Mark example as read-only
                
                unified.append(UnifiedList(
                    id: list.id,
                    source: .local,
                    summary: list,
                    originalFileId: nil,
                    isReadOnly: isReadOnly 
                ))
            }
        } catch {
            print("Failed to load local lists: \(error)")
        }
        
        // External lists
        let externalURLs = await ExternalFileStore.shared.getBookmarkedURLs()
        for url in externalURLs {
            guard !seenExternalURLs.contains(url.path) else { continue }
            seenExternalURLs.insert(url.path)
            
            do {
                let document = try await ExternalFileStore.shared.openFile(at: url)
                let runtimeId = "external:\(url.path)"
                
                var modifiedSummary = document.list
                modifiedSummary.id = runtimeId
                
                // Check if file is writable
                let isReadOnly = !ExternalFileStore.isFileWritable(at: url)
                
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
                print("❌ Failed to load external file \(url): \(error)")
                await ExternalFileStore.shared.closeFile(at: url)
            }
            
        }
        
        allLists = unified.sorted { list1, list2 in
            list1.summary.name.localizedCaseInsensitiveCompare(list2.summary.name) == .orderedAscending
        }
        
        // Initialize save status
        for list in unified where saveStatus[list.id] == nil {
            saveStatus[list.id] = .saved
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
            print("ℹ️ File already open: \(existing.summary.name)")
            return existing.id
        }
        
        // Show loading indicator
        isDownloadingFile = true
        defer { isDownloadingFile = false }
        
        // Open the file (this saves the bookmark)
        let document = try await ExternalFileStore.shared.openFile(at: url)
        
        // Check for ID conflicts with local lists
        let localLists = allLists.filter { !$0.isExternal }
        if localLists.contains(where: { $0.summary.id == document.list.id }) {
            print("⚠️ ID conflict detected for: \(document.list.name)")
            await ExternalFileStore.shared.closeFile(at: url)
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
        let isReadOnly = !ExternalFileStore.isFileWritable(at: url)
        
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
        
        print("✅ Opened and selected: \(newList.summary.name)")
        return newList.id
    }
    
    // MARK: - Items
    
    func fetchItems(for list: UnifiedList) async throws -> [ShoppingItem] {
        switch list.source {
        case .local:
            return try await LocalOnlyProvider.shared.fetchItems(for: list.summary.id)
        case .external(let url):
            let document = try await ExternalFileStore.shared.openFile(at: url)
            return document.items
        }
    }
    
    func addItem(_ item: ShoppingItem, to list: UnifiedList) async throws {
        switch list.source {
        case .local:
            try await LocalOnlyProvider.shared.addItem(item, to: list.summary.id)
        case .external(let url):
            var document = try await ExternalFileStore.shared.openFile(at: url)
            document.items.append(item)
            await ExternalFileStore.shared.updateCache(document, at: url)  // ADD THIS LINE
            triggerAutosave(for: list, document: document)
        }
        
    }
    
    /// Syncs an external list if the file has changed
    func syncIfNeeded(for list: UnifiedList) async throws {
        guard case .external(let url) = list.source else { return }
        
        // Prevent duplicate syncs for same list
        guard !activeSyncs.contains(list.id) else {
            print("⏸️ [Sync] Already syncing \(list.summary.name), skipping")
            return
        }
        
        if await ExternalFileStore.shared.hasFileChanged(at: url) {
            print("🔄 File changed, syncing: \(list.summary.name)")
            
            activeSyncs.insert(list.id)
            defer { activeSyncs.remove(list.id) }
            
            let mergedDoc = try await ExternalFileStore.shared.syncFile(at: url)
            
            // Update cache and UI
            await ExternalFileStore.shared.updateCache(mergedDoc, at: url)
            externalLabels[url] = mergedDoc.labels
            
            // Update the list in allLists
            if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                var updatedList = allLists[index]
                updatedList.summary = mergedDoc.list
                updatedList.summary.id = list.id  // Keep runtime ID
                allLists[index] = updatedList
            }
            
            objectWillChange.send()
        }
    }

    /// Checks all external files for changes and syncs if needed
    func syncAllExternalLists() async {
        for list in allLists where list.isExternal {
            try? await syncIfNeeded(for: list)
        }
    }
    
    func updateItem(_ item: ShoppingItem, in list: UnifiedList) async throws {
        switch list.source {
        case .local:
            try await LocalOnlyProvider.shared.updateItem(item)
        case .external(let url):
            var document = try await ExternalFileStore.shared.openFile(at: url)
            if let index = document.items.firstIndex(where: { $0.id == item.id }) {
                document.items[index] = item
                await ExternalFileStore.shared.updateCache(document, at: url)  // ADD THIS LINE
                triggerAutosave(for: list, document: document)
            }
        }
    }
    
    func deleteItem(_ item: ShoppingItem, from list: UnifiedList) async throws {
        switch list.source {
        case .local:
            // Local: soft delete (changed from hard delete)
            try await LocalOnlyProvider.shared.deleteItem(item)
        case .external(let url):
            // External: soft delete
            var document = try await ExternalFileStore.shared.openFile(at: url)
            if let index = document.items.firstIndex(where: { $0.id == item.id }) {
                document.items[index].isDeleted = true
                document.items[index].deletedAt = Date()
                document.items[index].modifiedAt = Date()
                await ExternalFileStore.shared.updateCache(document, at: url)
                triggerAutosave(for: list, document: document)
            }
        }
    }

    func fetchDeletedItems(for list: UnifiedList) async throws -> [ShoppingItem] {
        switch list.source {
        case .local:
            return try await LocalOnlyProvider.shared.fetchDeletedItems(for: list.summary.id)
        case .external(let url):
            let document = try await ExternalFileStore.shared.openFile(at: url)
            return document.items.filter { $0.isDeleted }
        }
    }
    
    func restoreItem(_ item: ShoppingItem, in list: UnifiedList) async throws {
        switch list.source {
        case .local:
            try await LocalOnlyProvider.shared.restoreItem(item)
        case .external(let url):
            var document = try await ExternalFileStore.shared.openFile(at: url)
            if let index = document.items.firstIndex(where: { $0.id == item.id }) {
                document.items[index].isDeleted = false
                document.items[index].deletedAt = nil
                document.items[index].modifiedAt = Date()
                await ExternalFileStore.shared.updateCache(document, at: url)
                triggerAutosave(for: list, document: document)
            }
        }
    }

    func permanentlyDeleteItem(_ item: ShoppingItem, from list: UnifiedList) async throws {
        switch list.source {
        case .local:
            try await LocalOnlyProvider.shared.permanentlyDeleteItem(item)
        case .external(let url):
            var document = try await ExternalFileStore.shared.openFile(at: url)
            document.items.removeAll { $0.id == item.id }
            await ExternalFileStore.shared.updateCache(document, at: url)
            triggerAutosave(for: list, document: document)
        }
    }

    
    // MARK: - Labels
    
    func fetchLabels(for list: UnifiedList) async throws -> [ShoppingLabel] {
        switch list.source {
        case .local:
            return try await LocalOnlyProvider.shared.fetchLabels(for: list.summary)
        case .external(let url):
            // Return cached labels if available (prevents stale reads)
            if let cached = externalLabels[url] {
                return cached
            }
            // Otherwise load from file and cache
            let document = try await ExternalFileStore.shared.openFile(at: url)
            externalLabels[url] = document.labels
            return document.labels
        }
    }
    
    func createLabel(_ label: ShoppingLabel, for list: UnifiedList) async throws {
        switch list.source {
        case .local:
            var labelWithListId = label
            labelWithListId.listId = list.summary.id
            try await LocalOnlyProvider.shared.createLabel(labelWithListId)
        case .external(let url):
            var document = try await ExternalFileStore.shared.openFile(at: url)
            document.labels.append(label)
            document.list.modifiedAt = Date()
            await ExternalFileStore.shared.updateCache(document, at: url)
            triggerAutosave(for: list, document: document)
            externalLabels[url] = document.labels
        }
    }
    
    func updateLabel(_ label: ShoppingLabel, for list: UnifiedList) async throws {
        switch list.source {
        case .local:
            try await LocalOnlyProvider.shared.updateLabel(label)
        case .external(let url):
            var document = try await ExternalFileStore.shared.openFile(at: url)
            if let index = document.labels.firstIndex(where: { $0.id == label.id }) {
                document.labels[index] = label
                document.list.modifiedAt = Date()
                await ExternalFileStore.shared.updateCache(document, at: url)
                triggerAutosave(for: list, document: document)
                externalLabels[url] = document.labels
            }
        }
    }
    
    func deleteLabel(_ label: ShoppingLabel, from list: UnifiedList) async throws {
        switch list.source {
        case .local:
            try await LocalOnlyProvider.shared.deleteLabel(label)
        case .external(let url):
            var document = try await ExternalFileStore.shared.openFile(at: url)
            document.labels.removeAll { $0.id == label.id }
            document.list.modifiedAt = Date()
            await ExternalFileStore.shared.updateCache(document, at: url) 
            triggerAutosave(for: list, document: document)
            externalLabels[url] = document.labels
        }
    }
    
    // MARK: - List Management
    
    func updateList(_ list: UnifiedList, name: String, extras: [String: String], items: [ShoppingItem]) async throws {
        switch list.source {
        case .local:
            try await LocalOnlyProvider.shared.updateList(list.summary, with: name, extras: extras, items: items)
        case .external(let url):
            var document = try await ExternalFileStore.shared.openFile(at: url)
            document.list.name = name
            document.list.extras = extras
            
            // Extract icon from extras to direct field (V2)
            if let icon = extras["listsForMealieListIcon"], !icon.isEmpty {
                document.list.icon = icon
            }
            
            // Extract hidden labels from extras to direct field (V2)
            if let hiddenString = extras["hiddenLabels"], !hiddenString.isEmpty {
                document.list.hiddenLabels = hiddenString.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
            }
            
            document.items = items
            try await saveExternalFile(document, to: url, listId: list.id)
        }
        
    }
    
    func deleteList(_ list: UnifiedList) async throws {
        switch list.source {
        case .local:
            try await LocalOnlyProvider.shared.deleteList(list.summary)
        case .external(let url):
            await ExternalFileStore.shared.closeFile(at: url)  // This already handles cleanup
            externalLabels.removeValue(forKey: url)
        }
        allLists.removeAll { $0.id == list.id }
        saveStatus.removeValue(forKey: list.id)
    }
    
    // MARK: - Autosave
    
    private func triggerAutosave(for list: UnifiedList, document: ListDocument) {
        guard case .external(let url) = list.source else { return }
        autosaveTasks[list.id]?.cancel()
        
        autosaveTasks[list.id] = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { saveStatus[list.id] = .saving }
            
            do {
                try await saveExternalFile(document, to: url, listId: list.id)
            } catch {
                await MainActor.run { saveStatus[list.id] = .failed(error.localizedDescription) }
            }
        }
    }
    
    private func saveExternalFile(_ document: ListDocument, to url: URL, listId: String) async throws {
        var docToSave = document
        if let list = allLists.first(where: { $0.id == listId }),
           let originalId = list.originalFileId {
            docToSave.list.id = originalId
        }
        
        do {
            try await ExternalFileStore.shared.saveFile(docToSave, to: url)
            await MainActor.run { saveStatus[listId] = .saved }
        } catch {
            let nsError = error as NSError
            print("❌ Save error: \(error)")
            print("   Domain: \(nsError.domain)")
            print("   Code: \(nsError.code)")
            print("   Description: \(nsError.localizedDescription)")
            
            // Check if file is writable now
            let isWritable = ExternalFileStore.isFileWritable(at: url)
            print("   File is writable: \(isWritable)")
            
            // If file is not writable (regardless of error type)
            if !isWritable {
                print("⚠️ File became read-only, reverting changes and reloading from disk")
                
                do {
                    // 1. Reload clean version from disk
                    let cleanDocument = try await ExternalFileStore.shared.openFile(at: url, forceReload: true)
                    
                    // 2. Update cache with clean version (discards unsaved changes)
                    await ExternalFileStore.shared.updateCache(cleanDocument, at: url)
                    
                    // 3. Update reactive label cache
                    await MainActor.run {
                        externalLabels[url] = cleanDocument.labels
                    }
                    
                    // 4. Mark list as read-only and update summary
                    if let index = allLists.firstIndex(where: { $0.id == listId }) {
                        var updatedList = allLists[index]
                        updatedList.isReadOnly = true
                        updatedList.summary = cleanDocument.list
                        updatedList.summary.id = listId  // Keep runtime ID
                        allLists[index] = updatedList
                        print("✅ Marked list as read-only and updated")
                    }
                    
                    // 5. Update save status
                    await MainActor.run {
                        saveStatus[listId] = .failed("File is read-only. Changes discarded.")
                    }
                    
                    // 6. Post notification to refresh views
                    NotificationCenter.default.post(name: .externalListChanged, object: listId)
                    
                    // 7. Trigger objectWillChange to update WelcomeView
                    objectWillChange.send()
                    
                    print("✅ Successfully reverted to clean version")
                } catch {
                    print("❌ Failed to reload clean version: \(error)")
                }
            } else {
                await MainActor.run {
                    saveStatus[listId] = .failed(error.localizedDescription)
                }
            }
            
            throw error
        }
    }
    
    // MARK: - Helper
    
    func reloadList(_ list: UnifiedList) async {
        switch list.source {
        case .local: break
        case .external(let url):
            do {
                let document = try await ExternalFileStore.shared.openFile(at: url, forceReload: true)
                if let index = allLists.firstIndex(where: { $0.id == list.id }) {
                    var updatedList = list
                    updatedList.summary = document.list
                    updatedList.summary.id = list.id // Keep runtime ID
                    allLists[index] = updatedList
                    externalLabels[url] = document.labels
                }
                objectWillChange.send()
            } catch {
                print("Failed to reload external list: \(error)")
            }
        }
    }
    
    func checkExternalFilesForChanges() async {
        await syncAllExternalLists()
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
                    print("🗑️ Auto-deleting old item: \(item.note) (deleted \(deletionDate))")
                    try? await permanentlyDeleteItem(item, from: list)
                }
            }
        } catch {
            print("Failed to cleanup old items: \(error)")
        }
    }
}
