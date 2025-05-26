import Foundation
import SwiftUI

@MainActor
class ShoppingListViewModel: ObservableObject {
    @Published var items: [ShoppingItem] = []
    @Published var isLoading = false
    @Published var labels: [ShoppingItem.LabelWrapper] = []
    private let shoppingListId: String
    private var fetchTask: Task<Void, Never>? = nil

    init(shoppingListId: String) {
        self.shoppingListId = shoppingListId
    }

    func loadItems() async {
        fetchTask?.cancel()
        fetchTask = Task {
            isLoading = true
            do {
                let allItems = try await ShoppingListAPI.shared.fetchItems()
                items = allItems.filter { $0.shoppingListId == shoppingListId }
            } catch {
                if (error as NSError).code != NSURLErrorCancelled {
                    print("Error loading items: \(error)")
                }
            }
            isLoading = false
            fetchTask = nil
        }
        await fetchTask?.value
    }
    
    func loadLabels() async {
        do {
            labels = try await ShoppingListAPI.shared.fetchShoppingLabels()
        } catch {
            print("Error loading labels: \(error)")
        }
    }

    @MainActor
    func addItem(note: String, label: ShoppingItem.LabelWrapper?, quantity: Double?) async -> Bool {
        let newItem = ShoppingItem(
            id: UUID(),
            note: note,
            checked: false,
            shoppingListId: shoppingListId,
            label: label,
            quantity: quantity
        )

        do {
            try await ShoppingListAPI.shared.addItem(newItem, to: shoppingListId)
            await loadItems()
            return true
        } catch {
            print("⚠️ Error adding item:", error)
            return false
        }
    }

    func deleteItems(at offsets: IndexSet) async {
        for index in offsets {
            let item = items[index]
            do {
                try await ShoppingListAPI.shared.deleteItem(item)  // Pass full item for token lookup
            } catch {
                print("Error deleting item: \(error)")
            }
        }
        await loadItems()
    }
    
    @MainActor
    func deleteItem(_ item: ShoppingItem) async -> Bool {
        do {
            try await ShoppingListAPI.shared.deleteItem(item)
            
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items.remove(at: index)
            }
            
            return true
        } catch {
            print("⚠️ Failed to delete item:", error)
            return false
        }
    }

    func toggleChecked(for item: ShoppingItem) async {
        var updated = item
        updated.checked.toggle()
        do {
            try await ShoppingListAPI.shared.toggleItem(updated)

            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = updated
            }
        } catch {
            print("Error toggling item: \(error)")
        }
    }
    
    func colorForLabel(name: String) -> Color? {
        if let item = items.first(where: { $0.label?.name == name }),
           let hex = item.label?.color {
            return Color(hex: hex)
        }
        return nil
    }
    
    @MainActor
    func updateItem(_ item: ShoppingItem, note: String, label: ShoppingItem.LabelWrapper?, quantity: Double?) async -> Bool {
        var updatedItem = item
        updatedItem.note = note
        updatedItem.label = label
        updatedItem.quantity = quantity

        do {
            try await ShoppingListAPI.shared.toggleItem(updatedItem)

            if let index = items.firstIndex(where: { $0.id == updatedItem.id }) {
                items[index] = updatedItem
            }

            return true
        } catch {
            print("⚠️ Failed to update item:", error)
            return false
        }
    }
    
    var itemsGroupedByLabel: [String: [ShoppingItem]] {
        Dictionary(grouping: items) { item in
            item.label?.name ?? "None"
        }
    }

    var sortedLabelKeys: [String] {
        itemsGroupedByLabel.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}
