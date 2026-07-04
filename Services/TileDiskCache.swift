import Foundation

/// Filesystem-backed PNG tile cache under ~/Library/Caches/QuiteListieTiles/{namespace}/z/x/y.png.
/// Concurrent writes to the same tile last-write-win — the payload is the same so races are harmless.
struct TileDiskCache {
    let root: URL

    static let rootBase: URL = {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("QuiteListieTiles", isDirectory: true)
    }()

    init(namespace: String) {
        self.root = Self.rootBase.appendingPathComponent(namespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(z: Int, x: Int, y: Int) -> URL {
        root.appendingPathComponent("\(z)/\(x)/\(y).png")
    }

    func read(z: Int, x: Int, y: Int) -> Data? {
        try? Data(contentsOf: url(z: z, x: x, y: y))
    }

    func write(z: Int, x: Int, y: Int, data: Data) {
        let u = url(z: z, x: x, y: y)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: u, options: .atomic)
    }

    /// Total size in bytes of everything under the root of all namespaces combined.
    static func totalSizeBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: rootBase,
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

    /// Wipe every namespace under the root.
    static func clearAll() {
        try? FileManager.default.removeItem(at: rootBase)
        try? FileManager.default.createDirectory(at: rootBase, withIntermediateDirectories: true)
    }
}
