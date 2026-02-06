//
//  DeeplinkCoordinator.swift
//  Listie-md
//
//  Created by Jack Nagy on 02/01/2026.
//


import Foundation
import SwiftUI
import Compression

@MainActor
class DeeplinkCoordinator: ObservableObject {
    @Published var fileToOpen: URL?
    @Published var markdownImport: MarkdownImportRequest?
    @Published var pendingImport: PendingImport?
    @Published var errorMessage: String?
    @Published var showError = false

    struct MarkdownImportRequest: Identifiable, Equatable {
        let id = UUID()
        let markdown: String
        let listId: String
        let shouldPreview: Bool
    }

    /// Holds decoded markdown when the target list is missing or not found,
    /// so the user can pick or create a list before importing.
    struct PendingImport: Identifiable {
        let id = UUID()
        let markdown: String
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

    /// Called when the user picks a list from the list picker for a pending import.
    func completePendingImport(with listId: String) {
        guard let pending = pendingImport else { return }
        markdownImport = MarkdownImportRequest(
            markdown: pending.markdown,
            listId: listId,
            shouldPreview: pending.shouldPreview
        )
        pendingImport = nil
    }

    private func handleMarkdownImport(_ url: URL, provider: UnifiedListProvider) async {
        print("📥 [Deeplink] Import action detected")

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems else {
            showErrorAlert("Invalid import URL")
            return
        }

        var listId: String?
        var markdownRaw: String?
        var shouldPreview = false
        var encodingType = "b64"

        for item in queryItems {
            switch item.name {
            case "list":
                listId = item.value
            case "markdown":
                markdownRaw = item.value
            case "preview":
                shouldPreview = item.value == "true"
            case "enc":
                encodingType = item.value ?? "b64"
            default:
                break
            }
        }

        // Decode markdown based on encoding type
        var markdown: String?

        if let rawValue = markdownRaw {
            switch encodingType {
            case "lzma":
                markdown = DeeplinkCompression.decompress(rawValue, algorithm: COMPRESSION_LZMA)
                if markdown == nil {
                    showErrorAlert("Failed to decompress markdown. The data may be corrupted.")
                    return
                }
            case "zlib":
                markdown = DeeplinkCompression.decompress(rawValue, algorithm: COMPRESSION_ZLIB)
                if markdown == nil {
                    showErrorAlert("Failed to decompress markdown. The data may be corrupted.")
                    return
                }
            default:
                // "b64" or missing: standard Base64 decode (backward compatible)
                if let data = Data(base64Encoded: rawValue),
                   let decoded = String(data: data, encoding: .utf8) {
                    markdown = decoded
                } else {
                    showErrorAlert("Failed to decode markdown parameter. The markdown must be base64 encoded.")
                    return
                }
            }
        }

        guard let markdown = markdown else {
            showErrorAlert("Missing required parameter: markdown (must be encoded)")
            return
        }

        // Wait for lists to load if needed
        if provider.allLists.isEmpty {
            await provider.loadAllLists()
        }

        // Try to find target list by ID
        if let listId = listId,
           let _ = provider.allLists.first(where: { $0.id == listId || $0.originalFileId == listId }) {
            // Direct match found
            markdownImport = MarkdownImportRequest(
                markdown: markdown,
                listId: listId,
                shouldPreview: shouldPreview
            )
        } else {
            // No list ID provided, or no matching list found — let user pick
            pendingImport = PendingImport(
                markdown: markdown,
                shouldPreview: shouldPreview
            )
        }
    }

    func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
    }
}
