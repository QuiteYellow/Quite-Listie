import SwiftUI

struct LabelManagerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: LabelManagerViewModel

    @State private var selectedLabel: ShoppingLabel? = nil
    @State private var showingDeleteConfirmation = false
    @State private var activeSheet: LabelEditorSheet? = nil

    struct UserGroup: Identifiable, Hashable {
        let id: String
        let name: String
        let tokenId: UUID
    }



    enum LabelEditorSheet: Identifiable {
        case new
        case edit(ShoppingLabel)

        var id: UUID {
            switch self {
            case .new:
                return UUID()
            case .edit(let label):
                return label.localTokenId ?? UUID()
            }
        }
    }


    private var availableGroups: [UserGroup] {
        AppSettings.shared.tokens
            .compactMap { token in
                guard let groupId = token.groupId else { return nil }
                return UserGroup(id: groupId, name: token.group ?? token.identifier, tokenId: token.id)
            }
            .uniqueBy(\.id)
    }
    
    private var remoteLabels: [ShoppingLabel] {
        viewModel.allLabels.filter { !$0.isLocal }
    }

    private var localLabels: [ShoppingLabel] {
        viewModel.allLabels.filter { $0.isLocal }
    }

    private var remoteGroupedLabels: [String: [ShoppingLabel]] {
        Dictionary(grouping: remoteLabels) { $0.groupId ?? "unknown" }
    }
    
    private func sectionTitle(for groupId: String) -> String {
        if let group = availableGroups.first(where: { $0.id == groupId }) {
            return group.name.capitalized
        }

        // Fallbacks
        if groupId == "unknown" {
            return "Unknown Group"
        } else if groupId == "local" || groupId == "local-group" {
            return "Local"
        } else {
            return groupId.capitalized
        }
    }
    
    @ViewBuilder
    private func labelRow(_ label: ShoppingLabel) -> some View {
        HStack {
            Text(label.name)
            Spacer()
            Image(systemName: "tag.fill")
                .foregroundColor(Color(hex: label.color).adjusted(forBackground: Color(.systemBackground)))
        }
        .contextMenu {
                Button {
                    activeSheet = .edit(label)
                } label: {
                    Label("Edit...", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    selectedLabel = label
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete...", systemImage: "trash")
                }
            }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                selectedLabel = label
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button {
                activeSheet = .edit(label)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.accentColor)
        }
    }

    private func labelEditorSheet(for label: ShoppingLabel? = nil) -> some View {
        let vm = label == nil ? LabelEditorViewModel() : LabelEditorViewModel(from: label!)

        return LabelEditorView(
            viewModel: vm,
            availableGroups: availableGroups,
            availableLocalTokens: AppSettings.shared.tokens,
            onSaveRemote: { name, colorHex, groupId in
                Task {
                    if let label {
                        var updated = label
                        updated.name = name
                        updated.color = colorHex
                        updated.groupId = groupId
                        await viewModel.updateLabel(updated)
                    } else {
                        saveLabel(name: name, colorHex: colorHex, groupId: groupId)
                    }
                    await viewModel.loadLabels()
                    activeSheet = nil
                }
            },
            onSaveLocal: { name, colorHex, tokenId in
                Task {
                    if let label {
                        var updated = label
                        updated.name = name
                        updated.color = colorHex
                        updated.localTokenId = tokenId
                        try? await LocalShoppingListStore.shared.updateLabel(updated) // ← use `updateLabel`!
                    } else {
                        let newLabel = ShoppingLabel(
                            id: "local-\(UUID().uuidString)",
                            name: name,
                            color: colorHex,
                            groupId: "local-group",
                            localTokenId: tokenId
                        )
                        try? await LocalShoppingListStore.shared.saveLabel(newLabel)
                    }

                    await viewModel.loadLabels()
                    activeSheet = nil
                }
            },
            onCancel: {
                activeSheet = nil
            }
        )
    }

    private func saveLabel(name: String, colorHex: String, groupId: String) {
        if let tokenId = availableGroups.first(where: { $0.id == groupId })?.tokenId {
            Task {
                await viewModel.createLabel(name: name, color: colorHex, groupId: groupId, tokenId: tokenId)
                await viewModel.loadLabels()
                activeSheet = nil
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                // 🔹 Remote label sections, grouped by groupId
                ForEach(remoteGroupedLabels.sorted(by: { $0.key < $1.key }), id: \.key) { groupId, labels in
                    Section(header: Text(sectionTitle(for: groupId))) {
                        ForEach(labels.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })) { label in
                            labelRow(label)
                        }
                    }
                }

                // 🔸 Local labels section
                if !localLabels.isEmpty {
                    Section(header: Text("On This Device")) {
                        ForEach(localLabels.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })) { label in
                            labelRow(label)
                        }
                    }
                }
            }
            .navigationTitle("Label Manager")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        activeSheet = .new
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .new:
                    labelEditorSheet()
                case .edit(let label):
                    labelEditorSheet(for: label)
                }
            }
            .alert("Delete Label?", isPresented: $showingDeleteConfirmation, presenting: selectedLabel) { label in
                Button("Delete", role: .none) {
                    Task {
                        await viewModel.deleteLabel(label)
                        await viewModel.loadLabels()
                        selectedLabel = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { label in
                Text("Are you sure you want to delete the label \"\(label.name)\"?")
            }
            .task(id: viewModel.allLabels.count) {
                if viewModel.allLabels.isEmpty {
                    await viewModel.loadLabels()
                }
            }
        }
    }
}
