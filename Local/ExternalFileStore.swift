//
//  ExternalFileStore_v2.swift
//  ListsForMealie
//
//  Updated to support V2 format with automatic migration
//

import Foundation

actor ExternalFileStore {
    static let shared = ExternalFileStore()
    
    private let defaultsKey = "com.listie.external-files"
    
    private var filePresenters: [String: ExternalFilePresenter] = [:]
    
    // In-memory cache of opened external files
    private var openedFiles: [String: (url: URL, document: ListDocument)] = [:]
    
    init() {
        Task {
            await loadBookmarkedFiles()
        }
    }
    
    // MARK: - File Management
    
    private var fileModificationDates: [String: Date] = [:]

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
            print("ðŸ”„ Cleaning external file ID: \(document.list.id) -> \(cleanId)")
            document.list.id = cleanId
            // We'll save the cleaned version when the user makes changes
        }
        
        // Cache the opened file
        openedFiles[url.path] = (url, document)
        
        // Save bookmark
        try await saveBookmark(for: url)
        
        print("âœ… Opened external file: \(document.list.name) (V\(document.version))")
        
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
        
        // Save bookmark
        try await saveBookmark(for: url)
        
        print("âœ… Saved external file: \(document.list.name) (V2)")
    }
    
    func getOpenedFile(at url: URL) -> ListDocument? {
        return openedFiles[url.path]?.document
    }
    
    func getOpenedFiles() -> [(url: URL, document: ListDocument)] {
        return Array(openedFiles.values)
    }
    
    func closeFile(at url: URL) {
        stopMonitoring(url: url)
        openedFiles.removeValue(forKey: url.path)
        
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
    }
    
    func updateCache(_ document: ListDocument, at url: URL) async {
        openedFiles[url.path] = (url, document)
    }
    
    func startMonitoring(url: URL) async {
        guard filePresenters[url.path] == nil else { return }
        
        let presenter = ExternalFilePresenter(url: url) { [weak self] in
            Task {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .externalFileChanged,
                        object: url
                    )
                }
            }
        }
        
        filePresenters[url.path] = presenter
        print("👁️ Started monitoring: \(url.lastPathComponent)")
    }

    func stopMonitoring(url: URL) {
        filePresenters.removeValue(forKey: url.path)
        print("🛑 Stopped monitoring: \(url.lastPathComponent)")
    }
}
