//
//  ListDocumentMigration.swift
//  Listie-md
//
//  Created by Jack Nagy on 22/12/2025.
//


//
//  ListDocumentMigration.swift
//  ListsForMealie
//
//  Handles migration from V1 (old) to V2 (new simplified) format
//

import Foundation

enum ListDocumentMigration {
    
    // MARK: - Detection
    
    /// Detects which version a document is
    static func detectVersion(_ document: ListDocument) -> Int {
        // If version field exists, use it
        return document.version
    }
    
    /// Checks if a document needs migration
    static func needsMigration(_ document: ListDocument) -> Bool {
        return document.version < 2
    }
    
    // MARK: - Migration
    
    /// Migrates a document from V1 to V2
    static func migrateToV2(_ document: ListDocument) -> ListDocument {
        print("🔄 Migrating document from V\(document.version) to V2...")
        
        // Migrate list
        let migratedList = migrateList(document.list)
        
        // Migrate labels (convert IDs to simple strings)
        let migratedLabels = migrateLabels(document.labels, listId: document.list.id)
        
        // Create label ID mapping for items
        let labelIdMapping = createLabelIdMapping(oldLabels: document.labels, newLabels: migratedLabels)
        
        // Migrate items (reference labels by new IDs)
        let migratedItems = migrateItems(document.items, labelIdMapping: labelIdMapping)
        
        print("✅ Migration complete: \(migratedItems.count) items, \(migratedLabels.count) labels")
        
        return ListDocument(
            list: migratedList,
            items: migratedItems,
            labels: migratedLabels
        )
    }
    
    // MARK: - List Migration
    
    private static func migrateList(_ oldList: ShoppingListSummary) -> ShoppingListSummary {
        // Remove "local-" prefix from ID
        let cleanId = oldList.cleanId
        
        // Extract icon from extras
        let icon = oldList.extras?["listsForMealieListIcon"]
        
        // Extract hidden labels from extras (convert from comma-separated string to array)
        let hiddenLabels: [String]? = {
            if let hiddenString = oldList.extras?["hiddenLabels"], !hiddenString.isEmpty {
                return hiddenString.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
            }
            return nil
        }()
        
        return ShoppingListSummary(
            id: cleanId,
            name: oldList.name,
            modifiedAt: Date(),
            icon: icon,
            hiddenLabels: hiddenLabels
        )
    }
    
    // MARK: - Label Migration
    
    private static func migrateLabels(_ oldLabels: [ShoppingLabel], listId: String) -> [ShoppingLabel] {
        var usedIds = Set<String>()
        
        return oldLabels.map { oldLabel in
            // Generate a clean, simple ID from the label name
            let baseId = generateSimpleId(from: oldLabel.name)
            let uniqueId = makeUniqueId(baseId: baseId, usedIds: &usedIds)
            
            return ShoppingLabel(
                id: uniqueId,
                name: oldLabel.name,
                color: oldLabel.color
            )
        }
    }
    
    private static func generateSimpleId(from name: String) -> String {
        // Convert name to lowercase, remove special characters, use dashes
        let cleaned = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0 == "-" }
        
