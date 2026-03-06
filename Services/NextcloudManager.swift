//
//  NextcloudManager.swift
//  Listie.md
//
//  Actor that owns all Nextcloud I/O: credential management, local disk cache,
//  ETag-based change detection, upload queue, and offline-first sync.
//

import Foundation
import Network
import NextcloudKit
import os

// MARK: - NextcloudManager

actor NextcloudManager {
    static let shared = NextcloudManager()

    // MARK: - Private state

    /// NextcloudKit instance — .shared in Swift 5 (init is internal), own instance in Swift 6+ (init is public).
    #if swift(<6.0)
    private let nk = NextcloudKit.shared
    #else
    private let nk = NextcloudKit()
    #endif

    /// `Library/Application Support/NextcloudLists/`
    private let cacheDir: URL

    /// Currently loaded credentials (nil = not connected).
    private(set) var credentials: NextcloudCredentials?

    /// ETag per "accountId:remotePath". Persisted via UserDefaults.
    private var etagStore: [String: String] = [:]

    /// In-memory parsed document cache.
    private var memCache: [String: ListDocument] = [:]

    /// Remote paths with unsaved local changes.
    private var pendingUploads: Set<String> = []

    private var pathMonitor: NWPathMonitor?

    private static let etagDefaultsKey = "com.listie.nextcloud.etags"
    private static let pendingUploadsKey = "com.listie.nextcloud.pendingUploads"

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("NextcloudLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Load persisted ETag store
        if let data = UserDefaults.standard.data(forKey: Self.etagDefaultsKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            etagStore = dict
        }

        // Restore pending uploads so offline edits survive app kills
        if let data = UserDefaults.standard.data(forKey: Self.pendingUploadsKey),
           let set = try? JSONDecoder().decode(Set<String>.self, from: data) {
            pendingUploads = set
        }

        // Restore session if credentials are saved
        if let creds = NextcloudCredentials.load() {
            credentials = creds
            creds.setupSession(nk: nk)
            // Actor init is synchronous so we defer monitor start
            Task { await NextcloudManager.shared.startNetworkMonitor() }
        }
    }

    private func savePendingUploads() {
        if let data = try? JSONEncoder().encode(pendingUploads) {
            UserDefaults.standard.set(data, forKey: Self.pendingUploadsKey)
        }
    }

    // MARK: - Session lifecycle

    /// Registers credentials and sets up the NextcloudKit session.
    func setup(credentials: NextcloudCredentials) {
        self.credentials = credentials
        credentials.setupSession(nk: nk)
        startNetworkMonitor()
    }

    private func startNetworkMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { await NextcloudManager.shared.retryPendingUploads() }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    /// Removes the session and clears credentials.
    func disconnect() {
        guard let creds = credentials else { return }
        // Remove all local cache for this account
        let accountCacheDir = cacheDir.appendingPathComponent(creds.accountId.sanitizedForFilename, isDirectory: true)
        try? FileManager.default.removeItem(at: accountCacheDir)
        // Clear ETag entries for this account
        let prefix = "\(creds.accountId):"
        etagStore = etagStore.filter { !$0.key.hasPrefix(prefix) }
        saveEtags()
        memCache = memCache.filter { !$0.key.hasPrefix(prefix) }
        pendingUploads = pendingUploads.filter { !$0.hasPrefix(prefix) }
        savePendingUploads()
        credentials = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Login Flow v2

    /// Initiates Login Flow v2. Returns the URL to open in a browser and the polling info.
    /// Call without credentials — this is an unauthenticated request to the server.
    func startLoginFlowV2(serverURL: String) async throws -> (loginURL: URL, token: String, endpoint: String) {
        nk.setup(groupIdentifier: nil)
        let result = try await nk.getLoginFlowV2(serverUrl: serverURL)
        return (loginURL: result.login, token: result.token, endpoint: result.endpoint.absoluteString)
    }

    /// Polls Login Flow v2 once. Returns credentials if the user completed sign-in, nil if not yet done.
    func pollLoginFlowV2(token: String, endpoint: String) async -> NextcloudCredentials? {
        let result = await nk.getLoginFlowV2PollAsync(token: token, endpoint: endpoint)
        guard result.error == .success,
              let server = result.server,
              let loginName = result.loginName,
              let appPassword = result.appPassword else { return nil }
        return NextcloudCredentials(serverURL: server, username: loginName, appPassword: appPassword)
    }

    // MARK: - File browser

    /// Lists files at a given remote path (e.g. "/", "/lists").
    func listFiles(at remotePath: String) async throws -> [NKFile] {
        guard let creds = credentials else { throw NCError.notConnected }
        let url = creds.davURL(for: remotePath)
        let result = await nk.readFileOrFolderAsync(
            serverUrlFileName: url,
            depth: "1",
            account: creds.accountId
        )
        guard result.error == .success, let files = result.files else {
            throw NCError.networkError(result.error.errorDescription ?? "Unknown error")
        }
        // PROPFIND depth:1 always returns the collection root as the first entry.
        // Drop it so the browser only shows children, not the folder itself.
        return Array(files.dropFirst())
    }

    // MARK: - Core I/O

    /// Opens a file, serving from cache immediately and refreshing in background.
    func openFile(remotePath: String, forceReload: Bool = false) async throws -> ListDocument {
        guard let creds = credentials else { throw NCError.notConnected }

        let cacheKey = cacheKey(creds: creds, remotePath: remotePath)

        // 1. Return in-memory cache if available and not forcing a reload.
        if !forceReload, let cached = memCache[cacheKey] {
            // Kick off background ETag check without blocking
            Task { try? await backgroundSync(remotePath: remotePath) }
            return cached
        }

        // 2. Try disk cache
        let diskURL = localCacheURL(creds: creds, remotePath: remotePath)
        if !forceReload, FileManager.default.fileExists(atPath: diskURL.path) {
            if let doc = try? loadFromDisk(at: diskURL) {
                memCache[cacheKey] = doc
                Task { try? await backgroundSync(remotePath: remotePath) }
                return doc
            }
        }

        // 3. Download from server
        return try await downloadFile(creds: creds, remotePath: remotePath)
    }

    /// Writes a document to local cache and uploads it.
    /// Uses a two-stage merge to handle concurrent server changes:
    ///
    /// Stage 1 — memCache merge: `syncIfNeeded` or a background refresh may have written a
    /// newer server version into memCache after the caller's edit was based on an older snapshot.
    /// Reading memCache BEFORE overwriting it and merging catches this without an extra network call.
    ///
    /// Stage 2 — server ETag check: if the server has a version that isn't even in memCache yet
    /// (i.e. etagStore diverges from the server), download and merge before uploading.
    func saveFile(_ doc: ListDocument, to remotePath: String) async throws {
        guard let creds = credentials else { throw NCError.notConnected }

        let key = cacheKey(creds: creds, remotePath: remotePath)

        // Stage 1: merge with whatever is currently in memCache.
        // If syncIfNeeded ran between the user's edit and autosave it will have written a
        // newer server version there; merging now ensures those changes aren't lost.
        var workingDoc = doc
        if let cached = memCache[key] {
            workingDoc = mergeDocuments(local: doc, server: cached)
        }

        // Write merged version to local cache
        memCache[key] = workingDoc
        let diskURL = localCacheURL(creds: creds, remotePath: remotePath)
        try? saveToDisk(workingDoc, at: diskURL)
        pendingUploads.insert(remotePath)
        savePendingUploads()

        do {
            // Stage 2: check whether the server has a version beyond what's in memCache.
            // Background sync deliberately skips updating etagStore so this can still fire
            // when only memCache was refreshed.
            let serverChanged = (try? await hasFileChanged(remotePath: remotePath)) ?? false
            let docToUpload: ListDocument

            if serverChanged {
                AppLogger.nextcloud.info("[NC] Server changed before upload — merging: \(remotePath, privacy: .public)")
                let serverDoc = try await downloadFile(creds: creds, remotePath: remotePath)
                let merged = mergeDocuments(local: workingDoc, server: serverDoc)
                memCache[key] = merged
                try? saveToDisk(merged, at: localCacheURL(creds: creds, remotePath: remotePath))
                docToUpload = merged
            } else {
                docToUpload = workingDoc
            }

            try await uploadFile(creds: creds, doc: docToUpload, remotePath: remotePath)
            pendingUploads.remove(remotePath)
            savePendingUploads()
        } catch {
            AppLogger.nextcloud.warning("[NC] Upload failed, queued for retry: \(remotePath, privacy: .public) — \(error, privacy: .public)")
            // Left in pendingUploads; NWPathMonitor + syncIfNeeded will retry
        }
    }

    /// Updates only the in-memory and disk cache without uploading.
    func updateCache(_ doc: ListDocument, remotePath: String) async {
        guard let creds = credentials else { return }
        let key = cacheKey(creds: creds, remotePath: remotePath)
        memCache[key] = doc
        let diskURL = localCacheURL(creds: creds, remotePath: remotePath)
        try? saveToDisk(doc, at: diskURL)
    }

    /// Returns true if the server ETag differs from the locally cached ETag.
    /// Returns true if the server ETag differs from the cached ETag.
    /// Throws `NCError.notFound` if the server returns 404 (file deleted or moved).
    /// Returns false for other network errors (assume unchanged).
    func hasFileChanged(remotePath: String) async throws -> Bool {
        guard let creds = credentials else { return false }
        let url = creds.davURL(for: remotePath)
        let result = await nk.readFileOrFolderAsync(
            serverUrlFileName: url,
            depth: "0",
            account: creds.accountId
        )
        if result.error.errorCode == 404 {
            throw NCError.notFound(remotePath)
        }
        guard result.error == .success, let serverEtag = result.files?.first?.etag else {
            return false  // transient network error — assume unchanged
        }
        let key = etagKey(creds: creds, remotePath: remotePath)
        return serverEtag != etagStore[key]
    }

    /// Background refresh triggered after serving from cache.
    /// Downloads the latest server version into memCache WITHOUT updating `etagStore`.
    /// Keeping `etagStore` at the last explicitly-synced ETag means `hasFileChanged` will
    /// still return `true` when `saveFile` runs, so any conflict is caught and merged there.
    /// Posts `nextcloudFileNotFound` if the server returns 404.
    private func backgroundSync(remotePath: String) async throws {
        guard let creds = credentials else { return }
        do {
            let serverChanged = try await hasFileChanged(remotePath: remotePath)
            guard serverChanged else { return }
            _ = try await downloadFile(creds: creds, remotePath: remotePath, updateEtag: false)
            AppLogger.nextcloud.debug("[NC] Background refresh: new server version cached (eTag held): \(remotePath, privacy: .public)")
        } catch NCError.notFound {
            AppLogger.nextcloud.warning("[NC] Background sync: file not found on server: \(remotePath, privacy: .public)")
            NotificationCenter.default.post(
                name: .nextcloudFileNotFound,
                object: nil,
                userInfo: ["remotePath": remotePath]
            )
        }
        // Other errors (network) are silently ignored — transient failures don't need action
    }

    /// Syncs with the server. Handles three cases:
    /// - Both local pending AND server changed → download server, 3-way merge, upload merged result
    /// - Only local pending → upload local to server
    /// - Only server changed → download server version
    /// Throws `NCError.notFound` if the server returns 404.
    @discardableResult
    func syncFile(remotePath: String) async throws -> ListDocument {
        guard let creds = credentials else { throw NCError.notConnected }

        let hasPending = pendingUploads.contains(remotePath)
        // Always check server ETag first (before uploading) — throws NCError.notFound if file deleted
        let serverChanged = try await hasFileChanged(remotePath: remotePath)

        let key = cacheKey(creds: creds, remotePath: remotePath)

        if hasPending && serverChanged {
            // CONFLICT: both sides have changes — 3-way merge
            AppLogger.nextcloud.info("[NC] Conflict on \(remotePath, privacy: .public) — merging local + server")
            let localDoc = memCache[key] ?? (try? loadFromDisk(at: localCacheURL(creds: creds, remotePath: remotePath)))
            // Download server version (updates memCache/disk/ETag)
            let serverDoc = try await downloadFile(creds: creds, remotePath: remotePath)
            guard let localDoc else {
                // No local doc to merge from — keep server version, drop pending
                pendingUploads.remove(remotePath)
                savePendingUploads()
                return serverDoc
            }
            let mergedDoc = mergeDocuments(local: localDoc, server: serverDoc)
            try await uploadFile(creds: creds, doc: mergedDoc, remotePath: remotePath)
            pendingUploads.remove(remotePath)
            savePendingUploads()
            memCache[key] = mergedDoc
            try? saveToDisk(mergedDoc, at: localCacheURL(creds: creds, remotePath: remotePath))
            AppLogger.nextcloud.info("[NC] Conflict resolved for \(remotePath, privacy: .public)")
            return mergedDoc

        } else if hasPending {
            // Local changes only — upload and return local
            let doc = memCache[key] ?? (try? loadFromDisk(at: localCacheURL(creds: creds, remotePath: remotePath)))
            if let doc {
                try await uploadFile(creds: creds, doc: doc, remotePath: remotePath)
                pendingUploads.remove(remotePath)
                savePendingUploads()
                return doc
            }
            pendingUploads.remove(remotePath)
            savePendingUploads()

        } else if serverChanged {
            // Server changes only — download
            return try await downloadFile(creds: creds, remotePath: remotePath)
        }

        // No changes — return cached or download fresh if no cache
        if let cached = memCache[key] { return cached }
        return try await downloadFile(creds: creds, remotePath: remotePath)
    }

    /// Merges a local document with a freshly downloaded server document.
    /// Items: merge by ID, latest `modifiedAt` wins. Labels: union, server wins on conflict.
    /// List summary: latest `modifiedAt` wins.
    private func mergeDocuments(local: ListDocument, server: ListDocument) -> ListDocument {
        // Items: latest modifiedAt wins per ID
        var itemsById: [UUID: ShoppingItem] = Dictionary(
            uniqueKeysWithValues: server.items.map { ($0.id, $0) }
        )
        for item in local.items {
            if let existing = itemsById[item.id] {
                if item.modifiedAt > existing.modifiedAt { itemsById[item.id] = item }
            } else {
                itemsById[item.id] = item
            }
        }

        // Labels: no modifiedAt — server wins on conflict, local adds new labels only
        var labelsById: [String: ShoppingLabel] = Dictionary(
            uniqueKeysWithValues: server.labels.map { ($0.id, $0) }
        )
        for label in local.labels where labelsById[label.id] == nil {
            labelsById[label.id] = label
        }

        // List summary: latest modifiedAt wins
        let summary = local.list.modifiedAt > server.list.modifiedAt ? local.list : server.list

        return ListDocument(
            list: summary,
            items: Array(itemsById.values),
            labels: Array(labelsById.values)
        )
    }

    /// Removes a file from in-memory cache and pending uploads (does NOT delete disk cache).
    func closeFile(remotePath: String) async {
        guard let creds = credentials else { return }
        let key = cacheKey(creds: creds, remotePath: remotePath)
        memCache.removeValue(forKey: key)
        if pendingUploads.remove(remotePath) != nil { savePendingUploads() }
    }

    /// Removes from cache and pending; deletes the disk cache file.
    func removeLocalCache(remotePath: String) async {
        guard let creds = credentials else { return }
        let key = cacheKey(creds: creds, remotePath: remotePath)
        memCache.removeValue(forKey: key)
        if pendingUploads.remove(remotePath) != nil { savePendingUploads() }
        let diskURL = localCacheURL(creds: creds, remotePath: remotePath)
        try? FileManager.default.removeItem(at: diskURL)
        let ekey = etagKey(creds: creds, remotePath: remotePath)
        etagStore.removeValue(forKey: ekey)
        saveEtags()
    }

    func hasPendingUpload(remotePath: String) -> Bool {
        pendingUploads.contains(remotePath)
    }

    /// Retries all pending uploads (call when network becomes available).
    func retryPendingUploads() async {
        guard let creds = credentials, !pendingUploads.isEmpty else { return }
        var succeeded: Set<String> = []
        for remotePath in pendingUploads {
            let key = cacheKey(creds: creds, remotePath: remotePath)
            // Fall back to disk cache — memCache may be empty after an app restart
            let doc = memCache[key] ?? (try? loadFromDisk(at: localCacheURL(creds: creds, remotePath: remotePath)))
            guard let doc else {
                AppLogger.nextcloud.warning("[NC] No cached doc for pending upload: \(remotePath, privacy: .public)")
                continue
            }
            do {
                try await uploadFile(creds: creds, doc: doc, remotePath: remotePath)
                succeeded.insert(remotePath)
                AppLogger.nextcloud.info("[NC] Retry upload succeeded: \(remotePath, privacy: .public)")
            } catch {
                AppLogger.nextcloud.warning("[NC] Retry upload failed: \(remotePath, privacy: .public) — \(error, privacy: .public)")
            }
        }
        if !succeeded.isEmpty {
            pendingUploads.subtract(succeeded)
            savePendingUploads()
        }
    }

    // MARK: - Helpers: cache keys & paths

    private func cacheKey(creds: NextcloudCredentials, remotePath: String) -> String {
        "\(creds.accountId):\(remotePath)"
    }

    private func etagKey(creds: NextcloudCredentials, remotePath: String) -> String {
        "\(creds.accountId):\(remotePath)"
    }

    private func localCacheURL(creds: NextcloudCredentials, remotePath: String) -> URL {
        let accountDir = cacheDir.appendingPathComponent(creds.accountId.sanitizedForFilename, isDirectory: true)
        try? FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        let escapedPath = remotePath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        // Preserve .listie extension so the file is opened by the right UTI
        let filename = escapedPath.hasSuffix(".listie") ? escapedPath : "\(escapedPath).listie"
        return accountDir.appendingPathComponent(filename)
    }

    // MARK: - Helpers: download / upload

    private func downloadFile(creds: NextcloudCredentials, remotePath: String, updateEtag: Bool = true) async throws -> ListDocument {
        let serverURL = creds.davURL(for: remotePath)

        // Download to a temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("listie")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = await nk.downloadAsync(
            serverUrlFileName: serverURL,
            fileNameLocalPath: tempURL.path,
            account: creds.accountId
        )
        guard result.nkError == .success else {
            if result.nkError.errorCode == 404 {
                throw NCError.notFound(remotePath)
            }
            throw NCError.networkError(result.nkError.errorDescription ?? "Download failed")
        }

        let doc = try loadFromDisk(at: tempURL)

        // Update caches
        let key = cacheKey(creds: creds, remotePath: remotePath)
        memCache[key] = doc
        let diskURL = localCacheURL(creds: creds, remotePath: remotePath)
        try? saveToDisk(doc, at: diskURL)

        // Update ETag (skipped for background refreshes — see backgroundSync)
        if updateEtag, let etag = result.etag {
            let ekey = etagKey(creds: creds, remotePath: remotePath)
            etagStore[ekey] = etag
            saveEtags()
        }

        return doc
    }

    private func uploadFile(creds: NextcloudCredentials, doc: ListDocument, remotePath: String) async throws {
        // Encode to a temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("listie")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        try saveToDisk(doc, at: tempURL)

        let serverURL = creds.davURL(for: remotePath)
        let result = await nk.uploadAsync(
            serverUrlFileName: serverURL,
            fileNameLocalPath: tempURL.path,
            overwrite: true,
            autoMkcol: true,
            account: creds.accountId
        )
        guard result.error == .success else {
            throw NCError.networkError(result.error.errorDescription ?? "Upload failed")
        }

        // Update ETag from upload response
        if let etag = result.etag {
            let ekey = etagKey(creds: creds, remotePath: remotePath)
            etagStore[ekey] = etag
            saveEtags()
        }

        AppLogger.nextcloud.info("[NC] Uploaded \(remotePath, privacy: .public)")
    }

    // MARK: - JSON helpers

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func saveToDisk(_ doc: ListDocument, at url: URL) throws {
        let data = try encoder.encode(doc)
        try data.write(to: url, options: .atomic)
    }

    private func loadFromDisk(at url: URL) throws -> ListDocument {
        let data = try Data(contentsOf: url)
        return try decoder.decode(ListDocument.self, from: data)
    }

    // MARK: - ETag persistence

    private func saveEtags() {
        if let data = try? JSONEncoder().encode(etagStore) {
            UserDefaults.standard.set(data, forKey: Self.etagDefaultsKey)
        }
    }
}

// MARK: - Error

enum NCError: LocalizedError {
    case notConnected
    case notFound(String)       // HTTP 404 — file deleted or moved on server
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Nextcloud"
        case .notFound(let path): return "File not found on server: \(path)"
        case .networkError(let msg): return msg
        }
    }
}

// MARK: - String helper

private extension String {
    /// Replaces characters that are unsafe for use as filesystem directory names.
    var sanitizedForFilename: String {
        self.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "@", with: "_at_")
    }
}
