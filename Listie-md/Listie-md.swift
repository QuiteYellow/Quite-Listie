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
    @FocusedValue(\.isReadOnly) private var isReadOnly: Bool?
    
    var body: some Scene {
        WindowGroup {
            WelcomeView()
                .onOpenURL { url in
                    print("📱 [Deeplink] Received URL: \(url)")
                    
                    // Handle external JSON files (existing)
                    if url.pathExtension == "json" {
                        print("📄 [Deeplink] Detected JSON file, posting OpenExternalFile notification")
                        NotificationCenter.default.post(
                            name: NSNotification.Name("OpenExternalFile"),
                            object: url
                        )
                    }
                    // Handle deeplink imports
                    else if url.scheme == "listie" {
                        print("🔗 [Deeplink] Detected listie:// URL scheme")
                        print("   Host: \(url.host ?? "nil")")
                        print("   Path: \(url.path)")
                        
                        if url.host == "import" {
                            print("📥 [Deeplink] Import action detected")
                            
                            // Parse query parameters
                            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
                                print("❌ [Deeplink] Failed to create URLComponents")
                                return
                            }
                            
                            print("   Query items: \(components.queryItems?.count ?? 0)")
                            
                            guard let queryItems = components.queryItems else {
                                print("❌ [Deeplink] No query items found")
                                return
                            }
                            
                            var listId: String?
                            var markdown: String?
                            var shouldPreview = false
                            
                            for item in queryItems {
                                print("   📋 Query param: \(item.name)")
                                
                                switch item.name {
                                case "list":
                                    listId = item.value
                                    print("      ✓ List ID: \(listId ?? "nil")")
                                case "markdown":
                                    // Decode from base64
                                    if let base64String = item.value,
                                       let data = Data(base64Encoded: base64String),
                                       let decoded = String(data: data, encoding: .utf8) {
                                        markdown = decoded
                                        print("      ✓ Markdown decoded: \(markdown?.count ?? 0) chars")
                                        print("      ✓ Preview: \(markdown?.prefix(100) ?? "")...")
                                    } else {
                                        print("      ❌ Failed to decode base64 markdown")
                                        // Post error notification
                                        NotificationCenter.default.post(
                                            name: NSNotification.Name("ImportMarkdownDeeplink"),
                                            object: nil,
                                            userInfo: [
                                                "error": "Failed to decode markdown parameter. The markdown must be base64 encoded."
                                            ]
                                        )
                                        return  // Stop processing
                                    }
                                case "preview":
                                    shouldPreview = item.value == "true"
                                    print("      ✓ Auto-preview: \(shouldPreview)")
                                default:
                                    print("      ⚠️ Unknown param: \(item.name)")
                                }
                            }
                            
                            // Check if we have all required parameters
                            if let markdown = markdown, let listId = listId {
                                print("✅ [Deeplink] Valid import request, posting notification")
                                print("   List ID: \(listId)")
                                print("   Auto-preview: \(shouldPreview)")
                                
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("ImportMarkdownDeeplink"),
                                    object: nil,
                                    userInfo: [
                                        "markdown": markdown,
                                        "listId": listId,
                                        "preview": shouldPreview
                                    ]
                                )
                            } else {
                                print("❌ [Deeplink] Missing required parameters")
                                var errorMsg = "Missing required parameters:\n"
                                if listId == nil {
                                    errorMsg += "- list (required)\n"
                                }
                                if markdown == nil {
                                    errorMsg += "- markdown (required, must be base64 encoded)\n"
                                }
                                
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("ImportMarkdownDeeplink"),
                                    object: nil,
                                    userInfo: [
                                        "error": errorMsg
                                    ]
                                )
                            }
                        } else {
                            print("⚠️ [Deeplink] Unknown host: \(url.host ?? "nil")")
                        }
                    } else {
                        print("⚠️ [Deeplink] Unhandled URL scheme: \(url.scheme ?? "nil")")
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
                    
                    Button("JSON (Backup)...") {
                        exportJSON = true
                    }
                    .keyboardShortcut("E", modifiers: [.command, .shift])
                    .disabled(exportJSON == nil || isReadOnly == true)
                }
            }
        }
    }
}
