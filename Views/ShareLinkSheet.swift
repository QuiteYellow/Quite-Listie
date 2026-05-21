//
//  ShareLinkSheet.swift
//  Listie-md
//
//  Sheet for generating and sharing compressed deeplink URLs
//

import SwiftUI

struct ShareLinkSheet: View {
    enum Mode {
        case share                       // one-off share — Copy / Share / URL preview
        case savePreset                  // creating a new preset — Name field + Save
        case editPreset(SharePreset)     // editing an existing preset — Name field + Update
    }

    let listName: String
    let listId: String?
    let items: [ListItem]
    let labels: [ListLabel]
    let labelOrder: [String]?
    let mode: Mode
    let onSavePreset: ((SharePreset) -> Void)?

    @Environment(\.dismiss) var dismiss

    @State private var compress: Bool
    @State private var includeComments: Bool
    @State private var selectedItemIds: Set<UUID>
    @State private var collapsedLabels: Set<String> = []
    @State private var showCopiedConfirmation = false
    @State private var presetName: String

    init(
        listName: String,
        listId: String?,
        items: [ListItem],
        labels: [ListLabel],
        labelOrder: [String]?,
        activeOnly: Bool = true,
        mode: Mode = .share,
        onSavePreset: ((SharePreset) -> Void)? = nil
    ) {
        self.listName = listName
        self.listId = listId
        self.items = items
        self.labels = labels
        self.labelOrder = labelOrder
        self.mode = mode
        self.onSavePreset = onSavePreset

        switch mode {
        case .editPreset(let preset):
            let validIds = Set(items.map { $0.id })
            self._selectedItemIds = State(initialValue: Set(preset.itemIds).intersection(validIds))
            self._compress = State(initialValue: preset.compress)
            self._includeComments = State(initialValue: preset.includeComments)
            self._presetName = State(initialValue: preset.name)
        case .savePreset, .share:
            let initial: Set<UUID> = activeOnly
                ? Set(items.filter { !$0.checked }.map { $0.id })
                : Set(items.map { $0.id })
            self._selectedItemIds = State(initialValue: initial)
            self._compress = State(initialValue: true)
            self._includeComments = State(initialValue: false)
            self._presetName = State(initialValue: "")
        }
    }

    private var isPresetMode: Bool {
        if case .share = mode { return false }
        return true
    }

    private var navigationTitleText: String {
        switch mode {
        case .share: return "Share as Link"
        case .savePreset: return "New Preset"
        case .editPreset: return "Edit Preset"
        }
    }

    private var saveActionTitle: String {
        if case .editPreset = mode { return "Update" }
        return "Save"
    }

    private var canSavePreset: Bool {
        let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && hasSelection
    }

    private func commitPreset() {
        let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, hasSelection else { return }
        let now = Date()
        let preset: SharePreset
        switch mode {
        case .editPreset(let existing):
            preset = SharePreset(
                id: existing.id,
                name: trimmed,
                itemIds: Array(selectedItemIds),
                compress: compress,
                includeComments: includeComments,
                createdAt: existing.createdAt,
                modifiedAt: now,
                isDeleted: false,
                deletedAt: nil
            )
        case .savePreset, .share:
            preset = SharePreset(
                name: trimmed,
                itemIds: Array(selectedItemIds),
                compress: compress,
                includeComments: includeComments,
                createdAt: now,
                modifiedAt: now
            )
        }
        onSavePreset?(preset)
        dismiss()
    }

    // MARK: - Computed Properties

    private var filteredItems: [ListItem] {
        items.filter { selectedItemIds.contains($0.id) }
    }

    private var hasSelection: Bool {
        !selectedItemIds.isEmpty
    }

    private var generatedURL: String {
        guard hasSelection else { return "" }
        return generateShareURL()
    }

    private var urlCharacterCount: Int {
        generatedURL.count
    }

    private var warningLevel: WarningLevel {
        if !hasSelection { return .none }
        if generatedURL.hasPrefix("Error") { return .none }
        if urlCharacterCount >= 4000 { return .error }
        if urlCharacterCount >= 2000 { return .warning }
        return .none
    }

    private enum WarningLevel {
        case none, warning, error
    }

    private struct LabelGroup: Identifiable {
        let id: String         // label name (also section heading)
        let items: [ListItem]
    }

    private var groupedItems: [LabelGroup] {
        let grouped = Dictionary(grouping: items) { item -> String in
            if let labelId = item.labelId,
               let label = labels.first(where: { $0.id == labelId }) {
                return label.name
            }
            return "No Label"
        }
        let ordered = sortedLabelNames(Array(grouped.keys), labels: labels, labelOrder: labelOrder)
        return ordered.compactMap { name in
            guard let bucket = grouped[name] else { return nil }
            let sorted = bucket.sorted {
                $0.note.localizedCaseInsensitiveCompare($1.note) == .orderedAscending
            }
            return LabelGroup(id: name, items: sorted)
        }
    }

