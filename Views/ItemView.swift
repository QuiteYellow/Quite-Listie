//
//  ItemView.swift (V2 - UPDATED)
//  Listie.md
//
//  Updated EditItemView to use V2 format with direct markdownNotes field
//

import SwiftUI
import MarkdownView

struct AddItemView: View {
    
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
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .help("Cancel")
                }
            }
            .alert("Failed to Add Item", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please check your internet connection or try again.")
            }
            .fullScreenCover(isPresented: $showMarkdownEditor) {
                MarkdownEditorView(text: $mdNotes)
            }
            .task {
                do {
                    let labels = try await viewModel.provider.fetchLabels(for: viewModel.list)
                    
                    // Extract hidden label IDs
                    let hiddenLabelIDs = Set(list.hiddenLabels ?? [])

                    // Filter out hidden labels
                    availableLabels = labels.filter { !hiddenLabelIDs.contains($0.id) }
                    
                    // Sort
                    availableLabels.sort {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                } catch {
                    print("⚠️ Failed to fetch labels:", error)
                }
                
                isLoading = false
            }
        }
    }
    
    private var formLeft: some View {
        Form {
            formLeftContent
        }
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
                    MarkdownView(mdNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Edit Item View

struct EditItemView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: ShoppingListViewModel

    let item: ShoppingItem
    let list: ShoppingListSummary
    let unifiedList: UnifiedList

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
                        if !unifiedList.isReadOnly {
                            Button("Delete") {
                                showDeleteConfirmation = true
                            }
                            .foregroundColor(.red)
                            
                            Button("Save") {
                                Task {
                                    // V2: Pass markdownNotes directly, no extras manipulation
                                    let success = await viewModel.updateItem(
                                        item,
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
                    }
                    
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .symbolRenderingMode(.hierarchical)
                        }
                        .help("Cancel")
                    }
                }
            }
            .fullScreenCover(isPresented: $showMarkdownEditor) {
                MarkdownEditorView(text: $mdNotes)
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
                    let labels = try await viewModel.provider.fetchLabels(for: viewModel.list)
                    
                    // Extract hidden label IDs - handle both V2 (array) and V1 (string)
                    let hiddenLabelIDs = Set(list.hiddenLabels ?? [])

                    
                    // Filter out hidden labels
                    availableLabels = labels.filter { !hiddenLabelIDs.contains($0.id) }
                    
                    // Sort
                    availableLabels.sort {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    
                    // Match selectedLabel
                    if let labelId = item.labelId {
                        selectedLabel = availableLabels.first(where: { $0.id == labelId })
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
            quantity = Int(item.quantity)
            
            // Read markdown notes - V2 (direct field) or V1 (extras)
            mdNotes = item.markdownNotes ?? ""
            
            // Selected label will be set in .task after labels load
        }
    }

    // MARK: - Forms and Content

    private var formLeft: some View {
        Form {
            formLeftContent
        }
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
                    MarkdownView(mdNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Markdown Editor View (Extracted for reuse)

struct MarkdownEditorView: View {
    @Binding var text: String
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > 700
            
            if isWide {
                NavigationView {
                    GeometryReader { geometry in
                        let totalHeight = geometry.size.height
                        let safeAreaTop = geometry.safeAreaInsets.top
                        let navigationBarHeight: CGFloat = 44
                        let usableHeight = totalHeight - safeAreaTop - navigationBarHeight
                        
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    Color(.secondarySystemGroupedBackground)
                                    
                                    CustomTextEditor(text: $text)
                                        .padding(8)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .padding(15)
                                        .frame(minHeight: usableHeight)
                                }
                            }
                            .background(.clear)
                            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                            .toolbarBackground(.visible, for: .navigationBar)
                            .frame(width: geometry.size.width * 0.4)
                            
                            Divider()
                            
                            VStack(alignment: .leading, spacing: 8) {
                                ScrollView {
                                    MarkdownView(text)
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
                                Button("Done") { dismiss() }
                            }
                            ToolbarItem(placement: .cancellationAction) {
                                Button {
                                    dismiss()
                                } label: {
                                    Image(systemName: "xmark")
                                        .symbolRenderingMode(.hierarchical)
                                }
                                .help("Cancel")
                            }
                        }
                    }
                }
                .navigationViewStyle(StackNavigationViewStyle())
            } else {
                NavigationView {
                    Form {
                        Section(header: Text("Edit Markdown Notes")) {
                            CustomTextEditor(text: $text)
                                .padding(8)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .padding(15)
                                .frame(minHeight: 300)
                        }
                        
                        Section(header: Text("Preview")) {
                            ScrollView {
                                MarkdownView(text).padding(.vertical)
                            }
                        }
                    }
                    .navigationTitle("Edit Notes")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .help("Cancel")
                        }
                    }
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        }
    }
}

// MARK: - Custom Text Editor

// MARK: - Custom Text Editor

struct CustomTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.autocorrectionType = .yes
        textView.autocapitalizationType = .sentences
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Create pure UIKit toolbar
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.backgroundColor = UIColor.systemGroupedBackground
        
        let snippets = ["**bold**", "*italic*", "[Link](URL)", "![Image](URL)", "`code`", "- item", "> quote"]
        
        var items: [UIBarButtonItem] = []
        for snippet in snippets {
            let button = UIBarButtonItem(title: snippet, style: .plain, target: context.coordinator, action: #selector(Coordinator.insertSnippet(_:)))
            button.accessibilityLabel = snippet
            items.append(button)
        }
        
        // Add flexible space to push items together nicely
        let flexSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        
        // Intersperse buttons with small fixed spaces
        var finalItems: [UIBarButtonItem] = []
        for (index, item) in items.enumerated() {
            finalItems.append(item)
            if index < items.count - 1 {
                let fixedSpace = UIBarButtonItem(barButtonSystemItem: .fixedSpace, target: nil, action: nil)
                fixedSpace.width = 8
                finalItems.append(fixedSpace)
            }
        }
        
        toolbar.items = finalItems
        textView.inputAccessoryView = toolbar
        
        context.coordinator.textView = textView

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CustomTextEditor
        weak var textView: UITextView?

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
        
        @objc func insertSnippet(_ sender: UIBarButtonItem) {
            guard let textView = textView,
                  let snippet = sender.accessibilityLabel,
                  let range = textView.selectedTextRange else { return }
            
            textView.replace(range, withText: snippet)
        }
    }
}
