import Foundation

/// Filesystem-backed tile cache under ~/Library/Caches/QuiteListieTiles/{namespace}/z/x/y.
/// Concurrent writes to the same tile last-write-win — the payload is the same so races are harmless.
///
/// The cache is bounded: a background trim keeps the whole root under
/// `capBytes`, evicting least-recently-used tiles first. "Use" is the file's
/// modification date, refreshed (throttled) on read — APFS access times are
/// unreliable, so reads touch the modification date instead.
///
struct TileDiskCache {
    let root: URL

    static let rootBase: URL = {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("QuiteListieTiles", isDirectory: true)
    }()

    init(namespace: String, legacyNamespace: String? = nil) {
        if let legacyNamespace, legacyNamespace != namespace {
            Self.adoptLegacyNamespace(legacyNamespace, forNew: namespace)
        }
        self.init(root: Self.rootBase.appendingPathComponent(namespace, isDirectory: true))
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
    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Tiles are stored extensionless (the format is whatever the server sent;
    /// decoders sniff the bytes). Older caches used a `.png` suffix regardless
    /// of the real format — reads fall back to that name.
    private func url(z: Int, x: Int, y: Int) -> URL {
        root.appendingPathComponent("\(z)/\(x)/\(y)")
    }

    func read(z: Int, x: Int, y: Int) -> Data? {
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

    func write(z: Int, x: Int, y: Int, data: Data) {
        let u = url(z: z, x: x, y: y)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: u, options: .atomic)
        Self.noteWrite()
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

    // MARK: - LRU trim

    /// Cache ceiling. Cheap, re-downloadable data — but left unbounded it grows
    /// by gigabytes a year for a map-heavy user. User-selectable in settings
    /// (small/medium/large).
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
