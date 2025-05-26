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

    func addItem(note: String, label: ShoppingItem.LabelWrapper?, quantity: Double?) async {
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
        } catch {
            print("⚠️ Error adding item:", error)
        }
    }

    // Now delete takes ShoppingItem (with tokenId), not just UUID
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
    
    func deleteItem(_ item: ShoppingItem) async {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            await deleteItems(at: IndexSet(integer: index))
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
    
    func updateItem(_ item: ShoppingItem, note: String, label: ShoppingItem.LabelWrapper?, quantity: Double?) async {
        var updatedItem = item
        updatedItem.note = note
        updatedItem.label = label
        updatedItem.quantity = quantity

        do {
            try await ShoppingListAPI.shared.toggleItem(updatedItem)  // PUT update

            if let index = items.firstIndex(where: { $0.id == updatedItem.id }) {
                items[index] = updatedItem
            }
        } catch {
            print("Failed to update item:", error)
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
