//
//  MarkdownListImportView.swift
//  Listie-md
//
//  Three-intent import sheet: .paste, .link, .preset.
//  Each intent has its own initial step, back-navigation contract, and visual identity.
//

import os
import SwiftUI

// MARK: - Testable logic helpers

/// Pure-Swift logic for the import preview. Lives outside the View so it's
/// unit-testable without a snapshot framework.
struct MarkdownImportLogic {
    struct MergeStats: Equatable {
        var newItems: Int = 0
        var updatedItems: Int = 0
        var newLabels: Int = 0
        var matchedLabels: Int = 0
        var unmatchedLabels: Int = 0
    }

    struct DiffLine: Equatable {
        enum Kind: String { case quantity, reactivate, label }
        let kind: Kind
        let text: String
    }

    /// UUID-first, name-fallback matching. UUID match uses the `expectedItems`
    /// snapshot (carried by preset reloads) to survive renames between the time
    /// the preset was captured and now.
    static func matchExisting(
        parsed: ParsedListItem,
        in existingItems: [ListItem],
        expectedItems: [ListItem]
    ) -> ListItem? {
        let uuidMatch = expectedItems
            .first { $0.note.lowercased() == parsed.note.lowercased() }
            .flatMap { expected in existingItems.first { $0.id == expected.id } }
        if let uuidMatch { return uuidMatch }
        return existingItems.first { $0.note.lowercased() == parsed.note.lowercased() }
    }

    static func mergeStats(
        for parsed: [ParsedListItem],
        existingItems: [ListItem],
        existingLabels: [ListLabel],
        expectedItems: [ListItem],
        createUnmatchedLabels: Bool
    ) -> MergeStats {
        var stats = MergeStats()
        for item in parsed {
            if matchExisting(parsed: item, in: existingItems, expectedItems: expectedItems) != nil {
                stats.updatedItems += 1
            } else {
                stats.newItems += 1
            }
        }

        let labelNamesInSelection = Set(parsed.compactMap { $0.labelName })
        let existingLabelNames = Set(existingLabels.map { $0.name.lowercased() })
        for name in labelNamesInSelection {
            if existingLabelNames.contains(name.lowercased()) {
                stats.matchedLabels += 1
            } else {
                stats.unmatchedLabels += 1
            }
        }
        stats.newLabels = createUnmatchedLabels ? stats.unmatchedLabels : 0
        return stats
    }

    /// Stacked diff lines for a matched item: quantity, reactivation, label.
    /// Returns only lines that represent a real change.
    static func diffLines(
        existing: ListItem,
        parsed: ParsedListItem,
        existingLabels: [ListLabel],
        replaceQuantities: Bool
    ) -> [DiffLine] {
        var lines: [DiffLine] = []

        let newQty: Double = (replaceQuantities || existing.checked)
            ? parsed.quantity
            : existing.quantity + parsed.quantity
        if existing.quantity != newQty {
            lines.append(.init(
                kind: .quantity,
                text: "Quantity \(formatQty(existing.quantity)) → \(formatQty(newQty))"
            ))
        }

        if existing.checked {
            lines.append(.init(kind: .reactivate, text: "Will be re-activated"))
        }

        let existingLabelName = existing.labelId.flatMap { id in
            existingLabels.first { $0.id == id }?.name
        }
        let labelChanged = (existingLabelName ?? "").lowercased()
            != (parsed.labelName ?? "").lowercased()
        if labelChanged {
            let from = existingLabelName ?? "no label"
            let to = parsed.labelName ?? "no label"
            lines.append(.init(kind: .label, text: "Label: \(from) → \(to)"))
        }

        return lines
    }

    private static func formatQty(_ qty: Double) -> String {
        Int(qty).formatted(.number.precision(.fractionLength(0)))
    }
}

// MARK: - View

struct MarkdownListImportView: View {

    /// Why this sheet was opened. Drives the initial step, the back-navigation
    /// contract, and every visible string.
    enum Intent {
        /// User pasted/typed markdown. Editor-first; back from preview returns to editor.
        case paste
        /// Markdown arrived from a deeplink. No back-to-editor; raw markdown is
        /// surfaced (and editable) only via the "View source" disclosure.
        case link(markdown: String, autoPreview: Bool)
        /// Reloading a saved preset on the same list. Preview-only; cancel-only.
        /// `expectedItems` carries the preset's original item snapshot for UUID matching.
        case preset(name: String, markdown: String, expectedItems: [ListItem])
    }

