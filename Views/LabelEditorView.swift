import SwiftUI

struct LabelEditorView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: LabelEditorViewModel

    var availableGroups: [LabelManagerView.UserGroup]
    var onSave: (_ name: String, _ colorHex: String, _ groupId: String) -> Void
    var onCancel: () -> Void 

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Label name", text: $viewModel.name)
                }

                Section("Color") {
                    ColorPicker("Pick a color", selection: $viewModel.color, supportsOpacity: false)
                }

                Section("Group") {
                    Picker("Group", selection: $viewModel.groupId) {
                        ForEach(availableGroups, id: \.id) { group in
                            Text(group.name.capitalized).tag(Optional(group.id))
                        }
                    }
                }
            }
            .navigationTitle("Label")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let groupId = viewModel.groupId else { return }
                        onSave(viewModel.name, viewModel.color.toHex(), groupId)
                        dismiss()
                    }
                    .disabled(!viewModel.isValid)
                }
            }
        }
    }
}
