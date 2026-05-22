//
//  ListModel.swift (V2 - SIMPLIFIED)
//  Listie.md
//
//  Simplified data model with fewer UUIDs and cleaner structure
//

import CoreLocation
import Foundation

// MARK: - JSON Preservation Helpers

/// A faithful in-memory representation of any JSON value. Used by the document
/// model to preserve unknown JSON keys and unparseable values of known keys
/// across a decode/encode round-trip, so opening a file written by a newer
/// version of the app (or with non-standard extensions) and saving it back
/// doesn't strip data the app doesn't understand.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Dynamic string-keyed CodingKey used to inspect a JSON object without
/// committing to a fixed CodingKeys enum. Lets the preservation decoders
/// enumerate keys not present in the typed CodingKeys.
struct JSONCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    init(_ stringValue: String) { self.stringValue = stringValue }
}

extension KeyedDecodingContainer where Key == JSONCodingKey {
    /// All keys not in `knownKeys`, decoded as raw JSONValue.
    func extras(excluding knownKeys: Set<String>) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in allKeys where !knownKeys.contains(key.stringValue) {
            out[key.stringValue] = try decode(JSONValue.self, forKey: key)
        }
        return out
    }
}

// MARK: - Lossy Array

/// Decodes an array element-by-element, skipping (and logging) any element
/// that fails to decode rather than failing the whole array. Used on the
/// three top-level arrays in `ListDocument` so a single structurally-broken
/// item can never make a file unopenable.
struct LossyArray<Element: Codable>: Codable {
    var values: [Element]

    init(_ values: [Element] = []) { self.values = values }

    private struct Skip: Decodable { init(from _: Decoder) throws {} }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var result: [Element] = []
        result.reserveCapacity(c.count ?? 0)
        while !c.isAtEnd {
            if let element = try? c.decode(Element.self) {
                result.append(element)
            } else {
                // Critical: must consume the bad element so the loop terminates.
                // Without this the unkeyed container's index never advances and
                // we'd spin forever on the same malformed element.
                _ = try? c.decode(Skip.self)
            }
        }
        self.values = result
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for element in values { try c.encode(element) }
    }
}

/// Try to decode an optional field, stashing the raw JSON value into
/// `stash` if the typed decode fails (so it round-trips byte-equivalent on
/// the next encode). An explicit `null` returns nil and is *not* stashed —
/// re-encoding will simply omit the key, matching the typical "absent or
/// null both mean none" convention.
fileprivate func decodeOptionalPreserving<T: Decodable, K: CodingKey>(
    _ type: T.Type,
    forKey key: K,
    in typed: KeyedDecodingContainer<K>,
    raw: KeyedDecodingContainer<JSONCodingKey>,
    stash: inout [String: JSONValue]
) -> T? {
    guard typed.contains(key) else { return nil }
    let rawKey = JSONCodingKey(key.stringValue)
    guard let rawValue = try? raw.decode(JSONValue.self, forKey: rawKey) else {
        return nil
    }
    if case .null = rawValue { return nil }
    if let value = try? typed.decode(T.self, forKey: key) {
        return value
    }
    stash[key.stringValue] = rawValue
    return nil
}

/// Writes preserved JSON values into `encoder` under a JSONCodingKey container.
/// Call this BEFORE writing typed fields — Foundation's keyed-container writes
/// at the same depth share state, so subsequent typed writes overwrite raw
/// values for the same key (which is what we want when the typed field is set).
fileprivate func encodePreserved(
    _ preserved: [String: JSONValue],
    to encoder: Encoder
) throws {
    guard !preserved.isEmpty else { return }
    var raw = encoder.container(keyedBy: JSONCodingKey.self)
    for (k, v) in preserved {
        try raw.encode(v, forKey: JSONCodingKey(k))
    }
}

