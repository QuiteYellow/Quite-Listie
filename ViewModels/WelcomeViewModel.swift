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
    let item: ListItem
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
    let item: ListItem
    let list: UnifiedList
    let labelName: String?
    let labelColor: String?   // Hex color
    let labelSymbol: String?
}

@Observable
@MainActor
class WelcomeViewModel {
    var lists: [ListSummary] = []
    var isLoading = false
    var errorMessage: String?
    var uncheckedCounts: [String: Int] = [:]

    /// All unchecked items with reminders across every list
    var reminderEntries: [ReminderEntry] = []

    /// All non-deleted items with pinned locations across every list
    var locationEntries: [LocationEntry] = []

    /// True once `loadUnifiedCounts` has completed at least one full fetch
    var hasLoadedLocations = false

    /// All labels referenced by items with locations (deduplicated by ID)
    var allLocationLabels: [ListLabel] = []

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

    var selectedListForSettings: ListSummary? = nil
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
        var labelsDict: [String: ListLabel] = [:]

        for list in lists {
            // Cache-first reads: never throw, never block on network. A list with no
            // cache yet returns empty arrays here — the provider schedules an async
            // load in the background and posts a change notification when it arrives.
            let items = await provider.fetchItemsForDisplay(for: list)
            let labels = await provider.fetchLabelsForDisplay(for: list)
            let active = items.filter { !$0.checked && !$0.isDeleted }
            result[list.id] = active.count

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
                var labelSymbol: String? = nil
                if let labelId = item.labelId,
                   let label = labels.first(where: { $0.id == labelId }) {
                    labelName = label.name
                    labelColor = label.color
                    labelSymbol = label.symbol
                }
                locEntries.append(LocationEntry(
                    item: item,
                    list: list,
                    labelName: labelName,
                    labelColor: labelColor,
                    labelSymbol: labelSymbol
                ))
            }

            // Accumulate labels (dedup by ID — first definition wins)
            for label in labels where labelsDict[label.id] == nil {
                labelsDict[label.id] = label
            }
        }

        await MainActor.run {
            uncheckedCounts = result
            reminderEntries = entries
            locationEntries = locEntries
            allLocationLabels = Array(labelsDict.values)
            hasLoadedLocations = true
        }
    }
}
