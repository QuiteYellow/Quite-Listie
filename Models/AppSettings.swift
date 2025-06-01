import Foundation
import SwiftUI



struct TokenInfo: Codable, Identifiable, Equatable {
    private(set) var id: UUID = UUID()  // handled automatically, UUID generated automatically, will gen an error if...
    var token: String                   // ...immutable (let) so private var to supress error but still effectively be read-only (outside).
    var identifier: String              // "account1", "someone@example.com" etc
    
    // Optional enriched metadata
    var email: String?
    var fullName: String?
    var username: String?
    var group: String?
    var household: String?
    var isAdmin: Bool?
    var groupId: String?
    var groupSlug: String?
    var householdId: String?
    var householdSlug: String?
    var canManage: Bool?
}


class AppSettings: ObservableObject {
    @Published var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: "serverURLString") }
    }
    
    // Old single token (optional to keep or migrate)
    @Published var apiToken: String {
        didSet { UserDefaults.standard.set(apiToken, forKey: "apiToken") }
    }
    
    // New array of tokens
    @Published var tokens: [TokenInfo] {
        didSet {
            saveTokensToUserDefaults()
        }
    }
    
    @Published var expandedSections: [String: Bool] {
        didSet { UserDefaults.standard.set(expandedSections, forKey: expandedSectionsKey) }
    }
    
    @Published var cloudflareAccessEnabled: Bool {
        didSet { UserDefaults.standard.set(cloudflareAccessEnabled, forKey: "cloudflareAccessEnabled") }
    }
    
    @Published var cfAccessClientId: String {
        didSet { UserDefaults.standard.set(cfAccessClientId, forKey: "cfAccessClientId") }
    }
    
    @Published var cfAccessClientSecret: String {
        didSet { UserDefaults.standard.set(cfAccessClientSecret, forKey: "cfAccessClientSecret") }
    }
    
    @Published var showCompletedAtBottom: Bool {
        didSet { UserDefaults.standard.set(showCompletedAtBottom, forKey: "showCompletedAtBottom") }
    }
    
    @Published var isEnrichingTokens: Bool = false
    
    private let expandedSectionsKey = "expandedSectionsKey"
    private let tokensKey = "tokensKey"
    
    static let shared = AppSettings()
    
    private init() {
        self.showCompletedAtBottom = UserDefaults.standard.bool(forKey: "showCompletedAtBottom")
        self.serverURLString = UserDefaults.standard.string(forKey: "serverURLString") ?? ""
        self.apiToken = UserDefaults.standard.string(forKey: "apiToken") ?? ""
        self.expandedSections = UserDefaults.standard.dictionary(forKey: expandedSectionsKey) as? [String: Bool] ?? [:]
        self.cloudflareAccessEnabled = UserDefaults.standard.bool(forKey: "cloudflareAccessEnabled")
        self.cfAccessClientId = UserDefaults.standard.string(forKey: "cfAccessClientId") ?? ""
        self.cfAccessClientSecret = UserDefaults.standard.string(forKey: "cfAccessClientSecret") ?? ""
        self.tokens = []
        loadTokensFromUserDefaults()
    }
    
    // MARK: - Multiple tokens persistence
    
    private func saveTokensToUserDefaults() {
        if let data = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(data, forKey: tokensKey)
        }
    }
    
    private func loadTokensFromUserDefaults() {
        
        guard let data = UserDefaults.standard.data(forKey: tokensKey),
              let savedTokens = try? JSONDecoder().decode([TokenInfo].self, from: data) else {
            return
        }
        self.tokens = savedTokens

        Task {
            await ShoppingListAPI.shared.enrichTokensWithUserInfo()
        }
    }
    
    // Convenience to add/remove tokens
    func addToken(_ token: TokenInfo) {
        tokens.append(token)
    }
    
    func removeToken(_ token: TokenInfo) {
        tokens.removeAll { $0 == token }
    }
    
    // Existing methods...
    func toggleSection(_ label: String) {
        withAnimation {
            if let isExpanded = expandedSections[label] {
                expandedSections[label] = !isExpanded
            } else {
                expandedSections[label] = true
            }
        }
    }
    
    func initializeExpandedSections(for labels: [String]) {
        var didChange = false
        for label in labels {
            if expandedSections[label] == nil {
                expandedSections[label] = false
                didChange = true
            }
        }
        if didChange {
            expandedSections = expandedSections
        }
    }
}
