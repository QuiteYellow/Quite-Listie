//
//  DeeplinkCoordinator.swift
//  Listie-md
//
//  Created by Jack Nagy on 02/01/2026.
//


import Foundation
import os
import SwiftUI
import Compression

@Observable
@MainActor
class DeeplinkCoordinator {
    var fileToOpen: URL?
    var markdownImport: MarkdownImportRequest?
    var pendingImport: PendingImport?
    var errorMessage: String?
    var showError = false

    /// Set when a `quitelistie://item?id=<itemUUID>` deeplink is received.
    /// WelcomeView navigates to the resolved list and ShoppingListView opens the editor.
    var pendingItemNavigation: ItemNavigation?

    struct ItemNavigation: Equatable {
        let listId: String  // runtime list.id resolved during handling
        let itemId: String
    }

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
        AppLogger.deeplinks.info("[Deeplink] Received URL: \(url, privacy: .public)")

        // Handle external JSON files
        if url.pathExtension == "listie" || url.pathExtension == "json" {
            AppLogger.deeplinks.info("[Deeplink] Detected file")
            fileToOpen = url
            return
        }

        // Handle quitelistie:// scheme (also accept legacy listie:// for backward compatibility)
        guard url.scheme == "quitelistie" || url.scheme == "listie" else {
            AppLogger.deeplinks.warning("[Deeplink] Unhandled URL scheme: \(url.scheme ?? "nil", privacy: .public)")
            return
        }

        if url.host == "import" {
            await handleMarkdownImport(url, provider: provider)
        } else if url.host == "item" {
            await handleItemNavigation(url, provider: provider)
        } else {
            AppLogger.deeplinks.warning("[Deeplink] Unknown host: \(url.host ?? "nil", privacy: .public)")
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
        AppLogger.deeplinks.info("[Deeplink] Import action detected")

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

    private func handleItemNavigation(_ url: URL, provider: UnifiedListProvider) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let itemId = components.queryItems?.first(where: { $0.name == "id" })?.value else {
            AppLogger.deeplinks.warning("[Deeplink] item URL missing id parameter")
            return
        }

        AppLogger.deeplinks.info("[Deeplink] Looking up item \(itemId, privacy: .public)")

        // Ensure lists are loaded — handles cold launch where allLists is still empty
        if provider.allLists.isEmpty {
            await provider.loadAllLists()
        }

        // Scan all lists for the item UUID — no listId needed since item UUIDs are globally unique
        for list in provider.allLists where !list.isUnavailable {
            if let items = try? await provider.fetchItems(for: list),
               items.contains(where: { $0.id.uuidString == itemId }) {
                AppLogger.deeplinks.info("[Deeplink] Found item in list \(list.summary.name, privacy: .public)")
                pendingItemNavigation = ItemNavigation(listId: list.id, itemId: itemId)
                return
            }
        }

        AppLogger.deeplinks.warning("[Deeplink] Item \(itemId, privacy: .public) not found in any list")
    }

    func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
    }
}
