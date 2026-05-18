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

    /// In-flight download tasks keyed by cacheKey. Prevents duplicate downloads when multiple
    /// callers request the same file before the first download completes (actor reentrancy).
    private var inFlightDownloads: [String: Task<ListDocument, Error>] = [:]

    private var pathMonitor: NWPathMonitor?

    /// Set to true when the app crosses an inactive→active boundary or any other event
    /// that may have invalidated the NextcloudKit URLSession. The next credential resolution
    /// rebuilds the session, then clears this flag.
    private var needsReactivation: Bool = false

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
            // Migration: re-save to upgrade keychain accessibility to AfterFirstUnlock.
            try? creds.save()
            // End migration: can be removed once all users have run this version.
        }
    }

    private func savePendingUploads() {
        if let data = try? JSONEncoder().encode(pendingUploads) {
            UserDefaults.standard.set(data, forKey: Self.pendingUploadsKey)
        }
    }

    // MARK: - Session lifecycle

    /// Returns current credentials, refreshing the session if needed and retrying the
    /// keychain with bounded backoff when credentials aren't in memory.
    ///
    /// Two cases this handles:
    ///   1. `needsReactivation` is true (set when the app crossed an inactive→active
    ///      boundary): rebuild the NextcloudKit session because iOS may have invalidated
    ///      the underlying URLSession during suspension.
    ///   2. `credentials` is nil but the keychain might be temporarily refusing access
    ///      (common right after deep sleep): bounded retry with backoff before giving up.
    private func resolveCredentials() async -> NextcloudCredentials? {
        if needsReactivation {
            if credentials == nil {
                credentials = await NextcloudCredentials.loadWithRetry()
            }
            if let creds = credentials {
                creds.setupSession(nk: nk)
                startNetworkMonitor()
                AppLogger.nextcloud.info("[NC] Session reactivated (deferred refresh applied)")
            }
            needsReactivation = false
        } else if credentials == nil {
            if let creds = await NextcloudCredentials.loadWithRetry() {
                credentials = creds
                creds.setupSession(nk: nk)
                startNetworkMonitor()
                AppLogger.nextcloud.info("[NC] Credentials recovered from keychain (lazy retry)")
            }
        }
        return credentials
    }

    /// Returns current credentials, retrying the keychain if needed.
    /// External callers should use this instead of reading `credentials` directly.
    func currentCredentials() async -> NextcloudCredentials? {
        await resolveCredentials()
    }

    /// Registers credentials and sets up the NextcloudKit session.
    func setup(credentials: NextcloudCredentials) {
        self.credentials = credentials
        credentials.setupSession(nk: nk)
        startNetworkMonitor()
        needsReactivation = false
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

    /// Marks the session as needing a refresh before the next I/O call.
    /// Called from the App's ScenePhase observer when transitioning to `.active`.
    /// Cheap: just sets a flag. The actual session rebuild happens lazily on the
    /// next `resolveCredentials()` call so we don't refresh sessions nobody is using.
    func markNeedsReactivation() {
        needsReactivation = true
    }

    /// Re-establishes the NextcloudKit session immediately rather than lazily.
    /// Use when you want the session ready before the next network call without
    /// piggybacking on an I/O operation (e.g. from a one-shot foreground hook).
    func reactivateSession() async {
        needsReactivation = true
        _ = await resolveCredentials()
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
        guard let creds = await resolveCredentials() else { throw NCError.notConnected }
        let url = creds.davURL(for: remotePath)
        let result = await nk.readFileOrFolderAsync(
            serverUrlFileName: url,
            depth: "1",
            account: creds.accountId
        )
        guard result.error == .success, let files = result.files else {
            throw NCError.networkError(result.error.errorDescription)
        }
        // PROPFIND depth:1 always returns the collection root as the first entry.
        // Drop it so the browser only shows children, not the folder itself.
        return Array(files.dropFirst())
    }

    // MARK: - Core I/O

    /// Opens a file, serving from cache immediately and refreshing in background.
    func openFile(remotePath: String, forceReload: Bool = false) async throws -> ListDocument {
        guard let creds = await resolveCredentials() else { throw NCError.notConnected }

        let cacheKey = cacheKey(creds: creds, remotePath: remotePath)

        let fileName = remotePath.split(separator: "/").last.map(String.init) ?? remotePath

        // 1. Return in-memory cache if available and not forcing a reload.
        if !forceReload, let cached = memCache[cacheKey] {
            AppLogger.cache.info("[NC] Using cached document for \(fileName, privacy: .public)")
            Task { try? await backgroundSync(remotePath: remotePath) }
            return cached
        }

        // 2. Try disk cache
        let diskURL = localCacheURL(creds: creds, remotePath: remotePath)
        if !forceReload, FileManager.default.fileExists(atPath: diskURL.path) {
            if let doc = try? loadFromDisk(at: diskURL) {
                AppLogger.cache.info("[NC] Loaded from disk cache: \(fileName, privacy: .public)")
                memCache[cacheKey] = doc
                Task { try? await backgroundSync(remotePath: remotePath) }
                return doc
            }
        }

        // 3. Deduplicate: reuse an existing in-flight download if one is already running
        if let existing = inFlightDownloads[cacheKey] {
            AppLogger.cache.debug("[NC] Joining in-flight download for \(fileName, privacy: .public)")
            return try await existing.value
        }

        // 4. Start new download, register it so concurrent callers can share it
        AppLogger.nextcloud.info("[NC] Downloading \(fileName, privacy: .public) from server")
        let task = Task<ListDocument, Error> { try await self.downloadFile(creds: creds, remotePath: remotePath) }
        inFlightDownloads[cacheKey] = task
        defer { inFlightDownloads.removeValue(forKey: cacheKey) }
        return try await task.value
    }

    /// Outcome of a `saveFile` call so callers can distinguish "uploaded to server"
    /// from "saved locally but upload queued for retry". Used by the UI to show
    /// "Pending sync" instead of falsely claiming everything is synced.
    enum SaveOutcome {
        case uploaded   // local cache + server in sync
        case queued     // local cache safe; upload waiting on network/retry
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
    @discardableResult
    func saveFile(_ doc: ListDocument, to remotePath: String) async throws -> SaveOutcome {
        guard let creds = await resolveCredentials() else { throw NCError.notConnected }

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
            return .uploaded
        } catch {
            AppLogger.nextcloud.warning("[NC] Upload failed, queued for retry: \(remotePath, privacy: .public) — \(error, privacy: .public)")
            // Left in pendingUploads; NWPathMonitor + syncIfNeeded will retry.
            // Caller is told the local cache is fine but the upload is queued so the UI
            // can show "Pending sync" instead of falsely claiming everything synced.
            return .queued
        }
    }

    /// Returns a document from disk cache only (no network). Used as a fallback when
    /// the server is unreachable during app launch to avoid marking lists unavailable.
    func openFileFromDiskCache(remotePath: String) async -> ListDocument? {
        guard let creds = await resolveCredentials() else { return nil }
        let diskURL = localCacheURL(creds: creds, remotePath: remotePath)
        guard FileManager.default.fileExists(atPath: diskURL.path),
              let doc = try? loadFromDisk(at: diskURL) else { return nil }
        let key = cacheKey(creds: creds, remotePath: remotePath)
        memCache[key] = doc
        return doc
    }

    /// Returns the cached document (in-memory first, disk fallback) without ever
    /// hitting the network. Returns nil only if neither cache has the document.
    /// Use for display / reminder enumeration where stale-but-shown beats blank.
    func openFileFromAnyCache(remotePath: String) async -> ListDocument? {
        guard let creds = await resolveCredentials() else { return nil }
        let key = cacheKey(creds: creds, remotePath: remotePath)
        if let cached = memCache[key] { return cached }
        let diskURL = localCacheURL(creds: creds, remotePath: remotePath)
        guard FileManager.default.fileExists(atPath: diskURL.path),
              let doc = try? loadFromDisk(at: diskURL) else { return nil }
        memCache[key] = doc
        return doc
    }

    /// Updates only the in-memory and disk cache without uploading.
    func updateCache(_ doc: ListDocument, remotePath: String) async {
        guard let creds = await resolveCredentials() else { return }
        let key = cacheKey(creds: creds, remotePath: remotePath)
        memCache[key] = doc
        let diskURL = localCacheURL(creds: creds, remotePath: remotePath)
        try? saveToDisk(doc, at: diskURL)
    }

    /// Returns true if the Nextcloud server is reachable (a lightweight PROPFIND on the DAV root).
    func isServerReachable() async -> Bool {
        guard let creds = await resolveCredentials() else { return false }
        let url = creds.davBase()
        let result = await nk.readFileOrFolderAsync(
            serverUrlFileName: url,
            depth: "0",
            account: creds.accountId
        )
        return result.error == .success
    }

    enum FileChangeResult {
        case changed
        case unchanged
        case unreachable  // server could not be contacted
    }

    /// Returns true if the server ETag differs from the locally cached ETag.
    /// Returns true if the server ETag differs from the cached ETag.
    /// Throws `NCError.notFound` if the server returns 404 (file deleted or moved).
    /// Returns false for other network errors (assume unchanged).
    func hasFileChanged(remotePath: String) async throws -> Bool {
        let result = try await checkFileChanged(remotePath: remotePath)
        return result == .changed
    }

    /// Like `hasFileChanged` but distinguishes "unchanged" from "server unreachable".
    /// Throws `NCError.notFound` ONLY when we have confirmed the file is gone — i.e.
    /// the server returned 404 AND the account root is reachable (proving the server
    /// itself is up). Otherwise a server outage that 404s every request would be
    /// misclassified as "file deleted" and trigger permanent unavailable handling.
    func checkFileChanged(remotePath: String) async throws -> FileChangeResult {
        guard let creds = await resolveCredentials() else { return .unreachable }
        let url = creds.davURL(for: remotePath)
        let result = await nk.readFileOrFolderAsync(
            serverUrlFileName: url,
            depth: "0",
            account: creds.accountId
        )
        if result.error.errorCode == 404 {
            // Disambiguate: is this file truly gone, or is the whole server unreachable?
            // A cheap PROPFIND on the DAV root tells us. If the root also fails, treat
            // as transient (will retry); only confirmed file-specific 404 is permanent.
            let rootResult = await nk.readFileOrFolderAsync(
                serverUrlFileName: creds.davBase(),
                depth: "0",
                account: creds.accountId
            )
            if rootResult.error == .success {
                throw NCError.notFound(remotePath)
            }
            AppLogger.nextcloud.info("[NC] 404 on \(remotePath, privacy: .public) but root unreachable — treating as transient")
            return .unreachable
        }
        guard result.error == .success, let serverEtag = result.files?.first?.etag else {
            return .unreachable  // transient network error — assume unchanged
        }
        let key = etagKey(creds: creds, remotePath: remotePath)
        return serverEtag != etagStore[key] ? .changed : .unchanged
    }

    /// Background refresh triggered after serving from cache.
    /// Downloads the latest server version into memCache WITHOUT updating `etagStore`.
    /// Keeping `etagStore` at the last explicitly-synced ETag means `hasFileChanged` will
    /// still return `true` when `saveFile` runs, so any conflict is caught and merged there.
    /// Posts `nextcloudFileNotFound` if the server returns 404.
    private func backgroundSync(remotePath: String) async throws {
        guard let creds = await resolveCredentials() else { return }
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
        guard let creds = await resolveCredentials() else { throw NCError.notConnected }

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
    /// List summary: latest `modifiedAt` wins. Deleted-label tombstones are unioned and respected.
    private func mergeDocuments(local: ListDocument, server: ListDocument) -> ListDocument {
        // Items: latest modifiedAt wins per ID
        var itemsById: [UUID: ListItem] = Dictionary(
            uniqueKeysWithValues: server.items.map { ($0.id, $0) }
        )
        for item in local.items {
            if let existing = itemsById[item.id] {
                if item.modifiedAt > existing.modifiedAt { itemsById[item.id] = item }
            } else {
                itemsById[item.id] = item
            }
        }

        // Union tombstones from both sides so deletions propagate across devices
        let deletedIDs = Set(local.deletedLabelIDs).union(server.deletedLabelIDs)

        // Labels: no modifiedAt — local wins on conflict (preserves edits just made),
        // server adds any labels created on other devices that don't exist locally.
        // Tombstoned labels are excluded so stale caches can't resurrect deleted labels.
        var labelsById: [String: ListLabel] = Dictionary(
            uniqueKeysWithValues: local.labels.map { ($0.id, $0) }
        )
        for label in server.labels where labelsById[label.id] == nil {
            labelsById[label.id] = label
        }
        for id in deletedIDs { labelsById.removeValue(forKey: id) }

        // List summary: latest modifiedAt wins
        let summary = local.list.modifiedAt > server.list.modifiedAt ? local.list : server.list

        return ListDocument(
            list: summary,
            items: Array(itemsById.values),
            labels: Array(labelsById.values),
            deletedLabelIDs: Array(deletedIDs)
        )
    }

    /// Removes a file from in-memory cache and pending uploads (does NOT delete disk cache).
    func closeFile(remotePath: String) async {
        guard let creds = await resolveCredentials() else { return }
        let key = cacheKey(creds: creds, remotePath: remotePath)
        memCache.removeValue(forKey: key)
        if pendingUploads.remove(remotePath) != nil { savePendingUploads() }
    }

    /// Removes from cache and pending; deletes the disk cache file.
    func removeLocalCache(remotePath: String) async {
        guard let creds = await resolveCredentials() else { return }
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

    /// Layer 5: human-readable snapshot of the manager's current state. Use for bug
    /// reports — the user can copy this from the long-press menu on the sync chip
    /// and paste it into their report. Side-effect-free; safe to call from any context.
    func stateSnapshot() async -> String {
        let creds = credentials
        let memSize = memCache.count
        let pending = pendingUploads.count
        let etagCount = etagStore.count
        let inflight = inFlightDownloads.count
        let mutationDepth = await MutationLog.shared.depth()
        let accountSummary = creds.map { "\($0.username)@\($0.serverURL)" } ?? "(not connected)"
        return """
        [Nextcloud state snapshot]
        account: \(accountSummary)
        needsReactivation: \(needsReactivation)
        memCache: \(memSize) doc(s)
        pendingUploads: \(pending) file(s)
        etagStore: \(etagCount) entry(s)
        inFlightDownloads: \(inflight)
        mutationLog depth: \(mutationDepth)
        """
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
                // Same disambiguation as checkFileChanged: a 404 only means "file gone"
                // if the server itself is reachable. Otherwise it's a transient outage.
                let rootResult = await nk.readFileOrFolderAsync(
                    serverUrlFileName: creds.davBase(),
                    depth: "0",
                    account: creds.accountId
                )
                if rootResult.error == .success {
                    throw NCError.notFound(remotePath)
                }
                AppLogger.nextcloud.info("[NC] Download 404 on \(remotePath, privacy: .public) but root unreachable — treating as transient")
                throw NCError.networkError("Server unreachable")
            }
            throw NCError.networkError(result.nkError.errorDescription)
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
            throw NCError.networkError(result.error.errorDescription)
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
