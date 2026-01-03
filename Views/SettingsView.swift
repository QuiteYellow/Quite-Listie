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
    @Binding var hideEmptyLabels: Bool

    @State private var showQuickAddInfo = false
    @State private var showEmptyLabelsInfo = false
    
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
                    HStack {
                        Toggle("Quick Add Items", isOn: Binding(
                            get: { !hideQuickAdd },
                            set: { hideQuickAdd = !$0 }
                        ))
                        .toggleStyle(.switch)
                        
                        Button {
                            showQuickAddInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.glass)
                    }
                    
                    HStack {
                        Toggle("Show Empty Labels", isOn: Binding(
                            get: { !hideEmptyLabels },
                            set: { hideEmptyLabels = !$0 }
                        ))
                        .toggleStyle(.switch)
                        
                        Button {
                            showEmptyLabelsInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.glass)
                    }
                } header: {
                    Text("Lists & Labels")
                }
                .alert("Quick Add Items", isPresented: $showQuickAddInfo) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Shows an inline '+ Add Item' button under each label for faster item creation.")
                }
                .alert("Show Empty Labels", isPresented: $showEmptyLabelsInfo) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Displays all labels even when they have no items, making it easy to add items to any category.")
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
    SettingsView(
        hideWelcomeList: .constant(false),
        hideQuickAdd: .constant(false),
        hideEmptyLabels: .constant(false)
    )
}
