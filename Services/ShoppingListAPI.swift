import Foundation

class ShoppingListAPI {
    static let shared = ShoppingListAPI()
    
    private var baseURL: URL? {
        guard let url = URL(string: AppSettings.shared.serverURLString) else { return nil }
        return url.appendingPathComponent("api")
    }
    
    private var tokens: [TokenInfo] {
        AppSettings.shared.tokens.filter { !$0.token.isEmpty }
    }
    
    // MARK: - Create authorized request with token info
    private func authorizedRequest(url: URL, tokenInfo: TokenInfo, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        request.setValue("Bearer \(tokenInfo.token)", forHTTPHeaderField: "Authorization")
        
        let settings = AppSettings.shared
        if settings.cloudflareAccessEnabled {
            if !settings.cfAccessClientId.isEmpty {
                request.setValue(settings.cfAccessClientId, forHTTPHeaderField: "CF-Access-Client-Id")
            }
            if !settings.cfAccessClientSecret.isEmpty {
                request.setValue(settings.cfAccessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
            }
        }
        
        request.httpBody = body
        return request
    }
    
    // MARK: - Fetch Items from all tokens concurrently and tag with tokenId
    func fetchItems() async throws -> [ShoppingItem] {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let itemsURL = baseURL.appendingPathComponent("households/shopping/items")
        
        // Define a struct for API response wrapper (items array)
        struct ShoppingItemResponse: Codable {
            let items: [ShoppingItem]
        }
        
        // Use Task Group to fetch concurrently for all tokens
        return try await withThrowingTaskGroup(of: [ShoppingItem].self) { group in
            
            // For each token, add a fetch task
            for tokenInfo in tokens {
                group.addTask {
                    let request = self.authorizedRequest(url: itemsURL, tokenInfo: tokenInfo)
                    let (data, response) = try await URLSession.shared.data(for: request)
                    
//                    if let httpResponse = response as? HTTPURLResponse {
//                        print("⭐️ [Token \(tokenInfo.id)] Status code:", httpResponse.statusCode)
//                    }
                    
                    let responseWrapper = try JSONDecoder().decode(ShoppingItemResponse.self, from: data)
                    
                    // Tag each item with the tokenId it came from
                    return responseWrapper.items.map { item in
                        var taggedItem = item
                        taggedItem.tokenId = tokenInfo.id
                        return taggedItem
                    }
                }
            }
            
            var allItems: [ShoppingItem] = []
            // Collect all results from concurrent tasks
            for try await items in group {
                allItems.append(contentsOf: items)
            }
            
            return allItems
        }
    }
    
    // MARK: - Helper to find TokenInfo by tokenId
    private func tokenInfo(for tokenId: UUID?) -> TokenInfo? {
        guard let id = tokenId else { return nil }
        return tokens.first(where: { $0.id == id })
    }
    
    // MARK: - Add Item uses any token (you can customize)
    func addItem(_ item: ShoppingItem, to shoppingListId: String) async throws {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let itemsURL = baseURL.appendingPathComponent("households/shopping/items")
        
        struct ShoppingItemCreateRequest: Codable {
            let note: String
            let checked: Bool
            let shoppingListId: String
            let labelId: String?
            let quantity: Double?
            let extras: [String: String]?
        }
        
        let createPayload = ShoppingItemCreateRequest(
            note: item.note,
            checked: item.checked,
            shoppingListId: shoppingListId,
            labelId: item.label?.id,
            quantity: item.quantity,
            extras: item.extras
        )
        
        let body = try JSONEncoder().encode(createPayload)
        
        // Use first token for add by default
        guard let tokenInfo = tokens.first else {
            throw URLError(.userAuthenticationRequired)
        }
        
        let request = authorizedRequest(url: itemsURL, tokenInfo: tokenInfo, method: "POST", body: body)
        _ = try await URLSession.shared.data(for: request)
    }
    
    // MARK: - Delete Item uses token associated with the item
    func deleteItem(_ item: ShoppingItem) async throws {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let itemsURL = baseURL.appendingPathComponent("households/shopping/items")
        let url = itemsURL.appendingPathComponent(item.id.uuidString)
        
        guard let tokenInfo = tokenInfo(for: item.tokenId) else {
            throw URLError(.userAuthenticationRequired)
        }
        
        let request = authorizedRequest(url: url, tokenInfo: tokenInfo, method: "DELETE")
        _ = try await URLSession.shared.data(for: request)
    }
    
    // MARK: - Toggle Item uses token associated with the item
    func toggleItem(_ item: ShoppingItem) async throws {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        
        struct ShoppingItemUpdateRequest: Codable {
            let id: UUID
            let note: String
            let checked: Bool
            let shoppingListId: String
            let labelId: String?
            let quantity: Double?
            let extras: [String: String]?
        }
        
        let updatePayload = ShoppingItemUpdateRequest(
            id: item.id,
            note: item.note,
            checked: item.checked,
            shoppingListId: item.shoppingListId,
            labelId: item.label?.id,
            quantity: item.quantity,
            extras: item.extras
        )
        
        let body = try JSONEncoder().encode(updatePayload)
        let url = baseURL
            .appendingPathComponent("households/shopping/items")
            .appendingPathComponent(item.id.uuidString)
        
        guard let tokenInfo = tokenInfo(for: item.tokenId) else {
            throw URLError(.userAuthenticationRequired)
        }
        
        let request = authorizedRequest(url: url, tokenInfo: tokenInfo, method: "PUT", body: body)
        _ = try await URLSession.shared.data(for: request)
    }
    
    // MARK: - Fetch shopping lists using all tokens concurrently and combine (optionally)
    func fetchShoppingLists() async throws -> [ShoppingListSummary] {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let listsURL = baseURL.appendingPathComponent("households/shopping/lists")
        
        struct ShoppingListsResponse: Codable {
            let items: [ShoppingListSummary]
        }
        
        return try await withThrowingTaskGroup(of: [ShoppingListSummary].self) { group in
            for tokenInfo in tokens {
                group.addTask {
                    let request = self.authorizedRequest(url: listsURL, tokenInfo: tokenInfo)
                    let (data, response) = try await URLSession.shared.data(for: request)
                    
//                    if let httpResponse = response as? HTTPURLResponse {
//                        print("⭐️ [Token \(tokenInfo.id)] Status code:", httpResponse.statusCode)
//                    }
                    
                    let responseWrapper = try JSONDecoder().decode(ShoppingListsResponse.self, from: data)
                    
                    // Tagging shopping lists with tokenId is possible if needed here
                    return responseWrapper.items
                }
            }
            
            var allLists: [ShoppingListSummary] = []
            for try await lists in group {
                allLists.append(contentsOf: lists)
            }
            return allLists
        }
    }
    
    // MARK: - Fetch labels from first token (or you can also fetch concurrently if needed)
    func fetchShoppingLabels() async throws -> [ShoppingItem.LabelWrapper] {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let labelsURL = baseURL.appendingPathComponent("groups/labels")
        
        guard let tokenInfo = tokens.first else {
            throw URLError(.userAuthenticationRequired)
        }
        
        let request = authorizedRequest(url: labelsURL, tokenInfo: tokenInfo)
        print("⭐️ Request URL:", request)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            print("⭐️ Status code:", httpResponse.statusCode)
        }
        
        struct LabelResponse: Decodable {
            let id: String
            let name: String
            let color: String
        }
        
        struct LabelsResponseWrapper: Decodable {
            let items: [LabelResponse]
        }
        
        let decoder = JSONDecoder()
        let responseWrapper = try decoder.decode(LabelsResponseWrapper.self, from: data)
        
        return responseWrapper.items.map { label in
            ShoppingItem.LabelWrapper(id: label.id, name: label.name, color: label.color)
        }
    }
}
