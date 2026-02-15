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
    var labelOrder: [String]?    // Array of label IDs defining custom display order



    enum CodingKeys: String, CodingKey {
            case id, name, modifiedAt, icon, hiddenLabels, labelOrder
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
            self.labelOrder = try container.decodeIfPresent([String].self, forKey: .labelOrder)

        }

        init(id: String, name: String, modifiedAt: Date = Date(), icon: String? = nil, hiddenLabels: [String]? = nil, labelOrder: [String]? = nil) {
            self.id = id
            self.name = name
            self.modifiedAt = modifiedAt
            self.icon = icon
            self.hiddenLabels = hiddenLabels
            self.labelOrder = labelOrder
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

enum ReminderRepeatUnit: String, Codable, CaseIterable {
    case day
    case week
    case month
    case year
    case weekdays  // Mon–Fri only

    var displayName: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .weekdays: return "Weekdays"
        }
    }

    var pluralName: String {
        switch self {
        case .day: return "Days"
        case .week: return "Weeks"
        case .month: return "Months"
        case .year: return "Years"
        case .weekdays: return "Weekdays"
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

struct ReminderRepeatRule: Codable, Equatable {
    var unit: ReminderRepeatUnit
    var interval: Int  // e.g. 2 = every 2 weeks

    /// Human-readable description, e.g. "Every 2 Weeks", "Daily", "Weekdays"
    var displayName: String {
        if unit == .weekdays { return "Weekdays" }
        if interval == 1 {
            switch unit {
            case .day: return "Daily"
            case .week: return "Weekly"
            case .month: return "Monthly"
            case .year: return "Yearly"
            case .weekdays: return "Weekdays"
            }
        }
        return "Every \(interval) \(unit.pluralName)"
    }

    // Common presets
    static let daily = ReminderRepeatRule(unit: .day, interval: 1)
    static let weekly = ReminderRepeatRule(unit: .week, interval: 1)
    static let biweekly = ReminderRepeatRule(unit: .week, interval: 2)
    static let monthly = ReminderRepeatRule(unit: .month, interval: 1)
    static let yearly = ReminderRepeatRule(unit: .year, interval: 1)
    static let weekdays = ReminderRepeatRule(unit: .weekdays, interval: 1)

    static let presets: [ReminderRepeatRule] = [daily, weekly, biweekly, monthly, yearly, weekdays]
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
    var reminderRepeatRule: ReminderRepeatRule?  // repeat rule (unit + interval)
    var reminderRepeatMode: ReminderRepeatMode?  // fixed or after-completion


    enum CodingKeys: String, CodingKey {
            case id, note, quantity, checked, labelId, modifiedAt, markdownNotes, isDeleted, deletedAt, reminderDate, reminderRepeatRule, reminderRepeatMode
        }

    init(id: UUID = UUID(), note: String, quantity: Double = 1, checked: Bool = false,
             labelId: String? = nil, markdownNotes: String? = nil, modifiedAt: Date = Date(),
             isDeleted: Bool = false, deletedAt: Date? = nil, reminderDate: Date? = nil,
             reminderRepeatRule: ReminderRepeatRule? = nil, reminderRepeatMode: ReminderRepeatMode? = nil) {
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
            self.reminderRepeatRule = reminderRepeatRule
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

// MARK: - Label Ordering Helper

/// Sorts label names respecting a custom label order.
/// Labels in `labelOrder` appear first (in that sequence), remaining labels follow alphabetically.
/// "No Label" is always placed last.
func sortedLabelNames(_ names: [String], labels: [ShoppingLabel], labelOrder: [String]?) -> [String] {
    guard let order = labelOrder, !order.isEmpty else {
        // No custom order — alphabetical, "No Label" last
        return names.sorted { lhs, rhs in
            if lhs == "No Label" { return false }
            if rhs == "No Label" { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    // Build a lookup from label ID → label name
    let idToName = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.name) })

    // Build ordered names from the order array (skip IDs that don't resolve to a name in our set)
    let nameSet = Set(names)
    var orderedNames: [String] = []
    var seen = Set<String>()

    for labelId in order {
        if let name = idToName[labelId], nameSet.contains(name), !seen.contains(name) {
            orderedNames.append(name)
            seen.insert(name)
        }
    }

    // Append any remaining names not in the order (new labels) — alphabetically
    let remaining = names.filter { !seen.contains($0) && $0 != "No Label" }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    orderedNames.append(contentsOf: remaining)

    // "No Label" always last
    if nameSet.contains("No Label") {
        orderedNames.append("No Label")
    }

    return orderedNames
}

/// Sorts ShoppingLabel objects respecting a custom label order.
/// Labels in `labelOrder` appear first (in that sequence), remaining labels follow alphabetically.
func sortedLabels(_ labels: [ShoppingLabel], by labelOrder: [String]?) -> [ShoppingLabel] {
    guard let order = labelOrder, !order.isEmpty else {
        return labels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    let idToLabel = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
    var result: [ShoppingLabel] = []
    var seen = Set<String>()

    for labelId in order {
        if let label = idToLabel[labelId], !seen.contains(labelId) {
            result.append(label)
            seen.insert(labelId)
        }
    }

    // Append remaining labels not in order — alphabetically
    let remaining = labels.filter { !seen.contains($0.id) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    result.append(contentsOf: remaining)

    return result
}
