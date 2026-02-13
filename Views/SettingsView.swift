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
    @State private var iCloudSyncEnabled = true
    @State private var storageLocation = "Loading..."
    @State private var showICloudInfo = false

    var body: some View {
        NavigationView {
            Form {
                // MARK: - Storage Section
                Section {
                    
                    HStack {
                        Text("Sync with iCloud")
                        
                        Spacer()
                        
                        Button {
                            showICloudInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        
                        Toggle("", isOn: $iCloudSyncEnabled)
                            .toggleStyle(.switch)
                            .fixedSize()
                            .onChange(of: iCloudSyncEnabled) { _, newValue in
                                Task {
                                    await iCloudContainerManager.shared.setICloudSyncEnabled(newValue)
                                    await updateStorageLocation()
                                    NotificationCenter.default.post(name: .storageLocationChanged, object: nil)
                                }
                            }
                    }
                    


                    HStack {
                        Text("Storage Location")
                        Spacer()
                        Text(storageLocation)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Label("Storage", systemImage: "icloud")
                } footer: {
                    Text("When disabled, private lists are stored locally and won't sync across devices.")
                }
                .alert("iCloud Sync", isPresented: $showICloudInfo) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Your private lists are stored in your iCloud account and sync automatically across all your Apple devices. Disabling this will store lists only on this device.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
                        Text("Quick Add Items")
                        Spacer()
                        
                        Button {
                            showQuickAddInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        
                        Toggle("", isOn: Binding(
                            get: { !hideQuickAdd },
                            set: { hideQuickAdd = !$0 }
                        ))
                        .toggleStyle(.switch)
                        .fixedSize()
                        
                        
                    }
                    
                    HStack {
                        Text("Show Empty Labels")
                        
                        Spacer()
                        
                        Button {
                            showEmptyLabelsInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        
                        Toggle("", isOn: Binding(
                            get: { !hideEmptyLabels },
                            set: { hideEmptyLabels = !$0 }
                        ))
                        .toggleStyle(.switch)
                        .fixedSize()
                        
                        
                        
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
                
                // MARK: - Third-Party Libraries
                Section {
                    DisclosureGroup("Open Source Libraries") {
                        libraryRow(
                            name: "MarkdownView",
                            description: "Markdown rendering for SwiftUI",
                            url: "https://github.com/LiYanan2004/MarkdownView",
                            license: "MIT"
                        )
                        libraryRow(
                            name: "SymbolPicker",
                            description: "SF Symbols picker for SwiftUI",
                            url: "https://github.com/xnth97/SymbolPicker",
                            license: "MIT"
                        )
                    }
                } header: {
                    Label("Acknowledgements", systemImage: "heart")
                } footer: {
                    Text("Listie is built with these open source libraries. Thank you to their authors.")
                }
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
            .task {
                // Load iCloud sync state
                iCloudSyncEnabled = await iCloudContainerManager.shared.isICloudSyncEnabled()
                await updateStorageLocation()
            }
        }
    }

    private func updateStorageLocation() async {
        storageLocation = await iCloudContainerManager.shared.getStorageLocationDescription()
    }

    @ViewBuilder
    private func libraryRow(name: String, description: String, url: String, license: String) -> some View {
        if let link = URL(string: url) {
            Link(destination: link) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(name)
                            .fontWeight(.medium)
                        Spacer()
                        Text(license)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
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