    private enum Step: Equatable { case pickList, editor, preview }

    struct ImportFailure: Identifiable {
        let id = UUID()
        let message: String
    }

    // MARK: - Inputs

    let intent: Intent
    let provider: UnifiedListProvider
    let allLists: [UnifiedList]
    let onComplete: ((UnifiedList) -> Void)?

    @State private var list: UnifiedList?
    @State private var existingItems: [ListItem]
    @State private var existingLabels: [ListLabel]

    // MARK: - View state

    @State private var step: Step
    @State private var markdownText: String
    @State private var parsedList: ParsedList?
    @State private var selectedItemIndices: Set<Int> = []
    @State private var createUnmatchedLabels = true
    @State private var replaceQuantities: Bool
    @State private var showSourceDisclosure = false
    @State private var showSelectionResetCaption = false
    @State private var isSaving = false
    @State private var isLoadingPickedList = false
    @State private var importFailure: ImportFailure?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(
        intent: Intent,
        list: UnifiedList?,
        existingItems: [ListItem],
        existingLabels: [ListLabel],
        allLists: [UnifiedList],
        provider: UnifiedListProvider,
        onComplete: ((UnifiedList) -> Void)? = nil
    ) {
        self.intent = intent
        self.provider = provider
        self.allLists = allLists
        self.onComplete = onComplete
        self._list = State(initialValue: list)
        self._existingItems = State(initialValue: existingItems)
        self._existingLabels = State(initialValue: existingLabels)

        // Per-intent initial state.
        switch intent {
        case .paste:
            self._markdownText = State(initialValue: "")
            self._replaceQuantities = State(initialValue: false)
            self._step = State(initialValue: list == nil ? .pickList : .editor)
        case .link(let markdown, let autoPreview):
            self._markdownText = State(initialValue: markdown)
            self._replaceQuantities = State(initialValue: false)
            if list == nil {
                self._step = State(initialValue: .pickList)
            } else {
                self._step = State(initialValue: autoPreview ? .preview : .editor)
            }
        case .preset(_, let markdown, _):
            assert(list != nil, "MarkdownListImportView .preset intent requires a list")
            self._markdownText = State(initialValue: markdown)
            self._replaceQuantities = State(initialValue: true)
            self._step = State(initialValue: list == nil ? .editor : .preview)
        }
    }

    // MARK: - Derived

    private var expectedItems: [ListItem] {
        if case .preset(_, _, let items) = intent { return items }
        return []
    }

    private var intentSymbol: String {
        switch intent {
        case .paste:  return "doc.on.clipboard"
        case .link:   return "link"
        case .preset: return "arrow.clockwise.circle"
        }
    }

    private var intentTint: Color {
        switch intent {
        case .paste:  return .blue
        case .link:   return .indigo
        case .preset: return .orange
        }
    }

    private var intentHeadline: String {
        switch intent {
        case .paste:                  return "Paste shopping list"
        case .link:                   return "Import from link"
        case .preset(let name, _, _): return "Reload \u{201C}\(name)\u{201D}"
        }
    }

    private var intentSubhead: String {
        guard let list else { return "Choose a list to import into." }
        switch intent {
        case .paste, .link: return "Importing to \(list.summary.name)"
        case .preset:       return "Re-activating items on \(list.summary.name)"
        }
    }

    private var pickerHeader: String {
        switch intent {
        case .paste:  return "Pick a list to import into."
        case .link:   return "The link doesn't specify a list, or the original list wasn't found. Choose where to import the items."
        case .preset: return ""  // unreachable; preset requires a list
        }
    }

    private var allowsBackFromPreview: Bool {
        // Only .paste supports "edit the markdown" as a back step.
        // .link/.preset surface the markdown via the disclosure, not via navigation.
        if case .paste = intent { return true }
        return false
    }

    private var showsSourceDisclosure: Bool {
        if case .paste = intent { return false }
        return true
    }

