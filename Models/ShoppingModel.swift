//
//  ShoppingModel.swift (V2 - SIMPLIFIED)
//  Listie.md
//
//  Simplified data model with fewer UUIDs and cleaner structure
//

import Foundation

// MARK: - Document Version
struct ListDocument: Codable {
    var version: Int = 2  // Version 2 = new simplified format
    var list: ShoppingListSummary
    var items: [ShoppingItem]
    var labels: [ShoppingLabel]
    
    init(list: ShoppingListSummary, items: [ShoppingItem] = [], labels: [ShoppingLabel] = []) {
        self.version = 2
        self.list = list
        self.items = items
        self.labels = labels
    }
    
    enum CodingKeys: String, CodingKey {
        case version
        case list
        case items
        case labels
    }
    
    // Custom decoder to handle missing version field (old withMealie files)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Default to version 1 if not present (old withMealie format)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.list = try container.decode(ShoppingListSummary.self, forKey: .list)
        self.items = try container.decode([ShoppingItem].self, forKey: .items)
        self.labels = try container.decode([ShoppingLabel].self, forKey: .labels)
    }
}

// MARK: - Shopping List
struct ShoppingListSummary: Codable, Identifiable, Hashable {
    var id: String  // Clean UUID without "local-" prefix
    var name: String
    var modifiedAt: Date
    
    // Optional fields for compatibility and features
    var icon: String?
    var hiddenLabels: [String]?  // Array of label IDs to hide
    
    // Legacy fields (will be ignored in new files)
    var localTokenId: UUID? = nil
    var groupId: String? = nil
    var userId: String? = nil
    var householdId: String? = nil
    var extras: [String: String]? = nil
    
    enum CodingKeys: String, CodingKey {
            case id, name, modifiedAt, icon, hiddenLabels
            case localTokenId, groupId, userId, householdId, extras
        }
        
        // Custom decoder for defensive parsing
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            // Required fields
            self.id = try container.decode(String.self, forKey: .id)
            self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed List"
            
            // Handle modification date with fallback
            if let modDate = try? container.decode(Date.self, forKey: .modifiedAt) {
                self.modifiedAt = modDate
            } else {
                self.modifiedAt = Date() // Fallback to current date
            }
            
            // Optional fields
            self.icon = try container.decodeIfPresent(String.self, forKey: .icon)
            self.hiddenLabels = try container.decodeIfPresent([String].self, forKey: .hiddenLabels)
            
            // Legacy fields
            self.localTokenId = try container.decodeIfPresent(UUID.self, forKey: .localTokenId)
            self.groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
            self.userId = try container.decodeIfPresent(String.self, forKey: .userId)
            self.householdId = try container.decodeIfPresent(String.self, forKey: .householdId)
            self.extras = try container.decodeIfPresent([String: String].self, forKey: .extras)
        }
        
        init(id: String, name: String, modifiedAt: Date = Date(), icon: String? = nil, hiddenLabels: [String]? = nil) {
            self.id = id
            self.name = name
            self.modifiedAt = modifiedAt
            self.icon = icon
            self.hiddenLabels = hiddenLabels
        }
    
    // Helper to get clean ID (remove "local-" prefix if present)
    var cleanId: String {
        if id.hasPrefix("local-") {
            return String(id.dropFirst(6))
        }
        return id
    }
}

// MARK: - Shopping Item
struct ShoppingItem: Identifiable, Codable {
    var id: UUID  // Keep UUID for conflict resolution
    var note: String
    var quantity: Double
    var checked: Bool
    var labelId: String?  // Reference to label by ID only
    var modifiedAt: Date
    var isDeleted: Bool  // Soft delete flag
    
    // Optional fields
    var markdownNotes: String?  // Moved out of extras
    var deletedAt: Date?  // tracks when item was deleted
    
    // Legacy fields (will be ignored in new files)
    var shoppingListId: String? = nil
    var label: ShoppingLabel? = nil  // Old embedded label
    var localTokenId: UUID? = nil
    var groupId: String? = nil
    var householdId: String? = nil
    var extras: [String: String]? = nil
    
