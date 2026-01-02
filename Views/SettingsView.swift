//
//  SettingsView.swift
//  Listie-md
//
//  Created by Jack Nagy on 27/12/2025.
//


//
//  SettingsView.swift
//  Listie-md
//
//  Settings view for app preferences
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    
    @Binding var hideWelcomeList: Bool
    @Binding var hideQuickAdd: Bool

    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Show Welcome List", isOn: Binding(
                        get: { !hideWelcomeList },
                        set: { hideWelcomeList = !$0 }
                    ))
                    .toggleStyle(.switch)
                } header: {
                    Text("Getting Started")
                } footer: {
                    Text("The welcome list contains helpful information about using Listie.")
                }
                
                Section {
                    Toggle("Quick Add Items", isOn: Binding(
                        get: { !hideQuickAdd },
                        set: { hideQuickAdd = !$0 }
                    ))
                    .toggleStyle(.switch)
                } header: {
                    Text("List Items")
                } footer: {
                    Text("Show an inline '+ Add Item' button under each label for faster item creation.")
                }
                
                // Future settings sections can go here
                // Section {
                //     ...
                // } header: {
                //     Text("Display")
                // }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView(hideWelcomeList: .constant(false), hideQuickAdd: .constant(false))
}
