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
    
    
    @State private var isFavourited: Bool = false
    var userID: String {
        AppSettings.shared.tokens
            .first(where: { $0.id == list.localTokenId && !($0.username ?? "").isEmpty })?
            .username ?? "local"
    }
    
    enum ListStorageType: String {
        case remote = "Saved to Mealie"
        case local = "On This Device"
    }
    
    var storageType: ListStorageType {
        list.isLocal ? .local : .remote
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Details")) {
                    // Name row with icon
                    HStack {
                        Label("Title", systemImage: "textformat")
                        Spacer()
                        TextField("Enter title", text: $name)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 400)
                            //.textFieldStyle(.roundedBorder)
                    }

                    // Icon picker row with icon
                    
                        HStack {
                            Label("Icon", systemImage: "square.grid.2x2")
                            Spacer()
                            Button {
                                iconPickerPresented = true
                            } label: {
                            Image(systemName: icon)
                                .imageScale(.large)
                                //.foregroundColor(.accentColor)
                        }
                    }
                    
                    .sheet(isPresented: $iconPickerPresented) {
                        SymbolPicker(symbol: $icon)
                    }

                    // Favourite toggle row with icon
                    Toggle(isOn: $isFavourited) {
                        Label("Mark as Favourite", systemImage: "star.fill")
                            
                    }
                    Label {
                            Text(storageType.rawValue)
                        } icon: {
                            Image(systemName: storageType == .local ? "internaldrive" : "icloud")
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
                        var extras = [
                            "listsForMealieListIcon": icon,
                            "hiddenLabels": hiddenLabelIDs.joined(separator: ",")
                        ]
                        
                        // Handle favourites logic
                        var favourites = list.extras?["favouritedBy"]?.components(separatedBy: ",").filter { !$0.isEmpty } ?? []
                        if isFavourited {
                            if !favourites.contains(userID) {
                                favourites.append(userID)
                            }
                        } else {
                            favourites.removeAll { $0 == userID }
                        }
                        extras["favouritedBy"] = favourites.joined(separator: ",")

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
            icon = list.extras?["listsForMealieListIcon"].flatMap { $0.isEmpty ? nil : $0 } ?? "checklist"

            // Extract hidden label IDs
            if let hidden = list.extras?["hiddenLabels"] {
                hiddenLabelIDs = Set(hidden.components(separatedBy: ","))
            }

            // Load initial favourite state
            if let favs = list.extras?["favouritedBy"]?.components(separatedBy: ",") {
                isFavourited = favs.contains(userID)
            }

            // Load labels
            Task {
                do {
                    allLabels = try await CombinedShoppingListProvider.shared.fetchLabels(for: list)
                } catch {
                    print("Failed to load labels: \(error)")
                }
            }
        }
    }
}
