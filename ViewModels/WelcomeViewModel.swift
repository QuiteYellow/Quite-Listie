//
//  WelcomeViewModel.swift
//  Listie.md
//
//  View model for tracking list counts and state
//  Now uses UnifiedListProvider for all list operations
//

import Foundation
import SwiftUI

/// A reminder item paired with its parent list context and label metadata
struct ReminderEntry: Identifiable {
    var id: UUID { item.id }
    let item: ShoppingItem
    let list: UnifiedList
    let labelName: String?
    let labelColor: String?   // Hex color

    /// Folder name for external lists (e.g. "Shared" folder)
    var folderName: String? {
        if case .external(let url) = list.source {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return nil
    }
}

@MainActor
class WelcomeViewModel: ObservableObject {
    @Published var lists: [ShoppingListSummary] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var uncheckedCounts: [String: Int] = [:]

    /// All unchecked items with reminders across every list
    @Published var reminderEntries: [ReminderEntry] = []

    /// Count of reminder items due today or overdue
    var todayReminderCount: Int {
        let calendar = Calendar.current
        return reminderEntries.filter { entry in
            guard let date = entry.item.reminderDate else { return false }
            return date < Date() || calendar.isDateInToday(date)
        }.count
    }

    /// Count of all reminder items (overdue + today + future, like Apple Reminders)
    var scheduledReminderCount: Int {
        return reminderEntries.filter { entry in
            entry.item.reminderDate != nil
        }.count
    }

    @Published var selectedListForSettings: ShoppingListSummary? = nil
    @Published var showingListSettings = false

    /// Legacy method - kept for backward compatibility but now does nothing
    /// All list loading is now done through UnifiedListProvider
    func loadLists() async {
        // No-op - lists are loaded through UnifiedListProvider.loadAllLists()
    }

    /// Loads unchecked item counts and reminder entries for all unified lists
    func loadUnifiedCounts(for lists: [UnifiedList], provider: UnifiedListProvider) async {
        var result: [String: Int] = [:]
        var entries: [ReminderEntry] = []

        for list in lists {
            do {
                let items = try await provider.fetchItems(for: list)
                let active = items.filter { !$0.checked && !$0.isDeleted }
                result[list.id] = active.count

                // Fetch labels once per list for label resolution
                let labels = try await provider.fetchLabels(for: list)

                // Collect items with reminders
                for item in active where item.reminderDate != nil {
                    var labelName: String? = nil
                    var labelColor: String? = nil
                    if let labelId = item.labelId,
                       let label = labels.first(where: { $0.id == labelId }) {
                        labelName = label.name
                        labelColor = label.color
                    }
                    entries.append(ReminderEntry(
                        item: item,
                        list: list,
                        labelName: labelName,
                        labelColor: labelColor
                    ))
                }
            } catch {
                result[list.id] = 0
            }
        }

        await MainActor.run {
            uncheckedCounts = result
            reminderEntries = entries
        }
    }
}