    private func selectedCount(in group: LabelGroup) -> Int {
        group.items.reduce(0) { $0 + (selectedItemIds.contains($1.id) ? 1 : 0) }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // Info / Name
                if isPresetMode {
                    Section {
                        TextField("Preset name", text: $presetName)
                            .textInputAutocapitalization(.words)
                    } header: {
                        Text("Name")
                    } footer: {
                        Text("Reload this preset later to re-activate the chosen items (un-checked) on this list.")
                    }
                } else {
                    Section {
                        Text("Anyone with this link can import these items into their Quite Listie app. They will be importing a copy. To collaborate, share a .listie file directly via icloud (or similar).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                // Toggles
                Section {
                    Toggle(isOn: $compress) {
                        Label("Compress", systemImage: "archivebox")
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $includeComments) {
                        Label("Comments", systemImage: "note.text")
                    }
                    .toggleStyle(.switch)
                } header: {
                    Text("Options")
                }

                // Item picker
                itemPickerSection

                // Details & warnings
                Section {
                    HStack {
                        Label("\(filteredItems.count) items\(includeComments ? " with comments" : "")", systemImage: "list.bullet")
                            .font(.subheadline)
                        Spacer()
                        Text("\(urlCharacterCount) characters")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(warningColor)
                    }

                    if warningLevel != .none {
                        warningView
                    }
                }

                if !isPresetMode {
                    // Actions
                    Section {
                        Button {
                            UIPasteboard.general.string = generatedURL
                            withAnimation {
                                showCopiedConfirmation = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    showCopiedConfirmation = false
                                }
                            }
                        } label: {
                            Label(
                                showCopiedConfirmation ? "Copied!" : "Copy Link",
                                systemImage: showCopiedConfirmation ? "checkmark.circle.fill" : "doc.on.doc"
                            )
                        }
                        .disabled(!hasSelection)

                        ShareLink(item: generatedURL) {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                        }
                        .disabled(!hasSelection)

                        if !hasSelection {
                            Text("Select at least one item to share.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // URL preview (at the bottom since it can be very long)
                    Section {
                        if hasSelection {
                            Text(generatedURL)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(nil)
                        } else {
                            Text("No URL — no items selected.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Share URL")
                    }
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
                    .help("Close")
                }
                if isPresetMode {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saveActionTitle) {
                            commitPreset()
                        }
                        .disabled(!canSavePreset)
                    }
                }
            }
        }
    }

    // MARK: - Item Picker

    @ViewBuilder
    private var itemPickerSection: some View {
        Section {
            HStack(spacing: 8) {
                Button("All") {
                    selectedItemIds = Set(items.map { $0.id })
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Active") {
                    selectedItemIds = Set(items.filter { !$0.checked }.map { $0.id })
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("None") {
                    selectedItemIds = []
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text("\(selectedItemIds.count) / \(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if items.isEmpty {
                Text("This list has no items to share.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groupedItems) { group in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { !collapsedLabels.contains(group.id) },
                            set: { expanded in
                                if expanded {
                                    collapsedLabels.remove(group.id)
                                } else {
                                    collapsedLabels.insert(group.id)
                                }
                            }
                        )
                    ) {
                        ForEach(group.items) { item in
                            itemRow(item)
                        }
                    } label: {
                        HStack {
                            Text(group.id)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(selectedCount(in: group)) / \(group.items.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        } header: {
            Text("Items")
        }
    }

    private func itemRow(_ item: ListItem) -> some View {
        let isSelected = selectedItemIds.contains(item.id)
        return Button {
            if isSelected {
                selectedItemIds.remove(item.id)
            } else {
                selectedItemIds.insert(item.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .imageScale(.large)

                if item.quantity > 1 {
                    Text("\(Int(item.quantity))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }

                Text(item.note)
                    .strikethrough(item.checked)
                    .foregroundStyle(item.checked ? Color.secondary : Color.primary)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Warning Color

    private var warningColor: Color {
        switch warningLevel {
        case .error: return .red
        case .warning: return .orange
        case .none: return .secondary
        }
    }

    // MARK: - Warning View

    @ViewBuilder
    private var warningView: some View {
        HStack(alignment: .top) {
            Image(systemName: warningLevel == .error
                  ? "exclamationmark.triangle.fill"
                  : "exclamationmark.triangle")
                .foregroundStyle(warningLevel == .error ? .red : .orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(warningLevel == .error
                     ? "URL is very long"
                     : "URL is getting long")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(warningLevel == .error ? .red : .orange)

                Text(warningLevel == .error
                     ? "URLs over 4,000 characters may not work on all platforms and messaging apps. Try enabling compression, removing comments, or deselecting some items."
                     : "URLs over 2,000 characters may be truncated by some apps. Consider enabling compression if it's not already on, or deselecting some items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - URL Generation

    private func generateShareURL() -> String {
        guard let id = listId else {
            return "Error: List ID not available."
        }

        let result = MarkdownListGenerator.generate(
            listName: listName,
            items: filteredItems,
            labels: labels,
            labelOrder: labelOrder,
            activeOnly: false,
            includeNotes: includeComments
        )
        let markdown = result.markdown

        let encodedMarkdown: String
        let encParam: String

        if compress {
            guard let compressed = DeeplinkCompression.compress(markdown) else {
                return "Error: Failed to compress markdown."
            }
            encodedMarkdown = compressed
            encParam = "zlib"
        } else {
            guard let base64 = markdown.data(using: .utf8)?.base64EncodedString() else {
                return "Error: Failed to encode markdown."
            }
            encodedMarkdown = base64
            encParam = "b64"
        }

        return "quitelistie://import?list=\(id)&markdown=\(encodedMarkdown)&enc=\(encParam)&preview=true"
    }
}
