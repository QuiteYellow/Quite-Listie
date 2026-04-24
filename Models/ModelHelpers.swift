//
//  ModelHelpers.swift
//  Listie-md
//
//  Created by Jack Nagy on 22/12/2025.
//


//
//  ModelHelpers_v2.swift
//  Listie.md
//
//  Helper functions for creating V2 model objects with clean IDs
//

import Foundation

enum ModelHelpers {
    
    // MARK: - List Creation
    
    /// Creates a new shopping list with V2 format
    static func createNewList(name: String, icon: String = "checklist") -> ListSummary {
        let cleanId = UUID().uuidString  // No "local-" prefix
        
        return ListSummary(
            id: cleanId,
            name: name,
            modifiedAt: Date(),
            icon: icon,
            hiddenLabels: nil
        )
    }
    
    // MARK: - Item Creation
    
    /// Creates a new shopping item with V2 format
    static func createNewItem(
        note: String,
        quantity: Double = 1,
        checked: Bool = false,
        labelId: String? = nil,
        markdownNotes: String? = nil,
        isDeleted: Bool = false,
        reminderDate: Date? = nil,
        reminderRepeatRule: ReminderRepeatRule? = nil,
        reminderRepeatMode: ReminderRepeatMode? = nil,
        location: Coordinate? = nil,
        sourceURL: String? = nil
    ) -> ListItem {
        return ListItem(
            id: UUID(),
            note: note,
            quantity: quantity,
            checked: checked,
            labelId: labelId,
            markdownNotes: markdownNotes,
            modifiedAt: Date(),
            isDeleted: isDeleted,
            reminderDate: reminderDate,
            reminderRepeatRule: reminderRepeatRule,
            reminderRepeatMode: reminderRepeatMode,
            location: location,
            sourceURL: sourceURL
        )
    }
    
    // MARK: - Label Creation
    
    static func createNewLabel(name: String, color: String, symbol: String? = nil, existingLabels: [ListLabel] = []) -> ListLabel {
        return ListLabel(
            id: UUID().uuidString,
            name: name,
            color: color,
            symbol: symbol
        )
    }
    
    static func createCommonLabels() -> [ListLabel] {
        return commonLabels.map { (name, color) in
            ListLabel(
                id: UUID().uuidString,
                name: name,
                color: color
            )
        }
    }
    
    // MARK: - Common Label Presets
    
    /// Common grocery shopping labels
    static let commonLabels: [(name: String, color: String)] = [
        ("Produce", "#4CAF50"),     // Green
        ("Dairy", "#2196F3"),       // Blue
        ("Meat", "#F44336"),        // Red
        ("Bakery", "#FF9800"),      // Orange
        ("Frozen", "#00BCD4"),      // Cyan
        ("Pantry", "#9C27B0"),      // Purple
        ("Snacks", "#FFEB3B"),      // Yellow
        ("Beverages", "#795548"),   // Brown
        ("Household", "#607D8B"),   // Blue Grey
        ("Personal Care", "#E91E63") // Pink
    ]
    
    // MARK: - Update Helpers
    
    /// Updates an item's modified timestamp
    static func touchItem(_ item: ListItem) -> ListItem {
        var updated = item
        updated.modifiedAt = Date()
        return updated
    }
    
    /// Updates a list's modified timestamp
    static func touchList(_ list: ListSummary) -> ListSummary {
        var updated = list
        updated.modifiedAt = Date()
        return updated
    }
    
    /// Updates a list summary with new values from extras
    static func updateListFromExtras(
        _ list: inout ListSummary,
        name: String,
        extras: [String: String]
    ) {
        list.name = name
        list.modifiedAt = Date()
        
        // Extract icon from extras
        if let icon = extras["listsForMealieListIcon"], !icon.isEmpty {
            list.icon = icon
        }
        
    }
    
}
