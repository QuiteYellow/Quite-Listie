//
//  MarkdownListImportView.swift
//  Listie-md
//
//  Created by Jack Nagy on 25/12/2025.
//


//
//  MarkdownListImportView.swift
//  Listie-md
//
//  View for importing markdown lists with preview
//

import SwiftUI

struct MarkdownListImportView: View {
    let list: UnifiedList
    let provider: UnifiedListProvider
    
    let initialMarkdown: String?
    let autoPreview: Bool

    
    @State private var existingItems: [ShoppingItem]
    @State private var existingLabels: [ShoppingLabel]
    
    
    @Environment(\.dismiss) var dismiss
    @State private var markdownText: String = ""
    @State private var showPreview = false
    @State private var parsedList: ParsedList?
    @State private var createUnmatchedLabels = true
    @State private var isSaving = false
    
    @State private var selectedItemIndices: Set<Int> = []
    
    
    init(
        list: UnifiedList,
        provider: UnifiedListProvider,
        existingItems: [ShoppingItem] = [],
        existingLabels: [ShoppingLabel] = [],
        initialMarkdown: String? = nil,
        autoPreview: Bool = false
    ) {
        self.list = list
        self.provider = provider
        self._existingItems = State(initialValue: existingItems)
        self._existingLabels = State(initialValue: existingLabels)
        self.initialMarkdown = initialMarkdown
        self.autoPreview = autoPreview
    }
    
