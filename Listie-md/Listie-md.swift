//
//  Listie-md.swift (UPDATED WITH FILE SUPPORT)
//  ListsForMealie
//
//  Now supports opening .json shopping list files directly
//

import SwiftUI

@main
struct ShoppingListApp: App {
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
                Button("New List") {
                    NotificationCenter.default.post(name: NSNotification.Name("CreateNewList"), object: nil)
                }
                .keyboardShortcut("N", modifiers: .command)
                
                Button("Open JSON File...") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenJSONFile"), object: nil)
                }
                .keyboardShortcut("O", modifiers: .command)
            }
        }
    }
}
