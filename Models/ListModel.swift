//
//  ListModel.swift (V2 - SIMPLIFIED)
//  Listie.md
//
//  Simplified data model with fewer UUIDs and cleaner structure
//

import CoreLocation
import Foundation

// MARK: - Document Version
struct ListDocument: Codable {
    var version: Int = 2  // Version 2 = new simplified format
    var list: ListSummary
    var items: [ListItem]
    var labels: [ListLabel]
    var deletedLabelIDs: [String] = []  // Tombstones: IDs of labels intentionally deleted
    var sharePresets: [SharePreset]?    // Saved share/reload bookmarks; optional for backward compat

    init(list: ListSummary, items: [ListItem] = [], labels: [ListLabel] = [], deletedLabelIDs: [String] = [], sharePresets: [SharePreset]? = nil) {
        self.version = 2
        self.list = list
        self.items = items
        self.labels = labels
        self.deletedLabelIDs = deletedLabelIDs
        self.sharePresets = sharePresets
    }

    enum CodingKeys: String, CodingKey {
        case version
        case list
        case items
        case labels
        case deletedLabelIDs
        case sharePresets
    }

    // Custom decoder to handle missing version field (old withMealie files)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Default to version 1 if not present (old withMealie format)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.list = try container.decode(ListSummary.self, forKey: .list)
        self.items = try container.decode([ListItem].self, forKey: .items)
        self.labels = try container.decode([ListLabel].self, forKey: .labels)
        self.deletedLabelIDs = try container.decodeIfPresent([String].self, forKey: .deletedLabelIDs) ?? []
        self.sharePresets = try container.decodeIfPresent([SharePreset].self, forKey: .sharePresets)
    }
}

// MARK: - Document Merge
extension ListDocument {
    /// Deterministic merge of two document versions for sync conflict resolution.
    /// Used by Nextcloud's pre-upload merge and by the iCloud read-merge-write save path.
    ///
    /// Rules:
    /// - Items: union by id, latest `modifiedAt` wins.
    /// - Deleted-label tombstones: unioned; merged labels matching a tombstone are dropped.
    /// - Labels: local wins on conflict (no `modifiedAt`); remote contributes new ids.
    /// - List summary: latest `modifiedAt` wins.
    /// - Share presets: union by id, latest `modifiedAt` wins; tombstones older than
    ///   `SharePreset.tombstoneRetention` are purged from the output.
    static func merge(local: ListDocument, remote: ListDocument) -> ListDocument {
        var itemsById: [UUID: ListItem] = Dictionary(
            uniqueKeysWithValues: remote.items.map { ($0.id, $0) }
        )
        for item in local.items {
            if let existing = itemsById[item.id] {
                if item.modifiedAt > existing.modifiedAt { itemsById[item.id] = item }
            } else {
                itemsById[item.id] = item
            }
        }

        let deletedIDs = Set(local.deletedLabelIDs).union(remote.deletedLabelIDs)

        var labelsById: [String: ListLabel] = Dictionary(
            uniqueKeysWithValues: local.labels.map { ($0.id, $0) }
        )
        for label in remote.labels where labelsById[label.id] == nil {
            labelsById[label.id] = label
        }
        for id in deletedIDs { labelsById.removeValue(forKey: id) }

        let summary = local.list.modifiedAt > remote.list.modifiedAt ? local.list : remote.list

        let mergedPresets = mergeSharePresets(local: local.sharePresets, remote: remote.sharePresets)

        return ListDocument(
            list: summary,
            items: Array(itemsById.values),
            labels: Array(labelsById.values),
            deletedLabelIDs: Array(deletedIDs),
            sharePresets: mergedPresets
        )
    }

    private static func mergeSharePresets(local: [SharePreset]?, remote: [SharePreset]?) -> [SharePreset]? {
        let localList = local ?? []
        let remoteList = remote ?? []
        if localList.isEmpty && remoteList.isEmpty { return nil }

        var byId: [UUID: SharePreset] = Dictionary(
            uniqueKeysWithValues: remoteList.map { ($0.id, $0) }
        )
        for preset in localList {
            if let existing = byId[preset.id] {
                if preset.modifiedAt > existing.modifiedAt { byId[preset.id] = preset }
            } else {
                byId[preset.id] = preset
            }
        }

        let cutoff = Date().addingTimeInterval(-SharePreset.tombstoneRetention)
        let alive = byId.values.filter { preset in
            guard preset.isDeleted, let deletedAt = preset.deletedAt else { return true }
            return deletedAt >= cutoff
        }
        return alive.isEmpty ? nil : Array(alive)
    }
}

// MARK: - Share Preset
/// A named bookmark of a curated subset of items + share options.
/// Stored per-list and synced via the .listie file. Merged across devices by `modifiedAt`.
struct SharePreset: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var itemIds: [UUID]
    /// Per-item override quantities, keyed by UUID string. nil means "use whatever
    /// the live list has at reload time." Stored at save / edit time so reloading
    /// can override live quantities — see `reloadPreset` in ListView.
    var quantities: [String: Double]?
    var compress: Bool
    var includeComments: Bool
    var createdAt: Date
    var modifiedAt: Date
    var isDeleted: Bool
    var deletedAt: Date?

    /// Retention for soft-deleted preset tombstones before they're purged at merge time.
    static let tombstoneRetention: TimeInterval = 30 * 24 * 3600

    init(
        id: UUID = UUID(),
        name: String,
        itemIds: [UUID],
        quantities: [String: Double]? = nil,
        compress: Bool = true,
        includeComments: Bool = false,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isDeleted: Bool = false,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.itemIds = itemIds
        self.quantities = quantities
        self.compress = compress
        self.includeComments = includeComments
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }

    /// Returns the override quantity for the given item, or nil if the preset
    /// doesn't specify one for that UUID.
    func quantity(for itemId: UUID) -> Double? {
        quantities?[itemId.uuidString]
    }
}

