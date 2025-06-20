//
//  LocalShoppingListStore.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 06/06/2025.
//

import Foundation

actor LocalShoppingListStore: ShoppingListProvider {
    static let shared = LocalShoppingListStore()

    private var lists: [ShoppingListSummary] = []
    private var items: [ShoppingItem] = []
    private var labels: [ShoppingLabel] = []

    private let listsFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("local_lists.json")
    private let itemsFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("local_items.json")
    private let labelsFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("local_labels.json")

    init() {
        Task {
            await loadData()
        }
    }

    // MARK: - Data Persistence

    private func loadData() async {
        //print("📂 [Local Load] Starting to load local data...")

        // Load Lists
        if FileManager.default.fileExists(atPath: listsFileURL.path) {
            do {
                let data = try Data(contentsOf: listsFileURL)
                let decoded = try JSONDecoder().decode([ShoppingListSummary].self, from: data)
                self.lists = decoded
                //print("✅ [Local Load] Loaded \(decoded.count) shopping lists")
            } catch {
                print("❌ [Local Load] Failed to load lists:", error)
            }
        } else {
            print("📭 [Local Load] No list file found at \(listsFileURL.lastPathComponent)")
        }

        // Load Items
        if FileManager.default.fileExists(atPath: itemsFileURL.path) {
            do {
                let data = try Data(contentsOf: itemsFileURL)
                let decoded = try JSONDecoder().decode([ShoppingItem].self, from: data)
                self.items = decoded
                //print("✅ [Local Load] Loaded \(decoded.count) shopping items")
            } catch {
                print("❌ [Local Load] Failed to load items:", error)
            }
        }

        // Load Labels
        if FileManager.default.fileExists(atPath: labelsFileURL.path) {
            do {
                let data = try Data(contentsOf: labelsFileURL)
                let decoded = try JSONDecoder().decode([ShoppingLabel].self, from: data)
                self.labels = decoded
                //print("✅ [Local Load] Loaded \(decoded.count) shopping labels")
            } catch {
                print("❌ [Local Load] Failed to load labels:", error)
            }
        }
    }

    private func save() async {
        do {
            //print("💾 [Local Save] Saving data...")

            let listData = try JSONEncoder().encode(lists)
            let itemData = try JSONEncoder().encode(items)
            let labelData = try JSONEncoder().encode(labels)

            //print("📦 [Local Save] List count: \(lists.count)")
            //print("📦 [Local Save] Item count: \(items.count)")
            //print("📦 [Local Save] Label count: \(labels.count)")

            try listData.write(to: listsFileURL)
            try itemData.write(to: itemsFileURL)
            try labelData.write(to: labelsFileURL)

            //print("✅ [Local Save] Save successful to:")
            //print("   - Lists: \(listsFileURL.lastPathComponent)")
            //print("   - Items: \(itemsFileURL.lastPathComponent)")
            //print("   - Labels: \(labelsFileURL.lastPathComponent)")
        } catch {
            print("❌ [Local Save] Save failed:", error)
        }
    }

    // MARK: - Lists

    func fetchShoppingLists() async throws -> [ShoppingListSummary] {
        return lists
    }

    func createList(_ list: ShoppingListSummary) async throws {
        //print("📝 [Local] Creating list: \(list.name)")
        lists.append(list)
        await save()
    }

    func updateList(_ list: ShoppingListSummary, with name: String, extras: [String: String], items: [ShoppingItem]) async throws {
        if let index = lists.firstIndex(where: { $0.id == list.id }) {
            lists[index].name = name
            lists[index].extras = extras
            
            self.items.removeAll { $0.shoppingListId == list.id }
            self.items.append(contentsOf: items)
            
            await save()
        }
    }

    func deleteList(_ list: ShoppingListSummary) async throws {
        lists.removeAll { $0.id == list.id }
        items.removeAll { $0.shoppingListId == list.id }
        await save()
    }

    // MARK: - Items

    func fetchItems(for listId: String) async throws -> [ShoppingItem] {
        return items.filter { $0.shoppingListId == listId }
    }

    func addItem(_ item: ShoppingItem, to listId: String) async throws {
        items.append(item)
        await save()
    }

    func deleteItem(_ item: ShoppingItem) async throws {
        items.removeAll { $0.id == item.id }
        await save()
    }

    func updateItem(_ item: ShoppingItem) async throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            throw NSError(domain: "Item not found", code: 1, userInfo: nil)
        }

        // Update the item with all fields from the input
        var updatedItem = item
            //updatedItem.checked.toggle() // Toggle checked value

        items[index] = updatedItem

        await save()
    }

    // MARK: - Labels

    func saveLabel(_ label: ShoppingLabel) async throws {
        labels.append(label)
        await save()
    }

    func updateLabel(_ label: ShoppingLabel) async throws {
        if let index = labels.firstIndex(where: { $0.id == label.id }) {
            labels[index] = label
            await save()
        }
    }

    func deleteLabel(_ label: ShoppingLabel) async throws {
        labels.removeAll { $0.id == label.id }
        await save()
    }

    func fetchLabels(for list: ShoppingListSummary) async throws -> [ShoppingLabel] {
        let matchingLabels = labels.filter { $0.localTokenId == list.localTokenId }

        //print("📦 [Labels] Returning \(matchingLabels.count) labels for list \(list.name) (\(list.id))")
        for label in matchingLabels {
           // print("• Label: [\(label.id)] \(label.name), groupId: \(label.groupId ?? "nil")")
        }

        return matchingLabels
    }

    func fetchAllLocalLabels() async throws -> [ShoppingLabel] {
        return labels
    }
}
