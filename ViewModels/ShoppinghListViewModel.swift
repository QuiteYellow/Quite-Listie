//
//  ListViewModel.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 25/05/2025.
//

import Foundation
import SwiftUI

@MainActor
class ShoppingListViewModel: ObservableObject {
    @Published var items: [ShoppingItem] = []
    @Published var isLoading = false
    private let shoppingListId: String
    private var fetchTask: Task<Void, Never>? = nil

    init(shoppingListId: String) {
            self.shoppingListId = shoppingListId
        }

    func loadItems() async {
            fetchTask?.cancel() // cancel any ongoing fetch
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

    func addItem(note: String, quantity: Double? = nil) async {
        let newItem = ShoppingItem(
            id: UUID(),
            note: note,
            checked: false,
            shoppingListId: shoppingListId,
            quantity: quantity
        )

        do {
            try await ShoppingListAPI.shared.addItem(newItem, to: shoppingListId)
            await loadItems()
        } catch {
            print("Error adding item: \(error)")
        }
    }

    func deleteItem(at offsets: IndexSet) async {
        for index in offsets {
            let id = items[index].id
            do {
                try await ShoppingListAPI.shared.deleteItem(id)
            } catch {
                print("Error deleting item: \(error)")
            }
        }
        await loadItems()
    }

    func toggleChecked(for item: ShoppingItem) async {
        var updated = item
        updated.checked.toggle()
        do {
            try await ShoppingListAPI.shared.toggleItem(updated)
            
            // After the toggle API call, update the local list with the toggled item,
            // preserving the label from the existing item
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                updated.label = items[index].label
                items[index] = updated
            }
        } catch {
            print("Error toggling item: \(error)")
        }
    }
    
    
    func colorForLabel(name: String) -> Color? {
        // Find first item with matching label and get color string
        if let item = items.first(where: { $0.label?.name == name }),
           let hex = item.label?.color {
            return Color(hex: hex)
        }
        return nil
    }
    
    
    var itemsGroupedByLabel: [String: [ShoppingItem]] {
            Dictionary(grouping: items) { item in
                item.label?.name ?? "Unlabeled"  // Adjust this depending on your model
            }
        }

        var sortedLabelKeys: [String] {
            itemsGroupedByLabel.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        }
    
    
}

