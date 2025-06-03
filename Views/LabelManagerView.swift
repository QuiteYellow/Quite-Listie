import SwiftUI

struct LabelManagerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: LabelManagerViewModel

    @State private var selectedLabel: ShoppingLabel? = nil
    @State private var showingDeleteConfirmation = false
    
    @State private var editorLabel: ShoppingLabel? = nil
    @State private var isCreatingNewLabel = false

    struct UserGroup: Identifiable, Hashable {
        let id: String
        let name: String
        let tokenId: UUID
    }

    // MARK: - Derived Properties

    private var groupedLabels: [String: [ShoppingLabel]] {
        Dictionary(grouping: viewModel.allLabels) { $0.groupId}
    }

    private var availableGroups: [UserGroup] {
        AppSettings.shared.tokens
            .compactMap { token in
                guard let groupId = token.groupId else { return nil }
                return UserGroup(id: groupId, name: token.group ?? token.identifier, tokenId: token.id)
            }
            .uniqueBy(\.id)
    }
    
    private func labelEditorSheet(for label: ShoppingLabel? = nil) -> some View {
        let vm = label == nil ? LabelEditorViewModel() : LabelEditorViewModel(from: label!)
        
        return LabelEditorView(
            viewModel: vm,
            availableGroups: availableGroups,
            onSave: { name, colorHex, groupId in
                Task {
                    if let label {
                        // Edit
                        var updated = label
                        updated.name = name
                        updated.color = colorHex
                        updated.groupId = groupId
                        await viewModel.updateLabel(updated)
                    } else {
                        // New
                        saveLabel(name: name, colorHex: colorHex, groupId: groupId)
                    }
                    await viewModel.loadLabels()
                    editorLabel = nil
                    isCreatingNewLabel = false
                }
            },
            onCancel: {
                editorLabel = nil
                isCreatingNewLabel = false
            }
        )
    }
    private func saveLabel(name: String, colorHex: String, groupId: String) {
        if let tokenId = availableGroups.first(where: { $0.id == groupId })?.tokenId {
            Task {
                await viewModel.createLabel(name: name, color: colorHex, groupId: groupId, tokenId: tokenId)
                await viewModel.loadLabels()
                isCreatingNewLabel = false
            }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            List {
                ForEach(groupedLabels.sorted(by: { $0.key < $1.key }), id: \.key) { groupId, labels in
                    Section(header: Text(sectionTitle(for: groupId))) {
                        ForEach(labels.sorted {
                            $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }) { label in
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
                            isCreatingNewLabel = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
            }
            .sheet(isPresented: $isCreatingNewLabel) {
                labelEditorSheet()
            }
            .sheet(item: $editorLabel) { label in
                labelEditorSheet(for: label)
            }
            .alert("Delete Label?", isPresented: $showingDeleteConfirmation, presenting: selectedLabel) { label in
                Button("Delete", role: .destructive) {
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
        }
        .task {
            await viewModel.loadLabels()
        }
    }

    // MARK: - Helpers

    private func sectionTitle(for groupId: String) -> String {
        let groupName = availableGroups.first(where: { $0.id == groupId })?.name.capitalized ?? "Unknown"
        let tokens = AppSettings.shared.tokens.filter { $0.groupId == groupId }
        let identifiers = tokens.map(\.identifier).sorted().joined(separator: ", ")
        return identifiers.isEmpty ? groupName : "\(groupName) (\(identifiers))"
    }

    private func labelRow(_ label: ShoppingLabel) -> some View {
        HStack {
            Text(label.name)
            Spacer()
            Image(systemName: "tag.fill")
                .foregroundColor(Color(hex: label.color).adjusted(forBackground: Color(.systemBackground)))
        }
        .swipeActions(edge: .trailing) {
            Button(role: .none) {
                selectedLabel = label
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        
        }
        .swipeActions(edge: .leading) {
            Button {
                editorLabel = label
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.accentColor)
        }
    }
}
