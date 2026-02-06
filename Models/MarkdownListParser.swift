//
//  ParsedListItem.swift
//  Listie-md
//
//  Created by Jack Nagy on 25/12/2025.
//


//
//  MarkdownListParser.swift
//  Listie-md
//
//  Parses markdown lists into shopping items with labels
//

import Foundation

struct ParsedListItem {
    let note: String
    let quantity: Double
    let checked: Bool
    let labelName: String?
    let markdownNotes: String?
}

struct ParsedList {
    let items: [ParsedListItem]
    let labelNames: Set<String>
}

enum MarkdownListParser {
    
    /// Parses a markdown text into shopping list items with labels
    /// - Parameters:
    ///   - markdown: The markdown text to parse
    ///   - listTitle: Optional list title to skip in headings (case-insensitive)
    static func parse(_ markdown: String, listTitle: String? = nil) -> ParsedList {
        let lines = markdown.components(separatedBy: .newlines)
        var items: [ParsedListItem] = []
        var labelNames = Set<String>()
        
        var currentLabel: String? = nil
        var i = 0
        var skippedFirstHeading = false
        
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines
            if trimmed.isEmpty {
                i += 1
                continue
            }
            
            // Check for heading (becomes label)
            if let heading = extractHeading(from: trimmed) {
                // Skip if this heading matches the list title (case-insensitive)
                if let title = listTitle,
                   heading.lowercased() == title.lowercased() {
                    // Skip this heading - it's the list title
                    i += 1
                    skippedFirstHeading = true
                    continue
                }
                
                // Also skip the very first heading if no list title was provided
                // (assumes first heading is the list title)
                if !skippedFirstHeading && listTitle == nil && i < 5 {
                    // Only skip if it's within the first few lines
                    skippedFirstHeading = true
                    i += 1
                    continue
                }
                
                currentLabel = heading
                labelNames.insert(heading)
                i += 1
                continue
            }
            
            // Check for list item
            if let (baseIndent, itemText, isChecked) = extractListItem(from: line) {
                // Parse quantity and note
                let (quantity, note) = extractQuantityAndNote(from: itemText)
                
                // Look ahead for sub-items (become markdown notes)
                var subItems: [String] = []
                var j = i + 1
                
                while j < lines.count {
                    let nextLine = lines[j]
                    let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    
                    // Empty line ends sub-items
                    if nextTrimmed.isEmpty {
                        break
                    }
                    
                    // Check if this is a sub-item (more indented)
                    if let (nextIndent, subText, _) = extractListItem(from: nextLine),
                       nextIndent > baseIndent {
                        subItems.append(subText)
                        j += 1
                    } else {
                        // Not a sub-item, stop looking
                        break
                    }
                }
                
                // Create markdown notes from sub-items
                let markdownNotes = subItems.isEmpty ? nil : subItems.map { "- \($0)" }.joined(separator: "\n")
                
                let item = ParsedListItem(
                    note: note,
                    quantity: quantity,
                    checked: isChecked,
                    labelName: currentLabel,
                    markdownNotes: markdownNotes
                )
                items.append(item)
                
                // Skip the sub-items we already processed
                i = j
            } else {
                i += 1
            }
        }
        
        return ParsedList(items: items, labelNames: labelNames)
    }
    
    /// Extracts heading text from a markdown heading line
    private static func extractHeading(from line: String) -> String? {
        // Match any level of heading: # Heading, ## Heading, ### Heading, etc.
        let pattern = #"^#{1,6}\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range]).trimmingCharacters(in: .whitespaces)
    }
    
    /// Extracts list item text and checked status
    /// Returns (indentation level, text, isChecked)
    private static func extractListItem(from line: String) -> (Int, String, Bool)? {
        // Count leading whitespace for indentation
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        // Match unchecked: - [ ] text or - text or * text
        if trimmed.hasPrefix("- [ ]") {
            let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return (indent, text, false)
        }
        
        // Match checked: - [x] text or - [X] text
        if trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
            let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return (indent, text, true)
        }
        
        // Match bullet list: - text, * text, or + text
        if trimmed.hasPrefix("- ") {
            let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return (indent, text, false)
        }

        if trimmed.hasPrefix("* ") {
            let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return (indent, text, false)
        }

        if trimmed.hasPrefix("+ ") {
            let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return (indent, text, false)
        }

        // Match numbered list: 1. text, 2. text, etc.
        if let range = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            let text = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (indent, text, false)
        }

        return nil
    }
    
    /// Extracts quantity and note from item text
    /// Examples: "2 Apples" -> (2.0, "Apples"), "Milk" -> (1.0, "Milk")
    private static func extractQuantityAndNote(from text: String) -> (Double, String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        
        // Match number at start: "2 Apples", "3.5 lbs flour"
        let pattern = #"^(\d+(?:\.\d+)?)\s+(.+)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let qtyRange = Range(match.range(at: 1), in: trimmed),
           let noteRange = Range(match.range(at: 2), in: trimmed),
           let quantity = Double(trimmed[qtyRange]) {
            let note = String(trimmed[noteRange])
            return (quantity, note)
        }
        
        // No quantity found
        return (1.0, trimmed)
    }
}
