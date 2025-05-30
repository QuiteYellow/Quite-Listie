//
//  ListItemModel.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 25/05/2025.
//

import Foundation

struct ShoppingItem: Identifiable, Codable {
    var id: UUID
    var note: String
    var checked: Bool
    var shoppingListId: String
    var label: LabelWrapper?
    var quantity: Double?
    
    var tokenId: UUID? = nil
    
    var extras: [String: String]?
    
    var groupId: String?
    var householdId: String?

        var markdownNotes: String {
            get { extras?["markdownNotes"] ?? "" }
            set {
                if extras == nil { extras = [:] }
                extras?["markdownNotes"] = newValue
            }
        }
    
    struct LabelWrapper: Codable, Hashable {
        let id: String
        let name: String
        let color: String
        let groupId: String
        
        var tokenId: UUID? = nil
    }
}

import Foundation

struct ShoppingListsResponse: Codable {
    let page: Int
    let per_page: Int
    let total: Int
    let total_pages: Int
    let items: [ShoppingListSummary]
}

struct ShoppingListSummary: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var tokenId: UUID?
    var groupId: String?
    var userId: String?
    var extras: [String: String]?
    
    enum CodingKeys: String, CodingKey {
            case id
            case name
            case groupId
            case userId
            case extras
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            groupId = try? container.decode(String.self, forKey: .groupId)
            userId = try? container.decode(String.self, forKey: .userId)
            extras = try? container.decode([String: String].self, forKey: .extras)

            tokenId = nil
        }

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
}
