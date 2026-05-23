//
//  ImportListPickerSheet.swift
//  Listie-md
//
//  Inline list picker used as the first step of MarkdownListImportView when
//  the target list isn't yet known (e.g. a deeplink with no list parameter).
//  No sheet chrome — the parent supplies NavigationStack, toolbar, dismiss.
//

import SwiftUI

struct ImportListPicker: View {
    let lists: [UnifiedList]
    /// Optional copy shown above the picker (e.g. "The link doesn't specify a list…").
    let header: String?
    let onSelect: (UnifiedList) -> Void

    // MARK: - Filtered & grouped lists

    private var privateLists: [UnifiedList] {
        lists.filter { $0.isPrivate && !$0.isReadOnly }
            .sorted { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }
    }

    private var externalLists: [UnifiedList] {
        lists.filter { $0.isExternal && !$0.isReadOnly && !$0.isPermanentlyUnavailable }
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
        List {
            if let header {
                Section {
                    Text(header)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !privateLists.isEmpty {
                Section {
                    ForEach(privateLists) { list in
                        listButton(for: list)
                    }
                } header: {
                    Label("Private", systemImage: "lock.icloud.fill")
                }
            }

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
    }

    // MARK: - Helpers

    @ViewBuilder
    private func listButton(for list: UnifiedList) -> some View {
        Button {
            onSelect(list)
        } label: {
            Label(list.summary.name, systemImage: list.summary.icon ?? "checklist")
                .foregroundStyle(.primary)
        }
    }

    private func folderName(for list: UnifiedList) -> String {
        if case .external(let url) = list.source {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return ""
    }
}
