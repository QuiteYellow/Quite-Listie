//
//  RecentChangesView.swift
//  Listie-md
//
//  Created by Jack Nagy on 16/5/2026.
//

import SwiftUI

struct RecentChangesView: View {
    let list: UnifiedList
    let provider: UnifiedListProvider
    var viewModel: ListViewModel
    var onItemsChanged: (() -> Void)?
    @Environment(\.dismiss) var dismiss

    @State private var recentItems: [ListItem] = []
    @State private var selectedItem: ListItem?
    @State private var syncSnapshot: String? = nil
    @State private var pendingMutations: Int = 0

    private var sourceDescription: String {
        switch list.source {
        case .nextcloud(let accountId, _): return "NextCloud · \(accountId)"
        case .privateICloud: return "iCloud / On Device"
        case .external: return "Files"
        }
    }

    /// Resolves the displayed state from the same `SaveStatus` enum the toolbar and
    /// sidebar use. Single source of truth — no separate "hasPendingSync" boolean to
    /// keep in sync.
    private var syncStateDescription: String {
        if list.isPermanentlyUnavailable { return "Unavailable (file gone)" }
        if list.hasTransientSyncError { return "Syncing (last attempt failed)" }
        switch provider.saveStatus[list.id] ?? .saved {
        case .saved:
            return list.isReadOnly ? "Read-only" : "Synced"
        case .saving:
            return "Saving…"
        case .unsaved:
            return "Unsaved changes"
        case .pendingSync:
            return "Pending sync (offline)"
        case .syncFailed(let msg):
            return "Sync failed — \(msg)"
        case .saveFailed(let msg):
            return "Save failed — \(msg)"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Layer 5: sync activity at the top of Recent Changes. Gives the user
                // ground truth about the list's connection state without a separate sheet.
                Section("Sync Activity") {
                    LabeledContent("Source", value: sourceDescription)
                    LabeledContent("State", value: syncStateDescription)
                    if pendingMutations > 0 {
                        LabeledContent("Pending Mutations", value: "\(pendingMutations)")
                    }
                    Button {
                        Task {
                            let dump = await provider.combinedStateSnapshot()
                            syncSnapshot = dump
                            #if canImport(UIKit)
                            UIPasteboard.general.string = dump
                            #endif
                        }
                    } label: {
                        Label("Copy Debug Snapshot", systemImage: "doc.on.clipboard")
                    }
                    if let syncSnapshot {
                        Text(syncSnapshot)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(20)
                    }
                }

                if recentItems.isEmpty {
                    ContentUnavailableView(
                        "No Recent Changes",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Changes to items will appear here")
                    )
                } else {
                    ForEach(recentItems) { item in
                        Button {
                            if !item.isDeleted {
                                selectedItem = item
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: iconName(for: item))
                                    .foregroundStyle(iconColor(for: item))
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.note)
                                        .font(.body)
                                        .lineLimit(1)

                                    Text(changeDescription(for: item) + " · " + relativeTime(item.modifiedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if canUndo(item) {
                                    Button("Undo") {
                                        Task { await undoChange(item) }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(item.isDeleted)
                    }
                }
            }
            .navigationTitle("Recent Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadRecentItems()
                pendingMutations = await MutationLog.shared.depth()
            }
            .fullScreenCover(item: $selectedItem, onDismiss: {
                Task { await loadRecentItems() }
                onItemsChanged?()
            }) { item in
                EditItemView(viewModel: viewModel, item: item, list: list.summary, unifiedList: list)
            }
        }
    }

    private func loadRecentItems() async {
        do {
            let allItems = try await provider.fetchItems(for: list)
            recentItems = allItems
                .filter { $0.lastChangeField != nil }
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(30)
                .map { $0 }
        } catch {
            recentItems = []
        }
    }

    private func canUndo(_ item: ListItem) -> Bool {
        switch item.lastChangeField {
        case "checked": return !item.isDeleted
        case "deleted": return true
        default: return false
        }
    }

    private func undoChange(_ item: ListItem) async {
        do {
            // Animate the old row out
            withAnimation(.easeInOut(duration: 0.3)) {
                recentItems.removeAll { $0.id == item.id }
            }

            // Small delay so the removal animation completes before the new state appears
            try await Task.sleep(nanoseconds: 350_000_000)

            switch item.lastChangeField {
            case "checked":
                var reverted = item
                reverted.checked.toggle()
                reverted.modifiedAt = Date()
                reverted.checkedAt = Date()
                reverted.lastChangeField = "checked"
                try await provider.updateItem(reverted, in: list)
            case "deleted":
                try await provider.restoreItem(item, in: list)
            default:
                return
            }
            onItemsChanged?()

            // Reload with animation so the updated row slides in
            let allItems = try await provider.fetchItems(for: list)
            let updated = allItems
                .filter { $0.lastChangeField != nil }
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(30)
                .map { $0 }
            withAnimation(.easeInOut(duration: 0.3)) {
                recentItems = updated
            }
        } catch {
            // Silently fail — item may have been permanently deleted
        }
    }

    private func iconName(for item: ListItem) -> String {
        switch item.lastChangeField {
        case "added": return "plus.circle"
        case "checked": return item.checked ? "checkmark.circle.fill" : "circle"
        case "note": return "pencil"
        case "quantity": return "number"
        case "label": return "tag"
        case "reminder": return "bell"
        case "location": return "mappin"
        case "subitems": return "list.bullet"
        case "deleted": return "trash"
        case "restored": return "arrow.uturn.backward"
        default: return "questionmark.circle"
        }
    }

    private func iconColor(for item: ListItem) -> Color {
        switch item.lastChangeField {
        case "checked": return item.checked ? .green : .orange
        case "deleted": return .red
        case "restored": return .blue
        case "added": return .green
        default: return .secondary
        }
    }

    private func changeDescription(for item: ListItem) -> String {
        switch item.lastChangeField {
        case "added": return "Added"
        case "checked": return item.checked ? "Checked off" : "Unchecked"
        case "note": return "Name updated"
        case "quantity": return "Quantity changed"
        case "label": return "Category changed"
        case "reminder": return "Reminder updated"
        case "location": return "Location updated"
        case "subitems": return "Sub-items updated"
        case "deleted": return "Deleted"
        case "restored": return "Restored"
        default: return "Modified"
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
