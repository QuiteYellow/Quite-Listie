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

    @AppStorage("kanbanColumnWidth") private var kanbanColumnWidth = "normal"
    @AppStorage("navShowAppleMaps") private var navShowAppleMaps: Bool = true
    @AppStorage("navShowGoogleMaps") private var navShowGoogleMaps: Bool = true
    @AppStorage("navShowTomTomGo") private var navShowTomTomGo: Bool = true
    @AppStorage("mapStyleMuted") private var mapStyleMuted: Bool = true

    @State private var showQuickAddInfo = false
    @State private var showEmptyLabelsInfo = false
    @State private var showKanbanWidthInfo = false
    @State private var iCloudSyncEnabled = true
    @State private var storageLocation = "Loading..."
    @State private var showICloudInfo = false

    @Bindable private var ekManager = EventKitManager.shared

    // Nextcloud
    @State private var nextcloudCredentials: NextcloudCredentials? = nil
    @State private var showNextcloudSetup = false
    @State private var showNextcloudDisconnectConfirm = false

    var body: some View {
        NavigationStack {
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
                                .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
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

                // MARK: - Nextcloud Section
                Section {
                    if let creds = nextcloudCredentials {
                        LabeledContent("Account") {
                            Text(creds.accountId)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Button("Disconnect", role: .destructive) {
                            showNextcloudDisconnectConfirm = true
                        }
                    } else {
                        Button("Connect to Nextcloud") {
                            showNextcloudSetup = true
                        }
                    }
                } header: {
                    Label("Nextcloud", systemImage: "cloud")
                } footer: {
                    if nextcloudCredentials != nil {
                        Text("Connected. Open files from Nextcloud using the button in the sidebar.")
                    } else {
                        Text("Connect to a Nextcloud server to open and sync lists stored there.")
                    }
                }

                // MARK: - System Calendar Section
                Section {
                    Toggle("Add to System Calendar", isOn: $ekManager.isEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: ekManager.isEnabled) { _, enabled in
                            if enabled {
                                Task { await EventKitManager.shared.requestAccessAndEnable() }
                            } else {
                                EventKitManager.shared.disable()
                            }
                        }

                    if ekManager.isEnabled {
                        if ekManager.isCalendarAccessGranted {
                            Label("Writing to 'Listie Schedule' calendar", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)

                            if ekManager.availableSources.count > 1 {
                                Picker("Account", selection: Binding(
                                    get: { ekManager.selectedSourceId ?? "" },
                                    set: { newId in
                                        EventKitManager.shared.changeSource(to: newId)
                                    }
                                )) {
                                    ForEach(ekManager.availableSources, id: \.sourceIdentifier) { source in
                                        Text(source.title).tag(source.sourceIdentifier)
                                    }
                                }
                                .pickerStyle(.menu)
                            } else if let source = ekManager.availableSources.first {
                                LabeledContent("Account") {
                                    Text(source.title)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if ekManager.isCalendarAccessDenied {
                            Label("Calendar access denied", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Button("Open Settings") {
                                #if targetEnvironment(macCatalyst)
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                    UIApplication.shared.open(url)
                                }
                                #else
                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                                #endif
                            }
                        }
                    }
                } header: {
                    Label("Calendar", systemImage: "calendar")
                } footer: {
                    Text("Reminder items are added to a 'Listie Schedule' calendar in Calendar.app. Share that calendar to subscribe from any device — the sharing URL works on iOS, Mac, and Google Calendar.")
                }

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
                    Toggle("Muted Map Style", isOn: $mapStyleMuted)
                    DisclosureGroup("Navigation Buttons") {
                        Toggle("Apple Maps", isOn: $navShowAppleMaps)
                        Toggle("Google Maps", isOn: $navShowGoogleMaps)
                        #if !targetEnvironment(macCatalyst)
                        Toggle("TomTom Go", isOn: $navShowTomTomGo)
                        #endif
                    }
                } header: {
                    Label("Navigation", systemImage: "map")
                } footer: {
                    Text("Muted style de-emphasises the map background so your pins stand out. Choose which navigation apps appear on items with a pinned location.")
                }

                Section {
                    HStack {
                        Text("Quick Add Items")
                        Spacer()

                        Button {
                            showQuickAddInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        Toggle("", isOn: Binding(
                            get: { !hideEmptyLabels },
                            set: { hideEmptyLabels = !$0 }
                        ))
                        .toggleStyle(.switch)
                        .fixedSize()



                    }

                    HStack {
                        Text("Kanban Column Width")

                        Spacer()

                        Button {
                            showKanbanWidthInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        Picker("", selection: $kanbanColumnWidth) {
                            Text("Narrow").tag("narrow")
                            Text("Normal").tag("normal")
                            Text("Wide").tag("wide")
                        }
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
                .alert("Kanban Column Width", isPresented: $showKanbanWidthInfo) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Sets the width of columns in kanban board view. On narrow screens (such as iPhone), columns always use the narrow width.")
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
                        libraryRow(
                            name: "NextcloudKit",
                            description: "Nextcloud API client for Swift",
                            url: "https://github.com/nextcloud/NextcloudKit",
                            license: "LGPL-3.0"
                        )
                    }
                } header: {
                    Label("Acknowledgements", systemImage: "heart")
                } footer: {
                    Text("Quite Listie is built with these open source libraries. Thank you to their authors.")
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
                // Load Nextcloud credentials
                nextcloudCredentials = NextcloudCredentials.load()
            }
            .sheet(isPresented: $showNextcloudSetup) {
                NextcloudSetupView { newCreds in
                    nextcloudCredentials = newCreds
                }
            }
            .confirmationDialog("Disconnect from Nextcloud?", isPresented: $showNextcloudDisconnectConfirm, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    Task {
                        NextcloudCredentials.delete()
                        await NextcloudManager.shared.disconnect()
                        nextcloudCredentials = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your Nextcloud credentials will be removed. Lists opened from Nextcloud will be removed from the sidebar, but files on the server will not be deleted.")
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
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
