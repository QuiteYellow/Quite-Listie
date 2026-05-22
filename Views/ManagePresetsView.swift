//
//  ManagePresetsView.swift
//  Listie-md
//
//  Manage saved share-link presets for a list. CRUD + tombstone recovery.
//

import SwiftUI

struct ManagePresetsView: View {
    let list: UnifiedList
    let provider: UnifiedListProvider
    let items: [ListItem]
    let labels: [ListLabel]
    let labelOrder: [String]?
    var onPresetsChanged: (([SharePreset]) -> Void)?

    @Environment(\.dismiss) var dismiss

    @State private var presets: [SharePreset] = []
    @State private var showDeleted = false
    @State private var creatingNew = false
    @State private var editingPreset: SharePreset?
    @State private var renamingPreset: SharePreset?
    @State private var renameDraft: String = ""
    @State private var pendingDelete: SharePreset?
    @State private var errorMessage: String?
    @State private var showError = false

    private var isReadOnly: Bool {
        list.isReadOnly
    }

    private var active: [SharePreset] {
        presets.filter { !$0.isDeleted }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private var deleted: [SharePreset] {
        presets.filter { $0.isDeleted }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if active.isEmpty && !showDeleted {
                    Section {
                        ContentUnavailableView(
                            "No Presets",
                            systemImage: "bookmark",
                            description: Text("Save a preset to remember a set of items you re-activate often, like a weekly shopping trip.")
                        )
                    }
                } else if !active.isEmpty {
                    Section {
                        ForEach(active) { preset in
                            presetRow(preset)
                        }
                    } header: {
                        Text("Saved")
                    } footer: {
                        Text("Tap a preset to edit. Reloading re-activates the preset's items on this list (matched by ID, then name) and updates their quantities. Other items on your list stay as they are.")
                    }
                }

                if showDeleted && !deleted.isEmpty {
                    Section {
                        ForEach(deleted) { preset in
                            deletedRow(preset)
                        }
                    } header: {
                        Text("Recently Deleted")
                    } footer: {
                        Text("Deleted presets are kept for 30 days, then permanently removed.")
                    }
                }

                if !deleted.isEmpty || showDeleted {
                    Section {
                        Toggle("Show deleted presets", isOn: $showDeleted)
                    }
                }
            }
            .navigationTitle("Manage Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creatingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isReadOnly || items.isEmpty)
                    .help("New preset")
                }
            }
            .sheet(isPresented: $creatingNew) {
                ShareLinkSheet(
                    listName: list.summary.name,
                    listId: list.originalFileId ?? list.id,
                    items: items,
                    labels: labels,
                    labelOrder: labelOrder,
                    mode: .savePreset,
                    onSavePreset: { preset in
                        Task { await save(adding: preset) }
                    }
                )
            }
            .sheet(item: $editingPreset) { preset in
                ShareLinkSheet(
                    listName: list.summary.name,
                    listId: list.originalFileId ?? list.id,
                    items: items,
                    labels: labels,
                    labelOrder: labelOrder,
                    mode: .editPreset(preset),
                    onSavePreset: { updated in
                        Task { await save(updating: updated) }
                    }
                )
            }
            .alert("Rename Preset", isPresented: Binding(
                get: { renamingPreset != nil },
                set: { if !$0 { renamingPreset = nil } }
            )) {
                TextField("Name", text: $renameDraft)
                Button("Cancel", role: .cancel) { renamingPreset = nil }
                Button("Save") {
                    if let target = renamingPreset {
                        Task { await save(renaming: target, to: renameDraft) }
                    }
                    renamingPreset = nil
                }
            }
            .confirmationDialog(
                "Delete preset?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { preset in
                Button("Delete \"\(preset.name)\"", role: .destructive) {
                    Task { await save(deleting: preset) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
            .alert("Couldn't save", isPresented: $showError, presenting: errorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .task {
                await reload()
            }
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: SharePreset) -> some View {
        let liveCount = preset.itemIds.reduce(0) { acc, id in
            acc + (items.contains(where: { $0.id == id }) ? 1 : 0)
        }
        Button {
            editingPreset = preset
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text("\(liveCount) item\(liveCount == 1 ? "" : "s")")
                        Text("•")
                        Text(preset.modifiedAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isReadOnly)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = preset
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isReadOnly)

            Button {
                renameDraft = preset.name
                renamingPreset = preset
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
            .disabled(isReadOnly)
        }
        .contextMenu {
            Button {
                editingPreset = preset
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
            }
            Button {
                renameDraft = preset.name
                renamingPreset = preset
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingDelete = preset
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func deletedRow(_ preset: SharePreset) -> some View {
        let deletedAt = preset.deletedAt ?? preset.modifiedAt
        let daysAgo = Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
        let daysRemaining = max(0, 30 - daysAgo)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.body)
                Text("Deleted \(daysAgo) day\(daysAgo == 1 ? "" : "s") ago • Auto-removes in \(daysRemaining) day\(daysRemaining == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(daysRemaining <= 7 ? .orange : .secondary)
            }
            Spacer()
            Button("Restore") {
                Task { await save(restoring: preset) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isReadOnly)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await save(hardDeleting: preset) }
            } label: {
                Label("Delete Forever", systemImage: "trash.fill")
            }
            .disabled(isReadOnly)
        }
    }

    // MARK: - Persistence

    private func reload() async {
        do {
            presets = try await provider.fetchSharePresets(for: list)
        } catch {
            AppLogger.general.error("Failed to load share presets: \(error, privacy: .public)")
        }
    }

    private func save(adding preset: SharePreset) async {
        var copy = presets
        copy.append(preset)
        await commit(copy)
    }

    private func save(updating preset: SharePreset) async {
        var copy = presets
        if let idx = copy.firstIndex(where: { $0.id == preset.id }) {
            copy[idx] = preset
        } else {
            copy.append(preset)
        }
        await commit(copy)
    }

    private func save(renaming preset: SharePreset, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var copy = presets
        guard let idx = copy.firstIndex(where: { $0.id == preset.id }) else { return }
        copy[idx].name = trimmed
        copy[idx].modifiedAt = Date()
        await commit(copy)
    }

    private func save(deleting preset: SharePreset) async {
        var copy = presets
        guard let idx = copy.firstIndex(where: { $0.id == preset.id }) else { return }
        copy[idx].isDeleted = true
        copy[idx].deletedAt = Date()
        copy[idx].modifiedAt = Date()
        await commit(copy)
    }

    private func save(restoring preset: SharePreset) async {
        var copy = presets
        guard let idx = copy.firstIndex(where: { $0.id == preset.id }) else { return }
        copy[idx].isDeleted = false
        copy[idx].deletedAt = nil
        copy[idx].modifiedAt = Date()
        await commit(copy)
    }

    private func save(hardDeleting preset: SharePreset) async {
        var copy = presets
        guard let idx = copy.firstIndex(where: { $0.id == preset.id }) else { return }
        // Force purge by stamping deletedAt past the retention window.
        copy[idx].isDeleted = true
        copy[idx].deletedAt = Date().addingTimeInterval(-SharePreset.tombstoneRetention - 1)
        copy[idx].modifiedAt = Date()
        await commit(copy)
    }

    private func commit(_ newPresets: [SharePreset]) async {
        do {
            try await provider.updateSharePresets(list, presets: newPresets)
            presets = newPresets
            onPresetsChanged?(newPresets.filter { !$0.isDeleted })
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
