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
                        print("🏷️ taggedItem: \(taggedItem)")
                        taggedItem.localTokenId = tokenInfo.id
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
    
    // MARK: - Helper to find TokenInfo by localTokenId
    private func tokenInfo(for localTokenId: UUID?) -> TokenInfo? {
        guard let id = localTokenId else { return nil }
        return tokens.first(where: { $0.id == id })
    }
    
    // MARK: - Add Item uses any token
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
            let groupId: String?
            let householdId: String?
        }
        
        let createPayload = ShoppingItemCreateRequest(
            note: item.note,
            checked: item.checked,
            shoppingListId: shoppingListId,
            labelId: item.label?.id,
            quantity: item.quantity,
            extras: item.extras,
            groupId: item.groupId ?? "",
            householdId: item.householdId ?? ""
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
        
        guard let tokenInfo = tokenInfo(for: item.localTokenId) else {
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
            let groupId: String?
            let householdId: String?
        }
        
        let updatePayload = ShoppingItemUpdateRequest(
            id: item.id,
            note: item.note,
            checked: item.checked,
            shoppingListId: item.shoppingListId,
            labelId: item.label?.id,
            quantity: item.quantity,
            extras: item.extras,
            groupId: item.groupId ?? "",
            householdId: item.householdId ?? ""
        )
        
        let body = try JSONEncoder().encode(updatePayload)
        let url = baseURL
            .appendingPathComponent("households/shopping/items")
            .appendingPathComponent(item.id.uuidString)
        
        guard let tokenInfo = tokenInfo(for: item.localTokenId) else {
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
                    
                    // Tagging shopping lists with localTokenId is possible if needed here
                    return responseWrapper.items.map { list in
                        var taggedList = list
                        taggedList.localTokenId = tokenInfo.id
                        return taggedList
                    }
                }
            }
            
            var allLists: [ShoppingListSummary] = []
            for try await lists in group {
                allLists.append(contentsOf: lists)
            }
            return allLists
        }
    }
    
    // MARK: - Fetch labels using all tokens concurrently
    func fetchShoppingLabels() async throws -> [ShoppingItem.LabelWrapper] {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let labelsURL = baseURL.appendingPathComponent("groups/labels")
        
        struct LabelResponse: Decodable {
            let id: String
            let name: String
            let color: String
            let groupId: String
        }
        
        struct LabelsResponseWrapper: Decodable {
            let items: [LabelResponse]
        }
        
        return try await withThrowingTaskGroup(of: [ShoppingItem.LabelWrapper].self) { group in
            for tokenInfo in tokens {
                group.addTask {
                    let request = self.authorizedRequest(url: labelsURL, tokenInfo: tokenInfo)
                    let (data, _) = try await URLSession.shared.data(for: request)
                    let wrapper = try JSONDecoder().decode(LabelsResponseWrapper.self, from: data)
                    
                    return wrapper.items.map { label in
                        var wrapper = ShoppingItem.LabelWrapper(id: label.id, name: label.name, color: label.color, groupId: label.groupId)
                        wrapper.localTokenId = tokenInfo.id  // Tag the label with its token
                        return wrapper
                    }
                }
            }
/*
            var allLabels: [ShoppingItem.LabelWrapper] = []
            for try await labels in group {
                allLabels.append(contentsOf: labels)
            }
            return allLabels
            
 */
            
            // Define a Hashable struct for the dictionary key to stopp hashable error
            struct LabelKey: Hashable {
                let id: String
                let groupId: String
            }

            // LabelKey
            var allLabels: [ShoppingItem.LabelWrapper] = []
            for try await labels in group {
                allLabels.append(contentsOf: labels)
            }

            // Remove duplicates by (id, groupId), treating nil as ""
            var dict = [LabelKey: ShoppingItem.LabelWrapper]()
            for label in allLabels {
                let key = LabelKey(id: label.id, groupId: label.groupId)
                dict[key] = label
            }

            return Array(dict.values)
        }
    }
    
    // MARK: - Update Shopping List Name
    func updateShoppingListName(list: ShoppingListSummary, newName: String, items: [ShoppingItem], extras: [String: String] = [:]) async throws {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }

        guard let groupId = list.groupId,
              let userId = list.userId,
              let tokenInfo = tokenInfo(for: list.localTokenId) else {
            throw NSError(domain: "API", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing required fields"])
        }

        let updateURL = baseURL
            .appendingPathComponent("households/shopping/lists")
            .appendingPathComponent(list.id)

        let payload = UpdateListRequest(
            id: list.id,
            name: newName,
            extras: extras,
            groupId: groupId,
            userId: userId,
            listItems: items
            
        )

        let body = try JSONEncoder().encode(payload)
        let request = authorizedRequest(url: updateURL, tokenInfo: tokenInfo, method: "PUT", body: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            print("🧩 Status Code: \(httpResponse.statusCode)")
            if let bodyString = String(data: data, encoding: .utf8) {
                print("🧾 Response Body: \(bodyString)")
            }
            if !(200..<300).contains(httpResponse.statusCode) {
                throw NSError(domain: "API", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to update list name"])
            }
        }
    }

}
