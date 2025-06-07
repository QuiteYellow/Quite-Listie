//
//  ItemView.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 25/05/2025.
//

import SwiftUI
import MarkdownUI

struct AddItemView: View {
    
    //let groupId: String?
    let list: ShoppingListSummary
    
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: ShoppingListViewModel
    
    @State private var itemName = ""
    @State private var selectedLabel: ShoppingLabel? = nil
    @State private var availableLabels: [ShoppingLabel] = []
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
                            
                            Divider()
                            
                            formRight
                                .frame(width: geometry.size.width * 0.6)
                        }
                    } else {
                        Form {
                            formLeftContent

                            
                            Section(header: Text("Preview")) {
                                formRightContent
                                    .padding(.top, 8)
                                    
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
                    let allLabels = try await CombinedShoppingListProvider.shared.fetchLabels(for: list)

                    // Extract hidden label IDs
                    let hiddenLabelIDs: Set<String> = {
                        if let hidden = list.extras?["hiddenLabels"] {
                            return Set(hidden.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                        } else {
                            return []
                        }
                    }()

                    // Filter by groupId and hide labels
                    if let groupId = list.groupId {
                        availableLabels = allLabels
                            .filter { $0.groupId == groupId && !hiddenLabelIDs.contains($0.id) }
                    } else {
                        availableLabels = allLabels
                            .filter { !hiddenLabelIDs.contains($0.id) }
                    }

                    // Sort
                    availableLabels.sort {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }

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
                                        ZStack {
                                            Color(.secondarySystemGroupedBackground)

                                            CustomTextEditor(text: $mdNotes)
                                                .padding(8)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                                .padding(15)
                                                .frame(minHeight: usableHeight)
                                        }
                                        
                                    }
                                    .background(.clear)
                                    .toolbarBackground(.ultraThinMaterial, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
                                    .toolbarBackground(.visible, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
                                    .frame(width: geometry.size.width * 0.4) // adjust width as needed

                                    Divider()
                                    
                                    // Right pane with Form and Section for preview
                                    VStack(alignment: .leading, spacing: 8) {
                                            
                                        ScrollView {
                                            Markdown(mdNotes)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.top, 4)
                                        }
                                        
                                        
                                    }
                                    .padding(15)
                                    .background(Color.clear)
                                    
                                    .frame(width: geometry.size.width * 0.6)
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
        .padding(20)
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
                        Text("No Label").tag(Optional<ShoppingLabel>(nil))
                        
                        ForEach(availableLabels, id: \.id) { label in
                            Text(label.name.removingLabelNumberPrefix())
                                .tag(Optional(label))
                        }
                    }
                }
            }
            
            Section(header: Text("Notes")) {
                Button("Edit Notes in Markdown") {
                    showMarkdownEditor = true
                }
            }
           
        }
    }

    private var formRightContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                if mdNotes.isEmpty {
                    Text("No notes")
                        .foregroundColor(.secondary)
                } else {
                    Markdown(mdNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                
            }
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
    let list: ShoppingListSummary
    //let groupId: String?

    @State private var itemName: String = ""
    @State private var selectedLabel: ShoppingLabel? = nil
    @State private var quantity: Int = 1
    @State private var mdNotes: String = ""
    @State private var availableLabels: [ShoppingLabel] = []
    @State private var isLoading = true
    @State private var showDeleteConfirmation = false
    @State private var showError = false
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
                            Divider()
                            
                            formRight
                                .frame(width: geometry.size.width * 0.6)
                        }
                    } else {
                        Form {
                            formLeftContent
                            Section(header: Text("Preview")) {
                                formRightContent
                                    .padding(.top, 8)
                                
                            }
                            
                        }
                    }
                }
                .navigationTitle("Edit Item")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .confirmationAction) {
                        if !list.isReadOnlyExample {
                            Button("Delete") {
                                showDeleteConfirmation = true
                            }
                            .foregroundColor(.red)
                            
                            Button("Save") {
                                Task {
                                    let updates = ["markdownNotes": mdNotes]
                                    let updatedExtras = item.updatedExtras(with: updates)
                                    
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
                                        ZStack {
                                            Color(.secondarySystemGroupedBackground)
                                            
                                            CustomTextEditor(text: $mdNotes)
                                                .padding(8)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                                .padding(15)
                                                .frame(minHeight: usableHeight)
                                        }
                                        
                                    }
                                    .background(.clear)
                                    .toolbarBackground(.ultraThinMaterial, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
                                    .toolbarBackground(.visible, for: .navigationBar) // forces the navigation bar blur to show, otherwise bug causes left view not to trigger it.
                                    .frame(width: geometry.size.width * 0.4) // adjust width as needed
                                    
                                    Divider()
                                    
                                    // Right pane with Form and Section for preview
                                    VStack(alignment: .leading, spacing: 8) {
                                        
                                        ScrollView {
                                            Markdown(mdNotes)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.top, 4)
                                        }
                                        
                                        
                                    }
                                    .padding(15)
                                    .background(Color.clear)
                                    
                                    .frame(width: geometry.size.width * 0.6)
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
                    let allLabels = try await CombinedShoppingListProvider.shared.fetchLabels(for: list)

                    //print("🧪 [EditItemView] allLabels.count: \(allLabels.count)")
                    //print("🧪 [EditItemView] First few labels:")
                    for label in allLabels.prefix(5) {
                        //print("→ \(label.name) | id: \(label.id) | group: \(label.groupId ?? "nil")")
                    }
                    // Extract hidden label IDs
                    let hiddenLabelIDs: Set<String> = {
                        if let hidden = list.extras?["hiddenLabels"] {
                            return Set(hidden.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                        } else {
                            return []
                        }
                    }()

                    // Filter by groupId and hide labels
                    if let groupId = list.groupId {
                        availableLabels = allLabels
                            .filter { $0.groupId == groupId && !hiddenLabelIDs.contains($0.id) }
                    } else {
                        availableLabels = allLabels
                            .filter { !hiddenLabelIDs.contains($0.id) }
                    }

                    // Sort
                    availableLabels.sort {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }

                    // Match selectedLabel to an instance from the visible list
                    if let originalLabel = item.label {
                        selectedLabel = availableLabels.first(where: { $0.id == originalLabel.id })
                    } else {
                        selectedLabel = nil
                    }

                } catch {
                    print("⚠️ Failed to fetch labels:", error)
                }
                
                isLoading = false
            }
        }
        .onAppear {
            // Initialize state values from item
            itemName = item.note
            selectedLabel = item.label
            quantity = Int(item.quantity ?? 1)
            mdNotes = item.markdownNotes
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
        .padding(20)
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
                        Text("No Label").tag(Optional<ShoppingLabel>(nil))
                        
                        ForEach(availableLabels, id: \.id) { label in
                            Text(label.name.removingLabelNumberPrefix())
                                .tag(Optional(label))
                        }
                    }
                }
            }
            
            Section(header: Text("Notes")) {
                Button("Edit Notes in Markdown") {
                    showMarkdownEditor = true
                }
            }
           
        }
    }

    private var formRightContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if mdNotes.isEmpty {
                    Text("No notes")
                        .foregroundColor(.secondary)
                } else {
                    Markdown(mdNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                
            }
            
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity)
    }
}

struct CustomTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear // Transparent background
        textView.isScrollEnabled = true
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.autocorrectionType = .yes
        textView.autocapitalizationType = .sentences
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CustomTextEditor

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}
