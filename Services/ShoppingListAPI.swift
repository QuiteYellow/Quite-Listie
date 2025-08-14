import Foundation

class ShoppingListAPI {
    static let shared = ShoppingListAPI()
    
    private var baseURL: URL? {
        guard let url = AppSettings.shared.validatedServerURL else {
            print("❌ baseURL is nil because validatedServerURL is nil")
            return nil
        }
        return url.appendingPathComponent("api")
    }
    
    private var tokens: [TokenInfo] {
        AppSettings.shared.tokens.filter { !$0.token.isEmpty && !$0.isLocal }
    }
    
    func isMealieServerReachable(at baseURL: URL) async -> Bool {
        let fullURL = baseURL.appendingPathComponent("api/app/about")
        //print("🌐 Checking reachability for: \(fullURL)")

        var request = URLRequest(url: fullURL)
        request.timeoutInterval = 5

        // ✅ Add Cloudflare headers if configured
        let settings = AppSettings.shared
        if settings.cloudflareAccessEnabled {
            if !settings.cfAccessClientId.isEmpty {
                request.setValue(settings.cfAccessClientId, forHTTPHeaderField: "CF-Access-Client-Id")
            }
            if !settings.cfAccessClientSecret.isEmpty {
                request.setValue(settings.cfAccessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
            }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Not an HTTP response")
                return false
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            //print("📡 Content-Type: \(contentType)")
            //print("🔍 Status Code: \(httpResponse.statusCode)")

            // Detect Cloudflare Access fallback page
            if contentType.contains("text/html") {
                let body = String(data: data, encoding: .utf8) ?? ""
                if body.contains("Cloudflare Access") || body.contains("cloudflare") {
                    //print("⚠️ Cloudflare Access page detected — check token settings")
                    DispatchQueue.main.async {
                        AppSettings.shared.lastReachabilityError = "Cloudflare Access is required for this server."
                    }
                    return false
                }
            }

            guard httpResponse.statusCode == 200 else {
                print("❌ Unexpected status code: \(httpResponse.statusCode)")
                return false
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["version"] as? String {
                //print("✅ Mealie version: \(version)")
                DispatchQueue.main.async {
                    AppSettings.shared.lastReachabilityError = nil
                }
                return true
            }

            print("❌ 'version' not found in JSON")
            return false

        } catch {
            print("❌ Network error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                AppSettings.shared.lastReachabilityError = error.localizedDescription
            }
            return false
        }
    }
    
    // MARK: - Create authorized request with token info
    private func authorizedRequest(url: URL, tokenInfo: TokenInfo, method: String = "GET", body: Data? = nil) -> URLRequest {
        precondition(!tokenInfo.isLocal, "🚫 Local token used in authorizedRequest. This should never happen.")
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
        
        struct ShoppingItemResponse: Codable {
            let items: [ShoppingItem]
            let page: Int
            let total_pages: Int
        }
        
        return try await withThrowingTaskGroup(of: [ShoppingItem].self) { tokenGroup in
            for tokenInfo in tokens {
                tokenGroup.addTask {
                    // First, fetch page 1 to know total_pages
                    var components = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
                    components.queryItems = [URLQueryItem(name: "page", value: "1")]
                    let firstURL = components.url!
                    
                    let firstRequest = self.authorizedRequest(url: firstURL, tokenInfo: tokenInfo)
                    let (firstData, firstResponse) = try await URLSession.shared.data(for: firstRequest)
                    
                    /*
                    if let httpResponse = firstResponse as? HTTPURLResponse {
                        print("⭐️ [Token \(tokenInfo.id)] Page 1 Status:", httpResponse.statusCode)
                    }
                    print("📦 Raw JSON for token \(tokenInfo.id), page 1:",
                          String(data: firstData, encoding: .utf8) ?? "<invalid utf8>")
                    */
                    
                    let firstResponseWrapper = try JSONDecoder().decode(ShoppingItemResponse.self, from: firstData)
                    
                    var allItems = firstResponseWrapper.items.map { item in
                        var taggedItem = item
                        taggedItem.localTokenId = tokenInfo.id
                        return taggedItem
                    }
                    
                    let totalPages = firstResponseWrapper.total_pages
                    
                    if totalPages > 1 {
                        // Fetch remaining pages concurrently
                        try await withThrowingTaskGroup(of: [ShoppingItem].self) { pageGroup in
                            for page in 2...totalPages {
                                pageGroup.addTask {
                                    var comps = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)!
                                    comps.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
                                    let pagedURL = comps.url!
                                    
                                    let request = self.authorizedRequest(url: pagedURL, tokenInfo: tokenInfo)
                                    let (data, response) = try await URLSession.shared.data(for: request)
                                    /*
                                    if let httpResponse = response as? HTTPURLResponse {
                                        print("⭐️ [Token \(tokenInfo.id)] Page \(page) Status:", httpResponse.statusCode)
                                    }
                                    print("📦 Raw JSON for token \(tokenInfo.id), page \(page):",
                                          String(data: data, encoding: .utf8) ?? "<invalid utf8>")
                                    */
                                    let responseWrapper = try JSONDecoder().decode(ShoppingItemResponse.self, from: data)
                                    return responseWrapper.items.map { item in
                                        var taggedItem = item
                                        taggedItem.localTokenId = tokenInfo.id
                                        return taggedItem
                                    }
                                }
                            }
                            
                            for try await pageItems in pageGroup {
                                allItems.append(contentsOf: pageItems)
                            }
                        }
                    }
                    
                    return allItems
                }
            }
            
            var allItemsAcrossTokens: [ShoppingItem] = []
            for try await tokenItems in tokenGroup {
                allItemsAcrossTokens.append(contentsOf: tokenItems)
            }
            return allItemsAcrossTokens
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
            print("[AddItem] ❌ Invalid base URL")
            throw URLError(.badURL)
        }
        
        let itemsURL = baseURL.appendingPathComponent("households/shopping/items")
        print("[AddItem] 📝 Items URL: \(itemsURL.absoluteString)")
        
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
            groupId: item.groupId,
            householdId: item.householdId
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let body = try encoder.encode(createPayload)
        
        if let jsonString = String(data: body, encoding: .utf8) {
            print("[AddItem] 📦 Request Body:\n\(jsonString)")
        }
        
        guard let tokenInfo = tokenInfo(for: item.localTokenId) else {
            print("[AddItem] ❌ No matching token for item.localTokenId = \(item.localTokenId?.uuidString ?? "nil")")
            throw URLError(.userAuthenticationRequired)
        }
        
        print("[AddItem] 🔑 Using token for authorization")
        
        let request = authorizedRequest(url: itemsURL, tokenInfo: tokenInfo, method: "POST", body: body)
        print("[AddItem] 📡 Sending request to \(request.url?.absoluteString ?? "unknown URL")")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("[AddItem] ✅ Response Status Code: \(httpResponse.statusCode)")
            }
            
            if let responseBody = String(data: data, encoding: .utf8) {
                print("[AddItem] 📥 Response Body:\n\(responseBody)")
            }
        } catch {
            print("[AddItem] ❌ Error adding item: \(error.localizedDescription)")
            throw error
        }
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
    
