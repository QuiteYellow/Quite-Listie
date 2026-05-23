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
    /// Single source of truth for "user is being shown the markdown import sheet."
    /// `preloadedList` is nil when the URL didn't specify a list or the specified
    /// list wasn't found — the import view shows its built-in picker step.
    var markdownImport: MarkdownImportRequest?
    var errorMessage: String?
    var showError = false

    /// Set when a `quitelistie://item?id=<itemUUID>` deeplink is received.
    /// WelcomeView navigates to the resolved list and ListView opens the editor.
    var pendingItemNavigation: ItemNavigation?

    struct ItemNavigation: Equatable {
        let listId: String  // runtime list.id resolved during handling
        let itemId: String
    }

    struct MarkdownImportRequest: Identifiable, Equatable {
        let id = UUID()
        let markdown: String
        let shouldPreview: Bool
        /// nil ⇒ import view starts at its list-picker step.
        let preloadedList: UnifiedList?
        let preloadedItems: [ListItem]
        let preloadedLabels: [ListLabel]

        // Identity-only equality so .onChange fires per-request even when the
        // payload types ([ListItem]) aren't Equatable on their own.
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
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

        // Try to find target list by ID and preload its contents so the import
        // sheet opens with stats ready — no in-sheet async race, no "0 items
        // selected" flash on first paint.
        if let listId = listId,
           let matched = provider.allLists.first(where: { $0.id == listId || $0.originalFileId == listId }) {
            do {
                let items = try await provider.fetchItems(for: matched)
                let labels = try await provider.fetchLabels(for: matched)
                markdownImport = MarkdownImportRequest(
                    markdown: markdown,
                    shouldPreview: shouldPreview,
                    preloadedList: matched,
                    preloadedItems: items,
                    preloadedLabels: labels
                )
            } catch {
                AppLogger.deeplinks.error("Failed to preload list for import: \(error, privacy: .public)")
                // Fall through to picker step so the user can pick a different target.
                markdownImport = MarkdownImportRequest(
                    markdown: markdown,
                    shouldPreview: shouldPreview,
                    preloadedList: nil,
                    preloadedItems: [],
                    preloadedLabels: []
                )
            }
        } else {
            // No list ID provided, or no matching list found — let user pick
            // inside the import view's first step.
            markdownImport = MarkdownImportRequest(
                markdown: markdown,
                shouldPreview: shouldPreview,
                preloadedList: nil,
                preloadedItems: [],
                preloadedLabels: []
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
        // Transient sync errors still have a usable local cache — search them too.
        // Only permanent unavailability (file deleted) is worth skipping.
        for list in provider.allLists where !list.isPermanentlyUnavailable {
            let items = await provider.fetchItemsForDisplay(for: list)
            if items.contains(where: { $0.id.uuidString == itemId }) {
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
