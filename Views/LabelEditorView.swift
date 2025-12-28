//
//  LabelEditorView.swift (LOCAL-ONLY VERSION)
//  Listie.md
//
//  Simplified for local-only storage
//

import SwiftUI

struct LabelEditorView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: LabelEditorViewModel
    
    var onSave: (_ name: String, _ colorHex: String) -> Void
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
            }
            .navigationTitle(viewModel.isEditing ? "Edit Label" : "New Label")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {

                    Button {
                        onCancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .help("Cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = viewModel.name
                        let colorHex = viewModel.color.toHex()
                        onSave(name, colorHex)
                        dismiss()
                    }
                    .disabled(!viewModel.isNameValid)
                }
            }
        }
    }
}