    // MARK: - Delete List uses token associated with the list
    func deleteList(_ list: ShoppingListSummary) async throws {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }
        let listsURL = baseURL.appendingPathComponent("households/shopping/lists")
        let url = listsURL.appendingPathComponent(list.id)

        guard let tokenInfo = tokenInfo(for: list.localTokenId) else {
            throw URLError(.userAuthenticationRequired)
        }

        let request = authorizedRequest(url: url, tokenInfo: tokenInfo, method: "DELETE")
        _ = try await URLSession.shared.data(for: request)
    }
    
    // MARK: - Toggle Item uses token associated with the item
    func updateItem(_ item: ShoppingItem) async throws {
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
            let page: Int
            let total_pages: Int
        }
        
        return try await withThrowingTaskGroup(of: [ShoppingListSummary].self) { tokenGroup in
            for tokenInfo in tokens {
                tokenGroup.addTask {
                    // Fetch the first page to know how many total pages there are
                    var request = self.authorizedRequest(url: listsURL, tokenInfo: tokenInfo)
                    request.url = URL(string: "\(listsURL)?page=1")
                    let (firstData, _) = try await URLSession.shared.data(for: request)
                    let firstPageResponse = try JSONDecoder().decode(ShoppingListsResponse.self, from: firstData)
                    
                    // Tag items with tokenId
                    var allLists: [ShoppingListSummary] = firstPageResponse.items.map { list in
                        var taggedList = list
                        taggedList.localTokenId = tokenInfo.id
                        return taggedList
                    }
                    
                    // If more pages, fetch concurrently
                    if firstPageResponse.total_pages > 1 {
                        try await withThrowingTaskGroup(of: [ShoppingListSummary].self) { pageGroup in
                            for page in 2...firstPageResponse.total_pages {
                                pageGroup.addTask {
                                    var pageRequest = self.authorizedRequest(url: listsURL, tokenInfo: tokenInfo)
                                    pageRequest.url = URL(string: "\(listsURL)?page=\(page)")
                                    let (data, _) = try await URLSession.shared.data(for: pageRequest)
                                    let pageResponse = try JSONDecoder().decode(ShoppingListsResponse.self, from: data)
                                    
                                    return pageResponse.items.map { list in
                                        var taggedList = list
                                        taggedList.localTokenId = tokenInfo.id
                                        return taggedList
                                    }
                                }
                            }
                            
                            for try await lists in pageGroup {
                                allLists.append(contentsOf: lists)
                            }
                        }
                    }
                    
                    return allLists
                }
            }
            
            var combinedLists: [ShoppingListSummary] = []
            for try await lists in tokenGroup {
                combinedLists.append(contentsOf: lists)
            }
            
            return combinedLists
        }
    }
    
    // MARK: - Fetch labels using all tokens concurrently
    func fetchShoppingLabels() async throws -> [ShoppingLabel] {
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
            let page: Int
            let total_pages: Int
        }
        
        return try await withThrowingTaskGroup(of: [ShoppingLabel].self) { tokenGroup in
            for tokenInfo in tokens {
                tokenGroup.addTask {
                    // Page 1
                    var comps = URLComponents(url: labelsURL, resolvingAgainstBaseURL: false)!
                    comps.queryItems = [URLQueryItem(name: "page", value: "1")]
                    let firstRequest = self.authorizedRequest(url: comps.url!, tokenInfo: tokenInfo)
                    let (firstData, _) = try await URLSession.shared.data(for: firstRequest)
                    
                    let firstWrapper = try JSONDecoder().decode(LabelsResponseWrapper.self, from: firstData)
                    
                    var allLabels = firstWrapper.items.map { label in
                        var wrapped = ShoppingLabel(id: label.id, name: label.name, color: label.color, groupId: label.groupId)
                        wrapped.localTokenId = tokenInfo.id
                        return wrapped
                    }
                    
                    let totalPages = firstWrapper.total_pages
                    
                    if totalPages > 1 {
                        try await withThrowingTaskGroup(of: [ShoppingLabel].self) { pageGroup in
                            for page in 2...totalPages {
                                pageGroup.addTask {
                                    var comps = URLComponents(url: labelsURL, resolvingAgainstBaseURL: false)!
                                    comps.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
                                    let request = self.authorizedRequest(url: comps.url!, tokenInfo: tokenInfo)
                                    let (data, _) = try await URLSession.shared.data(for: request)
                                    let wrapper = try JSONDecoder().decode(LabelsResponseWrapper.self, from: data)
                                    
                                    return wrapper.items.map { label in
                                        var wrapped = ShoppingLabel(id: label.id, name: label.name, color: label.color, groupId: label.groupId)
                                        wrapped.localTokenId = tokenInfo.id
                                        return wrapped
                                    }
                                }
                            }
                            
                            for try await pageLabels in pageGroup {
                                allLabels.append(contentsOf: pageLabels)
                            }
                        }
                    }
                    
                    return allLabels
                }
            }
            
            var mergedLabels: [ShoppingLabel] = []
            for try await labels in tokenGroup {
                mergedLabels.append(contentsOf: labels)
            }
            
            // Deduplicate by (id, groupId)
            struct LabelKey: Hashable {
                let id: String
                let groupId: String
            }
            var dict = [LabelKey: ShoppingLabel]()
            for label in mergedLabels {
                let key = LabelKey(id: label.id, groupId: label.groupId ?? "unknown")
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
            //print("🧩 Status Code: \(httpResponse.statusCode)")
            if let bodyString = String(data: data, encoding: .utf8) {
                //print("🧾 Response Body: \(bodyString)")
            }
            if !(200..<300).contains(httpResponse.statusCode) {
                throw NSError(domain: "API", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to update list name"])
            }
        }
    }
    
    // MARK: - Create Shopping List
    func createShoppingList(_ list: ShoppingListSummary) async throws {
        guard let baseURL = baseURL else {
            throw URLError(.badURL)
        }

        guard let tokenInfo = tokenInfo(for: list.localTokenId) else {
            throw URLError(.userAuthenticationRequired)
        }

        let url = baseURL.appendingPathComponent("households/shopping/lists")

        struct CreateListRequest: Codable {
            let name: String
            let extras: [String: String]?
            let createdAt: String
            let update_at: String
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let payload = CreateListRequest(
            name: list.name,
            extras: list.extras,
            createdAt: now,
            update_at: now
        )

        let body = try JSONEncoder().encode(payload)
        let request = authorizedRequest(url: url, tokenInfo: tokenInfo, method: "POST", body: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
    }
    
    // MARK: - Enrich Tokens With User Info
    func enrichTokensWithUserInfo(tokens: [TokenInfo]) async {
        guard let baseURL = baseURL else { return }

        DispatchQueue.main.async {
            AppSettings.shared.isEnrichingTokens = true
        }

        defer {
            DispatchQueue.main.async {
                AppSettings.shared.isEnrichingTokens = false
            }
        }

        var enrichedTokens: [TokenInfo] = []

        for token in tokens {
            // Skip enriching the local device token
            if token.id == TokenInfo.localDeviceToken.id {
                enrichedTokens.append(token)
                continue
            }

            let userURL = baseURL.appendingPathComponent("/users/self")
            let request = authorizedRequest(url: userURL, tokenInfo: token)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    print("❌ HTTP error for \(token.identifier): \(response)")
                    enrichedTokens.append(token)
                    continue
                }

                let info = try JSONDecoder().decode(UserInfoResponse.self, from: data)

                var enriched = token
                enriched.email = info.email
                enriched.fullName = info.fullName
                enriched.username = info.username
                enriched.group = info.group
                enriched.household = info.household
                enriched.isAdmin = info.admin
                enriched.groupId = info.groupId
                enriched.groupSlug = info.groupSlug
                enriched.householdId = info.householdId
                enriched.householdSlug = info.householdSlug
                enriched.canManage = info.canManage

                enrichedTokens.append(enriched)

            } catch {
                print("❌ Failed to decode user info for \(token.identifier): \(error.localizedDescription)")
                enrichedTokens.append(token)
            }
        }

        DispatchQueue.main.async {
            var updated = AppSettings.shared.tokens

            for enriched in enrichedTokens {
                if let index = updated.firstIndex(where: { $0.id == enriched.id }) {
                    updated[index] = enriched
                } else {
                    updated.append(enriched)
                }
            }

            AppSettings.shared.tokens = updated
        }
    }
    
    func createLabel(name: String, color: String, groupId: String, tokenInfo: TokenInfo) async throws {
        guard let baseURL = baseURL else { throw URLError(.badURL) }

        let url = baseURL.appendingPathComponent("groups/labels")
        let payload = [
            "name": name,
            "color": color,
            "groupId": groupId
        ]
        let body = try JSONEncoder().encode(payload)
        let request = authorizedRequest(url: url, tokenInfo: tokenInfo, method: "POST", body: body)
        _ = try await URLSession.shared.data(for: request)
    }
    
    func updateLabel(label: ShoppingLabel, tokenInfo: TokenInfo) async throws {
        guard let baseURL = baseURL else { throw URLError(.badURL) }

        let url = baseURL.appendingPathComponent("groups/labels/\(label.id)")
        let payload = [
            "id": label.id,
            "name": label.name,
            "color": label.color,
            "groupId": label.groupId
        ]
        let body = try JSONEncoder().encode(payload)

        //print("📡 Sending PUT to \(url)")
        //print("   ➤ Payload: \(payload)")

        let request = authorizedRequest(url: url, tokenInfo: tokenInfo, method: "PUT", body: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                //print("🌐 Response Status: \(httpResponse.statusCode)")
                if !(200...299).contains(httpResponse.statusCode) {
                    //print("⚠️ Response Body: \(String(data: data, encoding: .utf8) ?? "Invalid UTF8")")
                }
            }
        } catch {
            print("❌ Network request failed: \(error)")
            throw error
        }
    }
    
    func deleteLabel(label: ShoppingLabel, tokenInfo: TokenInfo) async throws {
        guard let baseURL = baseURL else { throw URLError(.badURL) }

        let url = baseURL.appendingPathComponent("groups/labels/\(label.id)")
        let request = authorizedRequest(url: url, tokenInfo: tokenInfo, method: "DELETE")
        _ = try await URLSession.shared.data(for: request)
    }

}

