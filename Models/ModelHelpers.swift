//
//  ModelHelpers.swift
//  Listie-md
//
//  Created by Jack Nagy on 22/12/2025.
//


//
//  ModelHelpers_v2.swift
//  ListsForMealie
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
        isDeleted: Bool = false
    ) -> ShoppingItem {
        return ShoppingItem(
            id: UUID(),
            note: note,
            quantity: quantity,
            checked: checked,
            labelId: labelId,
            markdownNotes: markdownNotes,
            modifiedAt: Date(),
            isDeleted: isDeleted
        )
    }
    
    // MARK: - Label Creation
    
    /// Creates a new label with a simple, readable ID
    static func createNewLabel(name: String, color: String, existingLabels: [ShoppingLabel] = []) -> ShoppingLabel {
        // Generate a simple ID from the name
        let baseId = generateSimpleLabelId(from: name)
        
        // Ensure uniqueness
        let existingIds = Set(existingLabels.map { $0.id })
        let uniqueId = makeUniqueLabelId(baseId: baseId, existingIds: existingIds)
        
        return ShoppingLabel(
            id: uniqueId,
            name: name,
            color: color
        )
    }
    
    /// Generates a simple label ID from a name (e.g., "Produce" -> "produce")
    private static func generateSimpleLabelId(from name: String) -> String {
        let cleaned = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0 == "-" }
        
        return cleaned.isEmpty ? "label" : cleaned
    }
    
    /// Makes a label ID unique by appending a counter if needed
    private static func makeUniqueLabelId(baseId: String, existingIds: Set<String>) -> String {
        var candidateId = baseId
        var counter = 1
        
        while existingIds.contains(candidateId) {
            candidateId = "\(baseId)-\(counter)"
            counter += 1
        }
        
        return candidateId
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
    
    /// Creates a set of common labels
    static func createCommonLabels() -> [ShoppingLabel] {
        return commonLabels.map { (name, color) in
            ShoppingLabel(
                id: generateSimpleLabelId(from: name),
                name: name,
                color: color
            )
        }
    }
    
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
    
    // MARK: - Migration Helpers
    
    /// Extracts icon from legacy extras
    static func extractIcon(from extras: [String: String]?) -> String? {
        return extras?["listsForMealieListIcon"]
    }
    
    /// Extracts hidden labels from legacy extras
    static func extractHiddenLabels(from extras: [String: String]?) -> [String]? {
        if let hiddenString = extras?["hiddenLabels"], !hiddenString.isEmpty {
            return hiddenString.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
        }
        return nil
    }
    
    /// Extracts markdown notes from legacy extras
    static func extractMarkdownNotes(from extras: [String: String]?) -> String? {
        if let notes = extras?["markdownNotes"], !notes.isEmpty {
            return notes
        }
        return nil
    }
}

// MARK: - Convenience Extensions

extension ShoppingListSummary {
    /// Creates legacy-style extras dictionary for backward compatibility
    var legacyExtras: [String: String] {
        var extras: [String: String] = [:]
        
        if let icon = icon {
            extras["listsForMealieListIcon"] = icon
        }
        
        if let hiddenLabels = hiddenLabels, !hiddenLabels.isEmpty {
            extras["hiddenLabels"] = hiddenLabels.joined(separator: ",")
        }
        
        return extras
    }
}

extension ShoppingItem {
    /// Creates legacy-style extras dictionary for backward compatibility
    var legacyExtras: [String: String] {
        var extras: [String: String] = [:]
        
        if let notes = markdownNotes {
            extras["markdownNotes"] = notes
        }
        
        return extras
    }
    
    /// Updates extras with new values (for backward compatibility)
    func updatedExtras(with updates: [String: String?]) -> [String: String] {
        var merged = self.legacyExtras
        for (key, value) in updates {
            if let value = value {
                merged[key] = value
            } else {
                merged.removeValue(forKey: key)
            }
        }
        return merged
    }
}
