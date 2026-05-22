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

import os
import SwiftUI

struct MarkdownListImportView: View {
    let list: UnifiedList
    let provider: UnifiedListProvider
    
    let initialMarkdown: String?
    let autoPreview: Bool

    
    @State private var existingItems: [ListItem]
    @State private var existingLabels: [ListLabel]
    
    
    @Environment(\.dismiss) var dismiss
    @State private var markdownText: String = ""
    @State private var showPreview = false
    @State private var parsedList: ParsedList?
    @State private var createUnmatchedLabels = true
    @State private var replaceQuantities: Bool
    @State private var isSaving = false
    
    @State private var selectedItemIndices: Set<Int> = []
    
    
    /// When invoked from a preset reload, the original items that built the markdown.
    /// Used to resolve UUID-first matching: a parsed item's name is looked up here to
    /// recover the originating UUID, then the live list is queried by that UUID. Falls
    /// back to name-only matching when nil or when the lookup misses.
    let expectedItems: [ListItem]?

    /// Why this view is being shown. Drives every visible string and the primary
    /// action's label so a preset reload doesn't read as a foreign-import flow.
    enum Intent: Equatable {
        case `import`                    // paste markdown / open deeplink
        case reloadPreset(name: String)  // reload a saved preset from this list

        var isReload: Bool {
            if case .reloadPreset = self { return true }
            return false
        }
    }

    let intent: Intent

    init(
        list: UnifiedList,
        provider: UnifiedListProvider,
        existingItems: [ListItem] = [],
        existingLabels: [ListLabel] = [],
        initialMarkdown: String? = nil,
        autoPreview: Bool = false,
        expectedItems: [ListItem]? = nil,
        replaceQuantitiesDefault: Bool = false,
        intent: Intent = .import
    ) {
        self.list = list
        self.provider = provider
        self._existingItems = State(initialValue: existingItems)
        self._existingLabels = State(initialValue: existingLabels)
        self.initialMarkdown = initialMarkdown
        self.autoPreview = autoPreview
        self.expectedItems = expectedItems
        self._replaceQuantities = State(initialValue: replaceQuantitiesDefault)
        self.intent = intent
    }

    // MARK: - Intent-aware copy

    private var navigationTitleText: String {
        switch intent {
        case .import:
            return showPreview ? "Preview Import" : "Paste Shopping List"
        case .reloadPreset(let name):
            return "Reload \u{201C}\(name)\u{201D}"
        }
    }

    private var confirmActionTitle: String {
        if case .reloadPreset = intent {
            return "Reload \(selectedItemIndices.count) item\(selectedItemIndices.count == 1 ? "" : "s")"
        }
        return "Import"
    }

    private var importingToHeader: String {
        intent.isReload ? "Reloading on" : "Importing to"
    }

    private var unmatchedLabelToggleTitle: String {
        intent.isReload ? "Re-create deleted labels" : "Create New Labels for Unmatched"
    }

    private var newItemsStatLabel: (Int) -> String {
        { count in
            self.intent.isReload
                ? "\(count) item\(count == 1 ? "" : "s") new to this list (will be added)"
                : "\(count) new items"
        }
    }

