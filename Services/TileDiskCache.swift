import Foundation

/// Filesystem-backed tile cache under ~/Library/Caches/QuiteListieTiles/{namespace}/z/x/y.
/// Concurrent writes to the same tile last-write-win — the payload is the same so races are harmless.
///
/// The cache is bounded: a background trim keeps the whole root under
/// `capBytes`, evicting least-recently-used tiles first. "Use" is the file's
/// modification date, refreshed (throttled) on read — APFS access times are
/// unreliable, so reads touch the modification date instead.
///
/// Offline packs live in a separate *pinned* tree (Application Support, never
/// purged, excluded from backup). A cache instance can carry a pinned root:
/// reads check pinned → cache, so renderers get offline tiles for free. The
/// trim only ever walks the Caches tree — pinned tiles are untouchable by it.
struct TileDiskCache {
    let root: URL
    /// Same-namespace offline-pack directory, consulted before `root` on read.
    /// nil for stores that *are* the pinned pack (the downloader's target).
    let pinnedRoot: URL?

    static let rootBase: URL = {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("QuiteListieTiles", isDirectory: true)
    }()

    /// Root of all offline packs: Application Support/OfflineTiles/{namespace}.
    /// Deliberately not under Caches/ — the OS may purge Caches at will, and an
    /// offline pack that evaporates offline is worse than none.
    static let pinnedRootBase: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OfflineTiles", isDirectory: true)
    }()

    /// Per-namespace validator manifest filename — spared by the trim, because
    /// losing it silently discards the conditional-refresh validators.
    static let manifestFilename = "manifest.json"

    init(namespace: String, legacyNamespace: String? = nil) {
        if let legacyNamespace, legacyNamespace != namespace {
            Self.adoptLegacyNamespace(legacyNamespace, forNew: namespace)
        }
        self.init(root: Self.rootBase.appendingPathComponent(namespace, isDirectory: true),
                  pinnedRoot: Self.pinnedRootBase.appendingPathComponent(namespace, isDirectory: true))
    }

    /// The write target for downloading an offline pack: a store rooted
    /// directly in the pinned tree, so pack tiles are stored exactly once
    /// (never duplicated into the purgeable cache). The manifest written next
    /// to the tiles is what makes conditional refresh work per pack.
    static func pinnedStore(namespace: String) -> TileDiskCache {
        try? FileManager.default.createDirectory(at: pinnedRootBase,
                                                 withIntermediateDirectories: true)
        var base = pinnedRootBase
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)
        return TileDiskCache(root: pinnedRootBase.appendingPathComponent(namespace, isDirectory: true))
    }

    /// Rename a namespace directory hashed under an old scheme to its new name,
    /// so a namespace-hash change (e.g. key-stripping) carries the existing
    /// tiles over instead of orphaning them. No-op when the old directory is
    /// missing or the new one already exists (never clobbers real tiles).
    static func adoptLegacyNamespace(_ legacy: String, forNew namespace: String,
                                     under root: URL = rootBase) {
        let fm = FileManager.default
        let old = root.appendingPathComponent(legacy, isDirectory: true)
        let new = root.appendingPathComponent(namespace, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue,
              !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    /// Root-injectable for tests, so trim/eviction never touches the real cache.
    init(root: URL, pinnedRoot: URL? = nil) {
        self.root = root
        self.pinnedRoot = pinnedRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Tiles are stored extensionless (the format is whatever the server sent;
    /// decoders sniff the bytes). Older caches used a `.png` suffix regardless
    /// of the real format — reads fall back to that name.
    private func url(z: Int, x: Int, y: Int) -> URL {
        root.appendingPathComponent("\(z)/\(x)/\(y)")
    }

    func read(z: Int, x: Int, y: Int) -> Data? {
        // Offline pack first: pinned tiles are refreshed deliberately, so they
        // are at least as current as whatever the cache holds. No LRU touch —
        // pinned files aren't eviction candidates.
        if let pinnedRoot,
           let data = try? Data(contentsOf: pinnedRoot.appendingPathComponent("\(z)/\(x)/\(y)")) {
            return data
        }
        let u = url(z: z, x: x, y: y)
        if let data = try? Data(contentsOf: u) {
            Self.touchIfStale(u)
            return data
        }
        let legacy = u.appendingPathExtension("png")
        if let data = try? Data(contentsOf: legacy) {
            Self.touchIfStale(legacy)
            return data
        }
        return nil
    }

    /// Cheap existence check (no data read, no LRU touch) — the download
    /// engine's resume path, where reading 20k tiles just to skip them would
    /// thrash I/O.
    func contains(z: Int, x: Int, y: Int) -> Bool {
        let u = url(z: z, x: x, y: y)
        return FileManager.default.fileExists(atPath: u.path)
            || FileManager.default.fileExists(atPath: u.appendingPathExtension("png").path)
    }

    func write(z: Int, x: Int, y: Int, data: Data) {
        let u = url(z: z, x: x, y: y)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: u, options: .atomic)
        Self.noteWrite()
    }

    /// On-disk size of one tile, or nil when absent. Used for exact pack-size
    /// accounting without loading the bytes.
    func fileSize(z: Int, x: Int, y: Int) -> Int64? {
        let u = url(z: z, x: x, y: y)
        for candidate in [u, u.appendingPathExtension("png")] {
            if let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                return Int64(size)
            }
        }
        return nil
    }

    /// Remove one tile (both the current and legacy filenames). Used when a
    /// refresh discovers the server no longer has it.
    func remove(z: Int, x: Int, y: Int) {
        let u = url(z: z, x: x, y: y)
        try? FileManager.default.removeItem(at: u)
        try? FileManager.default.removeItem(at: u.appendingPathExtension("png"))
    }

    /// Refresh the LRU stamp, but only when it's over a day stale — a write per
    /// read would double the cache's I/O for no eviction-accuracy gain.
    private static func touchIfStale(_ u: URL) {
        guard let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
              Date().timeIntervalSince(mod) > 86_400 else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
    }

    // MARK: - Size accounting

    /// Total size in bytes of everything under the root of all namespaces combined.
    static func totalSizeBytes() -> Int64 {
        sizeOfTree(rootBase)
    }

    /// Bytes per namespace directory, for the per-layer breakdown in settings.
    static func sizesByNamespace(under root: URL = rootBase) -> [String: Int64] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [:] }
        var out: [String: Int64] = [:]
        for dir in dirs
        where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            out[dir.lastPathComponent] = sizeOfTree(dir)
        }
        return out
    }

    private static func sizeOfTree(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Clearing

    /// Wipe every namespace under the root.
    static func clearAll() {
        try? FileManager.default.removeItem(at: rootBase)
        try? FileManager.default.createDirectory(at: rootBase, withIntermediateDirectories: true)
    }

    /// Wipe one namespace (one layer's tiles).
    static func clear(namespace: String) {
        try? FileManager.default.removeItem(
            at: rootBase.appendingPathComponent(namespace, isDirectory: true))
    }

    /// Wipe one namespace's *offline pack*. Only region deletion calls this —
    /// never the cache-clearing UI, which must not eat downloaded packs.
    static func clearPinned(namespace: String) {
        try? FileManager.default.removeItem(
            at: pinnedRootBase.appendingPathComponent(namespace, isDirectory: true))
    }

    // MARK: - LRU trim

    /// Cache ceiling. Cheap, re-downloadable data — but left unbounded it grows
    /// by gigabytes a year for a map-heavy user. User-selectable in settings
    /// (small/medium/large); offline packs live outside this budget entirely.
    static let capBytesDefaultsKey = "tileCacheCapBytes.v1"
    static let defaultCapBytes: Int64 = 500 * 1024 * 1024
    /// The selectable sizes: small (0.5 GB), medium (1 GB), large (3 GB).
    static let capChoices: [Int64] = [500 * 1024 * 1024,
                                      1024 * 1024 * 1024,
                                      3 * 1024 * 1024 * 1024]
    static var capBytes: Int64 {
        let stored = UserDefaults.standard.object(forKey: capBytesDefaultsKey) as? Int64
        return stored ?? defaultCapBytes
    }
    static func setCapBytes(_ bytes: Int64) {
        UserDefaults.standard.set(bytes, forKey: capBytesDefaultsKey)
    }

    /// Delete least-recently-used tiles until the tree is under `cap`.
    /// Manifest files are spared (they're tiny and hold refresh validators).
    /// Root-injectable so tests never trim the real cache.
    static func trim(under root: URL = rootBase, toBytes cap: Int64 = capBytes) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        struct Candidate {
            let url: URL
            let size: Int64
            let date: Date
        }
        var candidates: [Candidate] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            total += size
            guard url.lastPathComponent != manifestFilename else { continue }
            candidates.append(Candidate(url: url, size: size,
                                        date: v.contentModificationDate ?? .distantPast))
        }
        guard total > cap else { return }

        candidates.sort { $0.date < $1.date }
        var excess = total - cap
        let fm = FileManager.default
        for c in candidates where excess > 0 {
            do {
                try fm.removeItem(at: c.url)
                excess -= c.size
            } catch { continue }
        }
    }

    // MARK: - Trim scheduling

    // Cross-thread bookkeeping for the debounce; everything below touches these
    // only under `trimLock`.
    private static let trimLock = NSLock()
    nonisolated(unsafe) private static var lastTrimAt: Date = .distantPast
    nonisolated(unsafe) private static var writesSinceTrim = 0

    /// Kick a background trim unless one ran recently. Called at launch and,
    /// via `noteWrite`, as tiles accumulate.
    static func scheduleTrim(minimumInterval: TimeInterval = 300) {
        trimLock.lock()
        let due = Date().timeIntervalSince(lastTrimAt) >= minimumInterval
        if due {
            lastTrimAt = Date()
            writesSinceTrim = 0
        }
        trimLock.unlock()
        guard due else { return }
        Task.detached(priority: .utility) { trim() }
    }

    /// Write-side debounce: a burst of tile downloads (~512 tiles ≈ 15–40 MB)
    /// earns one trim pass.
    private static func noteWrite() {
        trimLock.lock()
        writesSinceTrim += 1
        let due = writesSinceTrim >= 512
        trimLock.unlock()
        if due { scheduleTrim(minimumInterval: 60) }
    }
}

