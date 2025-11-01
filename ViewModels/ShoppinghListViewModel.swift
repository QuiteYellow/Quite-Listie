import Foundation
import SwiftUI

@MainActor
class ShoppingListViewModel: ObservableObject {
    @Published var items: [ShoppingItem] = []
    @Published var isLoading = false
    @Published var labels: [ShoppingLabel] = []
    let list: ShoppingListSummary
    var shoppingListId: String { list.id }
    private var fetchTask: Task<Void, Never>? = nil

    init(list: ShoppingListSummary) {
        self.list = list
    }

    func loadItems() async {
        fetchTask?.cancel()
        fetchTask = Task {
            isLoading = true
            do {
                let allItems = try await CombinedShoppingListProvider.shared.fetchItems(for: shoppingListId)
                items = allItems
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
            labels = try await CombinedShoppingListProvider.shared.fetchLabels(for: list)
        } catch {
            print("Error loading labels: \(error)")
        }
    }

    @MainActor
    func addItem(note: String, label: ShoppingLabel?, quantity: Double?, markdownNotes: String?) async -> Bool {
        var newItem = ShoppingItem(
            id: UUID(),
            note: note,
            checked: false,
            shoppingListId: shoppingListId,
            label: label,
            quantity: quantity
        )
        
        if let mdNotes = markdownNotes {
            newItem.markdownNotes = mdNotes  // This sets extras["markdownNotes"]
        }
        
        //  Copy the token ID from the list
            newItem.localTokenId = list.localTokenId

        do {
            try await CombinedShoppingListProvider.shared.addItem(newItem, to: shoppingListId)
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
                try await CombinedShoppingListProvider.shared.deleteItem(item)  // Pass full item for token lookup
            } catch {
                print("Error deleting item: \(error)")
            }
        }
        await loadItems()
    }
    
    @MainActor
    func deleteItem(_ item: ShoppingItem) async -> Bool {
        do {
            try await CombinedShoppingListProvider.shared.deleteItem(item)
            
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items.remove(at: index)
            }
            
            return true
        } catch {
            print("⚠️ Failed to delete item:", error)
            return false
        }
    }

    func toggleChecked(for item: ShoppingItem, didUpdate: @escaping (Int) async -> Void) async {
        var updated = item
        updated.checked.toggle()
        do {
            try await CombinedShoppingListProvider.shared.updateItem(updated)

            if let index = items.firstIndex(where: { $0.id == updated.id }) {
                items[index] = updated
            }

            let count = items.filter { $0.shoppingListId == item.shoppingListId && !$0.checked }.count
            await didUpdate(count)
        } catch {
            print("Error toggling item: \(error)")
        }
    }
    
    func setAllItems(for listId: String, toCompleted completed: Bool, didUpdate: @escaping (Int) async -> Void) async {
        var updatedItems: [ShoppingItem] = []

        for var item in items where item.shoppingListId == listId {
            if item.checked != completed {
                item.checked = completed
                do {
                    try await CombinedShoppingListProvider.shared.updateItem(item)
                    if let index = items.firstIndex(where: { $0.id == item.id }) {
                        items[index] = item
                    }
                    updatedItems.append(item)
                } catch {
                    print("Error updating item: \(error)")
                }
            }
        }

        // Count unchecked (active) items in this list
        let count = items.filter { $0.shoppingListId == listId && !$0.checked }.count
        await didUpdate(count)
    }
    
    func colorForLabel(name: String) -> Color? {
        if let item = items.first(where: { $0.label?.name == name }),
           let hex = item.label?.color {
            return Color(hex: hex)
        }
        return nil
    }
    
    @MainActor
    func updateItem(
        _ item: ShoppingItem,
        note: String,
        label: ShoppingLabel?,
        quantity: Double?,
        extras: [String: String]? = nil
    ) async -> Bool {
        var updatedItem = item
        updatedItem.note = note
        updatedItem.label = label
        updatedItem.quantity = quantity
        if let extras = extras {
            updatedItem.extras = extras
        }

        do {
            try await CombinedShoppingListProvider.shared.updateItem(updatedItem)

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
            item.label?.name ?? "No Label"
        }
    }

    var sortedLabelKeys: [String] {
        itemsGroupedByLabel.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}
