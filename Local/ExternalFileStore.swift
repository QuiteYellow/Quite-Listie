//
//  ExternalFileStore_v2.swift
//  ListsForMealie
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
    
    init() {
        Task {
            await loadBookmarkedFiles()
        }
    }
    
    // MARK: - File Management
    
    func openFile(at url: URL, forceReload: Bool = false) async throws -> ListDocument {
        // Return cached document if available and not forcing reload
        if !forceReload, let cached = openedFiles[url.path]?.document {
            return cached
        }
        
        // Otherwise read from disk
        var didStart = false
        if url.startAccessingSecurityScopedResource() {
            didStart = true
        }
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        // Use NSFileCoordinator for reading
        let coordinator = NSFileCoordinator()
        var content: Data?
        var coordinatorError: NSError?
        
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            content = try? Data(contentsOf: readURL)
        }
        
        if let error = coordinatorError {
            throw error
        }
        
        guard let data = content else {
            throw NSError(domain: "ExternalFileStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read file"])
        }
        
        // Load and migrate document if necessary
        var document = try ListDocumentMigration.loadDocument(from: data)
        
        // Ensure clean ID
        let cleanId = document.list.cleanId
        if document.list.id != cleanId {
            print("🧹 Cleaning external file ID: \(document.list.id) -> \(cleanId)")
            document.list.id = cleanId
            // We'll save the cleaned version when the user makes changes
        }
        
        // Cache the opened file
        openedFiles[url.path] = (url, document)
        
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let currentModDate = attributes[.modificationDate] as? Date,
              let storedModDate = fileModificationDates[url.path] else {
            return false
        }
        return currentModDate > storedModDate
    }
    
    func saveFile(_ document: ListDocument, to url: URL) async throws {
        var didStart = false
        if url.startAccessingSecurityScopedResource() {
            didStart = true
        }
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        // Ensure we're saving in V2 format
        let data = try ListDocumentMigration.saveDocument(document)
        
        // Use NSFileCoordinator for writing
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { writeURL in
            try? data.write(to: writeURL, options: .atomic)
        }
        
        if let error = coordinatorError {
            throw error
        }
        
        // Update cache
        openedFiles[url.path] = (url, document)
        
        // Update modification date
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attributes[.modificationDate] as? Date {
            fileModificationDates[url.path] = modDate
        }
        
        // Save bookmark
        try await saveBookmark(for: url)
        
        print("✅ Saved external file: \(document.list.name) (V2)")
    }
    
    func getOpenedFile(at url: URL) -> ListDocument? {
        return openedFiles[url.path]?.document
    }
    
    func getOpenedFiles() -> [(url: URL, document: ListDocument)] {
        return Array(openedFiles.values)
    }
    
    func closeFile(at url: URL) {
        openedFiles.removeValue(forKey: url.path)
        fileModificationDates.removeValue(forKey: url.path)
        
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
    
    func updateCache(_ document: ListDocument, at url: URL) async {
        openedFiles[url.path] = (url, document)
    }
    
    // MARK: - Sync Resolution
    
    /// Syncs file by merging cached changes with disk changes, using modification dates to resolve conflicts
    func syncFile(at url: URL) async throws -> ListDocument {
        print("🔄 Syncing file: \(url.lastPathComponent)")
        
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
