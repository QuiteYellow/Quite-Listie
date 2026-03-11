//
//  ShoppingListViewModel.swift (V2 - UNIFIED VERSION)
//  Listie.md
//
//  Updated to use V2 format with labelId references and timestamps
//

import Foundation
import os
import SwiftUI

enum ListViewMode: String, Codable {
    case list
    case kanban
    case map
}

@Observable
@MainActor
class ShoppingListViewModel {
    var items: [ShoppingItem] = []
    var isLoading = false
    var labels: [ShoppingLabel] = []

    var expandedSections: [String: Bool] = [:]
    /// Saved collapse state before a search began; nil when not searching.
    private var preSearchExpandedSections: [String: Bool]? = nil
    var kanbanCompletedVisible: [String: Bool] = [:]
    var showCompletedAtBottom: Bool = false
    var listBackground: ListBackground? = nil
    var viewMode: ListViewMode = .list

    var searchText: String = ""

    var list: UnifiedList
    let provider: UnifiedListProvider
    
    var shoppingListId: String { list.summary.id }
    
    init(list: UnifiedList, provider: UnifiedListProvider) {
        self.list = list
        self.provider = provider
        
        // Load expanded sections for this list
        if let data = UserDefaults.standard.data(forKey: "expandedSections"),
           let allData = try? JSONDecoder().decode([String: [String: Bool]].self, from: data),
           let sections = allData[list.id] {
            self.expandedSections = sections
        }
        
        // Load kanban completed visibility for this list
        if let data = UserDefaults.standard.data(forKey: "kanbanCompletedVisible"),
           let allData = try? JSONDecoder().decode([String: [String: Bool]].self, from: data),
           let sections = allData[list.id] {
            self.kanbanCompletedVisible = sections
        }

        // Load show completed preference for this list
        if let data = UserDefaults.standard.data(forKey: "showCompletedAtBottom"),
           let dict = try? JSONDecoder().decode([String: Bool].self, from: data) {
            self.showCompletedAtBottom = dict[list.id] ?? false
        }

        // Load background preference for this list
        if let data = UserDefaults.standard.data(forKey: "listBackgrounds"),
           let dict = try? JSONDecoder().decode([String: ListBackground].self, from: data) {
            self.listBackground = dict[list.id]
        }

        // Load view mode preference for this list
        if let data = UserDefaults.standard.data(forKey: "listViewMode"),
           let dict = try? JSONDecoder().decode([String: ListViewMode].self, from: data) {
            self.viewMode = dict[list.id] ?? .list
        }
    }
    
    func loadItems() async {
        guard !Task.isCancelled else { return }
        isLoading = true
        do {
            let allItems = try await provider.fetchItems(for: list)
            guard !Task.isCancelled else { return }
            // Filter out soft-deleted items
            items = allItems.filter { !($0.isDeleted) }
        } catch is CancellationError {
            // Task was cancelled — don't publish anything further
        } catch {
            AppLogger.items.error("Error loading items: \(error, privacy: .public)")
        }
        guard !Task.isCancelled else { return }
        isLoading = false
    }

    func loadLabels() async {
        guard !Task.isCancelled else { return }
        do {
            let fetched = try await provider.fetchLabels(for: list)
            guard !Task.isCancelled else { return }
            labels = fetched
        } catch is CancellationError {
            // Task was cancelled — don't publish anything further
        } catch {
            AppLogger.labels.error("Error loading labels: \(error, privacy: .public)")
        }
    }

    /// Updates the list reference after a sync, so labelOrder and other metadata stay current.
    func updateList(_ updated: UnifiedList) {
        list = updated
    }
    
    // MARK: - Filtering & Grouping
    
    var filteredItems: [ShoppingItem] {
        guard !searchText.isEmpty else { return items }
        
        return items.filter { item in
            // Search in item name
            if item.note.localizedCaseInsensitiveContains(searchText) {
                return true
            }
            
            // Search in markdown notes if present
            if let notes = item.markdownNotes,
               notes.localizedCaseInsensitiveContains(searchText) {
                return true
            }
            
            return false
        }
    }
    
    var filteredItemsGroupedByLabel: [String: [ShoppingItem]] {
        let grouped = Dictionary(grouping: filteredItems) { item in
            if let labelId = item.labelId,
               let label = labels.first(where: { $0.id == labelId }) {
                return label.name
            }
            return "No Label"
        }
        
        // Sort items within each group alphabetically
        return grouped.mapValues { items in
            items.sorted { item1, item2 in
                item1.note.localizedCaseInsensitiveCompare(item2.note) == .orderedAscending
            }
        }
    }
    
