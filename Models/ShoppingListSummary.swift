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
    let name: String
    var tokenId: UUID?
    
    enum CodingKeys: String, CodingKey {
            case id
            case name
            // do NOT include tokenId, it'll be injected in as not provided by the API
        }
    
    init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            tokenId = nil  // Manually assign later
        }

}