    enum CodingKeys: String, CodingKey {
            case id, note, quantity, checked, labelId, modifiedAt, markdownNotes, isDeleted, deletedAt
            case shoppingListId, label, localTokenId, groupId, householdId, extras
        }
        
        // Custom decoder for defensive parsing
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            // Required fields with fallbacks
            self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            self.note = try container.decode(String.self, forKey: .note)
            self.quantity = try container.decodeIfPresent(Double.self, forKey: .quantity) ?? 1.0
            self.checked = try container.decodeIfPresent(Bool.self, forKey: .checked) ?? false
            self.labelId = try container.decodeIfPresent(String.self, forKey: .labelId)
            
            // Handle deletedAt
                self.deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
            
            // Handle modification date with fallback
            if let modDate = try? container.decode(Date.self, forKey: .modifiedAt) {
                self.modifiedAt = modDate
            } else {
                self.modifiedAt = Date() // Fallback to current date
            }
            
            // Handle isDeleted with default to false
            self.isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
            
            // Optional fields
            self.markdownNotes = try container.decodeIfPresent(String.self, forKey: .markdownNotes)
            
            // Legacy fields
            self.shoppingListId = try container.decodeIfPresent(String.self, forKey: .shoppingListId)
            self.label = try container.decodeIfPresent(ShoppingLabel.self, forKey: .label)
            self.localTokenId = try container.decodeIfPresent(UUID.self, forKey: .localTokenId)
            self.groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
            self.householdId = try container.decodeIfPresent(String.self, forKey: .householdId)
            self.extras = try container.decodeIfPresent([String: String].self, forKey: .extras)
        }
        
        init(id: UUID = UUID(), note: String, quantity: Double = 1, checked: Bool = false,
             labelId: String? = nil, markdownNotes: String? = nil, modifiedAt: Date = Date(), isDeleted: Bool = false) {
            self.id = id
            self.note = note
            self.quantity = quantity
            self.checked = checked
            self.labelId = labelId
            self.markdownNotes = markdownNotes
            self.modifiedAt = modifiedAt
            self.isDeleted = isDeleted
        }
    }


// MARK: - Shopping Label
struct ShoppingLabel: Identifiable, Codable, Hashable, Equatable {
    var id: String  // Simple string like "need", "want", "groceries"
    var name: String
    var color: String  // Hex color
    
    // Legacy fields (will be ignored in new files)
    var groupId: String? = nil
    var listId: String? = nil
    var localTokenId: UUID? = nil
    var householdId: String? = nil
    
    enum CodingKeys: String, CodingKey {
        case id, name, color
        case groupId, listId, localTokenId, householdId
    }
    
    init(id: String, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }
    
    // Helper to get clean ID (remove "local-" prefix if present)
    var cleanId: String {
        if id.hasPrefix("local-") {
            return String(id.dropFirst(6))
        }
        return id
    }
}


// MARK: - Provider Protocol
protocol ShoppingListProvider {
    func fetchShoppingLists() async throws -> [ShoppingListSummary]
    func fetchItems(for listId: String) async throws -> [ShoppingItem]
    func addItem(_ item: ShoppingItem, to listId: String) async throws
    func deleteItem(_ item: ShoppingItem) async throws
    func createList(_ list: ShoppingListSummary) async throws
    func deleteList(_ list: ShoppingListSummary) async throws
    func updateItem(_ item: ShoppingItem) async throws
    func updateList(_ list: ShoppingListSummary, with name: String, extras: [String: String], items: [ShoppingItem]) async throws
}


extension ShoppingItem {
    var isLocal: Bool {
        shoppingListId?.hasPrefix("local-") ?? true
    }
}

extension String {
    var isLocalListId: Bool {
        self.hasPrefix("local-")
    }
}

extension ShoppingLabel {
    var isLocal: Bool {
        id.hasPrefix("local-")
    }
}
