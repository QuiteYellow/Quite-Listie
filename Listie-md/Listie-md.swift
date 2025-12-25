//
//  Listie-md.swift (UPDATED WITH FILE SUPPORT)
//  ListsForMealie
//
//  Now supports opening .json shopping list files directly
//

import SwiftUI

@main
struct ShoppingListApp: App {
    @FocusedBinding(\.newListSheet) private var newListSheet: Bool?
    @FocusedBinding(\.fileImporter) private var fileImporter: Bool?
    @FocusedBinding(\.newConnectedExporter) private var newConnectedExporter: Bool?
    
    var body: some Scene {
        WindowGroup {
            WelcomeView()
                .onOpenURL { url in
                    // Handle opening JSON files from the system
                    Task {
                        do {
                            _ = try await ExternalFileStore.shared.openFile(at: url)
                            
                            // Post notification to update UI
                            NotificationCenter.default.post(
                                name: NSNotification.Name("ExternalFileOpened"),
                                object: url
                            )
                        } catch {
                            print("Failed to open external file: \(error)")
                        }
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New List (Private)") {
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
                
                Button("Open JSON File...") {
                    fileImporter = true
                }
                .keyboardShortcut("O", modifiers: .command)
                .disabled(fileImporter == nil)
            }
        }
    }
}
