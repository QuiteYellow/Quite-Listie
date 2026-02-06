//
//  Listie-md.swift (UPDATED WITH FILE SUPPORT)
//  Listie.md
//
//  Now supports opening .json shopping list files directly and export commands
//

import SwiftUI


@main
struct ShoppingListApp: App {
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
