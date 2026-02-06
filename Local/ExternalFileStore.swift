//
//  FileStore.swift (formerly ExternalFileStore)
//  Listie.md
//
//  Unified file store for both private (iCloud container) and external (user-selected) files.
//  Updated to support V2 format with automatic migration and sync resolution.
//

import Foundation

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
        Task {
            await loadBookmarkedFiles()
        }
    }
    
    private func resolveConflicts(at url: URL) async throws {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty else {
            return // No conflicts
        }
        
        print("⚠️ Found \(conflicts.count) conflicting version(s) for \(url.lastPathComponent)")
        
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
            print("✅ Merged \(conflicts.count) conflicting version(s)")
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
            print("⚠️ Merge failed, fell back to newest version")
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
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            // If we can get a download status, it's an iCloud file
            return values.ubiquitousItemDownloadingStatus != nil
        } catch {
            return false
        }
    }

    // Checks if an iCloud file is fully downloaded
    private func isFileDownloaded(at url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        
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
        // Check if it's an iCloud file
        let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        
        guard values.ubiquitousItemDownloadingStatus != nil else {
            // Not an iCloud file
            return
        }
        
        // If not current, trigger download
        if values.ubiquitousItemDownloadingStatus != .current {
            print("☁️ [iCloud] File not fully downloaded, requesting: \(url.lastPathComponent)")
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            
            // Wait a moment for iCloud to respond
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        // Now try to read the file - this will block until iCloud downloads it
        print("☁️ [iCloud] Attempting file access (will auto-download if needed)...")
        let coordinator = NSFileCoordinator()
        var error: NSError?
        var fileSize: Int64 = 0
        
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { readURL in
            if let attributes = try? FileManager.default.attributesOfItem(atPath: readURL.path),
               let size = attributes[.size] as? Int64 {
                fileSize = size
            }
        }
        
        if let error = error {
            throw error
        }
        
        print("✅ [iCloud] File accessible: \(url.lastPathComponent) (\(fileSize) bytes)")
    }
    
    
    
    
    // MARK: - File Management
    
    func openFile(at url: URL, forceReload: Bool = false) async throws -> ListDocument {
        // Return cached document if available and not forcing reload
        if !forceReload, let cached = getOpenedFile(at: url) {
            print("✅ [Cache] Using cached document for \(url.lastPathComponent)")
            return cached
        }

        print("📂 [Cache] Cache miss/expired for \(url.lastPathComponent) - loading from disk")
        
        print("📂 Attempting to open: \(url.path)")

        // Try to access security-scoped resource FIRST
        let didStart = url.startAccessingSecurityScopedResource()
        print("   Security scope started: \(didStart)")

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

        print("   File exists: \(FileManager.default.fileExists(atPath: url.path))")
        print("   Is readable: \(FileManager.default.isReadableFile(atPath: url.path))")

        // Resolve any iCloud conflicts before opening
        try await resolveConflicts(at: url)
        
        // Try direct read first (simpler, works for most cases)
        var content: Data?
        
        do {
            content = try Data(contentsOf: url)
            print("✅ Successfully read \(content?.count ?? 0) bytes")
        } catch {
            print("❌ Failed to read file: \(error)")
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
            print("🧹 Cleaning external file ID: \(document.list.id) -> \(cleanId)")
            var cleanDoc = document
            cleanDoc.list.id = cleanId
            // Don't save here - let user decide if they want to keep it
        }
        
        // Cache the opened file
        openedFiles[url.path] = (url, document)
        
        cacheTimestamps[url.path] = Date()
        print("✅ [Cache] Cached \(document.list.name) (expires in \(cacheTTL)s)")
        
        // Save bookmark
        try await saveBookmark(for: url)
        
        print("✅ Opened external file: \(document.list.name) (V\(document.version))")
        
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
            print("☁️ [Sync] File evicted but not changed: \(url.lastPathComponent)")
            return false  // Eviction is NOT a change
        }
        
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let currentModDate = attributes[.modificationDate] as? Date,
              let storedModDate = fileModificationDates[url.path] else {
            return false
        }
        
        let changed = currentModDate > storedModDate
        if changed {
            print("📝 [Sync] File actually modified: \(url.lastPathComponent)")
        }
        return changed
    }
    
    func saveFile(_ document: ListDocument, to url: URL, bypassOptimisticCheck: Bool = false) async throws {
        print("💾 Attempting to save file: \(url.lastPathComponent)")
        
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
        print("   isWritableFile returned: \(isWritable)")
        
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
                print("⚠️ [OPTIMISTIC LOCK] File changed externally - triggering merge")
                print("   Last known: \(lastKnownDate)")
                print("   Current:    \(currentDate)")   
                
                let mergedDocument = try await syncFile(at: url)
                print("   After merge: \(mergedDocument.labels.count) labels")
                
                
                // Recursive call with bypass flag to prevent infinite loop
                try await saveFile(mergedDocument, to: url, bypassOptimisticCheck: true)
                return
            }
        }
        
        print("💾 [DIRECT SAVE] Writing \(document.labels.count) labels to disk")

        
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
        print("✅ [Cache] Cached \(document.list.name) (expires in \(cacheTTL)s)")
        
        // Update modification date
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attributes[.modificationDate] as? Date {
            fileModificationDates[url.path] = modDate
        }
        
        // Save bookmark
        try await saveBookmark(for: url)
        
        print("✅ Saved external file: \(document.list.name) (V2)")
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
                print("🔄 [Cache] Expired for \(url.lastPathComponent) (TTL: \(cacheTTL)s)")
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
            print("🗑️ [Cache] Cleaning up \(expiredPaths.count) expired entries")
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
            print("🗑️ [External] Removed \(keysToRemove.count) bookmark(s) for \(url.path)")
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
            print("✅ Saved bookmark for: \(url.lastPathComponent)")
        } catch {
            print("⚠️ Could not save bookmark (read-only file?): \(error)")
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
    
    private func loadBookmarkedFiles() async {
        let bookmarks = loadBookmarks()
        unavailableBookmarks.removeAll()

        // Track seen resolved paths to avoid duplicates
        var seenResolvedPaths: Set<String> = []

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

                // If bookmark is stale, try to refresh it while we still have access
                if isStale && didStartAccess {
                    print("🔄 [External] Refreshing stale bookmark for: \(url.lastPathComponent)")
                    do {
                        try await saveBookmark(for: url)
                    } catch {
                        print("⚠️ [External] Failed to refresh stale bookmark: \(error)")
                    }
                }

                // If we couldn't start security-scoped access, the bookmark may have lost permissions
                // This can happen after iOS updates, app reinstalls, or extended time without access
                if !didStartAccess {
                    print("⚠️ [External] Security scope access denied for: \(fileName)")
                    // Don't mark as unavailable yet - the file might still be accessible
                    // The openFile() call will be the final arbiter
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
                    print("⚠️ [External] File is in Trash: \(path)")
                    continue
                }

                // Check if file exists locally OR is an iCloud placeholder
                if !FileManager.default.fileExists(atPath: url.path) {
                    // Check if it's an iCloud file that's just not downloaded
                    let isICloudPlaceholder = isICloudFile(at: url)

                    if isICloudPlaceholder {
                        // File exists in iCloud but not downloaded locally - treat as available
                        // It will be downloaded on-demand when opened via ensureFileDownloaded()
                        print("☁️ [External] iCloud file not downloaded locally (available): \(fileName)")
                        continue
                    }

                    // Truly not found - not an iCloud placeholder
                    unavailableBookmarks[url.path] = UnavailableBookmark(
                        id: path,
                        originalPath: url.path,
                        reason: .fileNotFound,
                        fileName: fileName,
                        folderName: folderName
                    )
                    print("⚠️ [External] File not found: \(path)")
                    continue
                }

                // File is available - not in unavailableBookmarks
            } catch {
                // Bookmark can't be resolved - track as unavailable (use bookmark key path)
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
                print("⚠️ [External] Invalid bookmark for \(path): \(error)")
            }
        }

        if !unavailableBookmarks.isEmpty {
            print("⚠️ [External] \(unavailableBookmarks.count) bookmark(s) are unavailable")
        }
    }
    
    func getBookmarkedURLs() -> [URL] {
        let bookmarks = loadBookmarks()
        var urls: [URL] = []
        var seenPaths: Set<String> = []

        for (_, bookmarkData) in bookmarks {
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

                // Skip duplicates
                guard !seenPaths.contains(url.path) else { continue }
                seenPaths.insert(url.path)

                // Skip files in .Trash (handled by unavailableBookmarks)
                if url.path.contains("/.Trash/") {
                    continue
                }

                // Start security-scoped access to check file attributes
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                // Check if file exists OR is an iCloud placeholder
                if FileManager.default.fileExists(atPath: url.path) {
                    urls.append(url)
                } else if isICloudFile(at: url) {
                    // iCloud file not downloaded locally - still include it
                    // openFile() will handle downloading via ensureFileDownloaded()
                    urls.append(url)
                }
                // If neither exists nor is iCloud placeholder, skip it
                // (handled by unavailableBookmarks from loadBookmarkedFiles)
            } catch {
                // Bookmark resolution failed - skip silently
                // (handled by unavailableBookmarks from loadBookmarkedFiles)
                continue
            }
        }

        return urls
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

        print("🧹 [Cache] Cleared \(keysToRemove.count) private list cache entries")
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
        print("🗑️ [External] Removed unavailable bookmark: \(bookmark.fileName)")
    }

    /// Refreshes the availability status of all bookmarks
    func refreshBookmarkAvailability() async {
        await loadBookmarkedFiles()
    }
    
    private func preferredFileExtension() -> String {
        return "listie"  // Use .listie for new files
    }
    
    func updateCache(_ document: ListDocument, at url: URL) async {
        openedFiles[url.path] = (url, document)
        
        cacheTimestamps[url.path] = Date()
        print("✅ [Cache] Cached \(document.list.name) (expires in \(cacheTTL)s)")
    }
    
    // MARK: - Sync Resolution
    
    /// Syncs file by merging cached changes with disk changes, using modification dates to resolve conflicts
    func syncFile(at url: URL) async throws -> ListDocument {
        print("🔄 Syncing file: \(url.lastPathComponent)")
        
        // Resolve conflicts first to ensure clean state
        try await resolveConflicts(at: url)
        
        // 1. IMPORTANT: Save the cached version BEFORE reloading from disk
        let cachedDocument = openedFiles[url.path]?.document
        
        // 2. Load current file from disk (this will update the cache, so we saved it above)
        let diskDocument = try await openFile(at: url, forceReload: true)
        
        // 3. If no cache existed, just return disk version
        guard let cached = cachedDocument else {
            print("✅ No cache, using disk version")
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
        
        print("✅ Sync complete: \(mergedItems.count) items, \(mergedLabels.count) labels")
        
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
                        print("  📝 Item '\(cachedItem.note)': cache is newer (\(cachedItem.modifiedAt) vs \(diskItem.modifiedAt))")
                    }
                } else if diskItem.modifiedAt > cachedItem.modifiedAt {
                    // Disk is newer - already in dict, just log if meaningful difference
                    if diskItem.modifiedAt.timeIntervalSince(cachedItem.modifiedAt) > 1 {
                        print("  📝 Item '\(diskItem.note)': disk is newer (\(diskItem.modifiedAt) vs \(cachedItem.modifiedAt))")
                    }
                }
                // If timestamps are equal (within 1 second), don't log - no conflict
            } else {
                // Only in cache - add it (new item created locally)
                itemsById[cachedItem.id] = cachedItem
                print("  ➕ Item '\(cachedItem.note)': added from cache")
            }
        }
        
        // Check for items only in disk (new items created remotely)
        for diskItem in disk {
            if !cached.contains(where: { $0.id == diskItem.id }) {
                print("  ➕ Item '\(diskItem.note)': added from disk")
            }
        }
        
        return Array(itemsById.values).sorted { $0.modifiedAt > $1.modifiedAt }
    }
    
    /// Merges labels from cache and disk
    /// Merges labels from cache and disk
    private func mergeLabels(cached: [ShoppingLabel], disk: [ShoppingLabel]) -> [ShoppingLabel] {
        // LATEST SAVE WINS - just use cached labels (what we're about to save)
        // Merging labels is unnecessary complexity for a low-risk operation
        return cached
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
            print("⚠️ [Private] File already deleted: \(listId)")
            return
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var deleteError: Error?

        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { deleteURL in
            do {
                try FileManager.default.removeItem(at: deleteURL)
                print("🗑️ [Private] Deleted list: \(listId)")
            } catch {
                deleteError = error
            }
        }

        if let error = coordinatorError ?? deleteError {
            print("❌ [Private] Failed to delete list: \(error)")
            throw error
        }
    }

    // MARK: - Private List File Operations

    /// Opens a private file (no security-scoped access needed)
    private func openPrivateFile(at url: URL, forceReload: Bool = false) async throws -> ListDocument {
        // Return cached document if available and not forcing reload
        if !forceReload, let cached = getOpenedFile(at: url) {
            print("✅ [Cache] Using cached document for \(url.lastPathComponent)")
            return cached
        }

        print("📂 [Private] Loading: \(url.lastPathComponent)")

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

        print("✅ [Private] Opened: \(document.list.name)")
        return document
    }

    /// Saves a private file (no security-scoped access needed)
    private func savePrivateFile(_ document: ListDocument, to url: URL, bypassOptimisticCheck: Bool = false) async throws {
        print("💾 [Private] Saving: \(url.lastPathComponent)")

        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Check if file changed since we last loaded it
        if !bypassOptimisticCheck, let lastKnownDate = fileModificationDates[url.path] {
            if let currentAttrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let currentDate = currentAttrs[.modificationDate] as? Date,
               currentDate > lastKnownDate {
                print("⚠️ [Private] File changed externally - triggering merge")
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

        print("✅ [Private] Saved: \(document.list.name)")
    }

    /// Syncs a private file by merging cached changes with disk changes
    private func syncPrivateFile(at url: URL) async throws -> ListDocument {
        print("🔄 [Private] Syncing: \(url.lastPathComponent)")

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
        print("✅ [Private] Created new list: \(document.list.name)")
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