// MARK: - Coordinate
struct Coordinate: Codable, Equatable, Identifiable {
    var latitude: Double
    var longitude: Double
    var id: String { "\(latitude),\(longitude)" }
}

// MARK: - Shopping List
struct ListSummary: Codable, Identifiable, Hashable {
    var id: String  // Clean UUID without "local-" prefix
    var name: String
    var modifiedAt: Date

    // Optional fields for compatibility and features
    var icon: String?
    var hiddenLabels: [String]?  // Array of label IDs to hide
    var labelOrder: [String]?    // Array of label IDs defining custom display order
    var enableMapData: Bool?     // Opt-in per-list map/location support



    enum CodingKeys: String, CodingKey {
            case id, name, modifiedAt, icon, hiddenLabels, labelOrder, enableMapData
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
            self.enableMapData = try container.decodeIfPresent(Bool.self, forKey: .enableMapData)

        }

        init(id: String, name: String, modifiedAt: Date = Date(), icon: String? = nil, hiddenLabels: [String]? = nil, labelOrder: [String]? = nil, enableMapData: Bool? = nil) {
            self.id = id
            self.name = name
            self.modifiedAt = modifiedAt
            self.icon = icon
            self.hiddenLabels = hiddenLabels
            self.labelOrder = labelOrder
            self.enableMapData = enableMapData
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
struct ListItem: Identifiable, Codable {
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
    var location: Coordinate?  // optional pinned map coordinate
    var sourceURL: String?  // original maps URL used to set the location
    var checkedAt: Date?  // when the item was last checked/unchecked
    var lastChangeField: String?  // what was last changed: "checked", "note", "quantity", "label", "reminder", "location", "subitems", "added", "deleted", "restored"


    enum CodingKeys: String, CodingKey {
            case id, note, quantity, checked, labelId, modifiedAt, markdownNotes, isDeleted, deletedAt, reminderDate, reminderRepeatRule, reminderRepeatMode, location, sourceURL, checkedAt, lastChangeField
        }

    init(id: UUID = UUID(), note: String, quantity: Double = 1, checked: Bool = false,
             labelId: String? = nil, markdownNotes: String? = nil, modifiedAt: Date = Date(),
             isDeleted: Bool = false, deletedAt: Date? = nil, reminderDate: Date? = nil,
             reminderRepeatRule: ReminderRepeatRule? = nil, reminderRepeatMode: ReminderRepeatMode? = nil,
             location: Coordinate? = nil, sourceURL: String? = nil,
             checkedAt: Date? = nil, lastChangeField: String? = nil) {
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
            self.location = location
            self.sourceURL = sourceURL
            self.checkedAt = checkedAt
            self.lastChangeField = lastChangeField
        }
    }


// MARK: - Shopping Label
struct ListLabel: Identifiable, Codable, Hashable, Equatable {
    var id: String  // Simple string like "need", "want", "groceries"
    var name: String
    var color: String  // Hex color
    var symbol: String?  // Optional SF Symbol name shown on map pin instead of the default icon

    enum CodingKeys: String, CodingKey {
        case id, name, color, symbol
    }

    init(id: String, name: String, color: String, symbol: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.symbol = symbol
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

extension ListLabel {
    var isLocal: Bool {
        id.hasPrefix("local-")
    }
}

// MARK: - Label Ordering Helper

/// Sorts label names respecting a custom label order.
/// Labels in `labelOrder` appear first (in that sequence), remaining labels follow alphabetically.
/// "No Label" is always placed last.
func sortedLabelNames(_ names: [String], labels: [ListLabel], labelOrder: [String]?) -> [String] {
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

/// Sorts ListLabel objects respecting a custom label order.
/// Labels in `labelOrder` appear first (in that sequence), remaining labels follow alphabetically.
func sortedLabels(_ labels: [ListLabel], by labelOrder: [String]?) -> [ListLabel] {
    guard let order = labelOrder, !order.isEmpty else {
        return labels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    let idToLabel = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
    var result: [ListLabel] = []
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

// MARK: - Map Focus State

enum MapFocusState {
    case all, city, heading

    /// Cycles all → city → heading → all, skipping heading on devices without a compass.
    var next: MapFocusState {
        switch self {
        case .all:     return .city
        case .city:
#if targetEnvironment(macCatalyst)
            return .all
#else
            return CLLocationManager.headingAvailable() ? .heading : .all
#endif
        case .heading: return .all
        }
    }

    /// SF Symbol representing the current mode (matches Apple Maps conventions)
    var icon: String {
        switch self {
        case .all:     return "location"
        case .city:    return "location.fill"
        case .heading: return "location.north.line.fill"
        }
    }
}
