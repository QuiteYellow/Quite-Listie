//
//  FileStore.swift (formerly ExternalFileStore)
//  Listie.md
//
//  Unified file store for both private (iCloud container) and external (user-selected) files.
//  Updated to support V2 format with automatic migration and sync resolution.
//

import Foundation
import os

// MARK: - File Source

/// Represents the source/location of a list file
enum FileSource: Hashable {
    /// Private list stored in the app's iCloud container (or local fallback)
    case privateList(String)  // List ID

    /// External file selected by the user from Files app
    case externalFile(URL)

    /// Whether this source requires security-scoped resource access
    var requiresSecurityScope: Bool {
        if case .externalFile = self { return true }
        return false
    }

    /// Whether this is a private list (in app's container)
    var isPrivate: Bool {
        if case .privateList = self { return true }
        return false
    }

    /// Whether this is an external file (user-selected)
    var isExternal: Bool {
        if case .externalFile = self { return true }
        return false
    }

    /// Get the list ID if this is a private list
    var privateListId: String? {
        if case .privateList(let id) = self { return id }
        return nil
    }

    /// Get the URL if this is an external file
    var externalURL: URL? {
        if case .externalFile(let url) = self { return url }
        return nil
    }
}

/// Represents a bookmarked file that is currently unavailable
struct UnavailableBookmark: Identifiable {
    let id: String  // The original path used as key
    let originalPath: String
    let reason: UnavailabilityReason
    let fileName: String
    let folderName: String

    enum UnavailabilityReason {
        case fileNotFound
        case inTrash
        case bookmarkInvalid(Error)
        case iCloudNotDownloaded

        var localizedDescription: String {
            switch self {
            case .fileNotFound:
                return "File not found"
            case .inTrash:
                return "File is in Trash"
            case .bookmarkInvalid(let error):
                return "Cannot access file: \(error.localizedDescription)"
            case .iCloudNotDownloaded:
                return "File not downloaded from iCloud"
            }
        }

        var icon: String {
            switch self {
            case .fileNotFound:
                return "doc.questionmark"
            case .inTrash:
                return "trash"
            case .bookmarkInvalid:
                return "lock.slash"
            case .iCloudNotDownloaded:
                return "icloud.slash"
            }
        }
    }
}

/// Typealias for backward compatibility
typealias ExternalFileStore = FileStore

