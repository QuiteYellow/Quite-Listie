import Foundation
import SwiftUI

class AppSettings: ObservableObject {
    @Published var serverURLString: String {
            didSet {
                UserDefaults.standard.set(serverURLString, forKey: "serverURLString")
            }
        }
    
    @Published var apiToken: String {
        didSet {
            UserDefaults.standard.set(apiToken, forKey: "apiToken")
        }
    }
    
    @Published var expandedSections: [String: Bool] {
        didSet {
            UserDefaults.standard.set(expandedSections, forKey: expandedSectionsKey)
        }
    }
    
    @Published var cloudflareAccessEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cloudflareAccessEnabled, forKey: "cloudflareAccessEnabled")
        }
    }
    
    @Published var cfAccessClientId: String {
        didSet {
            UserDefaults.standard.set(cfAccessClientId, forKey: "cfAccessClientId")
        }
    }
    
    @Published var cfAccessClientSecret: String {
        didSet {
            UserDefaults.standard.set(cfAccessClientSecret, forKey: "cfAccessClientSecret")
        }
    }
    
    private let expandedSectionsKey = "expandedSectionsKey"
    
    static let shared = AppSettings()
    
    private init() {
        self.serverURLString = UserDefaults.standard.string(forKey: "serverURLString") ?? ""
        self.apiToken = UserDefaults.standard.string(forKey: "apiToken") ?? ""
        self.expandedSections = UserDefaults.standard.dictionary(forKey: expandedSectionsKey) as? [String: Bool] ?? [:]
        self.cloudflareAccessEnabled = UserDefaults.standard.bool(forKey: "cloudflareAccessEnabled")
        self.cfAccessClientId = UserDefaults.standard.string(forKey: "cfAccessClientId") ?? ""
        self.cfAccessClientSecret = UserDefaults.standard.string(forKey: "cfAccessClientSecret") ?? ""
    }
    
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
            // Trigger didSet manually to save changes
            expandedSections = expandedSections
        }
    }
}
