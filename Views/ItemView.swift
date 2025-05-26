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
    @State private var selectedLabel: ShoppingItem.LabelWrapper?
    @State private var availableLabels: [ShoppingItem.LabelWrapper] = []
    @State private var isLoading = true
    
    @State private var quantity: Int = 1

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Name")) {
                    TextField("Item name", text: $itemName)
                }
                Section(header: Text("Quantity")) {
                    Stepper(value: $quantity, in: 1...100, step: 1) {
                        Text("\(quantity)")
                    }
                }
                Section(header: Text("Label")) {
                    if isLoading {
                        ProgressView("Loading Labels...")
                    } else {
                        Picker("Label", selection: $selectedLabel) {
                            Text("None").tag(Optional<ShoppingItem.LabelWrapper>(nil))
                            ForEach(availableLabels, id: \.id) { label in
                                Text(label.name.removingLabelNumberPrefix()).tag(Optional(label))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            // Make sure your addItem function supports quantity
                            await viewModel.addItem(note: itemName, label: selectedLabel, quantity: Double(quantity))
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
            .task {
                do {
                    availableLabels = try await ShoppingListAPI.shared.fetchShoppingLabels()
                    availableLabels.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                } catch {
                    print("⚠️ Failed to fetch labels:", error)
                }
                isLoading = false
            }
        }
    }
}

struct EditItemView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: ShoppingListViewModel
    
    @State private var itemName: String
    @State private var selectedLabel: ShoppingItem.LabelWrapper?
    @State private var availableLabels: [ShoppingItem.LabelWrapper] = []
    @State private var isLoading = true
    @State private var quantity: Int = 1
    
    @State private var showDeleteConfirmation = false
    
    let item: ShoppingItem
    
    init(viewModel: ShoppingListViewModel, item: ShoppingItem) {
        self.viewModel = viewModel
        self.item = item
        _itemName = State(initialValue: item.note)
        _selectedLabel = State(initialValue: item.label)
        _quantity = State(initialValue: Int(item.quantity ?? 1))
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Name")) {
                    TextField("Item name", text: $itemName)
                }
                Section(header: Text("Quantity")) {
                    Stepper(value: $quantity, in: 1...100, step: 1) {
                        Text("\(quantity)")
                    }
                }
                Section(header: Text("Label")) {
                    if isLoading {
                        ProgressView("Loading Labels...")
                    } else {
                        Picker("", selection: $selectedLabel) {
                            Text("None").tag(Optional<ShoppingItem.LabelWrapper>(nil))
                            ForEach(availableLabels, id: \.id) { label in
                                Text(label.name.removingLabelNumberPrefix()).tag(Optional(label))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Delete") {
                        showDeleteConfirmation = true
                    }
                    .foregroundColor(.red)
                    
                    Button("Save") {
                        Task {
                            await viewModel.updateItem(item, note: itemName, label: selectedLabel, quantity: Double(quantity))
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
            .alert("Delete Item?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.deleteItem(item)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this item?")
            }
            .task {
                do {
                    availableLabels = try await ShoppingListAPI.shared.fetchShoppingLabels()
                    availableLabels.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                } catch {
                    print("⚠️ Failed to fetch labels:", error)
                }
                isLoading = false
            }
        }
    }
}
