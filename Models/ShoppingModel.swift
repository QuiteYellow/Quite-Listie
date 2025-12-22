//
//  ShoppingModel.swift (V2 - SIMPLIFIED)
//  ListsForMealie
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
    
    // Optional fields
    var markdownNotes: String?  // Moved out of extras
    
    // Legacy fields (will be ignored in new files)
    var shoppingListId: String? = nil
    var label: ShoppingLabel? = nil  // Old embedded label
    var localTokenId: UUID? = nil
    var groupId: String? = nil
    var householdId: String? = nil
    var extras: [String: String]? = nil
    
    enum CodingKeys: String, CodingKey {
        case id, note, quantity, checked, labelId, modifiedAt, markdownNotes
        case shoppingListId, label, localTokenId, groupId, householdId, extras
    }
    
    init(id: UUID = UUID(), note: String, quantity: Double = 1, checked: Bool = false,
         labelId: String? = nil, markdownNotes: String? = nil, modifiedAt: Date = Date()) {
        self.id = id
        self.note = note
        self.quantity = quantity
        self.checked = checked
        self.labelId = labelId
        self.markdownNotes = markdownNotes
        self.modifiedAt = modifiedAt
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

// MARK: - Legacy Support Types
struct ShoppingListsResponse: Codable {
    let page: Int
    let per_page: Int
    let total: Int
    let total_pages: Int
    let items: [ShoppingListSummary]
}

struct UpdateListRequest: Codable {
    let id: String
    let name: String
    var extras: [String: String]
    let groupId: String
    let userId: String
    let listItems: [ShoppingItem]
    
    var listsForMealieListIcon: String {
        get { extras["listsForMealieListIcon"] ?? "" }
        set { extras["listsForMealieListIcon"] = newValue }
    }
    
    var hiddenLabels: Bool {
        get { extras["hiddenLabels"].flatMap { Bool($0) } ?? false }
        set { extras["hiddenLabels"] = String(newValue) }
    }

    var favouritedBy: [String] {
        get { extras["favouritedBy"]?.split(separator: ",").map(String.init) ?? [] }
        set { extras["favouritedBy"] = newValue.joined(separator: ",") }
    }
}

struct UserInfoResponse: Codable {
    let email: String
    let fullName: String
    let username: String
    let group: String
    let household: String
    let admin: Bool
    let groupId: String?
    let groupSlug: String?
    let householdId: String?
    let householdSlug: String?
    let canManage: Bool?
}

extension UpdateListRequest {
    func isFavourited(by userID: String) -> Bool {
        favouritedBy.contains(userID)
    }

    mutating func toggleFavourite(by userID: String) {
        var current = Set(favouritedBy)
        if current.contains(userID) {
            current.remove(userID)
        } else {
            current.insert(userID)
        }
        favouritedBy = Array(current)
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

// MARK: - Convenience Extensions
extension ShoppingListSummary {
    var isLocal: Bool {
        id.hasPrefix("local-")
    }
    
    var isReadOnlyExample: Bool {
        id == "example-welcome-list"
    }
}

extension ShoppingItem {
    var isLocal: Bool {
        shoppingListId?.hasPrefix("local-") ?? true
    }
    
    var isFromReadOnlyList: Bool {
        shoppingListId == "example-welcome-list"
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