    private var navigationTitleText: String {
        switch step {
        case .pickList: return "Import to…"
        case .editor:
            if case .paste = intent { return "Paste Shopping List" }
            return "Edit Markdown"
        case .preview:
            switch intent {
            case .paste:                  return "Preview Import"
            case .link:                   return "Preview Import"
            case .preset(let name, _, _): return "Reload \u{201C}\(name)\u{201D}"
            }
        }
    }

    private var confirmActionTitle: String {
        if case .preset = intent {
            let n = selectedItemIndices.count
            return "Reload \(n) item\(n == 1 ? "" : "s")"
        }
        return "Import"
    }

    private var unmatchedLabelToggleTitle: String {
        if case .preset = intent { return "Re-create deleted labels" }
        return "Create new labels for unmatched"
    }

    private var newItemsStatLabel: (Int) -> String {
        if case .preset = intent {
            return { "\($0) item\($0 == 1 ? "" : "s") new to this list (will be added)" }
        }
        return { "\($0) new item\($0 == 1 ? "" : "s")" }
    }

    private var updatedItemsStatLabel: (Int) -> String {
        if case .preset = intent {
            return { "\($0) item\($0 == 1 ? "" : "s") will be re-activated" }
        }
        return { "\($0) existing item\($0 == 1 ? "" : "s") will be updated" }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .pickList: pickListView
                case .editor:   editorView
                case .preview:  previewBody
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContents }
            .alert(item: $importFailure) { failure in
                Alert(
                    title: Text("Import couldn't finish"),
                    message: Text(failure.message),
                    dismissButton: .default(Text("OK"), action: { dismiss() })
                )
            }
            .task(id: stepTaskID) {
                // Parse once when we land on the preview without a parsed list yet.
                if step == .preview && parsedList == nil {
                    parseAndPreview(animated: false)
                }
            }
        }
    }

    /// Identifier passed to `.task(id:)` so it re-runs after picker → preview transitions.
    private var stepTaskID: String {
        "\(step)-\(list?.id ?? "nil")"
    }

    @ToolbarContentBuilder
    private var toolbarContents: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").symbolRenderingMode(.hierarchical)
            }
            .help("Cancel")
        }

        ToolbarItem(placement: .confirmationAction) {
            if step == .preview {
                Button(confirmActionTitle) {
                    Task { await importItems() }
                }
                .disabled(isSaving || selectedItemIndices.isEmpty)
            } else if step == .editor {
                Button("Preview") {
                    parseAndPreview(animated: true)
                }
                .disabled(markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        if step == .preview && allowsBackFromPreview {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    withAnimation { step = .editor }
                } label: {
                    Image(systemName: "chevron.backward").symbolRenderingMode(.hierarchical)
                }
                .help("Back")
            }
        }
    }

    // MARK: - Step: pick list

    private var pickListView: some View {
        ZStack {
            ImportListPicker(lists: allLists, header: pickerHeader) { picked in
                Task { await pickList(picked) }
            }
            if isLoadingPickedList {
                Color.black.opacity(0.05).ignoresSafeArea()
                ProgressView("Loading…")
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func pickList(_ picked: UnifiedList) async {
        isLoadingPickedList = true
        defer { isLoadingPickedList = false }

        do {
            let items = try await provider.fetchItems(for: picked)
            let labels = try await provider.fetchLabels(for: picked)
            self.list = picked
            self.existingItems = items
            self.existingLabels = labels

            switch intent {
            case .paste:
                withAnimation { step = .editor }
            case .link(_, let autoPreview):
                if autoPreview {
                    parseAndPreview(animated: true)
                } else {
                    withAnimation { step = .editor }
                }
            case .preset:
                // Preset requires a list at init time; the picker step is unreachable.
                withAnimation { step = .preview }
            }
        } catch {
            AppLogger.markdown.error("Failed to load picked list: \(error, privacy: .public)")
            importFailure = ImportFailure(message: "Could not load that list. Please try another.")
        }
    }

    // MARK: - Step: editor

    private var editorView: some View {
        Form {
            if let list {
                Section {
                    HStack {
                        Image(systemName: list.summary.icon ?? "list.bullet")
                            .foregroundStyle(.secondary)
                        Text(list.summary.name).font(.headline)
                        Spacer()
                    }
                } header: {
                    Text("Importing to")
                }
            }

            Section {
                TextEditor(text: $markdownText)
                    .frame(minHeight: 200)
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Paste markdown list")
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

    // MARK: - Step: preview

    @ViewBuilder
    private var previewBody: some View {
        if let parsed = parsedList {
            previewView(parsed)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewView(_ parsed: ParsedList) -> some View {
        List {
            intentBanner

            if showsSourceDisclosure {
                sourceDisclosureSection
            }

            optionsSection

            summarySection(parsed: parsed)

            // Items grouped by label
            let grouped = Dictionary(grouping: parsed.items.enumerated()) { (_, item) in
                item.labelName ?? "No Label"
            }
            let sortedLabelNames = grouped.keys.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }

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

    // MARK: - Preview pieces

    private var intentBanner: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: intentSymbol)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(intentTint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(intentHeadline).font(.subheadline.weight(.semibold))
                    Text(intentSubhead).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                intentTint.opacity(colorScheme == .dark ? 0.22 : 0.12),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(intentTint.opacity(0.25), lineWidth: 1)
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    private var sourceDisclosureSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showSourceDisclosure) {
                TextEditor(text: $markdownText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140)
                    .autocorrectionDisabled(true)
                Button("Re-parse") {
                    parseAndPreview(animated: false)
                    showSelectionResetCaption = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation { showSelectionResetCaption = false }
                    }
                }
                .font(.caption)
            } label: {
                Label("View source", systemImage: "chevron.right.square")
                    .font(.subheadline)
            }
        } footer: {
            if showSourceDisclosure {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This markdown was generated from the link or preset. Edit and tap Re-parse to preview different items.")
                    if showSelectionResetCaption {
                        Text("Selection reset.")
                            .foregroundStyle(.orange)
                            .transition(.opacity)
                    }
                }
                .font(.caption)
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle(unmatchedLabelToggleTitle, isOn: $createUnmatchedLabels)
                .toggleStyle(.switch)
            Toggle("Replace quantities", isOn: $replaceQuantities)
                .toggleStyle(.switch)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(createUnmatchedLabels
                     ? "Existing labels will be matched by name. New labels will be created for unmatched names."
                     : "Existing labels will be matched by name. Items with unmatched labels will have no label.")
                Text(replaceQuantities
                     ? "Matched items will be set to the imported quantity (overwriting the live value)."
                     : "Matched items that are currently active will have the imported quantity added to their existing one. Checked items will be set to the imported quantity.")
            }
            .font(.caption)
        }
    }

    private func summarySection(parsed: ParsedList) -> some View {
        let selectedItems = parsed.items.enumerated().filter { selectedItemIndices.contains($0.offset) }
        let stats = MarkdownImportLogic.mergeStats(
            for: selectedItems.map(\.element),
            existingItems: existingItems,
            existingLabels: existingLabels,
            expectedItems: expectedItems,
            createUnmatchedLabels: createUnmatchedLabels
        )

        return Section {
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
                Label("\(stats.newLabels) new label\(stats.newLabels == 1 ? "" : "s") will be created", systemImage: "tag.fill")
                    .foregroundStyle(.purple)
            }
            if stats.matchedLabels > 0 {
                Label("\(stats.matchedLabels) label\(stats.matchedLabels == 1 ? "" : "s") matched to existing", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if stats.unmatchedLabels > 0 && !createUnmatchedLabels {
                Label("\(stats.unmatchedLabels) item\(stats.unmatchedLabels == 1 ? "" : "s") will have no label", systemImage: "tag.slash")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Summary")
        }
    }

    @ViewBuilder
    private func importSectionHeader(labelName: String, totalCount: Int, selectedCount: Int) -> some View {
        HStack {
            Image(systemName: "tag.fill")
                .foregroundStyle(labelColor(for: labelName).adjusted(forBackground: Color(.systemBackground)))

            Text(labelName).foregroundStyle(.primary)

            if labelName != "No Label" {
                let existingLabel = existingLabels.first(where: { $0.name.lowercased() == labelName.lowercased() })
                if existingLabel != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green).imageScale(.small)
                } else if createUnmatchedLabels {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.purple).imageScale(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).imageScale(.small)
                }
            }

            Spacer()

            Text("\(selectedCount)/\(totalCount)")
                .foregroundStyle(.secondary).font(.subheadline)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func importItemRow(item: ParsedListItem, index: Int, labelName: String) -> some View {
        let isSelected = selectedItemIndices.contains(index)

        HStack(spacing: 12) {
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

                if let existing = MarkdownImportLogic.matchExisting(
                    parsed: item, in: existingItems, expectedItems: expectedItems
                ) {
                    diffBlock(existing: existing, parsed: item)
                }

                if let notes = item.markdownNotes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                }
            }

            Spacer()

            Button {
                if isSelected { selectedItemIndices.remove(index) }
                else { selectedItemIndices.insert(index) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.gray)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .opacity(isSelected ? 1.0 : 0.5)
    }

    @ViewBuilder
    private func diffBlock(existing: ListItem, parsed: ParsedListItem) -> some View {
        let lines = MarkdownImportLogic.diffLines(
            existing: existing,
            parsed: parsed,
            existingLabels: existingLabels,
            replaceQuantities: replaceQuantities
        )
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.text) { line in
                    diffLineView(line)
                }
            }
            .font(.caption2)
        }
    }

    @ViewBuilder
    private func diffLineView(_ line: MarkdownImportLogic.DiffLine) -> some View {
        let (symbol, tint): (String, Color) = {
            switch line.kind {
            case .quantity:   return ("number.circle", .blue)
            case .reactivate: return ("arrow.uturn.backward.circle", .green)
            case .label:      return ("tag", .purple)
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(line.text)
        }
        .foregroundStyle(tint)
    }

    // MARK: - Logic glue

    private func parseAndPreview(animated: Bool) {
        let listTitle = list?.summary.name ?? ""
        parsedList = MarkdownListParser.parse(markdownText, listTitle: listTitle)
        selectedItemIndices = Set(0..<(parsedList?.items.count ?? 0))
        if animated {
            withAnimation { step = .preview }
        } else {
            step = .preview
        }
    }

    private func labelColor(for labelName: String) -> Color {
        if let existing = existingLabels.first(where: { $0.name.lowercased() == labelName.lowercased() }) {
            return Color(hex: existing.color)
        }
        return createUnmatchedLabels ? .purple : .secondary
    }

    private func importItems() async {
        guard let parsed = parsedList else { return }
        guard let list else {
            importFailure = ImportFailure(message: "No list selected.")
            return
        }

        isSaving = true
        defer { isSaving = false }

        let itemsToImport = parsed.items.enumerated()
            .filter { selectedItemIndices.contains($0.offset) }
            .map { $0.element }
        let labelNamesInSelection = Set(itemsToImport.compactMap { $0.labelName })

        var succeeded = 0
        var firstErrorMessage: String?

        // Step 1: match/create labels for selected items.
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
                do {
                    try await provider.createLabel(newLabel, for: list)
                    labelMap[labelName] = newLabel
                } catch {
                    AppLogger.markdown.error("Failed to create label \(labelName, privacy: .public): \(error, privacy: .public)")
                    if firstErrorMessage == nil {
                        firstErrorMessage = "Could not create label \u{201C}\(labelName)\u{201D}."
                    }
                }
            }
        }

        // Step 2: add or update items.
        for parsedItem in itemsToImport {
            let existing = MarkdownImportLogic.matchExisting(
                parsed: parsedItem, in: existingItems, expectedItems: expectedItems
            )
            do {
                if let existing {
                    var updated = existing
                    if replaceQuantities || existing.checked {
                        updated.quantity = parsedItem.quantity
                    } else {
                        updated.quantity = existing.quantity + parsedItem.quantity
                    }
                    updated.checked = false
                    updated.modifiedAt = Date()
                    if let labelName = parsedItem.labelName, let label = labelMap[labelName] {
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
                succeeded += 1
            } catch {
                AppLogger.markdown.error("Failed to import item \(parsedItem.note, privacy: .public): \(error, privacy: .public)")
                if firstErrorMessage == nil {
                    firstErrorMessage = "Last error: \(error.localizedDescription)"
                }
            }
        }

        let total = itemsToImport.count
        if let firstErrorMessage, succeeded < total {
            importFailure = ImportFailure(
                message: "Imported \(succeeded) of \(total) item\(total == 1 ? "" : "s"). \(firstErrorMessage)"
            )
        } else {
            onComplete?(list)
            dismiss()
        }
    }
}
