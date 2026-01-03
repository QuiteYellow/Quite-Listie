//
//  ExternalFileStore_v2.swift
//  Listie.md
//
//  Updated to support V2 format with automatic migration and sync resolution
//

import Foundation

actor ExternalFileStore {
    static let shared = ExternalFileStore()
    
    private let defaultsKey = "com.listie.external-files"
    
    // In-memory cache of opened external files
    private var openedFiles: [String: (url: URL, document: ListDocument)] = [:]
    
    // Track file modification dates for change detection
    private var fileModificationDates: [String: Date] = [:]
    
    // TTL for cache
    private var cacheTimestamps: [String: Date] = [:]
    private let cacheTTL: TimeInterval = 30 // 30 seconds
    
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
                print("⚠️ File changed externally since last load - merging before save")
                
                let mergedDocument = try await syncFile(at: url)
                
                // Recursive call with bypass flag to prevent infinite loop
                try await saveFile(mergedDocument, to: url, bypassOptimisticCheck: true)
                return
            }
        }
        
        // Resolve any conflicts before saving
        try await resolveConflicts(at: url)
        
        let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            
        let data = try encoder.encode(document)
        
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
                // If bookmark can't be resolved, remove it anyway
                keysToRemove.append(key)
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
        var bookmarks = loadBookmarks()
        var bookmarksToRemove: [String] = []
        
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
                
                // Check if file still exists and is not in trash
                if !FileManager.default.fileExists(atPath: url.path) || url.path.contains("/.Trash/") {
                    bookmarksToRemove.append(path)
                    print("🗑️ [External] Removing bookmark for deleted/trashed file: \(path)")
                }
            } catch {
                // Bookmark can't be resolved - remove it
                bookmarksToRemove.append(path)
                print("🗑️ [External] Removing invalid bookmark for \(path): \(error)")
            }
        }
        
        // Clean up invalid bookmarks
        if !bookmarksToRemove.isEmpty {
            for path in bookmarksToRemove {
                bookmarks.removeValue(forKey: path)
            }
            saveBookmarks(bookmarks)
            print("✅ [External] Cleaned up \(bookmarksToRemove.count) invalid bookmark(s)")
        }
    }
    
    func getBookmarkedURLs() -> [URL] {
        let bookmarks = loadBookmarks()
        var urls: [URL] = []
        
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
                
                if FileManager.default.fileExists(atPath: url.path) {
                    // Skip files in .Trash
                    if url.path.contains("/.Trash/") {
                        continue
                    }
                    urls.append(url)
                }
            } catch {
                continue
            }
        }
        
        return urls
    }
    
    func clearBookmarks() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        openedFiles.removeAll()
        fileModificationDates.removeAll()
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
    private func mergeLabels(cached: [ShoppingLabel], disk: [ShoppingLabel]) -> [ShoppingLabel] {
        var labelsById: [String: ShoppingLabel] = [:]
        
        // Add all disk labels
        for label in disk {
            labelsById[label.id] = label
        }
        
        // Add cached labels not in disk
        for label in cached {
            if labelsById[label.id] == nil {
                labelsById[label.id] = label
            }
        }
        
        return Array(labelsById.values)
    }
}
