import Foundation
import SwiftUI

@MainActor
class WelcomeViewModel: ObservableObject {
    @Published var lists: [ShoppingListSummary] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var uncheckedCounts: [String: Int] = [:]

    @Published var selectedListForSettings: ShoppingListSummary? = nil
    @Published var showingListSettings = false

    func loadLists() async {
        isLoading = true
        errorMessage = nil

        do {
            let fetchedLists = try await ShoppingListAPI.shared.fetchShoppingLists()
            lists = fetchedLists.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            let counts = await loadUncheckedCounts()
            uncheckedCounts = counts
        } catch is CancellationError {
            print("Load lists task was cancelled")
        } catch {
            errorMessage = "Failed to load lists: \(error.localizedDescription)"
            print("⭐️ Failed to load lists: \(error)")
        }

        isLoading = false
    }

    func loadUncheckedCounts() async -> [String: Int] {
        do {
            let allItems = try await ShoppingListAPI.shared.fetchItems()
            let groupedItems = Dictionary(grouping: allItems, by: \.shoppingListId)

            return lists.reduce(into: [:]) { result, list in
                let unchecked = groupedItems[list.id]?.filter { !$0.checked }.count ?? 0
                result[list.id] = unchecked
            }
        } catch {
            return Dictionary(uniqueKeysWithValues: lists.map { ($0.id, 0) })
        }
    }

    func updateListName(listID: String, newName: String, extras: [String: String]) async {
        guard let index = lists.firstIndex(where: { $0.id == listID }) else { return }

        do {
            let list = lists[index]
            let allItems = try await ShoppingListAPI.shared.fetchItems()
            let listItems = allItems.filter { $0.shoppingListId == list.id }

            try await ShoppingListAPI.shared.updateShoppingListName(
                list: list,
                newName: newName,
                items: listItems,
                extras: extras
            )

            lists[index].name = newName
        } catch {
            print("❌ Failed to update list name: \(error.localizedDescription)")
        }
    }

    func toggleFavourite(for list: ShoppingListSummary, userID: String) async {
        var favourites = list.extras?["favouritedBy"]?
            .components(separatedBy: ",")
            .filter { !$0.isEmpty } ?? []

        let isFavourited = favourites.contains(userID)

        if isFavourited {
            favourites.removeAll { $0 == userID }
        } else {
            favourites.append(userID)
        }

        let updatedExtras = list.updatedExtras(with: [
            "favouritedBy": favourites.joined(separator: ",")
        ])

        do {
            let allItems = try await ShoppingListAPI.shared.fetchItems()
            let listItems = allItems.filter { $0.shoppingListId == list.id }

            try await ShoppingListAPI.shared.updateShoppingListName(
                list: list,
                newName: list.name,
                items: listItems,
                extras: updatedExtras
            )

            await loadLists()
        } catch {
            print("❌ Failed to toggle favourite: \(error)")
        }
    }
}