    var filteredSortedLabelKeys: [String] {
        sortedLabelNames(
            Array(filteredItemsGroupedByLabel.keys),
            labels: labels,
            labelOrder: list.summary.labelOrder
        )
    }
    
    var filteredCompletedItems: [ShoppingItem] {
        filteredItems.filter { $0.checked }.sorted {
            $0.note.localizedCaseInsensitiveCompare($1.note) == .orderedAscending
        }
    }
    
    @MainActor
    func addItem(note: String, label: ShoppingLabel?, quantity: Double?, checked: Bool = false, markdownNotes: String?, reminderDate: Date? = nil, reminderRepeatRule: ReminderRepeatRule? = nil, reminderRepeatMode: ReminderRepeatMode? = nil, location: Coordinate? = nil) async -> Bool {
        // Use ModelHelpers to create a clean V2 item
        var newItem = ModelHelpers.createNewItem(
            note: note,
            quantity: quantity ?? 1,
            checked: checked,
            labelId: label?.id,  // Reference by ID, not embedded object
            markdownNotes: markdownNotes,
            reminderDate: reminderDate,
            reminderRepeatRule: reminderRepeatRule,
            reminderRepeatMode: reminderRepeatMode,
            location: location
        )

        // Handle recurrence when adding a checked item with a repeat rule
        if checked && newItem.reminderDate != nil {
            let mode = newItem.reminderRepeatMode ?? .fixed

            if let rule = newItem.reminderRepeatRule,
               let nextDate = ReminderManager.nextReminderDate(from: newItem.reminderDate, rule: rule, mode: mode) {
                // Repeating reminder: uncheck, advance to next date
                newItem.checked = false
                newItem.reminderDate = nextDate
            } else {
                // One-off reminder: clear it
                newItem.reminderDate = nil
            }
        }

        do {
            try await provider.addItem(newItem, to: list)

            // Schedule reminder if set
            if let date = newItem.reminderDate, date > Date() {
                if await ReminderManager.requestPermission() {
                    ReminderManager.scheduleReminder(for: newItem, listName: list.summary.name, listId: list.id)
                }
            }

            await loadItems()
            return true
        } catch {
            AppLogger.items.warning("Error adding item: \(error, privacy: .public)")
            return false
        }
    }
    
