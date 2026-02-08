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
    static func createNewList(name: String, icon: String = "checklist") -> ShoppingListSummary {
        let cleanId = UUID().uuidString  // No "local-" prefix
        
        return ShoppingListSummary(
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
        reminderRepeatInterval: ReminderRepeatInterval? = nil,
        reminderRepeatMode: ReminderRepeatMode? = nil
    ) -> ShoppingItem {
        return ShoppingItem(
            id: UUID(),
            note: note,
            quantity: quantity,
            checked: checked,
            labelId: labelId,
            markdownNotes: markdownNotes,
            modifiedAt: Date(),
            isDeleted: isDeleted,
            reminderDate: reminderDate,
            reminderRepeatInterval: reminderRepeatInterval,
            reminderRepeatMode: reminderRepeatMode
        )
    }
    
    // MARK: - Label Creation
    
    static func createNewLabel(name: String, color: String, existingLabels: [ShoppingLabel] = []) -> ShoppingLabel {
        return ShoppingLabel(
            id: UUID().uuidString,
            name: name,
            color: color
        )
    }
    
    static func createCommonLabels() -> [ShoppingLabel] {
        return commonLabels.map { (name, color) in
            ShoppingLabel(
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
    static func touchItem(_ item: ShoppingItem) -> ShoppingItem {
        var updated = item
        updated.modifiedAt = Date()
        return updated
    }
    
    /// Updates a list's modified timestamp
    static func touchList(_ list: ShoppingListSummary) -> ShoppingListSummary {
        var updated = list
        updated.modifiedAt = Date()
        return updated
    }
    
    /// Updates a list summary with new values from extras
    static func updateListFromExtras(
        _ list: inout ShoppingListSummary,
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
