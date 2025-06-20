import Foundation

class CombinedShoppingListProvider: ShoppingListProvider {
    static let shared = CombinedShoppingListProvider()
    
    let api = ShoppingListAPI.shared
    let local = LocalShoppingListStore.shared

    func fetchShoppingLists() async throws -> [ShoppingListSummary] {
        var remoteLists: [ShoppingListSummary] = []

        // ✅ Only fetch remote if a valid server URL is configured
        if AppSettings.shared.validatedServerURL != nil {
            do {
                remoteLists = try await api.fetchShoppingLists()
            } catch {
                print("⚠️ Failed to fetch remote lists: \(error.localizedDescription)")
            }
        } else {
            print("ℹ️ No valid API URL configured — skipping remote list fetch.")
        }

        let localLists = (try? await local.fetchShoppingLists()) ?? []
        let allLists = remoteLists + localLists

        return allLists.isEmpty ? [ExampleData.welcomeList] : allLists
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

    func updateItem(_ item: ShoppingItem) async throws {
        if item.isLocal {
            try await local.updateItem(item)
        } else {
            try await api.updateItem(item)
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
            return try await local.fetchLabels(for: list)
        } else {
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
        if AppSettings.shared.validatedServerURL != nil {
            do {
                remoteLabels = try await api.fetchShoppingLabels()
            } catch {
                print("⚠️ Failed to fetch remote labels: \(error.localizedDescription)")
                remoteLabels = []
            }
        } else {
            remoteLabels = []
        }

        let localLabels = try await local.fetchAllLocalLabels()
        return remoteLabels + localLabels
    }

    func deleteLabel(_ label: ShoppingLabel) async throws {
        if label.isLocal {
            try await local.deleteLabel(label)
        } else {
            guard let tokenInfo = AppSettings.shared.tokens.first(where: { $0.id == label.localTokenId }) else {
                throw NSError(domain: "MissingToken", code: 0, userInfo: nil)
            }
            try await api.deleteLabel(label: label, tokenInfo: tokenInfo)
        }
    }

    func updateLabel(_ label: ShoppingLabel) async throws {
        if label.isLocal {
            try await local.updateLabel(label)
        } else {
            guard let tokenInfo = AppSettings.shared.tokens.first(where: { $0.id == label.localTokenId }) else {
                throw NSError(domain: "MissingTokenInfo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing tokenInfo for label: \(label.name)"])
            }
            try await api.updateLabel(label: label, tokenInfo: tokenInfo)
        }
    }
}