// MARK: - Validator manifest

/// Per-namespace record of HTTP validators (`ETag` / `Last-Modified`) for
/// cached tiles, enabling conditional refresh: `If-None-Match` costs a 304
/// instead of a re-download when the tile hasn't changed. One JSON manifest per
/// namespace — deliberately not per-tile sidecars, which would double the inode
/// count of a large cache.
///
/// Not thread-safe on its own: confined to the owning `TileFetcher` actor.
final class TileValidatorManifest {
    struct Entry: Codable, Equatable {
        var etag: String?
        var lastModified: String?
        /// When the tile was last confirmed current (fetched or 304'd).
        var checked: Date
    }

    private(set) var entries: [String: Entry]
    private let fileURL: URL
    private var unsavedMutations = 0

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(TileDiskCache.manifestFilename)
        entries = (try? JSONDecoder().decode(
            [String: Entry].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    func entry(for key: String) -> Entry? { entries[key] }

    func record(key: String, etag: String?, lastModified: String?) {
        guard etag != nil || lastModified != nil else { return }
        entries[key] = Entry(etag: etag, lastModified: lastModified, checked: Date())
        noteMutation()
    }

    func markChecked(key: String) {
        guard var e = entries[key] else { return }
        e.checked = Date()
        entries[key] = e
        noteMutation()
    }

    func remove(key: String) {
        if entries.removeValue(forKey: key) != nil { noteMutation() }
    }

    /// Persist pending changes. Batched (every 32 mutations) because a JSON
    /// rewrite per tile would swamp a bulk download; call explicitly after a
    /// refresh pass.
    func flush() {
        guard unsavedMutations > 0 else { return }
        unsavedMutations = 0
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func noteMutation() {
        unsavedMutations += 1
        if unsavedMutations >= 32 { flush() }
    }
}
