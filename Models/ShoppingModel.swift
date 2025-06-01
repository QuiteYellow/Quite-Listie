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
    var groupId: String?
    var householdId: String?
    
    var localTokenId: UUID? = nil
    
    var extras: [String: String] = [:]
    
    var markdownNotes: String {
        get { extras["markdownNotes"] ?? "" }
        set { extras["markdownNotes"] = newValue }
    }
    

    struct LabelWrapper: Codable, Equatable, Hashable {
        let id: String
        let name: String
        let color: String
        let groupId: String
        
        var localTokenId: UUID? = nil
        var householdId: String? = nil
    }
    
}

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
    var localTokenId: UUID?
    var groupId: String?
    var userId: String?
    var householdId: String?
    var extras: [String: String]?
    
    enum CodingKeys: String, CodingKey {
            case id
            case name
            case groupId
            case userId
            case extras
        }

}

struct UpdateListRequest: Codable {
    let id: String
    let name: String
    var extras: [String: String]
    let groupId: String
    let userId: String
    let listItems: [ShoppingItem]
    
    var listsForMealieListIcon: String { // Custom list icons
        get { extras["listsForMealieListIcon"] ?? "" }
        set { extras["listsForMealieListIcon"] = newValue }
    }
    
    var hiddenLabels: Bool { // Enable list colours per list
        get { extras["hiddenLabels"].flatMap { Bool($0) } ?? false }
        set { extras["hiddenLabels"] = String(newValue) }
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
