import SwiftUI
import SymbolPicker

struct ListSettingsView: View {
    let list: ShoppingListSummary
    let onSave: (String, String) -> Void
    
    @Environment(\.dismiss) var dismiss
    @State private var name: String = ""
    @State private var icon: String = "pencil"
    @State private var iconPickerPresented = false

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
        .onAppear {
            name = list.name
            icon = list.extras?["listsForMealieListIcon"] ?? ""
        }
    }
}
