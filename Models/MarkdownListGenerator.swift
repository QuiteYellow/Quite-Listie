//
//  MarkdownListGenerator.swift
//  Listie-md
//
//  Created by Jack Nagy on 25/12/2025.
//


//
//  MarkdownListGenerator.swift
//  Listie-md
//
//  Generates markdown from shopping list items
//

import Foundation

enum MarkdownListGenerator {
    
    /// Generates markdown from shopping list
    static func generate(
        listName: String,
        items: [ShoppingItem],
        labels: [ShoppingLabel],
        activeOnly: Bool = false,
        includeNotes: Bool = false
    ) -> String {
        // Debug logging
        print("📝 Generating markdown for '\(listName)'")
        print("   Items count: \(items.count)")
        print("   Labels count: \(labels.count)")
        print("   Active only: \(activeOnly)")
        
        var markdown = "# \(listName)\n\n"
        
        // Filter items if needed
        let itemsToExport = activeOnly ? items.filter { !$0.checked } : items
        print("   Items to export: \(itemsToExport.count)")
        
        // Handle empty list case
        if itemsToExport.isEmpty {
            if activeOnly {
                markdown += "*All items are checked!*\n\n"
            } else {
                markdown += "*This list is empty.*\n\n"
            }
            return markdown
        }
        
        // Group items by label
        let grouped = Dictionary(grouping: itemsToExport) { item -> String in
            if let labelId = item.labelId,
               let label = labels.first(where: { $0.id == labelId }) {
                return label.name
            }
            return "No Label"
        }
        
        print("   Grouped into \(grouped.keys.count) labels: \(grouped.keys.joined(separator: ", "))")
        
        // Sort label names
        let sortedLabelNames = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        
        // Generate sections
        for labelName in sortedLabelNames {
            guard let itemsInLabel = grouped[labelName] else { continue }
            
            // Add label heading
            markdown += "## \(labelName)\n\n"
            
            // Sort items alphabetically
            let sortedItems = itemsInLabel.sorted {
                $0.note.localizedCaseInsensitiveCompare($1.note) == .orderedAscending
            }
            
            // Add items
            for item in sortedItems {
                // Checkbox
                let checkbox = item.checked ? "[x]" : "[ ]"
                
                // Quantity prefix
                let quantityPrefix = item.quantity > 1 ? "\(Int(item.quantity)) " : ""
                
                // Main item line
                markdown += "- \(checkbox) \(quantityPrefix)\(item.note)\n"
                
                // Add markdown notes as sub-items if present
                if includeNotes, let notes = item.markdownNotes, !notes.isEmpty {
                    let noteLines = notes.components(separatedBy: .newlines)
                    for noteLine in noteLines {
                        let trimmed = noteLine.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            // Ensure sub-item has proper indentation
                            if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") {
                                markdown += "  \(trimmed)\n"
                            } else {
                                markdown += "  - \(trimmed)\n"
                            }
                        }
                    }
                }
            }
            
            markdown += "\n"
        }
        
        print("✅ Generated \(markdown.count) characters of markdown")
        
        return markdown
    }
}