    private var updatedItemsStatLabel: (Int) -> String {
        { count in
            self.intent.isReload
                ? "\(count) item\(count == 1 ? "" : "s") will be re-activated"
                : "\(count) existing items will be updated"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if showPreview, let parsed = parsedList {
                    previewView(parsed)
                } else {
                    editorView
                }
            }
            .navigationTitle(navigationTitleText)
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
                        Button(confirmActionTitle) {
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
                AppLogger.markdown.debug("View task started for list: \(list.summary.name, privacy: .public), items: \(existingItems.count, privacy: .public), labels: \(existingLabels.count, privacy: .public)")

                // Load existing items and labels if needed (for deeplinks)
                if existingItems.isEmpty || existingLabels.isEmpty {
                    AppLogger.markdown.debug("Loading existing data...")
                    do {
                        let items = try await provider.fetchItems(for: list)
                        let labels = try await provider.fetchLabels(for: list)

                        AppLogger.markdown.debug("Loaded \(items.count, privacy: .public) items, \(labels.count, privacy: .public) labels")

                        await MainActor.run {
                            self.existingItems = items
                            self.existingLabels = labels
                        }
                    } catch {
                        AppLogger.markdown.error("Failed to load existing data: \(error, privacy: .public)")
                    }
                }

                // Apply initial markdown if provided
                if let initial = initialMarkdown {
                    AppLogger.markdown.debug("Applying initial markdown (\(initial.count, privacy: .public) chars)")
                    markdownText = initial

                    if autoPreview {
                        parseAndPreview()
                    }
                }

                AppLogger.markdown.info("Import view task complete")
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
                            .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    // MARK: - Preview View
    
    private func previewView(_ parsed: ParsedList) -> some View {
        List {
            // Importing/Reloading to section
            Section {
                HStack {
                    Image(systemName: list.summary.icon ?? "list.bullet")
                        .foregroundStyle(.secondary)
                    Text(list.summary.name)
                        .font(.headline)
                    Spacer()
                }
            } header: {
                Text(importingToHeader)
            } footer: {
                if intent.isReload {
                    Text("Only the items shown here are affected. Other items on this list stay as they are. Matched items are re-activated (unchecked) and their quantity is updated.")
                        .font(.caption)
                }
            }

            // Options section
            Section {
                Toggle(unmatchedLabelToggleTitle, isOn: $createUnmatchedLabels)
                    .toggleStyle(.switch)
                Toggle("Replace Quantities", isOn: $replaceQuantities)
                    .toggleStyle(.switch)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(createUnmatchedLabels ?
                         "Existing labels will be matched by name. New labels will be created for unmatched names." :
                         "Existing labels will be matched by name. Items with unmatched labels will have no label.")
                    Text(replaceQuantities ?
                         "Matched items will be set to the imported quantity (overwriting the live value)." :
                         "Matched items that are currently active will have the imported quantity added to their existing one. Checked items will be set to the imported quantity.")
                }
                .font(.caption)
            }
            
            // Summary section
            Section {
                let selectedItems = parsed.items.enumerated().filter { selectedItemIndices.contains($0.offset) }
                let stats = calculateMergeStats(for: selectedItems.map(\.element))
                
                Text("**\(selectedItems.count)** of **\(parsed.items.count)** items selected")
                    .font(.headline)
                
                if stats.newItems > 0 {
                    Label(newItemsStatLabel(stats.newItems), systemImage: "plus.circle.fill")
                        .foregroundStyle(.green)
                }

                if stats.updatedItems > 0 {
                    Label(updatedItemsStatLabel(stats.updatedItems), systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                }
                
                if stats.newLabels > 0 {
                    Label("\(stats.newLabels) new labels will be created", systemImage: "tag.fill")
                        .foregroundStyle(.purple)
                }
                
                if stats.matchedLabels > 0 {
                    Label("\(stats.matchedLabels) labels matched to existing", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                
                if stats.unmatchedLabels > 0 && !createUnmatchedLabels {
                    Label("\(stats.unmatchedLabels) items will have no label", systemImage: "tag.slash")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Summary")
            }
            
            // Items grouped by label (ListView style)
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
                .foregroundStyle(labelColor(for: labelName).adjusted(forBackground: Color(.systemBackground)))
            
            Text(labelName)
                .foregroundStyle(.primary)
            
            // Show label status indicator
            if labelName != "No Label" {
                let existingLabel = existingLabels.first(where: { $0.name.lowercased() == labelName.lowercased() })
                if existingLabel != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .imageScale(.small)
                } else if createUnmatchedLabels {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.purple)
                        .imageScale(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                }
            }
            
            Spacer()
            
            // Show selection count
            Text("\(selectedCount)/\(totalCount)")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func importItemRow(item: ParsedListItem, index: Int, labelName: String) -> some View {
        let isSelected = selectedItemIndices.contains(index)
        
        HStack(spacing: 12) {
            // Quantity indicator (like ListView)
            if item.quantity > 1 {
                Text(Int(item.quantity).formatted(.number.precision(.fractionLength(0))))
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(minWidth: 12, alignment: .leading)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.note)
                    .font(.body)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .strikethrough(!isSelected, color: .gray)
                
                // Show if this will update an existing item — preview mirrors the same
                // rule the actual import uses (`replaceQuantities || existing.checked`).
                if let existing = existingItems.first(where: { $0.note.lowercased() == item.note.lowercased() }) {
                    let newQty: Double = (replaceQuantities || existing.checked)
                        ? item.quantity
                        : existing.quantity + item.quantity
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.blue)
                            .imageScale(.small)
                        Text("Quantity from \(Int(existing.quantity)) to \(Int(newQty))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.blue)
                }
                
                // Show markdown notes if present
                if let notes = item.markdownNotes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                }
            }
            
            Spacer()
            
            // Selection toggle (like checkbox in ListView)
            Button(action: {
                if isSelected {
                    selectedItemIndices.remove(index)
                } else {
                    selectedItemIndices.insert(index)
                }
            }) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.gray)
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
            var labelMap: [String: ListLabel] = [:]
            
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
                // Match by UUID first (preset reload path), fall back to case-insensitive name.
                // UUID-first survives item renames: the preset stores the UUID, expectedItems
                // carries the current ListItem (with its post-rename name), so we recover
                // the UUID even when the live item has since been renamed again.
                let uuidMatch: ListItem? = expectedItems
                    .flatMap { expected in
                        expected.first(where: { $0.note.lowercased() == parsedItem.note.lowercased() })
                    }
                    .flatMap { expectedItem in
                        existingItems.first(where: { $0.id == expectedItem.id })
                    }
                let nameMatch = existingItems.first(where: {
                    $0.note.lowercased() == parsedItem.note.lowercased()
                })
                if let existingItem = uuidMatch ?? nameMatch {
                    var updated = existingItem

                    if replaceQuantities || existingItem.checked {
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
            AppLogger.markdown.error("Failed to import items: \(error, privacy: .public)")
        }
    }
}

// MARK: - Preview

#Preview {
    MarkdownListImportView(
        list: UnifiedList(
            id: "test",
            source: .privateICloud("test"),
            summary: ListSummary(
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
