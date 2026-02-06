//
//  ImportListPickerSheet.swift
//  Listie-md
//
//  Picker sheet shown when a deeplink import has no matching list.
//  Lets the user choose an existing list to import into.
//

import SwiftUI

struct ImportListPickerSheet: View {
    let pending: DeeplinkCoordinator.PendingImport
    let lists: [UnifiedList]
    let onSelect: (String) -> Void

    @Environment(\.dismiss) var dismiss

    // MARK: - Filtered & grouped lists

    private var privateLists: [UnifiedList] {
        lists.filter { $0.isPrivate && !$0.isReadOnly }
            .sorted { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }
    }

    private var externalLists: [UnifiedList] {
        lists.filter { $0.isExternal && !$0.isReadOnly && !$0.isUnavailable }
    }

    private var externalGrouped: [(folder: String, lists: [UnifiedList])] {
        let grouped = Dictionary(grouping: externalLists) { folderName(for: $0) }
        return grouped.keys.sorted().map { key in
            let sorted = grouped[key]!.sorted {
                $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending
            }
            return (folder: key.isEmpty ? "Connected" : key, lists: sorted)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("The link doesn't specify a list, or the original list wasn't found. Choose where to import the items.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                // Private lists
                if !privateLists.isEmpty {
                    Section {
                        ForEach(privateLists) { list in
                            listButton(for: list)
                        }
                    } header: {
                        Label("Private", systemImage: "lock.icloud.fill")
                    }
                }

                // External lists grouped by folder
                ForEach(externalGrouped, id: \.folder) { group in
                    Section {
                        ForEach(group.lists) { list in
                            listButton(for: list)
                        }
                    } header: {
                        Label(group.folder, systemImage: "folder")
                    }
                }
            }
            .navigationTitle("Import To...")
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
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func listButton(for list: UnifiedList) -> some View {
        Button {
            let targetId = list.originalFileId ?? list.id
            onSelect(targetId)
            dismiss()
        } label: {
            Label(list.summary.name, systemImage: list.summary.icon ?? "checklist")
                .foregroundColor(.primary)
        }
    }

    private func folderName(for list: UnifiedList) -> String {
        if case .external(let url) = list.source {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return ""
    }
}
