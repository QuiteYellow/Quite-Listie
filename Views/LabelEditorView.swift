import SwiftUI

struct LabelEditorView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: LabelEditorViewModel

    var availableGroups: [LabelManagerView.UserGroup]
    var availableLocalTokens: [TokenInfo]
    var onSaveRemote: (_ name: String, _ colorHex: String, _ groupId: String) -> Void
    var onSaveLocal: (_ name: String, _ colorHex: String, _ tokenId: UUID) -> Void
    var onCancel: () -> Void

    @ObservedObject var networkMonitor = NetworkMonitor()

    enum LabelStorageType: String, CaseIterable, Identifiable {
        case remote = "Save to Mealie"
        case local = "On This Device"
        var id: String { rawValue }
    }

    @State private var selectedStorage: LabelStorageType = .remote
    @State private var selectedLocalTokenId: UUID = AppSettings.shared.tokens.first(where: { $0.isLocal })?.id ?? UUID()

    private var shouldForceLocal: Bool {
        AppSettings.shared.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !networkMonitor.isConnected
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Storage Location") {
                    Picker("Storage", selection: $selectedStorage) {
                        Text(LabelStorageType.remote.rawValue).tag(LabelStorageType.remote)
                        Text(LabelStorageType.local.rawValue).tag(LabelStorageType.local)
                    }
                    .pickerStyle(.segmented)
                    .disabled(shouldForceLocal)
                }

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

                if selectedStorage == .remote {
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
            }

            .navigationTitle("Label")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = viewModel.name
                        let colorHex = viewModel.color.toHex()

                        switch selectedStorage {
                        case .remote:
                            guard let groupId = viewModel.groupId else { return }
                            onSaveRemote(name, colorHex, groupId)
                        case .local:
                            onSaveLocal(name, colorHex, selectedLocalTokenId)
                        }
                        dismiss()
                    }
                    .disabled({
                        let trimmedName = viewModel.name.trimmingCharacters(in: .whitespaces)
                        let isNameValid = !trimmedName.isEmpty
                        let isRemoteValid = selectedStorage == .remote ? (viewModel.groupId != nil) : true
                        return !isNameValid || !isRemoteValid
                    }())
                }
            }
            .onAppear {
                if shouldForceLocal {
                    selectedStorage = .local
                } else if selectedStorage == .remote && viewModel.groupId == nil {
                    viewModel.groupId = availableGroups.first?.id
                }
            }
            .onChange(of: networkMonitor.isConnected) {
                if shouldForceLocal {
                    selectedStorage = .local
                }
            }
            .onChange(of: AppSettings.shared.serverURLString) {
                if shouldForceLocal {
                    selectedStorage = .local
                }
            }
        }
    }
}
