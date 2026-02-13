//
//  ShoppingListViewModel.swift (V2 - UNIFIED VERSION)
//  Listie.md
//
//  Updated to use V2 format with labelId references and timestamps
//

import Foundation
import SwiftUI

enum ListViewMode: String, Codable {
    case list
    case kanban
}

@MainActor
class ShoppingListViewModel: ObservableObject {
    @Published var items: [ShoppingItem] = []
    @Published var isLoading = false
    @Published var labels: [ShoppingLabel] = []
    
    @Published var expandedSections: [String: Bool] = [:]
    @Published var kanbanCompletedVisible: [String: Bool] = [:]
    @Published var showCompletedAtBottom: Bool = false
    @Published var listBackground: ListBackground? = nil
    @Published var viewMode: ListViewMode = .list

    @Published var searchText: String = ""
    
    let list: UnifiedList
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
        isLoading = true
        do {
            let allItems = try await provider.fetchItems(for: list)
            // Filter out soft-deleted items
            items = allItems.filter { !($0.isDeleted) }
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
        filteredItemsGroupedByLabel.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    }
    
    var filteredCompletedItems: [ShoppingItem] {
        filteredItems.filter { $0.checked }.sorted {
            $0.note.localizedCaseInsensitiveCompare($1.note) == .orderedAscending
        }
    }
    
    @MainActor
    func addItem(note: String, label: ShoppingLabel?, quantity: Double?, checked: Bool = false, markdownNotes: String?, reminderDate: Date? = nil, reminderRepeatRule: ReminderRepeatRule? = nil, reminderRepeatMode: ReminderRepeatMode? = nil) async -> Bool {
        // Use ModelHelpers to create a clean V2 item
        let newItem = ModelHelpers.createNewItem(
            note: note,
            quantity: quantity ?? 1,
            checked: checked,
            labelId: label?.id,  // Reference by ID, not embedded object
            markdownNotes: markdownNotes,
            reminderDate: reminderDate,
            reminderRepeatRule: reminderRepeatRule,
            reminderRepeatMode: reminderRepeatMode
        )

        do {
            try await provider.addItem(newItem, to: list)

            // Schedule reminder if set
            if reminderDate != nil {
                if await ReminderManager.requestPermission() {
                    ReminderManager.scheduleReminder(for: newItem, listName: list.summary.name, listId: list.id)
                }
            }

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
            print("Error toggling item: \(error)")
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
                    print("Error updating item: \(error)")
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
    func updateItem(_ item: ShoppingItem, note: String, labelId: String?, quantity: Double?, checked: Bool, markdownNotes: String?, reminderDate: Date? = nil, reminderRepeatRule: ReminderRepeatRule? = nil, reminderRepeatMode: ReminderRepeatMode? = nil) async -> Bool {
        var updatedItem = item
        updatedItem.note = note
        updatedItem.labelId = labelId  // Use labelId reference instead of embedded object
        updatedItem.quantity = quantity ?? 1
        updatedItem.checked = checked
        updatedItem.markdownNotes = markdownNotes  // Direct field
        updatedItem.reminderDate = reminderDate
        updatedItem.reminderRepeatRule = reminderRepeatRule
        updatedItem.reminderRepeatMode = reminderRepeatMode
        updatedItem.modifiedAt = Date()  // Update timestamp

        do {
            try await provider.updateItem(updatedItem, in: list)

            if let index = items.firstIndex(where: { $0.id == updatedItem.id }) {
                items[index] = updatedItem
            }

            // Handle reminder scheduling/cancellation
            if let date = reminderDate, date > Date() {
                if await ReminderManager.requestPermission() {
                    ReminderManager.scheduleReminder(for: updatedItem, listName: list.summary.name, listId: list.id)
                }
            } else {
                // Reminder removed or in the past — cancel
                ReminderManager.cancelReminder(for: updatedItem)
            }

            return true
        } catch {
            print("⚠️ Failed to update item:", error)
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
        itemsGroupedByLabel.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
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
