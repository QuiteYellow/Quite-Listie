//
//  DeeplinkCoordinator.swift
//  Listie-md
//
//  Created by Jack Nagy on 02/01/2026.
//


import Foundation
import SwiftUI

@MainActor
class DeeplinkCoordinator: ObservableObject {
    @Published var fileToOpen: URL?
    @Published var markdownImport: MarkdownImportRequest?
    @Published var errorMessage: String?
    @Published var showError = false
    
    struct MarkdownImportRequest: Identifiable, Equatable {
        let id = UUID()
        let markdown: String
        let listId: String
        let shouldPreview: Bool
    }
    
    func handle(_ url: URL, provider: UnifiedListProvider) async {
        print("📱 [Deeplink] Received URL: \(url)")
        
        // Handle external JSON files
        if url.pathExtension == "listie" || url.pathExtension == "json" {
            print("📄 [Deeplink] Detected file")
            fileToOpen = url
            return
        }
        
        // Handle listie:// scheme
        guard url.scheme == "listie" else {
            print("⚠️ [Deeplink] Unhandled URL scheme: \(url.scheme ?? "nil")")
            return
        }
        
        if url.host == "import" {
            await handleMarkdownImport(url, provider: provider)
        } else {
            print("⚠️ [Deeplink] Unknown host: \(url.host ?? "nil")")
        }
    }
    
    private func handleMarkdownImport(_ url: URL, provider: UnifiedListProvider) async {
        print("📥 [Deeplink] Import action detected")
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems else {
            showErrorAlert("Invalid import URL")
            return
        }
        
        var listId: String?
        var markdown: String?
        var shouldPreview = false
        
        for item in queryItems {
            switch item.name {
            case "list":
                listId = item.value
            case "markdown":
                if let base64String = item.value,
                   let data = Data(base64Encoded: base64String),
                   let decoded = String(data: data, encoding: .utf8) {
                    markdown = decoded
                } else {
                    showErrorAlert("Failed to decode markdown parameter. The markdown must be base64 encoded.")
                    return
                }
            case "preview":
                shouldPreview = item.value == "true"
            default:
                break
            }
        }
        
        guard let markdown = markdown, let listId = listId else {
            var errorMsg = "Missing required parameters:\n"
            if listId == nil { errorMsg += "- list (required)\n" }
            if markdown == nil { errorMsg += "- markdown (required, must be base64 encoded)\n" }
            showErrorAlert(errorMsg)
            return
        }
        
        // Wait for lists to load if needed
        if provider.allLists.isEmpty {
            await provider.loadAllLists()
        }
        
        // Find target list
        guard let _ = provider.allLists.first(where: { list in
            list.id == listId || list.originalFileId == listId
        }) else {
            let availableIDs = provider.allLists
                .filter { !$0.isReadOnly }
                .map { list in
                    if let originalId = list.originalFileId {
                        return "• \(list.summary.name): \(originalId)"
                    } else {
                        return "• \(list.summary.name): \(list.id)"
                    }
                }
            
            showErrorAlert("""
                No list found with ID: \(listId)
                
                Available lists:
                \(availableIDs.joined(separator: "\n"))
                """)
            return
        }
        
        // Success - set up import request
        markdownImport = MarkdownImportRequest(
            markdown: markdown,
            listId: listId,
            shouldPreview: shouldPreview
        )
    }
    
    func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
    }
}
