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
