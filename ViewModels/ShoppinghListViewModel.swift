//
//  ShoppingListViewModel.swift (V2 - UNIFIED VERSION)
//  Listie.md
//
//  Updated to use V2 format with labelId references and timestamps
//

import Foundation
import SwiftUI

@MainActor
class ShoppingListViewModel: ObservableObject {
    @Published var items: [ShoppingItem] = []
    @Published var isLoading = false
    @Published var labels: [ShoppingLabel] = []
    
    let list: UnifiedList
    let provider: UnifiedListProvider
    
    var shoppingListId: String { list.summary.id }

    init(list: UnifiedList, provider: UnifiedListProvider) {
        self.list = list
        self.provider = provider
    }

    func loadItems() async {
        isLoading = true
        do {
            let allItems = try await provider.fetchItems(for: list)
            // Filter out soft-deleted items
            items = allItems.filter { !($0.isDeleted ?? false) }
        } catch {
            print("Error loading items: \(error)")
        }
        isLoading = false
    }
    
    func loadLabels() async {
        do {
            labels = try await provider.fetchLabels(for: list)
        } catch {
            print("Error loading labels: \(error)")
        }
    }

    @MainActor
    func addItem(note: String, label: ShoppingLabel?, quantity: Double?, markdownNotes: String?) async -> Bool {
        // Use ModelHelpers to create a clean V2 item
        let newItem = ModelHelpers.createNewItem(
            note: note,
            quantity: quantity ?? 1,
            checked: false,
            labelId: label?.id,  // Reference by ID, not embedded object
            markdownNotes: markdownNotes
        )

        do {
            try await provider.addItem(newItem, to: list)
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
                try await provider.deleteItem(item, from: list)
            } catch {
                print("Error deleting item: \(error)")
            }
        }
        await loadItems()
    }
    
    @MainActor
    func deleteItem(_ item: ShoppingItem) async -> Bool {
        do {
            try await provider.deleteItem(item, from: list)
            
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
        updated.modifiedAt = Date()  // Update timestamp
        
        do {
            try await provider.updateItem(updated, in: list)

            if let index = items.firstIndex(where: { $0.id == updated.id }) {
                items[index] = updated
            }

            // Count unchecked items (works with both V1 and V2)
            let count = items.filter { !$0.checked }.count
            await didUpdate(count)
        } catch {
            print("Error toggling item: \(error)")
        }
    }
    
    func setAllItems(for listId: String, toCompleted completed: Bool, didUpdate: @escaping (Int) async -> Void) async {
        for var item in items {
            if item.checked != completed {
                item.checked = completed
                item.modifiedAt = Date()  // Update timestamp
                
                do {
                    try await provider.updateItem(item, in: list)
                    if let index = items.firstIndex(where: { $0.id == item.id }) {
                        items[index] = item
                    }
                } catch {
                    print("Error updating item: \(error)")
                }
            }
        }

        let count = items.filter { !$0.checked }.count
        await didUpdate(count)
    }
    
    func colorForLabel(name: String) -> Color? {
        // Find the label by name in the loaded labels array
        if let label = labels.first(where: { $0.name == name }) {
            return Color(hex: label.color)
        }
        return nil
    }
    
    func colorForLabelId(_ labelId: String) -> Color? {
        // Find the label by ID
        if let label = labels.first(where: { $0.id == labelId }) {
            return Color(hex: label.color)
        }
        return nil
    }
    
    @MainActor
    func updateItem(
        _ item: ShoppingItem,
        note: String,
        label: ShoppingLabel?,
        quantity: Double?,
        markdownNotes: String? = nil
    ) async -> Bool {
        var updatedItem = item
        updatedItem.note = note
        updatedItem.labelId = label?.id  // Use labelId reference instead of embedded object
        updatedItem.quantity = quantity ?? 1
        updatedItem.markdownNotes = markdownNotes  // Direct field
        updatedItem.modifiedAt = Date()  // Update timestamp

        do {
            try await provider.updateItem(updatedItem, in: list)

            if let index = items.firstIndex(where: { $0.id == updatedItem.id }) {
                items[index] = updatedItem
            }

            return true
        } catch {
            print("⚠️ Failed to update item:", error)
            return false
        }
    }
    
    // Helper to get label for an item
    func labelForItem(_ item: ShoppingItem) -> ShoppingLabel? {
        // First try V2 format (labelId)
        if let labelId = item.labelId {
            return labels.first(where: { $0.id == labelId })
        }
        // Fall back to V1 format (embedded label)
        return item.label
    }
    
    var itemsGroupedByLabel: [String: [ShoppingItem]] {
        let grouped = Dictionary(grouping: items) { item in
            // Use the helper to get label, works with both V1 and V2
            labelForItem(item)?.name ?? "No Label"
        }
        
        // Sort items within each group alphabetically
        return grouped.mapValues { items in
            items.sorted { item1, item2 in
                item1.note.localizedCaseInsensitiveCompare(item2.note) == .orderedAscending
            }
        }
    }

    var sortedLabelKeys: [String] {
        itemsGroupedByLabel.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}
