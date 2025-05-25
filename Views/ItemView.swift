//
//  ItemView.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 25/05/2025.
//

import SwiftUI

struct AddItemView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: ShoppingListViewModel
    @State private var itemName = ""

    var body: some View {
        NavigationView {
            Form {
                TextField("Item name", text: $itemName)
            }
            .navigationTitle("Add Item")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await viewModel.addItem(note: itemName)
                            dismiss()
                        }
                    }
                    .disabled(itemName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
