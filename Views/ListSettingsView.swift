import SwiftUI
import SymbolPicker

struct ListSettingsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var name: String
    @State private var iconPickerPresented = false
    @State private var icon = "pencil"

    let onSave: (String, String) -> Void // pass name and emoji

    init(list: ShoppingListSummary, onSave: @escaping (String, String) -> Void) {
        _name = State(initialValue: list.name)
        _icon = State(initialValue: list.extras?["listsForMealieListIcon"] ?? "") // get from extras if exists
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("List Name")) {
                    TextField("Name", text: $name)
                }
                Section(header: Text("Select Icon")) {
                    Button {
                            iconPickerPresented = true
                        } label: {
                            HStack {
                                Image(systemName: icon)
                                Text(icon)
                            }
                        }
                        .sheet(isPresented: $iconPickerPresented) {
                            SymbolPicker(symbol: $icon)
                        }
                }
            }
            .navigationTitle("List Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, icon)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
