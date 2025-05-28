//
//  ItemView.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 25/05/2025.
//

import SwiftUI
import MarkdownUI

struct AddItemView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: ShoppingListViewModel
    
    @State private var itemName = ""
    @State private var selectedLabel: ShoppingItem.LabelWrapper?
    @State private var availableLabels: [ShoppingItem.LabelWrapper] = []
    @State private var isLoading = true
    @State private var quantity: Int = 1
    @State private var showError = false
    
    @State private var mdNotes = ""
    @State private var showMarkdownEditor = false

    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                let isWide = geometry.size.width > 700
                
                Group {
                    if isWide {
                        HStack(spacing: 0) {
                            formLeft
                                .frame(width: geometry.size.width * 0.4)
                            
                            
                            formRight
                                .frame(width: geometry.size.width * 0.58)
                        }
                    } else {
                        Form {
                            formLeftContent
                            Divider()
                            
                            formRightContent
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
                            let success = await viewModel.addItem(
                                note: itemName,
                                label: selectedLabel,
                                quantity: Double(quantity),
                                markdownNotes: mdNotes.isEmpty ? nil : mdNotes
                            )
                            if success {
                                dismiss()
                            } else {
                                showError = true
                            }
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
            .alert("Failed to Add Item", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please check your internet connection or try again.")
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
            .fullScreenCover(isPresented: $showMarkdownEditor) {
                GeometryReader { geometry in
                    let isWide = geometry.size.width > 700

                    if isWide {
                        NavigationView {
                            GeometryReader { geometry in
                                let totalHeight = geometry.size.height
                                    let safeAreaTop = geometry.safeAreaInsets.top
                                    let navigationBarHeight: CGFloat = 44 // typical nav bar height
                                    
                                    let usableHeight = totalHeight - safeAreaTop - navigationBarHeight
                                HStack(spacing: 0) {
                                    // Left pane with Form and Section

                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("Editor")
                                                .font(.headline)
                                                .padding(.top, 5)
                                            Divider()
                                            TextEditor(text: $mdNotes)
                                                .frame(minHeight: usableHeight * 1)
                                                .autocapitalization(.sentences)
                                                .disableAutocorrection(false)
                                                .toolbar {
                                                    ToolbarItemGroup(placement: .keyboard) {
                                                        Button("**Bold**") { mdNotes += "**bold text**" }
                                                        Button("_Italic_") { mdNotes += "_italic text_" }
                                                        Button("Link") { mdNotes += "[text](LINK)" }
                                                        Button("Image") { mdNotes += "![altText](LINK)" }
                                                    }
                                                }
                                               
                                        } .padding(15)

                                    .background(.clear)
                                    .toolbarBackground(.ultraThinMaterial, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
                                    .toolbarBackground(.visible, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
                                    .frame(width: geometry.size.width * 0.4) // adjust width as needed

                                    Divider()
                                    
                                    // Right pane with Form and Section for preview
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("Preview")
                                                .font(.headline)
                                                .padding(.top, 5)
                                            Divider()
                                            Markdown(mdNotes)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.top, 4)
                                        }
                                        .padding(15)
                                    }
                                    .background(Color.clear)
                                    .frame(width: geometry.size.width * 0.58)
                                }
                                .navigationTitle("Edit Notes")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Done") {
                                            showMarkdownEditor = false
                                        }
                                    }
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Cancel") {
                                            showMarkdownEditor = false
                                        }
                                    }
                                }
                            }
                        }
                        // To prevent sidebar behavior, force navigationViewStyle to stack
                        .navigationViewStyle(StackNavigationViewStyle())
                    } else {
                        GeometryReader { _ in
                            NavigationView {
                                Form {
                                    Section(header: Text("Edit Markdown Notes")) {
                                        TextEditor(text: $mdNotes)
                                            .frame(minHeight: 400)
                                            .autocapitalization(.sentences)
                                            .disableAutocorrection(false)
                                            .toolbar {
                                                ToolbarItemGroup(placement: .keyboard) {
                                                    Button("**Bold**") { mdNotes += "**bold text**" }
                                                    Button("_Italic_") { mdNotes += "_italic text_" }
                                                    Button("Link") { mdNotes += "[text](LINK)" }
                                                    Button("Image") { mdNotes += "![altText](LINK)" }
                                                }
                                            }
                                    }
                                    Divider()

                                    Section(header: Text("Preview")) {
                                        ScrollView {
                                            Markdown(mdNotes).padding(.vertical)
                                        }
                                    }
                                }
                                .navigationTitle("Edit Notes")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Done") {
                                            showMarkdownEditor = false
                                        }
                                    }
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Cancel") {
                                            showMarkdownEditor = false
                                        }
                                    }
                                }
                            }
                            .navigationViewStyle(StackNavigationViewStyle())
                        }
                    }
                }
            }
        }
    }
    
    private var formLeft: some View {
        Form {
            formLeftContent
        }
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
        .toolbarBackground(.visible, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
        .frame(maxWidth: .infinity)
    }

    private var formRight: some View {

            formRightContent

        .frame(maxWidth: .infinity)
    }

    private var formLeftContent: some View {
        Group {
            Section(header: Text("Name")) {
                TextField("Item name", text: $itemName)
            }

            Section(header: Text("Quantity")) {
                Stepper(value: $quantity, in: 1...100) {
                    Text("\(quantity)")
                }
            }

            Section(header: Text("Label")) {
                if isLoading {
                    ProgressView("Loading Labels...")
                } else {
                    Picker("Label", selection: $selectedLabel) {
                        Text("No Label").tag(Optional<ShoppingItem.LabelWrapper>(nil))
                        ForEach(availableLabels, id: \.id) { label in
                            Text(label.name.removingLabelNumberPrefix()).tag(Optional(label))
                        }
                    }
                }
            }
            
           
        }
    }

    private var formRightContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Edit Notes") {
                    showMarkdownEditor = true
                }
                .buttonStyle(.borderedProminent)
                Divider()
                if mdNotes.isEmpty {
                    Text("No notes")
                        .foregroundColor(.secondary)
                } else {
                    Markdown(mdNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity)
    }
}