actor FileStore {
    static let shared = FileStore()

    private let defaultsKey = "com.listie.external-files"

    // In-memory cache of opened external files
    private var openedFiles: [String: (url: URL, document: ListDocument)] = [:]

    // Track file modification dates for change detection
    private var fileModificationDates: [String: Date] = [:]

    // TTL for cache
    private var cacheTimestamps: [String: Date] = [:]
    private let cacheTTL: TimeInterval = 30 // 30 seconds

    // Track unavailable bookmarks instead of deleting them
    private var unavailableBookmarks: [String: UnavailableBookmark] = [:]

    init() {
        // Bookmark loading is handled by refreshBookmarkAvailability() in loadAllLists()
        // No need to eagerly load here — it would just duplicate work on startup
    }
    
    private func resolveConflicts(at url: URL) async throws {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty else {
            return // No conflicts
        }
        
        AppLogger.sync.warning("Found \(conflicts.count) conflicting version(s) for \(url.lastPathComponent)")
        
        guard let currentVersion = NSFileVersion.currentVersionOfItem(at: url) else {
            throw NSError(domain: "ExternalFileStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not get current version"
            ])
        }
        
        // Instead of picking newest, merge all versions
        var mergedDocument: ListDocument?
        
        // Load current version
        if let currentData = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            mergedDocument = try? decoder.decode(ListDocument.self, from: currentData)
        }
        
        // Merge each conflict version
        for conflictVersion in conflicts {
            let conflictURL = conflictVersion.url
            if let conflictData = try? Data(contentsOf: conflictURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let conflictDoc = try? decoder.decode(ListDocument.self, from: conflictData) {
                    
                    if let existing = mergedDocument {
                        // Merge items and labels
                        let mergedItems = mergeItems(cached: existing.items, disk: conflictDoc.items)
                        let mergedLabels = mergeLabels(cached: existing.labels, disk: conflictDoc.labels)
                        
                        var combined = existing
                        combined.items = mergedItems
                        combined.labels = mergedLabels
                        combined.list.modifiedAt = max(existing.list.modifiedAt, conflictDoc.list.modifiedAt)
                        
                        mergedDocument = combined
                    } else {
                        mergedDocument = conflictDoc
                    }
                }
            }
        }
        
        
        // Write merged result back
            // Write merged result back
            if let merged = mergedDocument {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(merged)
                try data.write(to: url, options: .atomic)
            AppLogger.sync.info("Merged \(conflicts.count) conflicting version(s)")
        } else {
            // Fallback to original behavior if merge failed
            let allVersions = [currentVersion] + conflicts
            guard let newestVersion = allVersions.max(by: {
                ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast)
            }) else {
                throw NSError(domain: "ExternalFileStore", code: 3)
            }
            
            if newestVersion != currentVersion {
                try newestVersion.replaceItem(at: url, options: .byMoving)
            }
            AppLogger.sync.warning("Merge failed, fell back to newest version")
        }
        
        // Mark all conflicts as resolved
        for conflict in conflicts {
            conflict.isResolved = true
        }
        
        try NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
    
    // MARK: - Downloaded or not?

    /// Checks if a URL points to an iCloud file (even if not downloaded locally)
    /// Returns true if the file has an iCloud download status, meaning it exists in iCloud
    private func isICloudFile(at url: URL) -> Bool {
        do {
            // Clear cached resource values to get fresh iCloud status
            var freshURL = url
            freshURL.removeAllCachedResourceValues()
            let values = try freshURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            // If we can get a download status, it's an iCloud file
            return values.ubiquitousItemDownloadingStatus != nil
        } catch {
            return false
        }
    }

    // Checks if an iCloud file is fully downloaded
    private func isFileDownloaded(at url: URL) throws -> Bool {
        // Primary check: if the file is readable on disk, it's downloaded
        if FileManager.default.isReadableFile(atPath: url.path) {
            return true
        }

        // File isn't readable — clear cached resource values and check iCloud status
        var freshURL = url
        freshURL.removeAllCachedResourceValues()

        let values = try freshURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])

        guard let status = values.ubiquitousItemDownloadingStatus else {
            // Not an iCloud file
            return true
        }

        switch status {
        case .current:
            return true  // File is downloaded and current
        case .notDownloaded, .downloaded:
            return false  // File needs downloading
        default:
            return false
        }
    }

    // Ensures an iCloud file is downloaded, triggering download if needed
    private func ensureFileDownloaded(at url: URL) async throws {
        // Primary check: if the file is already readable on disk, skip all iCloud logic
        if FileManager.default.isReadableFile(atPath: url.path) {
            AppLogger.iCloud.info("File already on disk: \(url.lastPathComponent)")
            return
        }

        // File isn't readable — clear cached resource values to get fresh iCloud status
        var freshURL = url
        freshURL.removeAllCachedResourceValues()

        let values = try freshURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])

        guard values.ubiquitousItemDownloadingStatus != nil else {
            // Not an iCloud file and not readable — just return, caller will handle the error
            return
        }

        // Trigger download
        AppLogger.iCloud.info("File not on disk, requesting download: \(url.lastPathComponent)")
        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        // Poll using isReadableFile instead of resource values
        let maxWait: TimeInterval = 30
        let pollInterval: UInt64 = 500_000_000 // 0.5 seconds
        let startTime = Date()

        while !FileManager.default.isReadableFile(atPath: url.path) {
            if Date().timeIntervalSince(startTime) > maxWait {
                AppLogger.iCloud.warning("Timed out waiting for download: \(url.lastPathComponent)")
                break
            }
            try await Task.sleep(nanoseconds: pollInterval)
        }

        if FileManager.default.isReadableFile(atPath: url.path) {
            AppLogger.iCloud.info("File downloaded: \(url.lastPathComponent)")
        }
    }
    
    
    
    
    // MARK: - File Management
    
    func openFile(at url: URL, forceReload: Bool = false) async throws -> ListDocument {
        // Return cached document if available and not forcing reload
        if !forceReload, let cached = getOpenedFile(at: url) {
            AppLogger.cache.info("Using cached document for \(url.lastPathComponent)")
            return cached
        }

        AppLogger.cache.debug("Cache miss/expired for \(url.lastPathComponent) - loading from disk")

        AppLogger.fileStore.debug("Attempting to open: \(url.path)")

        // Try to access security-scoped resource FIRST
        let didStart = url.startAccessingSecurityScopedResource()
        AppLogger.fileStore.debug("Security scope started: \(didStart)")

        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Ensure file is downloaded from iCloud if needed (BEFORE checking if it exists)
        try await ensureFileDownloaded(at: url)

        // NOW check if file exists (after download attempt)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "ExternalFileStore", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "File not found at \(url.path)"
            ])
        }

        AppLogger.fileStore.debug("File exists: \(FileManager.default.fileExists(atPath: url.path))")
        AppLogger.fileStore.debug("Is readable: \(FileManager.default.isReadableFile(atPath: url.path))")

        // Resolve any iCloud conflicts before opening
        try await resolveConflicts(at: url)
        
        // Try direct read first (simpler, works for most cases)
        var content: Data?
        
        do {
            content = try Data(contentsOf: url)
            AppLogger.fileStore.info("Successfully read \(content?.count ?? 0) bytes")
        } catch {
            AppLogger.fileStore.error("Failed to read file: \(error)")
            throw error
        }
        
        guard let data = content else {
            throw NSError(domain: "ExternalFileStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to read file at \(url.path)"
            ])
        }
        
        // Simple decode - no migration
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ListDocument.self, from: data)
        
        // Ensure clean ID
        let cleanId = document.list.cleanId
        if document.list.id != cleanId {
            AppLogger.fileStore.debug("Cleaning external file ID: \(document.list.id) -> \(cleanId)")
            var cleanDoc = document
            cleanDoc.list.id = cleanId
            // Don't save here - let user decide if they want to keep it
        }
        
        // Cache the opened file
        openedFiles[url.path] = (url, document)
        
        cacheTimestamps[url.path] = Date()
        AppLogger.cache.info("Cached \(document.list.name) (expires in \(self.cacheTTL)s)")

        // Save bookmark
        try await saveBookmark(for: url)

        AppLogger.fileStore.info("Opened external file: \(document.list.name) (V\(document.version))")
        
        // After loading, store the file's modification date
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attributes[.modificationDate] as? Date {
            fileModificationDates[url.path] = modDate
        }
        
        return document
    }
    
    func hasFileChanged(at url: URL) -> Bool {
        // Check if file is downloaded - if not, DON'T treat as changed
        // (just means iOS evicted it to save space)
        guard let downloaded = try? isFileDownloaded(at: url), downloaded else {
            AppLogger.sync.info("File evicted but not changed: \(url.lastPathComponent)")
            return false  // Eviction is NOT a change
        }
        
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let currentModDate = attributes[.modificationDate] as? Date,
              let storedModDate = fileModificationDates[url.path] else {
            return false
        }
        
        let changed = currentModDate > storedModDate
        if changed {
            AppLogger.sync.debug("File actually modified: \(url.lastPathComponent)")
        }
        return changed
    }
    
    func saveFile(_ document: ListDocument, to url: URL, bypassOptimisticCheck: Bool = false) async throws {
        AppLogger.fileStore.debug("Attempting to save file: \(url.lastPathComponent)")
        
        var didStart = false
        if url.startAccessingSecurityScopedResource() {
            didStart = true
        }
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        // Check writability BEFORE attempting save
        let isWritable = FileManager.default.isWritableFile(atPath: url.path)
        AppLogger.fileStore.debug("isWritableFile returned: \(isWritable)")
        
        // If not writable, throw immediately
        if !isWritable {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
                NSLocalizedDescriptionKey: "File is read-only",
                NSFilePathErrorKey: url.path
            ])
        }
        
        // Check if file changed since we last loaded it
        if !bypassOptimisticCheck, let lastKnownDate = fileModificationDates[url.path] {
            if let currentAttrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let currentDate = currentAttrs[.modificationDate] as? Date,
               currentDate > lastKnownDate {
                AppLogger.sync.warning("[OPTIMISTIC LOCK] File changed externally - triggering merge")
                AppLogger.sync.debug("Last known: \(lastKnownDate)")
                AppLogger.sync.debug("Current: \(currentDate)")
                
                let mergedDocument = try await syncFile(at: url)
                AppLogger.sync.debug("After merge: \(mergedDocument.labels.count) labels")
                
                
                // Recursive call with bypass flag to prevent infinite loop
                try await saveFile(mergedDocument, to: url, bypassOptimisticCheck: true)
                return
            }
        }
        
        AppLogger.fileStore.debug("[DIRECT SAVE] Writing \(document.labels.count) labels to disk")

        
        // Resolve any conflicts before saving
        try await resolveConflicts(at: url)
        
        let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            
        let data = try encoder.encode(document)

        // Use NSFileCoordinator for iCloud-aware writes
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var writeError: Error?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let error = coordinatorError ?? writeError {
            throw error
        }

        // Update cache
        openedFiles[url.path] = (url, document)
        
        cacheTimestamps[url.path] = Date()
        AppLogger.cache.info("Cached \(document.list.name) (expires in \(self.cacheTTL)s)")

        // Update modification date
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attributes[.modificationDate] as? Date {
            fileModificationDates[url.path] = modDate
        }

        // Save bookmark
        try await saveBookmark(for: url)

        AppLogger.fileStore.info("Saved external file: \(document.list.name) (V2)")
    }
    
    static func isFileWritable(at url: URL) -> Bool {
        var didStart = false
        if url.startAccessingSecurityScopedResource() {
            didStart = true
        }
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        return FileManager.default.isWritableFile(atPath: url.path)
    }
    
    func getOpenedFile(at url: URL) -> ListDocument? {
        guard let timestamp = cacheTimestamps[url.path],
              Date().timeIntervalSince(timestamp) < cacheTTL else {
            if cacheTimestamps[url.path] != nil {
                AppLogger.cache.debug("Expired for \(url.lastPathComponent) (TTL: \(self.cacheTTL)s)")
            }
            return nil  // Cache expired
        }
        return openedFiles[url.path]?.document
    }
    
    func getOpenedFiles() -> [(url: URL, document: ListDocument)] {
        // Clean up expired entries first
        let now = Date()
        let expiredPaths = cacheTimestamps.filter { (path, timestamp) in
            now.timeIntervalSince(timestamp) >= cacheTTL
        }.map(\.key)
        
        if !expiredPaths.isEmpty {
            AppLogger.cache.debug("Cleaning up \(expiredPaths.count) expired entries")
            for path in expiredPaths {
                openedFiles.removeValue(forKey: path)
                cacheTimestamps.removeValue(forKey: path)
                fileModificationDates.removeValue(forKey: path)
            }
        }
        
        return Array(openedFiles.values)
    }
    
    func closeFile(at url: URL) {
        openedFiles.removeValue(forKey: url.path)
        fileModificationDates.removeValue(forKey: url.path)
        cacheTimestamps.removeValue(forKey: url.path) 
        
        // Remove the bookmark so file won't reappear on next launch
        var bookmarks = loadBookmarks()
        var keysToRemove: [String] = []
        
        // Find all bookmark keys that resolve to this URL
        for (key, bookmarkData) in bookmarks {
            do {
                var isStale = false
#if os(macOS)
                let bookmarkedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
#else
                let bookmarkedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
#endif
                
                // If this bookmark resolves to the URL we want to close, mark for removal
                if bookmarkedURL.path == url.path || bookmarkedURL.standardizedFileURL.path == url.standardizedFileURL.path {
                    keysToRemove.append(key)
                }
            } catch {
                // Don't remove bookmarks that fail to resolve - they might be temporarily unavailable
                // (e.g., iCloud not ready, device offline). Only remove when we have a matching URL.
                continue
            }
        }
        
        // Remove all matching bookmarks
        for key in keysToRemove {
            bookmarks.removeValue(forKey: key)
        }
        
        if !keysToRemove.isEmpty {
            saveBookmarks(bookmarks)
            AppLogger.fileStore.debug("Removed \(keysToRemove.count) bookmark(s) for \(url.path)")
        }
    }
    
    // MARK: - Bookmark Management
    
    private func saveBookmark(for url: URL) async throws {
        do {
            let bookmark: Data
#if os(macOS)
            bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
#else
            bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
#endif
            
            var bookmarks = loadBookmarks()
            bookmarks[url.path] = bookmark
            saveBookmarks(bookmarks)
            AppLogger.fileStore.info("Saved bookmark for: \(url.lastPathComponent)")
        } catch {
            AppLogger.fileStore.warning("Could not save bookmark (read-only file?): \(error)")
            // Don't throw - read-only files can't create bookmarks, but that's OK
            // The file will need to be reopened manually next time
        }
    }
    
    private func loadBookmarks() -> [String: Data] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let bookmarks = try? JSONDecoder().decode([String: Data].self, from: data) else {
            return [:]
        }
        return bookmarks
    }
    
    private func saveBookmarks(_ bookmarks: [String: Data]) {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
    
    /// Single-pass bookmark resolution: validates all bookmarks, refreshes stale ones (batched),
    /// populates unavailableBookmarks, and returns the list of available URLs.
    private func loadAndResolveBookmarks() async -> [URL] {
        let bookmarks = loadBookmarks()
        unavailableBookmarks.removeAll()

        var resolvedURLs: [URL] = []
        var seenResolvedPaths: Set<String> = []
        var staleBookmarksToSave: [(url: URL, path: String)] = []

        for (path, bookmarkData) in bookmarks {
            do {
                var isStale = false
#if os(macOS)
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
#else
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
#endif

                // Skip if we've already processed a bookmark that resolves to this path
                guard !seenResolvedPaths.contains(url.path) else {
                    continue
                }
                seenResolvedPaths.insert(url.path)

                // Start security-scoped access to check file attributes
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let fileName = url.deletingPathExtension().lastPathComponent
                let folderName = url.deletingLastPathComponent().lastPathComponent

                // Collect stale bookmarks for batched refresh
                if isStale && didStartAccess {
                    staleBookmarksToSave.append((url: url, path: path))
                }

                // If we couldn't start security-scoped access, the bookmark may have lost permissions
                if !didStartAccess {
                    AppLogger.fileStore.warning("Security scope access denied for: \(fileName)")
                }

                // Check if file is in trash
                if url.path.contains("/.Trash/") {
                    unavailableBookmarks[url.path] = UnavailableBookmark(
                        id: path,
                        originalPath: url.path,
                        reason: .inTrash,
                        fileName: fileName,
                        folderName: folderName
                    )
                    AppLogger.fileStore.warning("File is in Trash: \(path)")
                    continue
                }

                // Check if file exists locally OR is an iCloud placeholder
                if FileManager.default.fileExists(atPath: url.path) {
                    resolvedURLs.append(url)
                } else if isICloudFile(at: url) {
                    // File exists in iCloud but not downloaded locally - treat as available
                    AppLogger.iCloud.info("File not downloaded locally (available): \(fileName)")
                    resolvedURLs.append(url)
                } else {
                    // Truly not found
                    unavailableBookmarks[url.path] = UnavailableBookmark(
                        id: path,
                        originalPath: url.path,
                        reason: .fileNotFound,
                        fileName: fileName,
                        folderName: folderName
                    )
                    AppLogger.fileStore.warning("File not found: \(path)")
                }
            } catch {
                // Bookmark can't be resolved - track as unavailable
                guard !seenResolvedPaths.contains(path) else {
                    continue
                }
                seenResolvedPaths.insert(path)

                let fileName = (path as NSString).deletingPathExtension
                let folderName = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                unavailableBookmarks[path] = UnavailableBookmark(
                    id: path,
                    originalPath: path,
                    reason: .bookmarkInvalid(error),
                    fileName: (fileName as NSString).lastPathComponent,
                    folderName: folderName
                )
                AppLogger.fileStore.warning("Invalid bookmark for \(path): \(error)")
            }
        }

        // Batch-refresh all stale bookmarks in one UserDefaults write
        if !staleBookmarksToSave.isEmpty {
            AppLogger.fileStore.debug("Refreshing \(staleBookmarksToSave.count) stale bookmark(s)...")
            var allBookmarks = loadBookmarks()
            for entry in staleBookmarksToSave {
                // Re-start security-scoped access (it was stopped in the defer above)
                let didStart = entry.url.startAccessingSecurityScopedResource()
                defer {
                    if didStart {
                        entry.url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let bookmark: Data
#if os(macOS)
                    bookmark = try entry.url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
#else
                    bookmark = try entry.url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
#endif
                    allBookmarks[entry.url.path] = bookmark
                } catch {
                    AppLogger.fileStore.warning("Failed to refresh stale bookmark for \(entry.url.lastPathComponent): \(error)")
                }
            }
            saveBookmarks(allBookmarks)
            AppLogger.fileStore.info("Refreshed \(staleBookmarksToSave.count) stale bookmark(s)")
        }

        if !unavailableBookmarks.isEmpty {
            AppLogger.fileStore.warning("\(self.unavailableBookmarks.count) bookmark(s) are unavailable")
        }

        return resolvedURLs
    }

    /// Legacy wrapper — callers that only need the URL list
    func getBookmarkedURLs() async -> [URL] {
        return await loadAndResolveBookmarks()
    }
    
    func clearBookmarks() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        openedFiles.removeAll()
        fileModificationDates.removeAll()
        unavailableBookmarks.removeAll()
    }

    /// Clears the in-memory cache for private lists (used after storage location migration)
    func clearPrivateListsCache() {
        // Find and remove cache entries for private list URLs
        let privatePathPrefix = "LocalLists"
        let iCloudPathPrefix = "Documents/Lists"

        let keysToRemove = openedFiles.keys.filter { path in
            path.contains(privatePathPrefix) || path.contains(iCloudPathPrefix)
        }

        for key in keysToRemove {
            openedFiles.removeValue(forKey: key)
            cacheTimestamps.removeValue(forKey: key)
            fileModificationDates.removeValue(forKey: key)
        }

        AppLogger.cache.debug("Cleared \(keysToRemove.count) private list cache entries")
    }

    /// Returns all bookmarks that are currently unavailable
    func getUnavailableBookmarks() -> [UnavailableBookmark] {
        return Array(unavailableBookmarks.values)
    }

    /// Removes an unavailable bookmark permanently
    func removeUnavailableBookmark(_ bookmark: UnavailableBookmark) {
        var bookmarks = loadBookmarks()
        bookmarks.removeValue(forKey: bookmark.id)
        saveBookmarks(bookmarks)
        unavailableBookmarks.removeValue(forKey: bookmark.id)
        AppLogger.fileStore.debug("Removed unavailable bookmark: \(bookmark.fileName)")
    }

    /// Refreshes the availability status of all bookmarks and returns available URLs
    @discardableResult
    func refreshBookmarkAvailability() async -> [URL] {
        return await loadAndResolveBookmarks()
    }
    
    private func preferredFileExtension() -> String {
        return "listie"  // Use .listie for new files
    }
    
    func updateCache(_ document: ListDocument, at url: URL) async {
        openedFiles[url.path] = (url, document)
        
        cacheTimestamps[url.path] = Date()
        AppLogger.cache.info("Cached \(document.list.name) (expires in \(self.cacheTTL)s)")
    }

    // MARK: - Sync Resolution
    
    /// Syncs file by merging cached changes with disk changes, using modification dates to resolve conflicts
    func syncFile(at url: URL) async throws -> ListDocument {
        AppLogger.sync.debug("Syncing file: \(url.lastPathComponent)")
        
        // Resolve conflicts first to ensure clean state
        try await resolveConflicts(at: url)
        
        // 1. IMPORTANT: Save the cached version BEFORE reloading from disk
        let cachedDocument = openedFiles[url.path]?.document
        
        // 2. Load current file from disk (this will update the cache, so we saved it above)
        let diskDocument = try await openFile(at: url, forceReload: true)
        
        // 3. If no cache existed, just return disk version
        guard let cached = cachedDocument else {
            AppLogger.sync.info("No cache, using disk version")
            return diskDocument
        }
        
        // 4. Merge items based on modification dates
        let mergedItems = mergeItems(cached: cached.items, disk: diskDocument.items)
        
        // 5. Merge labels based on modification or presence
        let mergedLabels = mergeLabels(cached: cached.labels, disk: diskDocument.labels)
        
        // 6. Create merged document (use latest list metadata)
        var mergedDocument = diskDocument
        mergedDocument.items = mergedItems
        mergedDocument.labels = mergedLabels
        
        // Use latest list modification date
        if cached.list.modifiedAt > diskDocument.list.modifiedAt {
            mergedDocument.list = cached.list
        }
        
        // 7. Save merged version back to disk
        try await saveFile(mergedDocument, to: url)
        
        AppLogger.sync.info("Sync complete: \(mergedItems.count) items, \(mergedLabels.count) labels")
        
        return mergedDocument
    }
    
    /// Merges items from cache and disk, preferring the one with the latest modification date
    private func mergeItems(cached: [ShoppingItem], disk: [ShoppingItem]) -> [ShoppingItem] {
        var itemsById: [UUID: ShoppingItem] = [:]
        
        // Note: Items may reference labelIds that don't exist in labels array
        // This is handled gracefully - labelForItem returns nil and item appears under "No Label"
        
        // Add all disk items first
        for item in disk {
            itemsById[item.id] = item
        }
        
        // Merge with cached items (latest modification date wins)
        for cachedItem in cached {
            if let diskItem = itemsById[cachedItem.id] {
                // Both exist - compare modification dates
                if cachedItem.modifiedAt > diskItem.modifiedAt {
                    // Cache is newer - use it
                    itemsById[cachedItem.id] = cachedItem
                    // Only log if there's a meaningful time difference (> 1 second)
                    if cachedItem.modifiedAt.timeIntervalSince(diskItem.modifiedAt) > 1 {
                        AppLogger.merge.debug("Item '\(cachedItem.note)': cache is newer (\(cachedItem.modifiedAt) vs \(diskItem.modifiedAt))")
                    }
                } else if diskItem.modifiedAt > cachedItem.modifiedAt {
                    // Disk is newer - already in dict, just log if meaningful difference
                    if diskItem.modifiedAt.timeIntervalSince(cachedItem.modifiedAt) > 1 {
                        AppLogger.merge.debug("Item '\(diskItem.note)': disk is newer (\(diskItem.modifiedAt) vs \(cachedItem.modifiedAt))")
                    }
                }
                // If timestamps are equal (within 1 second), don't log - no conflict
            } else {
                // Only in cache - add it (new item created locally)
                itemsById[cachedItem.id] = cachedItem
                AppLogger.merge.debug("Item '\(cachedItem.note)': added from cache")
            }
        }
        
        // Check for items only in disk (new items created remotely)
        for diskItem in disk {
            if !cached.contains(where: { $0.id == diskItem.id }) {
                AppLogger.merge.debug("Item '\(diskItem.note)': added from disk")
            }
        }
        
        return Array(itemsById.values).sorted { $0.modifiedAt > $1.modifiedAt }
    }
    
    /// Merges labels from cache and disk — union of both sets.
    /// Labels only in cache (new local) are kept. Labels only on disk (new remote) are kept.
    /// Labels in both are kept (name/color from cache since it's the latest local state).
    private func mergeLabels(cached: [ShoppingLabel], disk: [ShoppingLabel]) -> [ShoppingLabel] {
        var labelsById: [String: ShoppingLabel] = [:]

        // Add all disk labels first (remote state)
        for label in disk {
            labelsById[label.id] = label
        }

        // Merge cached labels on top (local changes win for shared IDs, new locals are added)
        for label in cached {
            labelsById[label.id] = label
        }

        // Preserve disk order, then append any new cached labels at the end
        let diskIDs = Set(disk.map { $0.id })
        var result = disk.compactMap { labelsById[$0.id] }
        let newFromCache = cached.filter { !diskIDs.contains($0.id) }
        result.append(contentsOf: newFromCache)

        return result
    }

    // MARK: - FileSource-Based API (Unified Interface)

    /// Opens a file from either a private list or external file source
    func openFile(from source: FileSource, forceReload: Bool = false) async throws -> ListDocument {
        switch source {
        case .privateList(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            return try await openPrivateFile(at: url, forceReload: forceReload)

        case .externalFile(let url):
            return try await openFile(at: url, forceReload: forceReload)
        }
    }

    /// Saves a document to either a private list or external file source
    func saveFile(_ document: ListDocument, to source: FileSource, bypassOptimisticCheck: Bool = false) async throws {
        switch source {
        case .privateList(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            try await savePrivateFile(document, to: url, bypassOptimisticCheck: bypassOptimisticCheck)

        case .externalFile(let url):
            try await saveFile(document, to: url, bypassOptimisticCheck: bypassOptimisticCheck)
        }
    }

    /// Checks if a file has changed for the given source
    func hasFileChanged(for source: FileSource) async -> Bool {
        switch source {
        case .privateList(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            return hasFileChanged(at: url)

        case .externalFile(let url):
            return hasFileChanged(at: url)
        }
    }

    /// Syncs a file from the given source
    func syncFile(from source: FileSource) async throws -> ListDocument {
        switch source {
        case .privateList(let listId):
            let url = await iCloudContainerManager.shared.fileURL(for: listId)
            return try await syncPrivateFile(at: url)

        case .externalFile(let url):
            return try await syncFile(at: url)
        }
    }

    /// Deletes a private list file
    func deletePrivateList(_ listId: String) async throws {
        let url = await iCloudContainerManager.shared.fileURL(for: listId)

        // Remove from cache
        openedFiles.removeValue(forKey: url.path)
        fileModificationDates.removeValue(forKey: url.path)
        cacheTimestamps.removeValue(forKey: url.path)

        // Delete the file using NSFileCoordinator for proper iCloud sync
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLogger.fileStore.warning("[Private] File already deleted: \(listId)")
            return
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var deleteError: Error?

        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { deleteURL in
            do {
                try FileManager.default.removeItem(at: deleteURL)
                AppLogger.fileStore.debug("[Private] Deleted list: \(listId)")
            } catch {
                deleteError = error
            }
        }

        if let error = coordinatorError ?? deleteError {
            AppLogger.fileStore.error("[Private] Failed to delete list: \(error)")
            throw error
        }
    }

    // MARK: - Private List File Operations

    /// Opens a private file (no security-scoped access needed)
    private func openPrivateFile(at url: URL, forceReload: Bool = false) async throws -> ListDocument {
        // Return cached document if available and not forcing reload
        if !forceReload, let cached = getOpenedFile(at: url) {
            AppLogger.cache.info("Using cached document for \(url.lastPathComponent)")
            return cached
        }

        AppLogger.fileStore.debug("[Private] Loading: \(url.lastPathComponent)")

        // Ensure file is downloaded from iCloud if needed
        try await ensureFileDownloaded(at: url)

        // Check if file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "FileStore", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Private list file not found: \(url.lastPathComponent)"
            ])
        }

        // Resolve any iCloud conflicts before opening
        try await resolveConflicts(at: url)

        // Read file
        let data = try Data(contentsOf: url)

        // Decode
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ListDocument.self, from: data)

        // Cache the opened file
        openedFiles[url.path] = (url, document)
        cacheTimestamps[url.path] = Date()

        // Store modification date
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attributes[.modificationDate] as? Date {
            fileModificationDates[url.path] = modDate
        }

        AppLogger.fileStore.info("[Private] Opened: \(document.list.name)")
        return document
    }

    /// Saves a private file (no security-scoped access needed)
    private func savePrivateFile(_ document: ListDocument, to url: URL, bypassOptimisticCheck: Bool = false) async throws {
        AppLogger.fileStore.debug("[Private] Saving: \(url.lastPathComponent)")

        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Check if file changed since we last loaded it
        if !bypassOptimisticCheck, let lastKnownDate = fileModificationDates[url.path] {
            if let currentAttrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let currentDate = currentAttrs[.modificationDate] as? Date,
               currentDate > lastKnownDate {
                AppLogger.sync.warning("[Private] File changed externally - triggering merge")
                let mergedDocument = try await syncPrivateFile(at: url)
                try await savePrivateFile(mergedDocument, to: url, bypassOptimisticCheck: true)
                return
            }
        }

        // Resolve any conflicts before saving
        try await resolveConflicts(at: url)

        // Encode
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        // Use NSFileCoordinator for iCloud-aware writes
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var writeError: Error?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let error = coordinatorError ?? writeError {
            throw error
        }

        // Update cache
        openedFiles[url.path] = (url, document)
        cacheTimestamps[url.path] = Date()

        // Update modification date
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attributes[.modificationDate] as? Date {
            fileModificationDates[url.path] = modDate
        }

        AppLogger.fileStore.info("[Private] Saved: \(document.list.name)")
    }

    /// Syncs a private file by merging cached changes with disk changes
    private func syncPrivateFile(at url: URL) async throws -> ListDocument {
        AppLogger.sync.debug("[Private] Syncing: \(url.lastPathComponent)")

        // Resolve conflicts first
        try await resolveConflicts(at: url)

        // Save cached version before reloading
        let cachedDocument = openedFiles[url.path]?.document

        // Load from disk
        let diskDocument = try await openPrivateFile(at: url, forceReload: true)

        // If no cache, return disk version
        guard let cached = cachedDocument else {
            return diskDocument
        }

        // Merge
        let mergedItems = mergeItems(cached: cached.items, disk: diskDocument.items)
        let mergedLabels = mergeLabels(cached: cached.labels, disk: diskDocument.labels)

        var mergedDocument = diskDocument
        mergedDocument.items = mergedItems
        mergedDocument.labels = mergedLabels

        if cached.list.modifiedAt > diskDocument.list.modifiedAt {
            mergedDocument.list = cached.list
        }

        // Save merged version
        try await savePrivateFile(mergedDocument, to: url, bypassOptimisticCheck: true)

        return mergedDocument
    }

    // MARK: - Private List Discovery

    /// Returns URLs of all private lists in the iCloud container
    func getPrivateListURLs() async throws -> [URL] {
        return try await iCloudContainerManager.shared.discoverListFiles()
    }

    /// Creates a new private list
    func createPrivateList(_ document: ListDocument) async throws {
        let listId = document.list.id
        let source = FileSource.privateList(listId)
        try await saveFile(document, to: source)
        AppLogger.fileStore.info("[Private] Created new list: \(document.list.name)")
    }

    /// Checks if a private list exists
    func privateListExists(_ listId: String) async -> Bool {
        let url = await iCloudContainerManager.shared.fileURL(for: listId)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Utility

    /// Checks if a URL is for a private list (in app's container)
    func isPrivateListURL(_ url: URL) async -> Bool {
        let privateDirectory = await iCloudContainerManager.shared.getPrivateListsDirectory()
        return url.path.hasPrefix(privateDirectory.path)
    }

    /// Gets the file source for a given URL
    func fileSource(for url: URL) async -> FileSource {
        if await isPrivateListURL(url) {
            let listId = url.deletingPathExtension().lastPathComponent
            return .privateList(listId)
        } else {
            return .externalFile(url)
        }
    }
}
