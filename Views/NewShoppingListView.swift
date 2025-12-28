//
//  NewShoppingListView.swift (V2 - SIMPLIFIED)
//  Listie.md
//
//  Updated to use V2 format with clean IDs
//

import SwiftUI
import SymbolPicker

struct NewShoppingListView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var icon: String = "checklist"
    @State private var iconPickerPresented = false
    @State private var isSaving = false
    
    var onCreate: () -> Void
    
    var body: some View {
        NavigationView {
            Form {
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
                }
            }
            .navigationTitle("New List")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createList() }
                    }
                    .disabled(name.isEmpty || isSaving)
                }
                
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .help("Cancel")
                }
            }
        }
    }
    
    private func createList() async {
        isSaving = true
        defer { isSaving = false }
        
        // Use ModelHelpers to create a clean V2 list
        let newList = ModelHelpers.createNewList(name: name, icon: icon)
        
        do {
            try await LocalOnlyProvider.shared.createList(newList)
            onCreate()
            dismiss()
        } catch {
            print("❌ Failed to create list:", error.localizedDescription)
        }
    }
}
