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
import os

struct ExportResult {
    let markdown: String
    let warnings: [String]
}

enum MarkdownListGenerator {

    /// Returns true if a line from markdownNotes can be cleanly represented as a sublist item.
    /// Exportable: regular text, inline formatting, URLs, links, headings, images, and list markers (- * + 1.)
    /// Not exportable: blockquotes (>), code fences (```), tables, and horizontal rules
    static func isExportableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }

        let first = trimmed.first!

        // Block-level markdown that won't round-trip as sublists
        if first == ">" { return false }  // Blockquote
        if trimmed.hasPrefix("```") { return false }  // Code fence
        if trimmed.hasPrefix("---") || trimmed.hasPrefix("***") || trimmed.hasPrefix("___") { return false }  // Horizontal rule
        if first == "|" { return false }  // Table

        return true
    }

    /// Converts a markdown image to a link. Returns nil if not an image line.
    /// `![alt](url)` → `[alt](url)`, `![](url)` → `[Image link](url)`
    static func imageToLink(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^!\[([^\]]*)\]\(([^)]+)\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let altRange = Range(match.range(at: 1), in: trimmed),
              let urlRange = Range(match.range(at: 2), in: trimmed) else {
            return nil
        }
        let alt = String(trimmed[altRange])
        let url = String(trimmed[urlRange])
        let label = alt.isEmpty ? "Image link" : alt
        return "[\(label)](\(url))"
    }

    /// Returns the heading level (1-6) if the line is a markdown heading, nil otherwise.
    static func headingLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        let level = hashes.count
        // Must be 1-6 and followed by a space
        guard level >= 1, level <= 6, trimmed.count > level,
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " else {
            return nil
        }
        return level
    }

    /// Extracts the heading text (without the # prefix).
    static func headingText(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let afterHashes = trimmed.drop(while: { $0 == "#" })
        return afterHashes.trimmingCharacters(in: .whitespaces)
    }

    /// Generates markdown from shopping list
    static func generate(
        listName: String,
        items: [ShoppingItem],
        labels: [ShoppingLabel],
        labelOrder: [String]? = nil,
        activeOnly: Bool = false,
        includeNotes: Bool = false
    ) -> ExportResult {
        AppLogger.markdown.debug("Generating markdown for '\(listName, privacy: .public)' — items: \(items.count, privacy: .public), labels: \(labels.count, privacy: .public), activeOnly: \(activeOnly, privacy: .public)")

        var markdown = "# \(listName)\n\n"
        var warnings: [String] = []

        // Filter items if needed
        let itemsToExport = activeOnly ? items.filter { !$0.checked } : items
        AppLogger.markdown.debug("Items to export: \(itemsToExport.count, privacy: .public)")

        // Handle empty list case
        if itemsToExport.isEmpty {
            if activeOnly {
                markdown += "*All items are checked!*\n\n"
            } else {
                markdown += "*This list is empty.*\n\n"
            }
            return ExportResult(markdown: markdown, warnings: warnings)
        }
        
        // Group items by label
        let grouped = Dictionary(grouping: itemsToExport) { item -> String in
            if let labelId = item.labelId,
               let label = labels.first(where: { $0.id == labelId }) {
                return label.name
            }
            return "No Label"
        }
        
        AppLogger.markdown.debug("Grouped into \(grouped.keys.count, privacy: .public) labels")
        
        // Sort label names, respecting custom label order
        let orderedLabelNames = sortedLabelNames(Array(grouped.keys), labels: labels, labelOrder: labelOrder)

        // Generate sections
        for labelName in orderedLabelNames {
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
                // Headings become nested sublists: # = depth 1, ## = depth 2, etc.
                // Content under a heading inherits that heading's depth + 1
                if includeNotes, let notes = item.markdownNotes, !notes.isEmpty {
                    let noteLines = notes.components(separatedBy: .newlines)
                    var skippedCount = 0
                    // currentDepth tracks indentation: 1 = direct sublist of item
                    // Headings set depth to their level, content goes one level deeper
                    var currentDepth = 1
                    var hasSeenHeading = false

                    for noteLine in noteLines {
                        let trimmed = noteLine.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }

                        guard isExportableLine(trimmed) else {
                            skippedCount += 1
                            continue
                        }

                        let depth: Int
                        let text: String

                        if let level = headingLevel(trimmed) {
                            // Heading becomes a sublist item at its level depth
                            hasSeenHeading = true
                            currentDepth = level
                            depth = level
                            text = "**\(headingText(trimmed))**"
                        } else {
                            // Content under a heading nests one level deeper
                            // Content before any heading stays at base depth 1
                            depth = hasSeenHeading ? currentDepth + 1 : 1

                            // Convert images to links
                            if let link = imageToLink(trimmed) {
                                text = link
                            // Normalize list markers to "- "
                            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                                text = String(trimmed.dropFirst(2))
                            } else {
                                text = trimmed
                            }
                        }

                        let indent = String(repeating: "  ", count: depth)
                        markdown += "\(indent)- \(text)\n"
                    }

                    if skippedCount > 0 {
                        warnings.append("'\(item.note)' has notes that can't be exported: \(skippedCount) line(s) skipped")
                    }
                }
            }
            
            markdown += "\n"
        }
        
        AppLogger.markdown.info("Generated \(markdown.count, privacy: .public) characters of markdown")
        if !warnings.isEmpty {
            AppLogger.markdown.warning("Export warnings: \(warnings.count, privacy: .public)")
        }

        return ExportResult(markdown: markdown, warnings: warnings)
    }
}
