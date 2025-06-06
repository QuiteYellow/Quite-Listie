import SwiftUI
import SymbolPicker

struct NewShoppingListView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var icon: String = "checklist"
    @State private var iconPickerPresented = false

    // 🔹 Add Local/Remote picker
    enum ListStorageType: String, CaseIterable, Identifiable {
        case remote = "Save to Mealie"
        case local = "On This Device"

        var id: String { rawValue }
    }

    @State private var selectedStorage: ListStorageType = .remote

    struct HouseholdContext: Identifiable {
        let id: String // householdId
        let groupId: String
        let groupName: String
        let householdName: String
        let tokenInfo: TokenInfo
    }

    @State private var householdOptions: [HouseholdContext] = []
    @State private var selectedIndex = 0
    @State private var isSaving = false

    var onCreate: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Storage Location")) {
                    Picker("Storage", selection: $selectedStorage) {
                        ForEach(ListStorageType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Details")) {
                    HStack {
                        Label("Title", systemImage: "textformat")
                        Spacer()
                        TextField("Enter title", text: $name)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200)
                    }

                    HStack {
                        Label("Icon", systemImage: "square.grid.2x2")
                        Spacer()
                        Button {
                            iconPickerPresented = true
                        } label: {
                            Image(systemName: icon)
                                .imageScale(.large)
                                .foregroundColor(.accentColor)
                        }
                        .sheet(isPresented: $iconPickerPresented) {
                            SymbolPicker(symbol: $icon)
                        }
                    }

                    // 🔹 Only show account selection for remote lists
                    if selectedStorage == .remote {
                        HStack(alignment: .top) {
                            Label("Account", systemImage: "person.crop.circle")
                            Spacer()
                            if householdOptions.isEmpty {
                                Text("Loading...")
                                    .foregroundColor(.secondary)
                            } else {
                                Picker("", selection: $selectedIndex) {
                                    ForEach(householdOptions.indices, id: \.self) { i in
                                        let h = householdOptions[i]
                                        Text("\(h.tokenInfo.identifier) (\(h.tokenInfo.username ?? "Unknown"))")
                                            .tag(i)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 200)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New List")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createList() }
                    }
                    .disabled(name.isEmpty || (selectedStorage == .remote && householdOptions.isEmpty) || isSaving)
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                Task {
                    await loadHouseholds()
                }
            }
        }
    }

    private func loadHouseholds() async {
        householdOptions = AppSettings.shared.tokens.compactMap { token in
            guard
                let householdId = token.householdId,
                let householdSlug = token.householdSlug ?? token.household,
                let groupId = token.groupId,
                let groupSlug = token.groupSlug ?? token.group
            else {
                return nil
            }

            return HouseholdContext(
                id: householdId,
                groupId: groupId,
                groupName: groupSlug,
                householdName: householdSlug,
                tokenInfo: token
            )
        }
    }

    private func createList() async {
        isSaving = true
        defer { isSaving = false }

        let listId = selectedStorage == .local ? "local-\(UUID().uuidString)" : UUID().uuidString

        let newList = ShoppingListSummary(
            id: listId,
            name: name,
            localTokenId: selectedStorage == .local ? nil : householdOptions[selectedIndex].tokenInfo.id,
            groupId: selectedStorage == .local ? nil : householdOptions[selectedIndex].groupId,
            userId: nil,
            householdId: selectedStorage == .local ? nil : householdOptions[selectedIndex].id,
            extras: [
                "listsForMealieListIcon": icon
            ]
        )

        do {
            if selectedStorage == .local {
                try await LocalShoppingListStore.shared.createList(newList)
            } else {
                try await CombinedShoppingListProvider.shared.createList(newList)
            }
            onCreate()
            dismiss()
        } catch {
            print("❌ Failed to create list:", error.localizedDescription)
        }
    }
}
