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
    

    
    enum CodingKeys: String, CodingKey {
            case id, name, modifiedAt, icon, hiddenLabels
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

// MARK: - Reminder Repeat Support

enum ReminderRepeatInterval: String, Codable, CaseIterable {
    case none
    case daily
    case weekly
    case biweekly
    case monthly
    case yearly

    var displayName: String {
        switch self {
        case .none: return "Never"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 Weeks"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
}

enum ReminderRepeatMode: String, Codable, CaseIterable {
    case fixed         // Same day/time regardless of completion
    case afterComplete // X interval after item is checked off

    var displayName: String {
        switch self {
        case .fixed: return "Fixed Schedule"
        case .afterComplete: return "After Completion"
        }
    }

    var description: String {
        switch self {
        case .fixed: return "Repeats on the same day & time"
        case .afterComplete: return "Repeats after item is completed"
        }
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
    var markdownNotes: String?
    var deletedAt: Date?  // tracks when item was deleted
    var reminderDate: Date?  // when to send a reminder notification
    var reminderRepeatInterval: ReminderRepeatInterval?  // repeat frequency
    var reminderRepeatMode: ReminderRepeatMode?  // fixed or after-completion


    enum CodingKeys: String, CodingKey {
            case id, note, quantity, checked, labelId, modifiedAt, markdownNotes, isDeleted, deletedAt, reminderDate, reminderRepeatInterval, reminderRepeatMode
        }

    init(id: UUID = UUID(), note: String, quantity: Double = 1, checked: Bool = false,
             labelId: String? = nil, markdownNotes: String? = nil, modifiedAt: Date = Date(),
             isDeleted: Bool = false, deletedAt: Date? = nil, reminderDate: Date? = nil,
             reminderRepeatInterval: ReminderRepeatInterval? = nil, reminderRepeatMode: ReminderRepeatMode? = nil) {
            self.id = id
            self.note = note
            self.quantity = quantity
            self.checked = checked
            self.labelId = labelId
            self.markdownNotes = markdownNotes
            self.modifiedAt = modifiedAt
            self.isDeleted = isDeleted
            self.deletedAt = deletedAt
            self.reminderDate = reminderDate
            self.reminderRepeatInterval = reminderRepeatInterval
            self.reminderRepeatMode = reminderRepeatMode
        }
    }


// MARK: - Shopping Label
struct ShoppingLabel: Identifiable, Codable, Hashable, Equatable {
    var id: String  // Simple string like "need", "want", "groceries"
    var name: String
    var color: String  // Hex color
    

    
    enum CodingKeys: String, CodingKey {
        case id, name, color
    }
    
    init(id: String, name: String, color: String) {
            self.id = id
            self.name = name
            self.color = color
        }
        
        var cleanId: String {
            if id.hasPrefix("local-") {
                return String(id.dropFirst(6))
            }
            return id
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
