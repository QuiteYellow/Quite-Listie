import Foundation
import SwiftUI

@MainActor
class WelcomeViewModel: ObservableObject {
    @Published var lists: [ShoppingListSummary] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var uncheckedCounts: [String: Int] = [:]
    



    func loadLists() async {
        await MainActor.run {
            errorMessage = nil
            isLoading = true
        }

        do {
            try Task.checkCancellation()
            let fetchedLists = try await ShoppingListAPI.shared.fetchShoppingLists()

            // Animate the lists update
            await MainActor.run {
                withAnimation {
                    lists = fetchedLists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            }

            try Task.checkCancellation()

            // Animate the uncheckedCounts update
            let counts = await loadUncheckedCounts()

            await MainActor.run {
                withAnimation {
                    uncheckedCounts = counts
                    isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                isLoading = false
            }

            if error is CancellationError {
                print("Load lists task was cancelled")
                return
            }

            await MainActor.run {
                errorMessage = "Failed to load lists: \(error.localizedDescription)"
            }
            print("⭐️ Failed to load lists: \(error.localizedDescription)")
        }
    }

    // Change loadUncheckedCounts to return the counts instead of mutating @Published directly
    func loadUncheckedCounts() async -> [String: Int] {
        do {
            let allItems = try await ShoppingListAPI.shared.fetchItems()
            let groupedItems = Dictionary(grouping: allItems, by: { $0.shoppingListId })

            var counts: [String: Int] = [:]
            for list in lists {
                let itemsForList = groupedItems[list.id] ?? []
                let unchecked = itemsForList.filter { !$0.checked }.count
                counts[list.id] = unchecked
            }
            return counts
        } catch {
            var counts: [String: Int] = [:]
            for list in lists {
                counts[list.id] = 0
            }
            return counts
        }
    }
}
