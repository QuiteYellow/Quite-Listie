//
//  Listie-md.swift (UPDATED WITH FILE SUPPORT)
//  Listie.md
//
//  Now supports opening .json shopping list files directly and export commands
//

import os
import SwiftUI
import UserNotifications


// MARK: - App Delegate for Notification Handling

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ReminderManager.registerCategory()
        BackgroundRefreshManager.register()
        Task { await EventKitManager.shared.restoreState() }
        return true
    }

    /// Called when a notification is tapped or an action button is pressed
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let listId = userInfo["listId"] as? String
        let itemId = userInfo["itemId"] as? String

        if response.actionIdentifier == ReminderManager.completeActionIdentifier,
           let listId, let itemId {
            // "Complete" action — mark the item done in the background
            let scheduledDate = userInfo["scheduledDate"] as? TimeInterval
            Task {
                await ReminderManager.completeItemFromNotification(itemId: itemId, listId: listId, scheduledDate: scheduledDate)
                // Post so UI refreshes if visible
                NotificationCenter.default.post(
                    name: .reminderCompleted,
                    object: nil,
                    userInfo: ["listId": listId, "itemId": itemId]
                )
            }
        } else if let listId, let itemId {
            // Default tap — navigate to the list
            NotificationCenter.default.post(
                name: .reminderTapped,
                object: nil,
                userInfo: ["listId": listId, "itemId": itemId]
            )
        }
        completionHandler()
    }

    /// Show notifications even when the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

extension Notification.Name {
    static let reminderTapped = Notification.Name("reminderTapped")
    static let reminderCompleted = Notification.Name("reminderCompleted")
}

@main
struct ShoppingListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @FocusedBinding(\.newListSheet) private var newListSheet: Bool?
    @FocusedBinding(\.fileImporter) private var fileImporter: Bool?
    @FocusedBinding(\.newConnectedExporter) private var newConnectedExporter: Bool?
    @FocusedBinding(\.exportMarkdown) private var exportMarkdown: Bool?
    @FocusedBinding(\.exportJSON) private var exportJSON: Bool?
    @FocusedBinding(\.shareLink) private var shareLink: Bool?
    @FocusedValue(\.isReadOnly) private var isReadOnly: Bool?
    @FocusedBinding(\.settingsSheet) private var settingsSheet: Bool?
    @FocusedBinding(\.nextcloudBrowser) private var nextcloudBrowser: Bool?

    var body: some Scene {
        WindowGroup(id: "main") {
            WelcomeView()
                .onAppear {
#if targetEnvironment(macCatalyst)
                    configureMacWindow()
#endif
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    settingsSheet = true
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(settingsSheet == nil)
            }

            CommandGroup(replacing: .newItem) {
                Button {
                    openWindow(id: "main")
                } label: {
                    Label("New Window", systemImage: "macwindow.badge.plus")
                }
                .keyboardShortcut("N", modifiers: [.command, .option])

                Divider()

                Menu("New List...") {
                    Button {
                        newListSheet = true
                    } label: {
                        Label("New Private List...", systemImage: "doc.badge.plus")
                    }
                    .keyboardShortcut("N", modifiers: .command)
                    .disabled(newListSheet == nil)

                    Button {
                        newConnectedExporter = true
                    } label: {
                        Label("New List in Files...", systemImage: "doc.badge.plus")
                    }
                    .keyboardShortcut("N", modifiers: [.command, .shift])
                    .disabled(newConnectedExporter == nil)

                    Button {
                        nextcloudBrowser = true
                    } label: {
                        Label("New List in Nextcloud...", systemImage: "cloud")
                    }
                    .disabled(nextcloudBrowser == nil)
                }

                Divider()

                Menu("Open List...") {
                    Button {
                        fileImporter = true
                    } label: {
                        Label("Open from Files...", systemImage: "folder.badge.plus")
                    }
                    .keyboardShortcut("O", modifiers: .command)
                    .disabled(fileImporter == nil)

                    Button {
                        nextcloudBrowser = true
                    } label: {
                        Label("Open from Nextcloud...", systemImage: "cloud")
                    }
                    .keyboardShortcut("O", modifiers: [.command, .shift])
                    .disabled(nextcloudBrowser == nil)
                }

                Divider()
            }
            
            CommandGroup(before: .saveItem) {
                Divider()
                
                // Export submenu under File - keep menu enabled, disable items instead
                Menu("Export As...") {
                    Button("Markdown...") {
                        exportMarkdown = true
                    }
                    .keyboardShortcut("E", modifiers: .command)
                    .disabled(exportMarkdown == nil || isReadOnly == true)

                    Button("Share Link...") {
                        shareLink = true
                    }
                    .keyboardShortcut("L", modifiers: [.command, .shift])
                    .disabled(shareLink == nil || isReadOnly == true)

                    Divider()

                    Button("Quite Listie File...") {
                        exportJSON = true
                    }
                    .keyboardShortcut("E", modifiers: [.command, .shift])
                    .disabled(exportJSON == nil || isReadOnly == true)
                }
            }
        }
    }
#if targetEnvironment(macCatalyst)
    func configureMacWindow() {
        // Get the first UIWindowScene
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let titlebar = windowScene.titlebar else { return }
        
        AppLogger.ui.info("[Catalyst] Configuring window titlebar")
        
        // Hide the window title
        titlebar.titleVisibility = .hidden
        
        // Use expanded unified toolbar style
        titlebar.toolbarStyle = .expanded
        
    }
#endif // targetEnvironment(macCatalyst)
    
    
}
