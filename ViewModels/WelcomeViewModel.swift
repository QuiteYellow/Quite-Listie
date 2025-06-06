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
            let fetchedLists = try await CombinedShoppingListProvider.shared.fetchShoppingLists()
            let sortedLists = fetchedLists.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            self.lists = sortedLists
            self.uncheckedCounts = await loadUncheckedCounts(for: sortedLists)
        } catch {
            self.errorMessage = "Failed to load lists: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func loadUncheckedCounts(for lists: [ShoppingListSummary]) async -> [String: Int] {
        var result: [String: Int] = [:]

        for list in lists {
            do {
                let items = try await CombinedShoppingListProvider.shared.fetchItems(for: list.id)
                let count = items.filter { !$0.checked }.count
                result[list.id] = count
            } catch {
                result[list.id] = 0
            }
        }

        return result
    }

    func updateListName(listID: String, newName: String, extras: [String: String]) async {
        guard let index = lists.firstIndex(where: { $0.id == listID }) else { return }
        let list = lists[index]

        do {
            let items = try await CombinedShoppingListProvider.shared.fetchItems(for: list.id)

            try await CombinedShoppingListProvider.shared.updateList(
                list,
                with: newName,
                extras: extras,
                items: items
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
            let items = try await CombinedShoppingListProvider.shared.fetchItems(for: list.id)

            try await CombinedShoppingListProvider.shared.updateList(
                list,
                with: list.name,
                extras: updatedExtras,
                items: items
            )

            await loadLists()
        } catch {
            print("❌ Failed to toggle favourite: \(error)")
        }
    }
}
