import Foundation
import SwiftUI

@MainActor
class LabelManagerViewModel: ObservableObject {
    @Published var allLabels: [ShoppingLabel] = []
    
    func loadLabels() async {
        do {
            let labels = try await CombinedShoppingListProvider.shared.fetchAllLabels()
            print("📦 [LabelManager] Loaded \(labels.count) total labels")
            
            await MainActor.run {
                withAnimation {
                    allLabels = labels
                }
            }
        } catch {
            print("❌ Failed to load labels: \(error)")
        }
    }
    
    func createLabel(name: String, color: String, groupId: String, tokenId: UUID) async {
        guard let tokenInfo = AppSettings.shared.tokens.first(where: { $0.id == tokenId }) else { return }
        do {
            try await ShoppingListAPI.shared.createLabel(name: name, color: color, groupId: groupId, tokenInfo: tokenInfo)
            await loadLabels()
        } catch {
            print("❌ Failed to create label: \(error)")
        }
    }

    func updateLabel(_ label: ShoppingLabel) async {
        guard let tokenInfo = AppSettings.shared.tokens.first(where: { $0.id == label.localTokenId }) else { return }
        print("🔄 Updating label:")
        print("ID: \(label.id)")
        print("Name: \(label.name)")
        print("Color: \(label.color)")
        print("Group ID: \(label.groupId ?? "nil")")
        print("Token ID: \(tokenInfo.id)")
        do {
            try await ShoppingListAPI.shared.updateLabel(label: label, tokenInfo: tokenInfo)
            await loadLabels()
        } catch {
            print("❌ Failed to update label: \(error)")
        }
    }

    func deleteLabel(_ label: ShoppingLabel) async {
        guard let tokenInfo = AppSettings.shared.tokens.first(where: { $0.id == label.localTokenId }) else { return }
        do {
            try await ShoppingListAPI.shared.deleteLabel(label: label, tokenInfo: tokenInfo)
            await loadLabels()
        } catch {
            print("❌ Failed to delete label: \(error)")
        }
    }
}