        // If empty after cleaning, use a default
        return cleaned.isEmpty ? "label" : cleaned
    }
    
    private static func makeUniqueId(baseId: String, usedIds: inout Set<String>) -> String {
        var candidateId = baseId
        var counter = 1
        
        while usedIds.contains(candidateId) {
            candidateId = "\(baseId)-\(counter)"
            counter += 1
        }
        
        usedIds.insert(candidateId)
        return candidateId
    }
    
    private static func createLabelIdMapping(oldLabels: [ShoppingLabel], newLabels: [ShoppingLabel]) -> [String: String] {
        // Map old label IDs to new label IDs
        var mapping: [String: String] = [:]
        
        for (oldLabel, newLabel) in zip(oldLabels, newLabels) {
            mapping[oldLabel.id] = newLabel.id
            // Also map the clean ID (without "local-" prefix)
            mapping[oldLabel.cleanId] = newLabel.id
        }
        
        return mapping
    }
    
    // MARK: - Item Migration
    
    private static func migrateItems(_ oldItems: [ShoppingItem], labelIdMapping: [String: String]) -> [ShoppingItem] {
        return oldItems.map { oldItem in
            // Determine label ID (handle both embedded label and labelId reference)
            let newLabelId: String? = {
                // First try embedded label
                if let embeddedLabel = oldItem.label {
                    return labelIdMapping[embeddedLabel.id] ?? labelIdMapping[embeddedLabel.cleanId]
                }
                // Then try labelId field
                if let labelId = oldItem.labelId {
                    return labelIdMapping[labelId] ?? labelId
                }
                return nil
            }()
            
            // Extract markdown notes from extras
            let markdownNotes: String? = {
                if let notes = oldItem.extras?["markdownNotes"], !notes.isEmpty {
                    return notes
                }
                return nil
            }()
            
            return ShoppingItem(
                id: oldItem.id,
                note: oldItem.note,
                quantity: oldItem.quantity ?? 1,
                checked: oldItem.checked,
                labelId: newLabelId,
                markdownNotes: markdownNotes,
                modifiedAt: Date()
            )
        }
    }
    
    // MARK: - Validation & Repair
        
        /// Validates and repairs common issues in external documents
        static func validateAndRepair(_ document: ListDocument) -> (document: ListDocument, issues: [String]) {
            var repaired = document
            var issues: [String] = []
            
            // 1. Validate list modification date
            if repaired.list.modifiedAt.timeIntervalSince1970 < 0 {
                repaired.list.modifiedAt = Date()
                issues.append("Invalid list modification date - reset to current time")
            }
            
            // 2. Validate items
            var repairedItems: [ShoppingItem] = []
            for var item in repaired.items {
                var itemIssues: [String] = []
                
                // Check for missing/invalid modification date
                if item.modifiedAt.timeIntervalSince1970 < 0 ||
                   item.modifiedAt.timeIntervalSince1970 == 0 {
                    item.modifiedAt = Date()
                    itemIssues.append("invalid date")
                }
                
                // Ensure isDeleted is explicitly false if not set
                // (decoder handles this, but we're being explicit)
                if !item.isDeleted {
                    item.isDeleted = false
                }
                
                if !itemIssues.isEmpty {
                    issues.append("Item '\(item.note)': \(itemIssues.joined(separator: ", "))")
                }
                
                repairedItems.append(item)
            }
            
            repaired.items = repairedItems
            
            // 3. Validate labels
            for label in repaired.labels {
                // Ensure color is valid hex
                if !label.color.hasPrefix("#") || label.color.count < 7 {
                    issues.append("Label '\(label.name)': invalid color format")
                }
            }
            
            return (repaired, issues)
        }
    
    // MARK: - Helpers for Loading
    
    /// Loads a document from JSON data, migrating if necessary
    static func loadDocument(from data: Data) throws -> ListDocument {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            var document = try decoder.decode(ListDocument.self, from: data)
            
            // Check if migration is needed
            if needsMigration(document) {
                print("📦 Document version \(document.version) detected, migrating to V2...")
                document = migrateToV2(document)
            }
            
            // Validate and repair common issues
            let (repairedDocument, issues) = validateAndRepair(document)
            if !issues.isEmpty {
                print("🔧 Repaired \(issues.count) issue(s) in document:")
                for issue in issues {
                    print("   - \(issue)")
                }
            }
            
            return repairedDocument
        }
    
    /// Saves a document to JSON data in V2 format
    static func saveDocument(_ document: ListDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        // Ensure version is set to 2
        var docToSave = document
        docToSave.version = 2
        
        return try encoder.encode(docToSave)
    }
}

// MARK: - Convenient Extensions for Migration
extension ListDocument {
    /// Returns a migrated version if needed, otherwise returns self
    func migrated() -> ListDocument {
        if ListDocumentMigration.needsMigration(self) {
            return ListDocumentMigration.migrateToV2(self)
        }
        return self
    }
}
