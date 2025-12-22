//
//  LabelManagerViewModel.swift (V2 - SIMPLIFIED)
//  ListsForMealie
//
//  Updated to use V2 format with simple label IDs
//

import Foundation
import SwiftUI

@MainActor
class LabelManagerViewModel: ObservableObject {
    @Published var allLabels: [ShoppingLabel] = []
    
    func loadLabels() async {
        do {
            let labels = try await LocalOnlyProvider.shared.fetchAllLabels()
            
            await MainActor.run {
                withAnimation {
                    allLabels = labels
                }
            }
        } catch {
            print("❌ Failed to load labels: \(error)")
        }
    }
    
    func createLabel(name: String, color: String, for listId: String) async {
        // Fetch existing labels for this list to ensure unique IDs
        let existingLabels: [ShoppingLabel]
        do {
            // Get the list to fetch its labels
            let lists = try await LocalOnlyProvider.shared.fetchShoppingLists()
            if let list = lists.first(where: { $0.id == listId || $0.cleanId == listId }) {
                existingLabels = try await LocalOnlyProvider.shared.fetchLabels(for: list)
            } else {
                existingLabels = []
            }
        } catch {
            existingLabels = []
        }
        
        // Use ModelHelpers to create a label with a simple, unique ID
        let newLabel = ModelHelpers.createNewLabel(
            name: name,
            color: color,
            existingLabels: existingLabels
        )
        
        // Note: The label needs to know which list it belongs to
        // We'll need to update the storage layer to associate it properly
        var labelWithListId = newLabel
        // Store the list ID in legacy field for compatibility
        labelWithListId.listId = listId
        
        do {
            try await LocalOnlyProvider.shared.createLabel(labelWithListId)
            await loadLabels()
        } catch {
            print("❌ Failed to create label: \(error)")
        }
    }
    
    func updateLabel(_ label: ShoppingLabel) async {
        do {
            try await LocalOnlyProvider.shared.updateLabel(label)
            await loadLabels()
        } catch {
            print("❌ Failed to update label: \(error)")
        }
    }
    
    func deleteLabel(_ label: ShoppingLabel) async {
        do {
            try await LocalOnlyProvider.shared.deleteLabel(label)
            await loadLabels()
        } catch {
            print("❌ Could not delete label: \(error)")
        }
    }
}
