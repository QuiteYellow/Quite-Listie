//
//  WelcomeViewModel.swift
//  Listie.md
//
//  View model for tracking list counts and state
//  Now uses UnifiedListProvider for all list operations
//

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

    /// Legacy method - kept for backward compatibility but now does nothing
    /// All list loading is now done through UnifiedListProvider
    func loadLists() async {
        // No-op - lists are loaded through UnifiedListProvider.loadAllLists()
    }

    /// Loads unchecked item counts for all unified lists
    func loadUnifiedCounts(for lists: [UnifiedList], provider: UnifiedListProvider) async {
        var result: [String: Int] = [:]

        for list in lists {
            do {
                let items = try await provider.fetchItems(for: list)
                let count = items.filter { !$0.checked && !$0.isDeleted }.count
                result[list.id] = count
            } catch {
                result[list.id] = 0
            }
        }

        await MainActor.run {
            uncheckedCounts = result
        }
    }
}
