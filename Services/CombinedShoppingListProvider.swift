//
//  CombinedShoppingListProvider.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 06/06/2025.
//


class CombinedShoppingListProvider: ShoppingListProvider {
    static let shared = CombinedShoppingListProvider()
    
    let api = ShoppingListAPI.shared
    let local = LocalShoppingListStore.shared

    func fetchShoppingLists() async throws -> [ShoppingListSummary] {
        var remoteLists: [ShoppingListSummary] = []
        do {
            remoteLists = try await api.fetchShoppingLists()
        } catch {
            print("⚠️ Failed to fetch remote lists: \(error.localizedDescription)")
        }

        let localLists = (try? await local.fetchShoppingLists()) ?? []
        let allLists = remoteLists + localLists

        if allLists.isEmpty {
            return [ExampleData.welcomeList]
        }

        return allLists
    }

    func fetchItems(for listId: String) async throws -> [ShoppingItem] {
        if listId == ExampleData.welcomeListId {
            return ExampleData.welcomeItems
        }

        if listId.isLocalListId {
            return try await local.fetchItems(for: listId)
        } else {
            return try await api.fetchItems().filter { $0.shoppingListId == listId }
        }
    }

    func addItem(_ item: ShoppingItem, to listId: String) async throws {
        if listId.isLocalListId {
            try await local.addItem(item, to: listId)
        } else {
            try await api.addItem(item, to: listId)
        }
    }

    func deleteItem(_ item: ShoppingItem) async throws {
        if item.isLocal {
            try await local.deleteItem(item)
        } else {
            try await api.deleteItem(item)
        }
    }

    func createList(_ list: ShoppingListSummary) async throws {
        if list.isLocal {
            try await local.createList(list)
        } else {
            try await api.createShoppingList(list)
        }
    }

    func deleteList(_ list: ShoppingListSummary) async throws {
        if list.isLocal {
            try await local.deleteList(list)
        } else {
            try await api.deleteList(list)
        }
    }

    func toggleItem(_ item: ShoppingItem) async throws {
        if item.isLocal {
            try await local.toggleItem(item)
        } else {
            try await api.toggleItem(item)
        }
    }

    func updateList(_ list: ShoppingListSummary, with name: String, extras: [String: String], items: [ShoppingItem]) async throws {
        if list.isLocal {
            try await local.updateList(list, with: name, extras: extras, items: items)
        } else {
            try await api.updateShoppingListName(list: list, newName: name, items: items, extras: extras)
        }
    }
    
    func fetchLabels(for list: ShoppingListSummary) async throws -> [ShoppingLabel] {
        if list.isLocal {
           // print("📦 [Labels] Fetching LOCAL ONLY for: \(list.name) (\(list.id))")
            return try await local.fetchLabels(for: list)
        } else {
           // print("📦 [Labels] Fetching REMOTE ONLY for: \(list.name) (\(list.id))")
            do {
                return try await api.fetchShoppingLabels()
            } catch {
                print("⚠️ Failed to fetch remote labels: \(error.localizedDescription)")
                return []
            }
        }
    }
    
    func fetchAllLabels() async throws -> [ShoppingLabel] {
        let remoteLabels: [ShoppingLabel]
        do {
            remoteLabels = try await ShoppingListAPI.shared.fetchShoppingLabels()
        } catch {
            print("⚠️ Failed to fetch remote labels: \(error.localizedDescription)")
            remoteLabels = []
        }

        let localLabels = try await LocalShoppingListStore.shared.fetchAllLocalLabels()
        return remoteLabels + localLabels
    }
}