    func deleteItems(at offsets: IndexSet) async {
        for index in offsets {
            let item = items[index]
            do {
                try await provider.deleteItem(item, from: list)
            } catch {
                AppLogger.items.error("Error deleting item: \(error, privacy: .public)")
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
            AppLogger.items.warning("Failed to delete item: \(error, privacy: .public)")
            return false
        }
    }

    func toggleChecked(for item: ShoppingItem, didUpdate: @escaping (Int) async -> Void) async {
        var updated = item
        updated.checked.toggle()
        updated.modifiedAt = Date()  // Update timestamp

        // Handle reminder when checking off an item
        if updated.checked && updated.reminderDate != nil {
            let repeatRule = updated.reminderRepeatRule
            let repeatMode = updated.reminderRepeatMode ?? .fixed

            if let rule = repeatRule,
               let nextDate = ReminderManager.nextReminderDate(from: updated.reminderDate, rule: rule, mode: repeatMode) {
                // Repeating reminder: uncheck, set next date, reschedule
                updated.checked = false
                updated.reminderDate = nextDate
                ReminderManager.cancelReminder(for: item)
                ReminderManager.scheduleReminder(for: updated, listName: list.summary.name, listId: list.id)
            } else {
                // One-off reminder: clear it
                updated.reminderDate = nil
                ReminderManager.cancelReminder(for: item)
            }
        }

        do {
            try await provider.updateItem(updated, in: list)

            if let index = items.firstIndex(where: { $0.id == updated.id }) {
                items[index] = updated
            }

            // Count unchecked items (works with both V1 and V2)
            let count = items.filter { !$0.checked }.count
            await didUpdate(count)
        } catch {
            AppLogger.items.error("Error toggling item: \(error, privacy: .public)")
        }
    }
    
    func setAllItems(for listId: String, toCompleted completed: Bool, didUpdate: @escaping (Int) async -> Void) async {
        // Update all items in provider WITHOUT touching @Published items array
        for var item in items {
            if item.checked != completed {
                item.checked = completed
                item.modifiedAt = Date()

                // Handle reminders when checking off items
                if completed && item.reminderDate != nil {
                    let repeatRule = item.reminderRepeatRule
                    let repeatMode = item.reminderRepeatMode ?? .fixed

                    if let rule = repeatRule,
                       let nextDate = ReminderManager.nextReminderDate(from: item.reminderDate, rule: rule, mode: repeatMode) {
                        // Repeating: uncheck, advance to next date
                        item.checked = false
                        item.reminderDate = nextDate
                        ReminderManager.cancelReminder(for: item)
                        ReminderManager.scheduleReminder(for: item, listName: list.summary.name, listId: list.id)
                    } else {
                        // One-off: clear reminder
                        ReminderManager.cancelReminder(for: item)
                        item.reminderDate = nil
                    }
                }

                do {
                    try await provider.updateItem(item, in: list)
                } catch {
                    AppLogger.items.error("Error updating item: \(error, privacy: .public)")
                }
            }
        }
        
        // Completely reload from provider (clean state for Catalyst toolbar)
        await loadItems()
        
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
    func updateItem(_ item: ShoppingItem, note: String, labelId: String?, quantity: Double?, checked: Bool, markdownNotes: String?, reminderDate: Date? = nil, reminderRepeatRule: ReminderRepeatRule? = nil, reminderRepeatMode: ReminderRepeatMode? = nil, location: Coordinate? = nil) async -> Bool {
        var updatedItem = item
        updatedItem.note = note
        updatedItem.labelId = labelId  // Use labelId reference instead of embedded object
        updatedItem.quantity = quantity ?? 1
        updatedItem.checked = checked
        updatedItem.markdownNotes = markdownNotes  // Direct field
        updatedItem.reminderDate = reminderDate
        updatedItem.reminderRepeatRule = reminderRepeatRule
        updatedItem.reminderRepeatMode = reminderRepeatMode
        updatedItem.location = location
        updatedItem.modifiedAt = Date()  // Update timestamp

        // Handle recurrence when checking off an item with a repeat rule
        if !item.checked && checked && updatedItem.reminderDate != nil {
            let mode = updatedItem.reminderRepeatMode ?? .fixed

            if let rule = updatedItem.reminderRepeatRule,
               let nextDate = ReminderManager.nextReminderDate(from: updatedItem.reminderDate, rule: rule, mode: mode) {
                // Repeating reminder: uncheck, advance to next date, reschedule
                updatedItem.checked = false
                updatedItem.reminderDate = nextDate
                ReminderManager.cancelReminder(for: item)
                ReminderManager.scheduleReminder(for: updatedItem, listName: list.summary.name, listId: list.id)
            } else {
                // One-off reminder: clear it
                updatedItem.reminderDate = nil
                ReminderManager.cancelReminder(for: item)
            }
        }

        do {
            try await provider.updateItem(updatedItem, in: list)

            if let index = items.firstIndex(where: { $0.id == updatedItem.id }) {
                items[index] = updatedItem
            }

            // Handle reminder scheduling/cancellation (for non-recurrence cases)
            if updatedItem.checked || updatedItem.reminderDate == nil {
                // Item is checked or reminder was cleared — no scheduling needed
            } else if let date = updatedItem.reminderDate, date > Date() {
                if await ReminderManager.requestPermission() {
                    ReminderManager.scheduleReminder(for: updatedItem, listName: list.summary.name, listId: list.id)
                }
            } else {
                // Reminder in the past — cancel
                ReminderManager.cancelReminder(for: updatedItem)
            }

            return true
        } catch {
            AppLogger.items.warning("Failed to update item: \(error, privacy: .public)")
            return false
        }
    }
    
    var itemsGroupedByLabel: [String: [ShoppingItem]] {
        let grouped = Dictionary(grouping: items) { item in  
            if let labelId = item.labelId,
               let label = labels.first(where: { $0.id == labelId }) {
                return label.name
            }
            return "No Label"
        }
        
        // Sort items within each group alphabetically
        return grouped.mapValues { items in
            items.sorted { item1, item2 in
                item1.note.localizedCaseInsensitiveCompare(item2.note) == .orderedAscending
            }
        }
    }

    var sortedLabelKeys: [String] {
        sortedLabelNames(
            Array(itemsGroupedByLabel.keys),
            labels: labels,
            labelOrder: list.summary.labelOrder
        )
    }
    
    // MARK: - Quantity Management
    
    /// Increments item quantity by 1
    func incrementQuantity(for item: ShoppingItem) async {
        let newQty = item.quantity + 1
        _ = await updateItem(item, note: item.note, labelId: item.labelId, quantity: newQty, checked: item.checked, markdownNotes: item.markdownNotes,
                             reminderDate: item.reminderDate, reminderRepeatRule: item.reminderRepeatRule, reminderRepeatMode: item.reminderRepeatMode)
    }

    /// Decrements item quantity by 1. Returns false if item should be deleted (qty would be 0)
    func decrementQuantity(for item: ShoppingItem) async -> Bool {
        if item.quantity <= 1 {
            return false
        }
        let newQty = max(item.quantity - 1, 1)
        _ = await updateItem(item, note: item.note, labelId: item.labelId, quantity: newQty, checked: item.checked, markdownNotes: item.markdownNotes,
                             reminderDate: item.reminderDate, reminderRepeatRule: item.reminderRepeatRule, reminderRepeatMode: item.reminderRepeatMode)
        return true
    }
    
    func toggleSection(_ labelName: String) {
        expandedSections[labelName] = !(expandedSections[labelName] ?? true)
        saveExpandedSections()
    }

    /// Called when search text transitions between empty and non-empty.
    /// Expands all sections while searching and restores the previous state when done.
    func handleSearchActive(_ isActive: Bool) {
        if isActive {
            guard preSearchExpandedSections == nil else { return }
            preSearchExpandedSections = expandedSections
            for key in expandedSections.keys {
                expandedSections[key] = true
            }
        } else {
            guard let saved = preSearchExpandedSections else { return }
            expandedSections = saved
            preSearchExpandedSections = nil
        }
        // Don't persist — this is transient search state
    }
    
    func initializeExpandedSections(for labels: [String]) {
        for label in labels where expandedSections[label] == nil {
            expandedSections[label] = true
        }
        saveExpandedSections()
    }
    
    func toggleKanbanCompleted(_ labelName: String) {
        kanbanCompletedVisible[labelName] = !(kanbanCompletedVisible[labelName] ?? false)
        saveKanbanCompletedVisible()
    }

    func isKanbanCompletedVisible(_ labelName: String) -> Bool {
        kanbanCompletedVisible[labelName] ?? false
    }

    private func saveKanbanCompletedVisible() {
        var allData = (try? JSONDecoder().decode([String: [String: Bool]].self,
                                                 from: UserDefaults.standard.data(forKey: "kanbanCompletedVisible") ?? Data())) ?? [:]
        allData[list.id] = kanbanCompletedVisible
        if let data = try? JSONEncoder().encode(allData) {
            UserDefaults.standard.set(data, forKey: "kanbanCompletedVisible")
        }
    }

    func setShowCompletedAtBottom(_ value: Bool) {
        showCompletedAtBottom = value
        saveShowCompletedPreference()
    }

    private func saveExpandedSections() {
        var allData = (try? JSONDecoder().decode([String: [String: Bool]].self,
                                                 from: UserDefaults.standard.data(forKey: "expandedSections") ?? Data())) ?? [:]
        allData[list.id] = expandedSections
        if let data = try? JSONEncoder().encode(allData) {
            UserDefaults.standard.set(data, forKey: "expandedSections")
        }
    }
    
    private func saveShowCompletedPreference() {
        var dict = (try? JSONDecoder().decode([String: Bool].self,
                                              from: UserDefaults.standard.data(forKey: "showCompletedAtBottom") ?? Data())) ?? [:]
        dict[list.id] = showCompletedAtBottom
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: "showCompletedAtBottom")
        }
    }

    func setListBackground(_ background: ListBackground?) {
        listBackground = background
        saveListBackground()
    }

    func reloadBackground() {
        if let data = UserDefaults.standard.data(forKey: "listBackgrounds"),
           let dict = try? JSONDecoder().decode([String: ListBackground].self, from: data) {
            listBackground = dict[list.id]
        } else {
            listBackground = nil
        }
    }

    func setViewMode(_ mode: ListViewMode) {
        viewMode = mode
        saveViewModePreference()
    }

    private func saveViewModePreference() {
        var dict = (try? JSONDecoder().decode([String: ListViewMode].self,
                                              from: UserDefaults.standard.data(forKey: "listViewMode") ?? Data())) ?? [:]
        dict[list.id] = viewMode
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: "listViewMode")
        }
    }

    private func saveListBackground() {
        var dict = (try? JSONDecoder().decode([String: ListBackground].self,
                                              from: UserDefaults.standard.data(forKey: "listBackgrounds") ?? Data())) ?? [:]
        if let listBackground {
            dict[list.id] = listBackground
        } else {
            dict.removeValue(forKey: list.id)
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: "listBackgrounds")
        }
    }
}
