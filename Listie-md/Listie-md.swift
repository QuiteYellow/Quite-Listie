//
//  Listie-md.swift (UPDATED WITH FILE SUPPORT)
//  Listie.md
//
//  Now supports opening .json shopping list files directly and export commands
//

import SwiftUI
import UserNotifications


// MARK: - App Delegate for Notification Handling

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Called when a notification is tapped — post a notification so the UI can navigate
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let listId = userInfo["listId"] as? String,
           let itemId = userInfo["itemId"] as? String {
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
}

@main
struct ShoppingListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedBinding(\.newListSheet) private var newListSheet: Bool?
    @FocusedBinding(\.fileImporter) private var fileImporter: Bool?
    @FocusedBinding(\.newConnectedExporter) private var newConnectedExporter: Bool?
    @FocusedBinding(\.exportMarkdown) private var exportMarkdown: Bool?
    @FocusedBinding(\.exportJSON) private var exportJSON: Bool?
    @FocusedBinding(\.shareLink) private var shareLink: Bool?
    @FocusedValue(\.isReadOnly) private var isReadOnly: Bool?
    
    var body: some Scene {
        WindowGroup {
            WelcomeView()
                .onAppear {
#if targetEnvironment(macCatalyst)
                    configureMacWindow()
#endif
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Private List...") {
                    newListSheet = true
                }
                .keyboardShortcut("N", modifiers: .command)
                .disabled(newListSheet == nil)
                
                Button("New List As File...") {
                    newConnectedExporter = true
                }
                .keyboardShortcut("N", modifiers: [.command, .shift])
                .disabled(newConnectedExporter == nil)
                
                Divider()
                
                Button("Open File...") {
                    fileImporter = true
                }
                .keyboardShortcut("O", modifiers: .command)
                .disabled(fileImporter == nil)
                
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

                    Button("Listie File...") {
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
        
        print("✅ [Catalyst] Configuring window titlebar")
        
        // Hide the window title
        titlebar.titleVisibility = .hidden
        
        // Use expanded unified toolbar style
        titlebar.toolbarStyle = .expanded
        
    }
#endif // targetEnvironment(macCatalyst)
    
    
}