    var body: some View {
        NavigationView {
            Group {
                if showPreview, let parsed = parsedList {
                    previewView(parsed)
                } else {
                    editorView
                }
            }
            .navigationTitle(showPreview ? "Preview Import" : "Paste Shopping List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .help("Cancel")
                }
                
                
                ToolbarItem(placement: .confirmationAction) {
                    if showPreview {
                        Button("Import") {
                            Task { await importItems() }
                        }
                        .disabled(isSaving)
                    } else {
                        Button("Preview") {
                            parseAndPreview()
                        }
                        .disabled(markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                
                
                if showPreview {
                    ToolbarItem(placement: .navigationBarLeading) {

                        Button {
                            showPreview = false
                                } label: {
                                    Image(systemName: "chevron.backward")
                                        .symbolRenderingMode(.hierarchical)
                                }
                                .help("Back")
                    }
                }
            }
            .onAppear {
                if let initial = initialMarkdown {
                    markdownText = initial
                    if autoPreview {
                        parseAndPreview()
                    }
                }
            }
            .task {
                print("🎬 [MarkdownImport] View task started")
                print("   List: \(list.summary.name)")
                print("   Initial items count: \(existingItems.count)")
                print("   Initial labels count: \(existingLabels.count)")
                print("   Has initial markdown: \(initialMarkdown != nil)")
                print("   Auto-preview: \(autoPreview)")
                
                // Load existing items and labels if needed (for deeplinks)
                if existingItems.isEmpty || existingLabels.isEmpty {
                    print("📦 [MarkdownImport] Loading existing data...")
                    do {
                        let items = try await provider.fetchItems(for: list)
                        let labels = try await provider.fetchLabels(for: list)
                        
                        print("   Loaded \(items.count) items, \(labels.count) labels")
                        
                        await MainActor.run {
                            self.existingItems = items
                            self.existingLabels = labels
                            print("   ✅ Updated state")
                        }
                    } catch {
                        print("   ❌ Failed to load existing data: \(error)")
                    }
                }
                
                // Apply initial markdown if provided
                if let initial = initialMarkdown {
                    print("📝 [MarkdownImport] Applying initial markdown (\(initial.count) chars)")
                    markdownText = initial
                    
                    if autoPreview {
                        print("   🔍 Auto-previewing...")
                        parseAndPreview()
                    }
                }
                
                print("✅ [MarkdownImport] Task complete")
            }
        }
    }
    
    // MARK: - Editor View
    
    private var editorView: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack {
                        Image(systemName: list.summary.icon ?? "list.bullet")
                            .foregroundColor(.secondary)
                        Text(list.summary.name)
                            .font(.headline)
                        Spacer()
                    }
                } header: {
                    Text("Importing to")
                }
                
                Section {
                    TextEditor(text: $markdownText)
                        .frame(minHeight: 200)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Paste Markdown List")
                } footer: {
                    Text("""
                    Paste a markdown shopping list. Format:
                    
                    # Label Name (or ##, ###, etc.)
                    - [ ] Item name
                    - [x] 2 Checked item
                      - Sub-item becomes note
                    """)
                    .font(.caption)
                }
                
                Section {
                    Text("""
                    **Headings** become labels
                    **List items** become shopping items
                    **Numbers** at the start become quantity
                    **Sub-items** become markdown notes
                    """)
                    .font(.callout)
                    .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Preview View
    
    private func previewView(_ parsed: ParsedList) -> some View {
        List {
            // Importing to section
            Section {
                HStack {
                    Image(systemName: list.summary.icon ?? "list.bullet")
                        .foregroundColor(.secondary)
                    Text(list.summary.name)
                        .font(.headline)
                    Spacer()
                }
            } header: {
                Text("Importing to")
            }
            
            // Options section
            Section {
                Toggle("Create New Labels for Unmatched", isOn: $createUnmatchedLabels)
                    .toggleStyle(.switch)
            } footer: {
                Text(createUnmatchedLabels ?
                     "Existing labels will be matched by name. New labels will be created for unmatched names." :
                     "Existing labels will be matched by name. Items with unmatched labels will have no label.")
                    .font(.caption)
            }
            
            // Summary section
            Section {
                let selectedItems = parsed.items.enumerated().filter { selectedItemIndices.contains($0.offset) }
                let stats = calculateMergeStats(for: selectedItems.map(\.element))
                
                Text("**\(selectedItems.count)** of **\(parsed.items.count)** items selected")
                    .font(.headline)
                
                if stats.newItems > 0 {
                    Label("\(stats.newItems) new items", systemImage: "plus.circle.fill")
                        .foregroundColor(.green)
                }
                
                if stats.updatedItems > 0 {
                    Label("\(stats.updatedItems) existing items will be updated", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundColor(.blue)
                }
                
                if stats.newLabels > 0 {
                    Label("\(stats.newLabels) new labels will be created", systemImage: "tag.fill")
                        .foregroundColor(.purple)
                }
                
                if stats.matchedLabels > 0 {
                    Label("\(stats.matchedLabels) labels matched to existing", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
                
                if stats.unmatchedLabels > 0 && !createUnmatchedLabels {
                    Label("\(stats.unmatchedLabels) items will have no label", systemImage: "tag.slash")
                        .foregroundColor(.orange)
                }
            } header: {
                Text("Summary")
            }
            
            // Items grouped by label (ShoppingListView style)
            let grouped = Dictionary(grouping: parsed.items.enumerated()) { (index, item) -> String in
                item.labelName ?? "No Label"
            }
            
            let sortedLabelNames = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            
            ForEach(sortedLabelNames, id: \.self) { labelName in
                let itemsInLabel = grouped[labelName] ?? []
                let selectedInLabel = itemsInLabel.filter { selectedItemIndices.contains($0.offset) }
                
                Section {
                    ForEach(itemsInLabel, id: \.offset) { index, item in
                        importItemRow(item: item, index: index, labelName: labelName)
                    }
                } header: {
                    importSectionHeader(
                        labelName: labelName,
                        totalCount: itemsInLabel.count,
                        selectedCount: selectedInLabel.count
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    // MARK: - Helper Functions
    
    private func parseAndPreview() {
        parsedList = MarkdownListParser.parse(markdownText, listTitle: list.summary.name)
        // Select all items by default
        selectedItemIndices = Set(0..<(parsedList?.items.count ?? 0))
        withAnimation {
            showPreview = true
        }
    }
    
    private struct MergeStats {
        let newItems: Int
        let updatedItems: Int
        let newLabels: Int
        let matchedLabels: Int
        let unmatchedLabels: Int
    }
    
    private func calculateMergeStats(for items: [ParsedListItem]) -> MergeStats {
        let existingItemNames = Set(existingItems.map { $0.note.lowercased() })
        
        var newItems = 0
        var updatedItems = 0
        
        for item in items {
            if existingItemNames.contains(item.note.lowercased()) {
                updatedItems += 1
            } else {
                newItems += 1
            }
        }
        
        // Calculate label stats based on selected items
        let labelNamesInSelection = Set(items.compactMap { $0.labelName })
        let existingLabelNames = Set(existingLabels.map { $0.name.lowercased() })
        
        var matchedLabels = 0
        var unmatchedLabels = 0
        
        for labelName in labelNamesInSelection {
            if existingLabelNames.contains(labelName.lowercased()) {
                matchedLabels += 1
            } else {
                unmatchedLabels += 1
            }
        }
        
        let newLabels = createUnmatchedLabels ? unmatchedLabels : 0
        
        return MergeStats(
            newItems: newItems,
            updatedItems: updatedItems,
            newLabels: newLabels,
            matchedLabels: matchedLabels,
            unmatchedLabels: unmatchedLabels
        )
    }
    
    private func labelColor(for labelName: String) -> Color {
        // Always try to match existing labels (case-insensitive)
        if let existing = existingLabels.first(where: { $0.name.lowercased() == labelName.lowercased() }) {
            return Color(hex: existing.color)
        }
        // Purple indicates it will be created (or no label if createUnmatchedLabels is off)
        return createUnmatchedLabels ? .purple : .secondary
    }

    
    @ViewBuilder
    private func importSectionHeader(labelName: String, totalCount: Int, selectedCount: Int) -> some View {
        HStack {
            Image(systemName: "tag.fill")
                .foregroundColor(labelColor(for: labelName).adjusted(forBackground: Color(.systemBackground)))
            
            Text(labelName)
                .foregroundColor(.primary)
            
            // Show label status indicator
            if labelName != "No Label" {
                let existingLabel = existingLabels.first(where: { $0.name.lowercased() == labelName.lowercased() })
                if existingLabel != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)
                } else if createUnmatchedLabels {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.purple)
                        .imageScale(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .imageScale(.small)
                }
            }
            
            Spacer()
            
            // Show selection count
            Text("\(selectedCount)/\(totalCount)")
                .foregroundColor(.secondary)
                .font(.subheadline)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func importItemRow(item: ParsedListItem, index: Int, labelName: String) -> some View {
        let isSelected = selectedItemIndices.contains(index)
        
        HStack(spacing: 12) {
            // Quantity indicator (like ShoppingListView)
            if item.quantity > 1 {
                Text(Int(item.quantity).formatted(.number.precision(.fractionLength(0))))
                    .font(.subheadline)
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .frame(minWidth: 12, alignment: .leading)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.note)
                    .font(.body)
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .strikethrough(!isSelected, color: .gray)
                
                // Show if this will update an existing item
                if let existing = existingItems.first(where: { $0.note.lowercased() == item.note.lowercased() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.blue)
                            .imageScale(.small)
                        
                        if existing.checked {
                                    Text("Quantity from \(Int(existing.quantity)) to \(Int(item.quantity))")
                                } else {
                                    let newQty = existing.quantity + item.quantity
                                    Text("Quantity from \(Int(existing.quantity)) to \(Int(newQty))")
                                }
                    }
                    .font(.caption2)
                    .foregroundColor(.blue)
                }
                
                // Show markdown notes if present
                if let notes = item.markdownNotes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 16)
                }
            }
            
            Spacer()
            
            // Selection toggle (like checkbox in ShoppingListView)
            Button(action: {
                if isSelected {
                    selectedItemIndices.remove(index)
                } else {
                    selectedItemIndices.insert(index)
                }
            }) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .gray)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .opacity(isSelected ? 1.0 : 0.5)
    }
    
    // MARK: - Import Logic
    
    private func importItems() async {
        guard let parsed = parsedList else { return }
        
        isSaving = true
        defer { isSaving = false }
        
        // Filter to only selected items
        let itemsToImport = parsed.items.enumerated()
            .filter { selectedItemIndices.contains($0.offset) }
            .map { $0.element }
        
        // Get unique label names from selected items
        let labelNamesInSelection = Set(itemsToImport.compactMap { $0.labelName })
        
        do {
            // Step 1: Create/match labels (only for selected items)
            var labelMap: [String: ShoppingLabel] = [:]
            
            for labelName in labelNamesInSelection {
                if let existing = existingLabels.first(where: { $0.name.lowercased() == labelName.lowercased() }) {
                    labelMap[labelName] = existing
                } else if createUnmatchedLabels {
                    let newLabel = ModelHelpers.createNewLabel(
                        name: labelName,
                        color: Color.random().toHex(),
                        existingLabels: existingLabels
                    )
                    try await provider.createLabel(newLabel, for: list)
                    labelMap[labelName] = newLabel
                }
            }
            
            // Step 2: Import selected items
            for parsedItem in itemsToImport {
                // [Rest of the import logic stays the same]
                if let existingItem = existingItems.first(where: {
                    $0.note.lowercased() == parsedItem.note.lowercased()
                }) {
                    var updated = existingItem
                    
                    if existingItem.checked {
                        updated.quantity = parsedItem.quantity
                    } else {
                        updated.quantity = existingItem.quantity + parsedItem.quantity
                    }
                    
                    updated.checked = false
                    updated.modifiedAt = Date()
                    
                    if let labelName = parsedItem.labelName,
                       let label = labelMap[labelName] {
                        updated.labelId = label.id
                    }
                    
                    if let notes = parsedItem.markdownNotes {
                        updated.markdownNotes = notes
                    }
                    
                    try await provider.updateItem(updated, in: list)
                } else {
                    let label = parsedItem.labelName.flatMap { labelMap[$0] }
                    
                    let newItem = ModelHelpers.createNewItem(
                        note: parsedItem.note,
                        quantity: parsedItem.quantity,
                        checked: parsedItem.checked,
                        labelId: label?.id,
                        markdownNotes: parsedItem.markdownNotes
                    )
                    
                    try await provider.addItem(newItem, to: list)
                }
            }
            
            dismiss()
        } catch {
            print("❌ Failed to import items: \(error)")
        }
    }
}

// MARK: - Preview

#Preview {
    MarkdownListImportView(
        list: UnifiedList(
            id: "test",
            source: .privateICloud("test"),
            summary: ShoppingListSummary(
                id: "test",
                name: "Test List",
                modifiedAt: Date()
            )
        ),
        provider: UnifiedListProvider(),
        existingItems: [],
        existingLabels: []
    )
}
