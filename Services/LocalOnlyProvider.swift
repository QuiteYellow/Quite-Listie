//
//  LocalOnlyProvider.swift
//  ListsForMealie
//
//  Simplified provider - local storage only, no API
//

import Foundation

class LocalOnlyProvider: ShoppingListProvider {
    static let shared = LocalOnlyProvider()
    private let store = LocalShoppingListStore.shared
    
    func fetchShoppingLists() async throws -> [ShoppingListSummary] {
        let lists = try await store.fetchShoppingLists()
        
        return lists + [ExampleData.welcomeList]
    }
    
    func fetchItems(for listId: String) async throws -> [ShoppingItem] {
        // Handle welcome list
        if listId == ExampleData.welcomeListId {
            return ExampleData.welcomeItems
        }
        
        return try await store.fetchItems(for: listId)
    }
    
    func addItem(_ item: ShoppingItem, to listId: String) async throws {
        try await store.addItem(item, to: listId)
    }
    
    func deleteItem(_ item: ShoppingItem) async throws {
        try await store.deleteItem(item)
    }
    
    func restoreItem(_ item: ShoppingItem) async throws {
        try await store.restoreItem(item)
    }

    func permanentlyDeleteItem(_ item: ShoppingItem) async throws {
        try await store.permanentlyDeleteItem(item)
    }

    func fetchDeletedItems(for listId: String) async throws -> [ShoppingItem] {
        return try await store.fetchDeletedItems(for: listId)
    }
    
    func createList(_ list: ShoppingListSummary) async throws {
        try await store.createList(list)
    }
    
    func deleteList(_ list: ShoppingListSummary) async throws {
        try await store.deleteList(list)
    }
    
    func updateItem(_ item: ShoppingItem) async throws {
        try await store.updateItem(item)
    }
    
    func updateList(_ list: ShoppingListSummary, with name: String, extras: [String: String], items: [ShoppingItem]) async throws {
        try await store.updateList(list, with: name, extras: extras, items: items)
    }
    
    func fetchLabels(for list: ShoppingListSummary) async throws -> [ShoppingLabel] {
        return try await store.fetchLabels(for: list)
    }
    
    func fetchAllLabels() async throws -> [ShoppingLabel] {
        return try await store.fetchAllLocalLabels()
    }
    
    func deleteLabel(_ label: ShoppingLabel) async throws {
        try await store.deleteLabel(label)
    }
    
    func updateLabel(_ label: ShoppingLabel) async throws {
        try await store.updateLabel(label)
    }
    
    func createLabel(_ label: ShoppingLabel) async throws {
        try await store.saveLabel(label)
    }
}
