import SwiftUI
import SymbolPicker

struct NewShoppingListView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var icon: String = "checklist"
    @State private var iconPickerPresented = false

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
    
    @State private var selectedGroupId: String?
    @State private var selectedHouseholdId: String?

    var onCreate: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("List Name")) {
                    TextField("Enter list name", text: $name)
                }

                Section(header: Text("Select Icon")) {
                    Button {
                        iconPickerPresented = true
                    } label: {
                        HStack {
                            Text("Choose icon")
                            Spacer()
                            Image(systemName: icon)
                                .imageScale(.large)
                        }
                    }
                    .sheet(isPresented: $iconPickerPresented) {
                        SymbolPicker(symbol: $icon)
                    }
                }

                Section(header: Text("Select Account")) {
                    if householdOptions.isEmpty {
                        Text("Loading accounts...")
                    } else {
                        Picker("Account", selection: $selectedIndex) {
                            ForEach(householdOptions.indices, id: \.self) { i in
                                let h = householdOptions[i]
                                Text("\(h.tokenInfo.identifier) (\(h.tokenInfo.username ?? "Unknown"))").tag(i)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New List")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await createList()
                        }
                    }
                    .disabled(name.isEmpty || householdOptions.isEmpty || isSaving)
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

        let selected = householdOptions[selectedIndex]

        let newList = ShoppingListSummary(
            id: UUID().uuidString,
            name: name,
            localTokenId: selected.tokenInfo.id,
            groupId: selected.groupId,
            userId: nil,
            householdId: selected.id,
            extras: [
                "listsForMealieListIcon": icon
            ]
        )

        do {
            try await ShoppingListAPI.shared.createShoppingList(newList)
            onCreate()
            dismiss()
        } catch {
            print("❌ Failed to create list:", error.localizedDescription)
        }
    }
}
