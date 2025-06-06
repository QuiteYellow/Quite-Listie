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
    
    private let listsFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("local_lists.json")
    private let itemsFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("local_items.json")
    
    private var labels: [ShoppingLabel] = []
    private let labelsFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("local_labels.json")

    init() {
        Task {
            await loadData()
        }
    }

    private func loadData() async {
        if let listData = try? Data(contentsOf: listsFileURL),
           let loadedLists = try? JSONDecoder().decode([ShoppingListSummary].self, from: listData) {
            self.lists = loadedLists
        }

        if let itemData = try? Data(contentsOf: itemsFileURL),
           let loadedItems = try? JSONDecoder().decode([ShoppingItem].self, from: itemData) {
            self.items = loadedItems
        }
        
        if let labelData = try? Data(contentsOf: labelsFileURL),
           let loadedLabels = try? JSONDecoder().decode([ShoppingLabel].self, from: labelData) {
            self.labels = loadedLabels
        }
    }

    private func save() async {
        do {
            let listData = try JSONEncoder().encode(lists)
            let itemData = try JSONEncoder().encode(items)
            let labelData = try JSONEncoder().encode(labels)

            try listData.write(to: listsFileURL)
            try itemData.write(to: itemsFileURL)
            try labelData.write(to: labelsFileURL)
        } catch {
            print("⚠️ Failed to save local data:", error.localizedDescription)
        }
    }

    // MARK: - Protocol Implementation

    func fetchShoppingLists() async throws -> [ShoppingListSummary] {
        return lists
    }

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

    func createList(_ list: ShoppingListSummary) async throws {
        lists.append(list)
        await save()
    }

    func deleteList(_ list: ShoppingListSummary) async throws {
        lists.removeAll { $0.id == list.id }
        items.removeAll { $0.shoppingListId == list.id }
        await save()
    }

    func toggleItem(_ item: ShoppingItem) async throws {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].checked.toggle()
            await save()
        }
    }

    func updateList(_ list: ShoppingListSummary, with name: String, extras: [String: String], items: [ShoppingItem]) async throws {
        if let index = lists.firstIndex(where: { $0.id == list.id }) {
            lists[index].name = name
            lists[index].extras = extras
            await save()
        }
    }
    
    func createLabel(_ label: ShoppingLabel) async throws {
        labels.append(label)
        await save()
    }

    func deleteLabel(_ label: ShoppingLabel) async throws {
        labels.removeAll { $0.id == label.id }
        await save()
    }

    func updateLabel(_ label: ShoppingLabel) async throws {
        if let index = labels.firstIndex(where: { $0.id == label.id }) {
            labels[index] = label
            await save()
        }
    }
    func fetchLabels(for list: ShoppingListSummary) async throws -> [ShoppingLabel] {
        return labels // ✅ all labels
    }
}
