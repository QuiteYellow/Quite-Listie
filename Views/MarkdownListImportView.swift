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
    let existingItems: [ShoppingItem]
    let existingLabels: [ShoppingLabel]
    
    @Environment(\.dismiss) var dismiss
    @State private var markdownText: String = ""
    @State private var showPreview = false
    @State private var parsedList: ParsedList?
    @State private var createUnmatchedLabels = true
    @State private var isSaving = false
    
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
        }
    }
    
    // MARK: - Editor View
    
    private var editorView: some View {
        VStack(spacing: 0) {
            Form {
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
        Form {
            Section {
                Toggle("Create New Labels for Unmatched", isOn: $createUnmatchedLabels)
                    .toggleStyle(.switch)
            } footer: {
                Text(createUnmatchedLabels ?
                     "Existing labels will be matched by name. New labels will be created for unmatched names." :
                     "Existing labels will be matched by name. Items with unmatched labels will have no label.")
                    .font(.caption)
            }
            
            Section {
                Text("**\(parsed.items.count)** items will be imported")
                    .font(.headline)
                
                let mergeStats = calculateMergeStats(parsed)
                
                if mergeStats.newItems > 0 {
                    Label("\(mergeStats.newItems) new items", systemImage: "plus.circle.fill")
                        .foregroundColor(.green)
                }
                
                if mergeStats.updatedItems > 0 {
                    Label("\(mergeStats.updatedItems) existing items (checked: replace qty, active: add qty)", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundColor(.blue)
                }
                
                if mergeStats.newLabels > 0 {
                    Label("\(mergeStats.newLabels) new labels will be created", systemImage: "tag.fill")
                        .foregroundColor(.purple)
                }
                
                if mergeStats.matchedLabels > 0 {
                    Label("\(mergeStats.matchedLabels) labels matched to existing", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
                
                if mergeStats.unmatchedLabels > 0 && !createUnmatchedLabels {
                    Label("\(mergeStats.unmatchedLabels) items will have no label", systemImage: "tag.slash")
                        .foregroundColor(.orange)
                }
            } header: {
                Text("Summary")
            }
            
            Section {
                ForEach(Array(parsed.items.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if item.quantity > 1 {
                                Text("\(Int(item.quantity))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text(item.note)
                                .font(.body)
                            
                            Spacer()
                            
                            if item.checked {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        
                        if let labelName = item.labelName {
                            let labelColor = labelColor(for: labelName)
                            HStack(spacing: 4) {
                                Image(systemName: "tag.fill")
                                    .foregroundColor(labelColor)
                                    .imageScale(.small)
                                Text(labelName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let notes = item.markdownNotes {
                            Text(notes)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 16)
                        }
                        
                        // Show if this will update an existing item
                        if let existing = existingItems.first(where: { $0.note.lowercased() == item.note.lowercased() }) {
                            if existing.checked {
                                Text("Will update existing item (quantity → \(Int(item.quantity)))")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                    .italic()
                            } else {
                                let newQty = existing.quantity + item.quantity
                                Text("Will update existing item (quantity: \(Int(existing.quantity)) + \(Int(item.quantity)) = \(Int(newQty)))")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                    .italic()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Items Preview")
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private struct MergeStats {
        let newItems: Int
        let updatedItems: Int
        let newLabels: Int
        let matchedLabels: Int
        let unmatchedLabels: Int
    }
    
    private func calculateMergeStats(_ parsed: ParsedList) -> MergeStats {
        let existingItemNames = Set(existingItems.map { $0.note.lowercased() })
        
        var newItems = 0
        var updatedItems = 0
        
        for item in parsed.items {
            if existingItemNames.contains(item.note.lowercased()) {
                updatedItems += 1
            } else {
                newItems += 1
            }
        }
        
        // Always try to match existing labels by name (case-insensitive)
        let existingLabelNames = Set(existingLabels.map { $0.name.lowercased() })
        var matchedLabels = 0
        var unmatchedLabels = 0
        
        for labelName in parsed.labelNames {
            if existingLabelNames.contains(labelName.lowercased()) {
                matchedLabels += 1
            } else {
                unmatchedLabels += 1
            }
        }
        
        // Only count as "new labels" if we're creating them
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
    
    private func parseAndPreview() {
        parsedList = MarkdownListParser.parse(markdownText, listTitle: list.summary.name)
        withAnimation {
            showPreview = true
        }
    }
    
    // MARK: - Import Logic
    
    private func importItems() async {
        guard let parsed = parsedList else { return }
        
        isSaving = true
        defer { isSaving = false }
        
        do {
            // Step 1: Create/match labels
            var labelMap: [String: ShoppingLabel] = [:]
            
            for labelName in parsed.labelNames {
                // Always try to match existing labels first (case-insensitive)
                if let existing = existingLabels.first(where: { $0.name.lowercased() == labelName.lowercased() }) {
                    // Use existing label
                    labelMap[labelName] = existing
                } else if createUnmatchedLabels {
                    // Create new label only if toggle is on
                    let newLabel = ModelHelpers.createNewLabel(
                        name: labelName,
                        color: Color.random().toHex(),
                        existingLabels: existingLabels
                    )
                    try await provider.createLabel(newLabel, for: list)
                    labelMap[labelName] = newLabel
                }
                // If createUnmatchedLabels is false and no match, labelMap[labelName] stays nil
            }
            
            // Step 2: Import items
            for parsedItem in parsed.items {
                // Check if item exists (case-insensitive match)
                if let existingItem = existingItems.first(where: {
                    $0.note.lowercased() == parsedItem.note.lowercased()
                }) {
                    // Update existing item
                    var updated = existingItem
                    
                    // If item is checked (inactive), replace quantity
                    // If item is active, add quantities together
                    if existingItem.checked {
                        updated.quantity = parsedItem.quantity
                    } else {
                        updated.quantity = existingItem.quantity + parsedItem.quantity
                    }
                    
                    updated.checked = false // Make active
                    updated.modifiedAt = Date()
                    
                    // Update label if provided
                    if let labelName = parsedItem.labelName,
                       let label = labelMap[labelName] {
                        updated.labelId = label.id
                    }
                    
                    // Update notes if provided
                    if let notes = parsedItem.markdownNotes {
                        updated.markdownNotes = notes
                    }
                    
                    try await provider.updateItem(updated, in: list)
                } else {
                    // Create new item
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
            print("âŒ Failed to import items: \(error)")
        }
    }
}

// MARK: - Preview

#Preview {
    MarkdownListImportView(
        list: UnifiedList(
            id: "test",
            source: .local,
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
