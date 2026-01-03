//
//  ItemView.swift (V2 - UPDATED)
//  Listie.md
//
//  Updated EditItemView to use V2 format with direct markdownNotes field
//

import SwiftUI
import MarkdownView

// MARK: - Shared Item Form View
struct ItemFormView: View {
    @Binding var itemName: String
    @Binding var quantity: Int
    @Binding var selectedLabel: ShoppingLabel?
    @Binding var checked: Bool
    @Binding var mdNotes: String
    @Binding var showMarkdownEditor: Bool
    
    let availableLabels: [ShoppingLabel]
    let isLoading: Bool
    
    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > 700
            
            if isWide {
                HStack(spacing: 0) {
                    formLeft
                        .frame(width: geometry.size.width * 0.4)
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 0) {
                        
                        formRight
                    }
                    .frame(width: geometry.size.width * 0.6)
                }
            } else {
                Form {
                    formLeftContent
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Markdown Notes")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 8)
                        
                        Divider()
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                        
                        formRightContent
                    }
                    .frame(minHeight: 200)
                    .listRowBackground(Color.clear)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        showMarkdownEditor = true
                    } label: {
                        Label("Edit Notes", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.glass)
                    .padding(20)
                }
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
        ZStack(alignment: .bottomTrailing) {
            formRightContent
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .frame(maxWidth: .infinity)
            
            Button {
                showMarkdownEditor = true
            } label: {
                Label("Edit Notes", systemImage: "square.and.pencil")
            }
            .buttonStyle(.glass)
            .padding(20)
        }
    }
    
    private var formLeftContent: some View {
        Section(header: Text("Details")) {
            HStack {
                Label("Name", systemImage: "textformat")
                Spacer()
                TextField("Item name", text: $itemName)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 200)
            }
            
            HStack {
                Label("Quantity:", systemImage: "number")
                Spacer()
                Stepper(value: $quantity, in: 1...100) {
                    Text("\(quantity)")
                }
            }
            
            HStack {
                Label("Label", systemImage: "tag")
                Spacer()
                if isLoading {
                    ProgressView()
                } else {
                    Picker("", selection: $selectedLabel) {
                        Text("No Label").tag(Optional<ShoppingLabel>(nil))
                        
                        ForEach(availableLabels, id: \.id) { label in
                            Text(label.name.removingLabelNumberPrefix())
                                .tag(Optional(label))
                        }
                    }
                    .labelsHidden()
                }
            }
            
            HStack {
                Label("Completed", systemImage: "checkmark.circle")
                Spacer()
                Toggle("", isOn: $checked)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
    
    private var formRightContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if mdNotes.isEmpty {
                    Text("Click \"Edit Notes\" to add a note, use Markdown for Sublists, links, images and more.")
                        .foregroundStyle(.placeholder)
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

struct AddItemView: View {
    let list: ShoppingListSummary
    
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: ShoppingListViewModel
    
    @State private var itemName = ""
    @State private var selectedLabel: ShoppingLabel? = nil
    @State private var availableLabels: [ShoppingLabel] = []
    @State private var checked: Bool = false
    @State private var isLoading = true
    @State private var quantity: Int = 1
    @State private var showError = false
    @State private var mdNotes = ""
    @State private var showMarkdownEditor = false

    var body: some View {
        NavigationView {
            ItemFormView(
                itemName: $itemName,
                quantity: $quantity,
                selectedLabel: $selectedLabel,
                checked: $checked,
                mdNotes: $mdNotes,
                showMarkdownEditor: $showMarkdownEditor,
                availableLabels: availableLabels,
                isLoading: isLoading
            )
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
                                checked: checked,
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
                    let hiddenLabelIDs = Set(list.hiddenLabels ?? [])
                    availableLabels = labels.filter { !hiddenLabelIDs.contains($0.id) }
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
    @State private var checked: Bool = false
    @State private var isLoading = true
    @State private var showDeleteConfirmation = false
    @State private var showError = false
    @State private var showMarkdownEditor = false

    var body: some View {
        NavigationView {
            ItemFormView(
                itemName: $itemName,
                quantity: $quantity,
                selectedLabel: $selectedLabel,
                checked: $checked,
                mdNotes: $mdNotes,
                showMarkdownEditor: $showMarkdownEditor,
                availableLabels: availableLabels,
                isLoading: isLoading
            )
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
                                let success = await viewModel.updateItem(
                                    item,
                                    note: itemName,
                                    labelId: selectedLabel?.id,
                                    quantity: Double(quantity),
                                    checked: checked,
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
            .fullScreenCover(isPresented: $showMarkdownEditor) {
                MarkdownEditorView(text: $mdNotes)
            }
            .task {
                do {
                    let labels = try await viewModel.provider.fetchLabels(for: viewModel.list)
                    let hiddenLabelIDs = Set(list.hiddenLabels ?? [])
                    availableLabels = labels.filter { !hiddenLabelIDs.contains($0.id) }
                    availableLabels.sort {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
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
            itemName = item.note
            quantity = Int(item.quantity)
            mdNotes = item.markdownNotes ?? ""
            checked = item.checked
        }
    }
}

// MARK: - Markdown Editor View (Extracted for reuse)

struct MarkdownEditorView: View {
    @Binding var text: String
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab = 0
    @FocusState private var isTextEditorFocused: Bool
    
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
                                    
              
                                    TextEditor(text: $text)
                                    .padding()
                                    .focused($isTextEditorFocused)
                                        .onAppear {
                                            isTextEditorFocused = true
                                        }
                                    
                                    
                                    /*
                                    CustomTextEditor(text: $text)
                                        .padding(8)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .padding(15)
                                        .frame(minHeight: usableHeight)*/
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
                            
                        }
                    }
                }
                .navigationViewStyle(StackNavigationViewStyle())
            } else {
                NavigationView {
                    VStack(spacing: 0) {
                        // Content area
                        Group {
                            if selectedTab == 0 {
                                // Edit view
                                TextEditor(text: $text)
                                .padding()
                                .focused($isTextEditorFocused)
                                    .onAppear {
                                        isTextEditorFocused = true
                                    }
                                
                                //CustomTextEditor(text: $text)
                                  //  .frame(maxWidth: .infinity, alignment: .leading)
                                    //.padding()
                                    //.background(Color(.secondarySystemGroupedBackground))
                            } else {
                                // Preview view
                                ScrollView {
                                    MarkdownView(text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding()
                                }
                                .background(Color(.systemGroupedBackground))
                            }
                        }
                        //.ignoresSafeArea(edges: .top)
                    }
                    .navigationTitle("Item Notes")
                    .navigationBarTitleDisplayMode(.inline)
                    
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                selectedTab = selectedTab == 0 ? 1 : 0
                            } label: {
                                Image(systemName: selectedTab == 0 ? "eye" : "pencil")
                            }
                        }
                        
                        ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
                        
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                        
                    }
                }
            }
        }
    }
}

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
