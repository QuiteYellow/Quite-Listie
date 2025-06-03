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

                Section(
                    header: Text("Color"),
                    footer: Text("For better visibility, colors adapt automatically to the background.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                ) {
                    HStack {
                            ColorPicker("Pick a color...", selection: $viewModel.color, supportsOpacity: false)
                            Spacer()
                            Button {
                                viewModel.color = Color.random()
                            } label: {
                                Image(systemName: "shuffle")
                            }
                            .buttonStyle(.plain)
                            .help("Pick a random color")
                        }
                }

                Section("Group") {
                    Picker("Group", selection: Binding(
                        get: { viewModel.groupId ?? availableGroups.first?.id },
                        set: { viewModel.groupId = $0 }
                    )) {
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
