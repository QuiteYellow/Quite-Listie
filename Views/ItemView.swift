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
    @Binding var reminderEnabled: Bool
    @Binding var reminderDate: Date
    @Binding var repeatRule: ReminderRepeatRule?
    @Binding var repeatMode: ReminderRepeatMode

    let availableLabels: [ShoppingLabel]
    let isLoading: Bool

    /// Optional list context shown at the top of the form (icon, name, folder)
    var listIcon: String? = nil
    var listName: String? = nil
    var folderName: String? = nil
    
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
                    .controlSize(.large)
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
            .controlSize(.large)
            .buttonStyle(.glass)
            .padding(20)
        }
    }
    
    private var formLeftContent: some View {
        Section() {
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
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.25), value: quantity)
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

            HStack {
                Label("Reminder", systemImage: "bell")
                Spacer()
                Toggle("", isOn: $reminderEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if reminderEnabled {
                DatePicker(
                    "Date & Time",
                    selection: $reminderDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )

                RepeatRulePicker(rule: $repeatRule)

                if repeatRule != nil {
                    Picker("Mode", selection: $repeatMode) {
                        ForEach(ReminderRepeatMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            }

            if let name = listName {
                HStack(spacing: 6) {
                    
                    Spacer()
                    ItemFormChip(
                        icon: listIcon ?? "list.bullet",
                        text: name,
                        color: .accentColor
                    )
                    if let folder = folderName {
                        ItemFormChip(
                            icon: "folder",
                            text: folder,
                            color: .secondary
                        )
                    }
                }
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

// MARK: - Repeat Rule Picker

struct RepeatRulePicker: View {
    @Binding var rule: ReminderRepeatRule?

    // Internal state for custom mode
    @State private var selectedPresetIndex: Int = 0  // 0 = Never
    @State private var customUnit: ReminderRepeatUnit = .day
    @State private var customInterval: Int = 2
    @State private var isCustom: Bool = false
    @State private var didInitialize: Bool = false

    /// The picker options: Never, then presets, then Custom
    private static let presetLabels = ["Never"] + ReminderRepeatRule.presets.map(\.displayName) + ["Custom…"]

    var body: some View {
        Picker("Repeat", selection: $selectedPresetIndex) {
            ForEach(0..<Self.presetLabels.count, id: \.self) { index in
                Text(Self.presetLabels[index]).tag(index)
            }
        }
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            let idx = presetIndex(for: rule)
            selectedPresetIndex = idx
            if idx == Self.presetLabels.count - 1, let r = rule {
                isCustom = true
                customUnit = r.unit
                customInterval = r.interval
            }
        }
        .onChange(of: selectedPresetIndex) { _, newValue in
            applySelection(newValue)
        }

        if isCustom {
            HStack {
                Label("Every", systemImage: "arrow.trianglehead.2.clockwise")
                Spacer()
                Stepper(value: $customInterval, in: 1...365) {
                    Text("\(customInterval)")
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.25), value: customInterval)
                }
                .frame(maxWidth: 140)
            }
            .onChange(of: customInterval) { _, _ in
                updateCustomRule()
            }

            Picker("Unit", selection: $customUnit) {
                ForEach(ReminderRepeatUnit.allCases, id: \.self) { unit in
                    Text(customInterval == 1 ? unit.displayName : unit.pluralName).tag(unit)
                }
            }
            .onChange(of: customUnit) { _, _ in
                updateCustomRule()
            }
        }
    }

    private func applySelection(_ index: Int) {
        if index == 0 {
            rule = nil
            isCustom = false
        } else if index <= ReminderRepeatRule.presets.count {
            rule = ReminderRepeatRule.presets[index - 1]
            isCustom = false
        } else {
            isCustom = true
            updateCustomRule()
        }
    }

    private func updateCustomRule() {
        if customUnit == .weekdays {
            rule = ReminderRepeatRule(unit: .weekdays, interval: 1)
        } else {
            rule = ReminderRepeatRule(unit: customUnit, interval: customInterval)
        }
    }

    private func presetIndex(for rule: ReminderRepeatRule?) -> Int {
        guard let rule = rule else { return 0 }
        if let idx = ReminderRepeatRule.presets.firstIndex(of: rule) {
            return idx + 1
        }
        return Self.presetLabels.count - 1  // Custom
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
    @State private var reminderEnabled = false
    @State private var reminderDate = Date().addingTimeInterval(3600) // Default: 1 hour from now
    @State private var repeatRule: ReminderRepeatRule? = nil
    @State private var repeatMode: ReminderRepeatMode = .fixed

    var body: some View {
        NavigationView {
            ItemFormView(
                itemName: $itemName,
                quantity: $quantity,
                selectedLabel: $selectedLabel,
                checked: $checked,
                mdNotes: $mdNotes,
                showMarkdownEditor: $showMarkdownEditor,
                reminderEnabled: $reminderEnabled,
                reminderDate: $reminderDate,
                repeatRule: $repeatRule,
                repeatMode: $repeatMode,
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
                                markdownNotes: mdNotes.isEmpty ? nil : mdNotes,
                                reminderDate: reminderEnabled ? reminderDate : nil,
                                reminderRepeatRule: reminderEnabled ? repeatRule : nil,
                                reminderRepeatMode: reminderEnabled && repeatRule != nil ? repeatMode : nil
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

    private var editFolderName: String? {
        if case .external(let url) = unifiedList.source {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return nil
    }

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
    @State private var reminderEnabled = false
    @State private var reminderDate = Date().addingTimeInterval(3600)
    @State private var repeatRule: ReminderRepeatRule? = nil
    @State private var repeatMode: ReminderRepeatMode = .fixed

    var body: some View {
        NavigationView {
            ItemFormView(
                itemName: $itemName,
                quantity: $quantity,
                selectedLabel: $selectedLabel,
                checked: $checked,
                mdNotes: $mdNotes,
                showMarkdownEditor: $showMarkdownEditor,
                reminderEnabled: $reminderEnabled,
                reminderDate: $reminderDate,
                repeatRule: $repeatRule,
                repeatMode: $repeatMode,
                availableLabels: availableLabels,
                isLoading: isLoading,
                listIcon: list.icon,
                listName: list.name,
                folderName: editFolderName
            )
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    if !unifiedList.isReadOnly {
                        Button(role : .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                        .tint(.red)

                        Button(role : .close) {
                            Task {
                                let success = await viewModel.updateItem(
                                    item,
                                    note: itemName,
                                    labelId: selectedLabel?.id,
                                    quantity: Double(quantity),
                                    checked: checked,
                                    markdownNotes: mdNotes.isEmpty ? nil : mdNotes,
                                    reminderDate: reminderEnabled ? reminderDate : nil,
                                    reminderRepeatRule: reminderEnabled ? repeatRule : nil,
                                    reminderRepeatMode: reminderEnabled && repeatRule != nil ? repeatMode : nil
                                )
                                if success {
                                    dismiss()
                                } else {
                                    showError = true
                                }
                            }
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        .tint(.accentColor)
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
            if let date = item.reminderDate {
                reminderEnabled = true
                reminderDate = date
            }
            repeatRule = item.reminderRepeatRule
            repeatMode = item.reminderRepeatMode ?? .fixed
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
                        let _ = totalHeight - safeAreaTop - navigationBarHeight
                        
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
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(role : .close) { dismiss() }
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
#if targetEnvironment(macCatalyst)
                    .navigationTitle(selectedTab == 0 ? "Item Notes - Editing" : "Item Notes - Preview")
#else
                    .navigationTitle("Item Notes")
                    .navigationSubtitle(selectedTab == 0 ? "Currently Editing" : "Previewing as Markdown")
#endif
                    .navigationBarTitleDisplayMode(.inline)
                    
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                selectedTab = selectedTab == 0 ? 1 : 0
                            } label: {
                                Image(systemName: selectedTab == 0 ? "eye.slash" : "eye")
                            }
                            //.tint(selectedTab == 0 ? .primary.opacity(0.2) : .primary)
                        }
                        
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                        
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(role : .close) { dismiss() }
                        }
                        
                    }
                }
            }
        }
    }
}

// MARK: - Item Form Chip

private struct ItemFormChip: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .foregroundColor(color)
        .clipShape(Capsule())
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
        let _ = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        
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
