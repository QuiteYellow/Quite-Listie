import SwiftUI
import SymbolPicker

struct ListSettingsView: View {
    @State private var allLabels: [ShoppingLabel] = []
    @State private var hiddenLabelIDs: Set<String> = []
    let list: ShoppingListSummary
    let onSave: (String, [String: String]) -> Void
    
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
                                Text("Choose an icon...")
                                Spacer()
                                Image(systemName: icon)
                                    .imageScale(.large)
                            }
                        }
                        .sheet(isPresented: $iconPickerPresented) {
                            SymbolPicker(symbol: $icon)
                        }
                }
                Section(header: Text("Shown Labels")) {
                    if allLabels.isEmpty {
                        Text("Loading labels...")
                    } else {
                        ForEach(allLabels.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }), id: \.id) { label in
                            let isShown = !hiddenLabelIDs.contains(label.id)
                            
                            Toggle(isOn: Binding(
                                get: { isShown },
                                set: { newValue in
                                    if newValue {
                                        hiddenLabelIDs.remove(label.id)
                                    } else {
                                        hiddenLabelIDs.insert(label.id)
                                    }
                                }
                            )) {
                                Text(label.name)
                                    .foregroundColor(isShown ? .primary : .gray)
                                    .strikethrough(!isShown, color: .gray)
                            }
                        }
                    }
                }
            }
            .navigationTitle("List Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let extras = [
                                "listsForMealieListIcon": icon,
                                "hiddenLabels": hiddenLabelIDs.joined(separator: ",")
                            ]
                        onSave(name, extras)
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

            // Extract hidden label IDs from extras
            if let hidden = list.extras?["hiddenLabels"] {
                //print("HIDDEN: \(hidden)")
                hiddenLabelIDs = Set(hidden.components(separatedBy: ","))
            }

            Task {
                do {
                    let all = try await ShoppingListAPI.shared.fetchShoppingLabels()
                    if let groupId = list.groupId {
                        allLabels = all.filter { $0.groupId == groupId }
                    } else if let localTokenId = list.localTokenId {
                        allLabels = all.filter { $0.localTokenId == localTokenId }
                    } else {
                        allLabels = all
                    }
                } catch {
                    print("Failed to load labels: \(error)")
                }
            }
        }
    }
}