import SwiftUI

struct EditItemView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: ShoppingListViewModel

    let item: ShoppingItem

    @State private var itemName: String
    @State private var selectedLabel: ShoppingItem.LabelWrapper?
    @State private var quantity: Int
    @State private var mdNotes: String
    @State private var availableLabels: [ShoppingItem.LabelWrapper] = []
    @State private var isLoading = true
    @State private var showDeleteConfirmation = false
    @State private var showError = false
    @State private var showMarkdownEditor = false

    init(viewModel: ShoppingListViewModel, item: ShoppingItem) {
        self.viewModel = viewModel
        self.item = item
        _itemName = State(initialValue: item.note)
        _selectedLabel = State(initialValue: item.label)
        _quantity = State(initialValue: Int(item.quantity ?? 1))
        _mdNotes = State(initialValue: item.extras?["markdownNotes"] ?? "")
    }
    
    

    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                let isWide = geometry.size.width > 700

                Group {
                    if isWide {
                        HStack(spacing: 0) {
                            formLeft
                                .frame(width: geometry.size.width * 0.4)


                            formRight
                                .frame(width: geometry.size.width * 0.58)
                        }
                    } else {
                        Form {
                            formLeftContent
                            Divider()
            
                            formRightContent
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
                                var updatedExtras = item.extras ?? [:]
                                updatedExtras["markdownNotes"] = mdNotes
                                let success = await viewModel.updateItem(
                                    item,
                                    note: itemName,
                                    label: selectedLabel,
                                    quantity: Double(quantity),
                                    extras: updatedExtras
                                )
                                if success {
                                    dismiss()
                                } else {
                                    showError = true
                                }
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
            .fullScreenCover(isPresented: $showMarkdownEditor) {
                GeometryReader { geometry in
                    let isWide = geometry.size.width > 700

                    if isWide {
                        NavigationView {
                            GeometryReader { geometry in
                                let totalHeight = geometry.size.height
                                    let safeAreaTop = geometry.safeAreaInsets.top
                                    let navigationBarHeight: CGFloat = 44 // typical nav bar height
                                    
                                    let usableHeight = totalHeight - safeAreaTop - navigationBarHeight
                                HStack(spacing: 0) {
                                    // Left pane with Form and Section

                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("Editor")
                                                .font(.headline)
                                                .padding(.top, 5)
                                            Divider()
                                            TextEditor(text: $mdNotes)
                                                .frame(minHeight: usableHeight * 1)
                                                .autocapitalization(.sentences)
                                                .disableAutocorrection(false)
                                                .toolbar {
                                                    ToolbarItemGroup(placement: .keyboard) {
                                                        Button("**Bold**") { mdNotes += "**bold text**" }
                                                        Button("_Italic_") { mdNotes += "_italic text_" }
                                                        Button("Link") { mdNotes += "[text](LINK)" }
                                                        Button("Image") { mdNotes += "![altText](LINK)" }
                                                    }
                                                }
                                               
                                        } .padding(15)

                                    .background(.clear)
                                    .toolbarBackground(.ultraThinMaterial, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
                                    .toolbarBackground(.visible, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
                                    .frame(width: geometry.size.width * 0.4) // adjust width as needed

                                    Divider()
                                    
                                    // Right pane with Form and Section for preview
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("Preview")
                                                .font(.headline)
                                                .padding(.top, 5)
                                            Divider()
                                            Markdown(mdNotes)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.top, 4)
                                        }
                                        .padding(15)
                                    }
                                    .background(Color.clear)
                                    .frame(width: geometry.size.width * 0.58)
                                }
                                .navigationTitle("Edit Notes")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Done") {
                                            showMarkdownEditor = false
                                        }
                                    }
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Cancel") {
                                            showMarkdownEditor = false
                                        }
                                    }
                                }
                            }
                        }
                        // To prevent sidebar behavior, force navigationViewStyle to stack
                        .navigationViewStyle(StackNavigationViewStyle())
                    } else {
                        GeometryReader { _ in
                            NavigationView {
                                Form {
                                    Section(header: Text("Edit Markdown Notes")) {
                                        TextEditor(text: $mdNotes)
                                            .frame(minHeight: 400)
                                            .autocapitalization(.sentences)
                                            .disableAutocorrection(false)
                                            .toolbar {
                                                ToolbarItemGroup(placement: .keyboard) {
                                                    Button("**Bold**") { mdNotes += "**bold text**" }
                                                    Button("_Italic_") { mdNotes += "_italic text_" }
                                                    Button("Link") { mdNotes += "[text](LINK)" }
                                                    Button("Image") { mdNotes += "![altText](LINK)" }
                                                }
                                            }
                                    }
                                    Divider()

                                    Section(header: Text("Preview")) {
                                        ScrollView {
                                            Markdown(mdNotes).padding(.vertical)
                                        }
                                    }
                                }
                                .navigationTitle("Edit Notes")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Done") {
                                            showMarkdownEditor = false
                                        }
                                    }
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Cancel") {
                                            showMarkdownEditor = false
                                        }
                                    }
                                }
                            }
                            .navigationViewStyle(StackNavigationViewStyle())
                        }
                    }
                }
            }
            .alert("Delete Item?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    Task {
                        let success = await viewModel.deleteItem(item)
                        if success {
                            dismiss()
                        } else {
                            showError = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Failed to Save Changes", isPresented: $showError) {
                Button("OK", role: .cancel) {}
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

    // MARK: - Forms and Content

    private var formLeft: some View {
        Form {
            formLeftContent
        }
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
        .toolbarBackground(.visible, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
        .frame(maxWidth: .infinity)
    }

    private var formRight: some View {

            formRightContent

        .frame(maxWidth: .infinity)
    }

    private var formLeftContent: some View {
        Group {
            Section(header: Text("Name")) {
                TextField("Item name", text: $itemName)
            }

            Section(header: Text("Quantity")) {
                Stepper(value: $quantity, in: 1...100) {
                    Text("\(quantity)")
                }
            }

            Section(header: Text("Label")) {
                if isLoading {
                    ProgressView("Loading Labels...")
                } else {
                    Picker("Label", selection: $selectedLabel) {
                        Text("No Label").tag(Optional<ShoppingItem.LabelWrapper>(nil))
                        ForEach(availableLabels, id: \.id) { label in
                            Text(label.name.removingLabelNumberPrefix()).tag(Optional(label))
                        }
                    }
                }
            }
            
           
        }
    }

    private var formRightContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Edit Notes") {
                    showMarkdownEditor = true
                }
                .buttonStyle(.borderedProminent)
                Divider()
                if mdNotes.isEmpty {
                    Text("No notes")
                        .foregroundColor(.secondary)
                } else {
                    Markdown(mdNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity)
    }
}
