//
//  LocalShoppingListStore_v2.swift
//  ListsForMealie
//
//  Updated to use simplified V2 format with automatic migration
//

import Foundation

actor LocalShoppingListStore: ShoppingListProvider {
    static let shared = LocalShoppingListStore()

    // In-memory cache of all list documents
    private var listDocuments: [String: ListDocument] = [:]
    
    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

    init() {
        Task {
            await loadAllLists()
        }
    }

    // MARK: - File Management
    
    private func fileURL(for listId: String) -> URL {
        documentsDirectory.appendingPathComponent("list_\(listId).json")
    }
    
    private func listIdFromFilename(_ filename: String) -> String? {
        guard filename.hasPrefix("list_") && filename.hasSuffix(".json") else {
            return nil
        }
        let start = filename.index(filename.startIndex, offsetBy: 5) // "list_".count
        let end = filename.index(filename.endIndex, offsetBy: -5) // ".json".count
        return String(filename[start..<end])
    }

    // MARK: - Data Persistence

    private func loadAllLists() async {
        print("ðŸ“‚ [Local Load V2] Discovering list files...")
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: documentsDirectory,
                includingPropertiesForKeys: nil
            )
            
            let listFiles = fileURLs.filter { $0.lastPathComponent.hasPrefix("list_") && $0.pathExtension == "json" }
            
            print("ðŸ“‚ [Local Load V2] Found \(listFiles.count) list files")
            
            for fileURL in listFiles {
                do {
                    let data = try Data(contentsOf: fileURL)
                    
                    // Use migration utility to load and migrate if necessary
                    var document = try ListDocumentMigration.loadDocument(from: data)
                    
                    // Store using clean ID
                    let cleanId = document.list.cleanId
                    if document.list.id != cleanId {
                        // Update document to use clean ID
                        document.list.id = cleanId
                        // Save the migrated version back to disk
                        try await saveList(cleanId)
                    }
                    
                    listDocuments[cleanId] = document
                    print("âœ… [Local Load V2] Loaded list: \(document.list.name) (V\(document.version))")
                } catch {
                    print("❌ [Local Load V2] Failed to load \(fileURL.lastPathComponent): \(error)")
                    
                    // DON'T auto-delete - could be temporary error!
                    // Instead, try to read raw data and report issue
                    if let rawData = try? Data(contentsOf: fileURL),
                       let rawString = String(data: rawData, encoding: .utf8) {
                        print("⚠️ [Local Load V2] File contents (first 200 chars): \(rawString.prefix(200))")
                    }
                    
                    // Only delete if explicitly corrupted AND user confirms
                    // For now, just log and skip
                    print("⚠️ [Local Load V2] Skipping file - manual intervention needed")
                }
            }
            
            print("âœ… [Local Load V2] Loaded \(listDocuments.count) lists total")
        } catch {
            print("âŒ [Local Load V2] Failed to read directory: \(error)")
        }
    }

    private func saveList(_ listId: String) async throws {
        guard let document = listDocuments[listId] else {
            throw NSError(domain: "List not found in cache", code: 1, userInfo: nil)
        }
        
        let fileURL = fileURL(for: listId)
        
        // Use migration utility to save in V2 format
        let data = try ListDocumentMigration.saveDocument(document)
        try data.write(to: fileURL)
        
        print("âœ… [Local Save V2] Saved list \(document.list.name) to \(fileURL.lastPathComponent)")
    }
    
    private func deleteListFile(_ listId: String) async throws {
        let fileURL = fileURL(for: listId)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
            print("âœ… [Local Delete V2] Deleted file for list \(listId)")
        }
    }

    // MARK: - Lists

    func fetchShoppingLists() async throws -> [ShoppingListSummary] {
        return listDocuments.values.map { $0.list }
    }

    func createList(_ list: ShoppingListSummary) async throws {
        print("ðŸ“ [Local V2] Creating list: \(list.name)")
        
        // Ensure we're using clean ID (no "local-" prefix)
        var cleanList = list
        cleanList.id = list.cleanId
        cleanList.modifiedAt = Date()
        
        let document = ListDocument(list: cleanList, items: [], labels: [])
        listDocuments[cleanList.id] = document
        
        try await saveList(cleanList.id)
    }

    func updateList(_ list: ShoppingListSummary, with name: String, extras: [String: String], items: [ShoppingItem]) async throws {
        let cleanId = list.cleanId
        guard var document = listDocuments[cleanId] else {
            throw NSError(domain: "List not found", code: 1, userInfo: nil)
        }
        
        // Update list metadata
        document.list.name = name
        document.list.modifiedAt = Date()
        
        // Update icon from extras if present
        if let icon = extras["listsForMealieListIcon"], !icon.isEmpty {
            document.list.icon = icon
        }
        
        // Update hidden labels from extras if present
        if let hiddenString = extras["hiddenLabels"], !hiddenString.isEmpty {
            document.list.hiddenLabels = hiddenString.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
        }
        
        // Update items
        document.items = items.map { item in
            var updatedItem = item
            updatedItem.modifiedAt = Date()
            return updatedItem
        }
        
        listDocuments[cleanId] = document
        try await saveList(cleanId)
    }

    func deleteList(_ list: ShoppingListSummary) async throws {
        let cleanId = list.cleanId
        listDocuments.removeValue(forKey: cleanId)
        try await deleteListFile(cleanId)
    }

    // MARK: - Items

    func fetchItems(for listId: String) async throws -> [ShoppingItem] {
        let cleanId = cleanListId(listId)
        guard let document = listDocuments[cleanId] else {
            return []
        }
        return document.items
    }

    func addItem(_ item: ShoppingItem, to listId: String) async throws {
        let cleanId = cleanListId(listId)
        guard var document = listDocuments[cleanId] else {
            throw NSError(domain: "List not found", code: 1, userInfo: nil)
        }
        
        var newItem = item
        newItem.modifiedAt = Date()
        document.items.append(newItem)
        document.list.modifiedAt = Date()
        
        listDocuments[cleanId] = document
        try await saveList(cleanId)
    }

    func deleteItem(_ item: ShoppingItem) async throws {
        // Find which list contains this item
        for (listId, var document) in listDocuments {
            if let index = document.items.firstIndex(where: { $0.id == item.id }) {
                // Soft delete instead of removing
                document.items[index].isDeleted = true
                document.items[index].deletedAt = Date()
                document.items[index].modifiedAt = Date()
                document.list.modifiedAt = Date()
                listDocuments[listId] = document
                try await saveList(listId)
                return
            }
        }
        
        throw NSError(domain: "Item not found in any list", code: 1, userInfo: nil)
    }
    
    func restoreItem(_ item: ShoppingItem) async throws {
        for (listId, var document) in listDocuments {
            if let index = document.items.firstIndex(where: { $0.id == item.id }) {
                document.items[index].isDeleted = false
                document.items[index].deletedAt = nil 
                document.items[index].modifiedAt = Date()
                document.list.modifiedAt = Date()
                listDocuments[listId] = document
                try await saveList(listId)
                return
            }
        }
        throw NSError(domain: "Item not found", code: 1, userInfo: nil)
    }

    func permanentlyDeleteItem(_ item: ShoppingItem) async throws {
        for (listId, var document) in listDocuments {
            if let index = document.items.firstIndex(where: { $0.id == item.id }) {
                document.items.remove(at: index)
                document.list.modifiedAt = Date()
                listDocuments[listId] = document
                try await saveList(listId)
                return
            }
        }
        throw NSError(domain: "Item not found", code: 1, userInfo: nil)
    }

    func fetchDeletedItems(for listId: String) async throws -> [ShoppingItem] {
        let cleanId = cleanListId(listId)
        guard let document = listDocuments[cleanId] else {
            return []
        }
        return document.items.filter { $0.isDeleted }
    }

    func updateItem(_ item: ShoppingItem) async throws {
        // Find which list contains this item
        for (listId, var document) in listDocuments {
            if let index = document.items.firstIndex(where: { $0.id == item.id }) {
                var updatedItem = item
                updatedItem.modifiedAt = Date()
                document.items[index] = updatedItem
                document.list.modifiedAt = Date()
                listDocuments[listId] = document
                try await saveList(listId)
                return
            }
        }

        throw NSError(domain: "Item not found in any list", code: 1, userInfo: nil)
    }

    // MARK: - Labels

    func saveLabel(_ label: ShoppingLabel) async throws {
        // Labels are now stored per-list, need to find which list
        guard let targetListId = label.listId else {
            throw NSError(domain: "Label must have a listId", code: 1, userInfo: nil)
        }
        
        // Clean the list ID (remove "local-" prefix if present)
        let cleanId = cleanListId(targetListId)
        
        guard var document = listDocuments[cleanId] else {
            throw NSError(domain: "List not found: \(cleanId)", code: 1, userInfo: nil)
        }
        
        document.labels.append(label)
        document.list.modifiedAt = Date()
        listDocuments[cleanId] = document
        
        try await saveList(cleanId)
    }

    func updateLabel(_ label: ShoppingLabel) async throws {
        // Find which list contains this label
        for (listId, var document) in listDocuments {
            if let index = document.labels.firstIndex(where: { $0.id == label.id }) {
                document.labels[index] = label
                document.list.modifiedAt = Date()
                listDocuments[listId] = document
                try await saveList(listId)
                return
            }
        }
        
        throw NSError(domain: "Label not found", code: 1, userInfo: nil)
    }

    func deleteLabel(_ label: ShoppingLabel) async throws {
        // Find which list contains this label
        for (listId, var document) in listDocuments {
            if document.labels.contains(where: { $0.id == label.id }) {
                document.labels.removeAll { $0.id == label.id }
                document.list.modifiedAt = Date()
                listDocuments[listId] = document
                try await saveList(listId)
                return
            }
        }
        
        throw NSError(domain: "Label not found", code: 1, userInfo: nil)
    }

    func fetchLabels(for list: ShoppingListSummary) async throws -> [ShoppingLabel] {
        let cleanId = list.cleanId
        guard let document = listDocuments[cleanId] else {
            return []
        }
        
        return document.labels
    }

    func fetchAllLocalLabels() async throws -> [ShoppingLabel] {
        // Return all labels from all lists
        return listDocuments.values.flatMap { $0.labels }
    }
    
    // MARK: - Helper
    
    private func cleanListId(_ listId: String) -> String {
        if listId.hasPrefix("local-") {
            return String(listId.dropFirst(6))
        }
        return listId
    }
}