// MARK: - Document Version
struct ListDocument: Codable {
    var version: Int = 2  // Version 2 = new simplified format
    var list: ListSummary
    var items: [ListItem]
    var labels: [ListLabel]
    var deletedLabelIDs: [String] = []  // Tombstones: IDs of labels intentionally deleted
    var sharePresets: [SharePreset] = []  // Saved share/reload bookmarks
    /// Unknown JSON keys preserved across round-trip so a file written by a
    /// newer app version doesn't lose top-level fields when this version saves.
    var _preserved: [String: JSONValue] = [:]

    init(list: ListSummary, items: [ListItem] = [], labels: [ListLabel] = [], deletedLabelIDs: [String] = [], sharePresets: [SharePreset] = []) {
        self.version = 2
        self.list = list
        self.items = items
        self.labels = labels
        self.deletedLabelIDs = deletedLabelIDs
        self.sharePresets = sharePresets
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case list
        case items
        case labels
        case deletedLabelIDs
        case sharePresets
    }

    init(from decoder: Decoder) throws {
        let typed = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try decoder.container(keyedBy: JSONCodingKey.self)

        // Default to version 1 if not present (old withMealie format)
        self.version = try typed.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.list = try typed.decode(ListSummary.self, forKey: .list)
        // LossyArray: one structurally-broken item/label/preset doesn't kill the document.
        self.items = try typed.decode(LossyArray<ListItem>.self, forKey: .items).values
        self.labels = try typed.decode(LossyArray<ListLabel>.self, forKey: .labels).values
        self.deletedLabelIDs = try typed.decodeIfPresent([String].self, forKey: .deletedLabelIDs) ?? []
        self.sharePresets = try typed.decodeIfPresent(LossyArray<SharePreset>.self, forKey: .sharePresets)?.values ?? []

        let known = Set(CodingKeys.allCases.map(\.rawValue))
        self._preserved = (try? raw.extras(excluding: known)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        try encodePreserved(_preserved, to: encoder)
        var typed = encoder.container(keyedBy: CodingKeys.self)
        try typed.encode(version, forKey: .version)
        try typed.encode(list, forKey: .list)
        try typed.encode(items, forKey: .items)
        try typed.encode(labels, forKey: .labels)
        try typed.encode(deletedLabelIDs, forKey: .deletedLabelIDs)
        // Match existing wire format: omit sharePresets when empty.
        if !sharePresets.isEmpty {
            try typed.encode(sharePresets, forKey: .sharePresets)
        }
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

    private static func mergeSharePresets(local: [SharePreset], remote: [SharePreset]) -> [SharePreset] {
        if local.isEmpty && remote.isEmpty { return [] }

        var byId: [UUID: SharePreset] = Dictionary(
            uniqueKeysWithValues: remote.map { ($0.id, $0) }
        )
        for preset in local {
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
        return Array(alive)
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
    /// Unknown JSON keys and unparseable optional values preserved across round-trip.
    var _preserved: [String: JSONValue] = [:]

    /// Retention for soft-deleted preset tombstones before they're purged at merge time.
    static let tombstoneRetention: TimeInterval = 30 * 24 * 3600

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, itemIds, quantities, compress, includeComments, createdAt, modifiedAt, isDeleted, deletedAt
    }

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

    init(from decoder: Decoder) throws {
        let typed = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try decoder.container(keyedBy: JSONCodingKey.self)
        self.id = try typed.decode(UUID.self, forKey: .id)
        self.name = try typed.decode(String.self, forKey: .name)
        self.itemIds = try typed.decode([UUID].self, forKey: .itemIds)
        self.compress = try typed.decode(Bool.self, forKey: .compress)
        self.includeComments = try typed.decode(Bool.self, forKey: .includeComments)
        self.createdAt = try typed.decode(Date.self, forKey: .createdAt)
        self.modifiedAt = try typed.decode(Date.self, forKey: .modifiedAt)
        self.isDeleted = try typed.decode(Bool.self, forKey: .isDeleted)

        var stash: [String: JSONValue] = [:]
        self.quantities = decodeOptionalPreserving([String: Double].self, forKey: .quantities, in: typed, raw: raw, stash: &stash)
        self.deletedAt = decodeOptionalPreserving(Date.self, forKey: .deletedAt, in: typed, raw: raw, stash: &stash)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let extras = (try? raw.extras(excluding: known)) ?? [:]
        self._preserved = stash.merging(extras) { _, new in new }
    }

    func encode(to encoder: Encoder) throws {
        try encodePreserved(_preserved, to: encoder)
        var typed = encoder.container(keyedBy: CodingKeys.self)
        try typed.encode(id, forKey: .id)
        try typed.encode(name, forKey: .name)
        try typed.encode(itemIds, forKey: .itemIds)
        try typed.encodeIfPresent(quantities, forKey: .quantities)
        try typed.encode(compress, forKey: .compress)
        try typed.encode(includeComments, forKey: .includeComments)
        try typed.encode(createdAt, forKey: .createdAt)
        try typed.encode(modifiedAt, forKey: .modifiedAt)
        try typed.encode(isDeleted, forKey: .isDeleted)
        try typed.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }

    static func == (lhs: SharePreset, rhs: SharePreset) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.itemIds == rhs.itemIds
            && lhs.quantities == rhs.quantities
            && lhs.compress == rhs.compress
            && lhs.includeComments == rhs.includeComments
            && lhs.createdAt == rhs.createdAt
            && lhs.modifiedAt == rhs.modifiedAt
            && lhs.isDeleted == rhs.isDeleted
            && lhs.deletedAt == rhs.deletedAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(itemIds)
        hasher.combine(quantities)
        hasher.combine(compress)
        hasher.combine(includeComments)
        hasher.combine(createdAt)
        hasher.combine(modifiedAt)
        hasher.combine(isDeleted)
        hasher.combine(deletedAt)
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
    /// Unknown JSON keys preserved from decode so they round-trip on encode.
    var _preserved: [String: JSONValue] = [:]
    var id: String { "\(latitude),\(longitude)" }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case latitude, longitude
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(from decoder: Decoder) throws {
        let typed = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try decoder.container(keyedBy: JSONCodingKey.self)
        self.latitude = try typed.decode(Double.self, forKey: .latitude)
        self.longitude = try typed.decode(Double.self, forKey: .longitude)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        self._preserved = (try? raw.extras(excluding: known)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        try encodePreserved(_preserved, to: encoder)
        var typed = encoder.container(keyedBy: CodingKeys.self)
        try typed.encode(latitude, forKey: .latitude)
        try typed.encode(longitude, forKey: .longitude)
    }

    static func == (lhs: Coordinate, rhs: Coordinate) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
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

    /// Unknown JSON keys and unparseable optional values preserved across round-trip.
    var _preserved: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, modifiedAt, icon, hiddenLabels, labelOrder, enableMapData
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

    init(from decoder: Decoder) throws {
        let typed = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try decoder.container(keyedBy: JSONCodingKey.self)

        // Required: id must be present and a string.
        self.id = try typed.decode(String.self, forKey: .id)

        // Defensive: missing or malformed name → fallback, never crash the file open.
        self.name = (try? typed.decode(String.self, forKey: .name)) ?? "Unnamed List"

        // Defensive: missing or malformed modifiedAt → current date.
        if let modDate = try? typed.decode(Date.self, forKey: .modifiedAt) {
            self.modifiedAt = modDate
        } else {
            self.modifiedAt = Date()
        }

        var stash: [String: JSONValue] = [:]
        self.icon = decodeOptionalPreserving(String.self, forKey: .icon, in: typed, raw: raw, stash: &stash)
        self.hiddenLabels = decodeOptionalPreserving([String].self, forKey: .hiddenLabels, in: typed, raw: raw, stash: &stash)
        self.labelOrder = decodeOptionalPreserving([String].self, forKey: .labelOrder, in: typed, raw: raw, stash: &stash)
        self.enableMapData = decodeOptionalPreserving(Bool.self, forKey: .enableMapData, in: typed, raw: raw, stash: &stash)

        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let extras = (try? raw.extras(excluding: known)) ?? [:]
        self._preserved = stash.merging(extras) { _, new in new }
    }

    func encode(to encoder: Encoder) throws {
        try encodePreserved(_preserved, to: encoder)
        var typed = encoder.container(keyedBy: CodingKeys.self)
        try typed.encode(id, forKey: .id)
        try typed.encode(name, forKey: .name)
        try typed.encode(modifiedAt, forKey: .modifiedAt)
        try typed.encodeIfPresent(icon, forKey: .icon)
        try typed.encodeIfPresent(hiddenLabels, forKey: .hiddenLabels)
        try typed.encodeIfPresent(labelOrder, forKey: .labelOrder)
        try typed.encodeIfPresent(enableMapData, forKey: .enableMapData)
    }

    static func == (lhs: ListSummary, rhs: ListSummary) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.modifiedAt == rhs.modifiedAt
            && lhs.icon == rhs.icon
            && lhs.hiddenLabels == rhs.hiddenLabels
            && lhs.labelOrder == rhs.labelOrder
            && lhs.enableMapData == rhs.enableMapData
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(modifiedAt)
        hasher.combine(icon)
        hasher.combine(hiddenLabels)
        hasher.combine(labelOrder)
        hasher.combine(enableMapData)
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
    /// Unknown JSON keys preserved from decode so they round-trip on encode.
    var _preserved: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case unit, interval
    }

    init(unit: ReminderRepeatUnit, interval: Int) {
        self.unit = unit
        self.interval = interval
    }

    init(from decoder: Decoder) throws {
        let typed = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try decoder.container(keyedBy: JSONCodingKey.self)
        self.unit = try typed.decode(ReminderRepeatUnit.self, forKey: .unit)
        self.interval = try typed.decode(Int.self, forKey: .interval)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        self._preserved = (try? raw.extras(excluding: known)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        try encodePreserved(_preserved, to: encoder)
        var typed = encoder.container(keyedBy: CodingKeys.self)
        try typed.encode(unit, forKey: .unit)
        try typed.encode(interval, forKey: .interval)
    }

    static func == (lhs: ReminderRepeatRule, rhs: ReminderRepeatRule) -> Bool {
        lhs.unit == rhs.unit && lhs.interval == rhs.interval
    }

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

    /// Unknown JSON keys and unparseable optional values preserved across round-trip,
    /// so a file written by a newer app version doesn't lose data when this version saves.
    var _preserved: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
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

    init(from decoder: Decoder) throws {
        let typed = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try decoder.container(keyedBy: JSONCodingKey.self)

        // Required fields — if any fail the whole item is unrecoverable.
        // ListDocument decodes items via LossyArray, so a thrown error here
        // just causes this one item to be skipped, not the whole document.
        self.id = try typed.decode(UUID.self, forKey: .id)
        self.note = try typed.decode(String.self, forKey: .note)
        self.quantity = try typed.decode(Double.self, forKey: .quantity)
        self.checked = try typed.decode(Bool.self, forKey: .checked)
        self.modifiedAt = try typed.decode(Date.self, forKey: .modifiedAt)
        self.isDeleted = try typed.decode(Bool.self, forKey: .isDeleted)

        var stash: [String: JSONValue] = [:]
        self.labelId = decodeOptionalPreserving(String.self, forKey: .labelId, in: typed, raw: raw, stash: &stash)
        self.markdownNotes = decodeOptionalPreserving(String.self, forKey: .markdownNotes, in: typed, raw: raw, stash: &stash)
        self.deletedAt = decodeOptionalPreserving(Date.self, forKey: .deletedAt, in: typed, raw: raw, stash: &stash)
        self.reminderDate = decodeOptionalPreserving(Date.self, forKey: .reminderDate, in: typed, raw: raw, stash: &stash)
        self.reminderRepeatRule = decodeOptionalPreserving(ReminderRepeatRule.self, forKey: .reminderRepeatRule, in: typed, raw: raw, stash: &stash)
        self.reminderRepeatMode = decodeOptionalPreserving(ReminderRepeatMode.self, forKey: .reminderRepeatMode, in: typed, raw: raw, stash: &stash)
        self.location = decodeOptionalPreserving(Coordinate.self, forKey: .location, in: typed, raw: raw, stash: &stash)
        self.sourceURL = decodeOptionalPreserving(String.self, forKey: .sourceURL, in: typed, raw: raw, stash: &stash)
        self.checkedAt = decodeOptionalPreserving(Date.self, forKey: .checkedAt, in: typed, raw: raw, stash: &stash)
        self.lastChangeField = decodeOptionalPreserving(String.self, forKey: .lastChangeField, in: typed, raw: raw, stash: &stash)

        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let extras = (try? raw.extras(excluding: known)) ?? [:]
        self._preserved = stash.merging(extras) { _, new in new }
    }

    func encode(to encoder: Encoder) throws {
        try encodePreserved(_preserved, to: encoder)
        var typed = encoder.container(keyedBy: CodingKeys.self)
        try typed.encode(id, forKey: .id)
        try typed.encode(note, forKey: .note)
        try typed.encode(quantity, forKey: .quantity)
        try typed.encode(checked, forKey: .checked)
        try typed.encode(modifiedAt, forKey: .modifiedAt)
        try typed.encode(isDeleted, forKey: .isDeleted)
        try typed.encodeIfPresent(labelId, forKey: .labelId)
        try typed.encodeIfPresent(markdownNotes, forKey: .markdownNotes)
        try typed.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try typed.encodeIfPresent(reminderDate, forKey: .reminderDate)
        try typed.encodeIfPresent(reminderRepeatRule, forKey: .reminderRepeatRule)
        try typed.encodeIfPresent(reminderRepeatMode, forKey: .reminderRepeatMode)
        try typed.encodeIfPresent(location, forKey: .location)
        try typed.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try typed.encodeIfPresent(checkedAt, forKey: .checkedAt)
        try typed.encodeIfPresent(lastChangeField, forKey: .lastChangeField)
    }
}


// MARK: - Shopping Label
struct ListLabel: Identifiable, Codable, Hashable, Equatable {
    var id: String  // Simple string like "need", "want", "groceries"
    var name: String
    var color: String  // Hex color
    var symbol: String?  // Optional SF Symbol name shown on map pin instead of the default icon
    /// Unknown JSON keys and unparseable optional values preserved across round-trip.
    var _preserved: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, color, symbol
    }

    init(id: String, name: String, color: String, symbol: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.symbol = symbol
    }

    init(from decoder: Decoder) throws {
        let typed = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try decoder.container(keyedBy: JSONCodingKey.self)
        self.id = try typed.decode(String.self, forKey: .id)
        self.name = try typed.decode(String.self, forKey: .name)
        self.color = try typed.decode(String.self, forKey: .color)
        var stash: [String: JSONValue] = [:]
        self.symbol = decodeOptionalPreserving(String.self, forKey: .symbol, in: typed, raw: raw, stash: &stash)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let extras = (try? raw.extras(excluding: known)) ?? [:]
        self._preserved = stash.merging(extras) { _, new in new }
    }

    func encode(to encoder: Encoder) throws {
        try encodePreserved(_preserved, to: encoder)
        var typed = encoder.container(keyedBy: CodingKeys.self)
        try typed.encode(id, forKey: .id)
        try typed.encode(name, forKey: .name)
        try typed.encode(color, forKey: .color)
        try typed.encodeIfPresent(symbol, forKey: .symbol)
    }

    static func == (lhs: ListLabel, rhs: ListLabel) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.color == rhs.color && lhs.symbol == rhs.symbol
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(color)
        hasher.combine(symbol)
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
