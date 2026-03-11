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

/// An item with a pinned location, paired with its parent list and label metadata
struct LocationEntry: Identifiable {
    var id: UUID { item.id }
    let item: ShoppingItem
    let list: UnifiedList
    let labelName: String?
    let labelColor: String?   // Hex color
}

@Observable
@MainActor
class WelcomeViewModel {
    var lists: [ShoppingListSummary] = []
    var isLoading = false
    var errorMessage: String?
    var uncheckedCounts: [String: Int] = [:]

    /// All unchecked items with reminders across every list
    var reminderEntries: [ReminderEntry] = []

    /// All non-deleted items with pinned locations across every list
    var locationEntries: [LocationEntry] = []

    /// All labels referenced by items with locations (deduplicated by ID)
    var allLocationLabels: [ShoppingLabel] = []

    /// Count of non-completed pinned items across all lists (shown on sidebar card)
    var activeLocationCount: Int {
        locationEntries.filter { !$0.item.checked }.count
    }

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

    var selectedListForSettings: ShoppingListSummary? = nil
    var showingListSettings = false

    /// Legacy method - kept for backward compatibility but now does nothing
    /// All list loading is now done through UnifiedListProvider
    func loadLists() async {
        // No-op - lists are loaded through UnifiedListProvider.loadAllLists()
    }

    /// Loads unchecked item counts, reminder entries, and location entries for all unified lists
    func loadUnifiedCounts(for lists: [UnifiedList], provider: UnifiedListProvider) async {
        var result: [String: Int] = [:]
        var entries: [ReminderEntry] = []
        var locEntries: [LocationEntry] = []
        var labelsDict: [String: ShoppingLabel] = [:]

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

                // Collect all non-deleted items with pinned locations
                for item in items where item.location != nil && !item.isDeleted {
                    var labelName: String? = nil
                    var labelColor: String? = nil
                    if let labelId = item.labelId,
                       let label = labels.first(where: { $0.id == labelId }) {
                        labelName = label.name
                        labelColor = label.color
                    }
                    locEntries.append(LocationEntry(
                        item: item,
                        list: list,
                        labelName: labelName,
                        labelColor: labelColor
                    ))
                }

                // Accumulate labels (dedup by ID — first definition wins)
                for label in labels where labelsDict[label.id] == nil {
                    labelsDict[label.id] = label
                }
            } catch {
                result[list.id] = 0
            }
        }

        await MainActor.run {
            uncheckedCounts = result
            reminderEntries = entries
            locationEntries = locEntries
            allLocationLabels = Array(labelsDict.values)
        }
    }
}
