//
//  LabelEditorView.swift (LOCAL-ONLY VERSION)
//  Listie.md
//
//  Simplified for local-only storage
//

import SwiftUI
import SymbolPicker

struct LabelEditorView: View {
    @Environment(\.dismiss) var dismiss
    @Bindable var viewModel: LabelEditorViewModel

    var onSave: (_ name: String, _ colorHex: String, _ symbol: String?) -> Void
    var onCancel: () -> Void

    @State private var showingSymbolPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Label name", text: $viewModel.name)
                }

                Section(
                    header: Text("Map Icon"),
                    footer: Text("Shown on the map pin instead of the default icon.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                ) {
                    Button {
                        showingSymbolPicker = true
                    } label: {
                        HStack {
                            Text("Icon")
                                .foregroundStyle(.primary)
                            Spacer()
                            if let symbol = viewModel.symbol {
                                Image(systemName: symbol)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("None")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .sheet(isPresented: $showingSymbolPicker) {
                        SymbolPicker(symbol: $viewModel.symbol)
                    }

                    if viewModel.symbol != nil {
                        Button("Remove Icon", role: .destructive) {
                            viewModel.symbol = nil
                        }
                    }
                }

                Section(
                    header: Text("Color"),
                    footer: Text("For better visibility, colors adapt automatically to the background.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                        onSave(viewModel.name, viewModel.color.toHex(), viewModel.symbol)
                        dismiss()
                    }
                    .disabled(!viewModel.isNameValid)
                }
            }
        }
    }
}
