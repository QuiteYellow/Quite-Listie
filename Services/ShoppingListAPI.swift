//
//  ListAPI.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 25/05/2025.
//

import Foundation

class ShoppingListAPI {
    static let shared = ShoppingListAPI()
    private var baseURL: URL? {
        guard let url = URL(string: AppSettings.shared.serverURLString) else { return nil }
        return url.appendingPathComponent("api")
    }

    private var token: String {
        UserDefaults.standard.string(forKey: "apiToken") ?? ""
    }

    private func authorizedRequest(url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let settings = AppSettings.shared
        
        if !settings.apiToken.isEmpty {
            request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        }
        
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

    struct ShoppingItemResponse: Codable {
        let items: [ShoppingItem]
    }

    func fetchItems() async throws -> [ShoppingItem] {
        guard let baseURL = baseURL else {
                throw URLError(.badURL)
            }
        let itemsURL = baseURL.appendingPathComponent("households/shopping/items")
        let request = authorizedRequest(url: itemsURL)
        print("⭐️ Request URL:", request)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Debug: print response status code
        if let httpResponse = response as? HTTPURLResponse {
            print("⭐️ Status code:", httpResponse.statusCode)
        }
        
        // Debug: print raw response body
        //if let body = String(data: data, encoding: .utf8) {
        //    print("Raw response body:\n\(body)")
        //}
        
        // Decode the JSON dictionary first, then extract the items array
        let responseWrapper = try JSONDecoder().decode(ShoppingItemResponse.self, from: data)
        return responseWrapper.items
    }

    func addItem(_ item: ShoppingItem, to shoppingListId: String) async throws {
        // Construct the URL with the list ID included
        guard let baseURL = baseURL else {
                throw URLError(.badURL)
            }
        let itemsURL = baseURL.appendingPathComponent("households/shopping/items")
        // Encode the item into JSON data
        var newItemWithListId = item
        newItemWithListId.shoppingListId = shoppingListId
        let body = try JSONEncoder().encode(newItemWithListId)
        // Create the authorized POST request with the body
        let request = authorizedRequest(url: itemsURL, method: "POST", body: body)
        // Perform the network call
        _ = try await URLSession.shared.data(for: request)
    }

    func deleteItem(_ id: UUID) async throws {
        guard let baseURL = baseURL else {
                throw URLError(.badURL)
            }
        let itemsURL = baseURL.appendingPathComponent("households/shopping/items")
        let url = itemsURL.appendingPathComponent(id.uuidString)
        let request = authorizedRequest(url: url, method: "DELETE")
        _ = try await URLSession.shared.data(for: request)
    }

    func toggleItem(_ item: ShoppingItem) async throws {
        guard let baseURL = baseURL else {
                throw URLError(.badURL)
            }
        let itemsURL = baseURL.appendingPathComponent("households/shopping/items")
        let url = itemsURL.appendingPathComponent(item.id.uuidString)
        let body = try JSONEncoder().encode(item)
        let request = authorizedRequest(url: url, method: "PUT", body: body)
        _ = try await URLSession.shared.data(for: request)
    }
    
    func fetchShoppingLists() async throws -> [ShoppingListSummary] {
        guard let baseURL = baseURL else {
                throw URLError(.badURL)
            }
        let listsURL = baseURL.appendingPathComponent("households/shopping/lists")
        let request = authorizedRequest(url: listsURL)
        print("⭐️ Request URL:", request)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            print("⭐️ Status code:", httpResponse.statusCode)
        }
        
        let decoder = JSONDecoder()
        let responseWrapper = try decoder.decode(ShoppingListsResponse.self, from: data)
        return responseWrapper.items
    }
    
    func fetchShoppingLabels() async throws -> [ShoppingItem.LabelWrapper] {
        guard let baseURL = baseURL else {
                throw URLError(.badURL)
            }
        let labelsURL = baseURL.appendingPathComponent("api/groups/labels")
        let request = authorizedRequest(url: labelsURL)
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

