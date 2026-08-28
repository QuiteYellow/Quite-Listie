//
//  RemovedMapFeaturePurge.swift
//  QuiteListie
//
//  One-shot cleanup of data left behind by two removed map features:
//  standard-projection (web-mercator XYZ) layers and offline map packs. Both
//  are unreachable from the UI now, so their stored records, downloaded packs
//  and cached tiles would otherwise sit on disk forever with no way to see or
//  clear them.
//
//  Runs once, guarded by a flag; a no-op on every launch after that. See
//  notes/removed-standard-projection-layers.md and
//  notes/removed-offline-map-packs.md — restoring either feature means deleting
//  this file first, or it will wipe the restored data on next launch.
//

import Foundation

enum RemovedMapFeaturePurge {
    private static let doneKey = "removedMapFeaturePurge.v1"

    /// Cache namespaces of standard layers were prefixed with this; BNG layers
    /// use "src-" and must survive untouched.
    private static let standardNamespacePrefix = "std-"

    /// Offline packs lived outside the tile cache, in Application Support.
    private static var offlinePackRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("OfflineTiles", isDirectory: true)
    }

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        defaults.removeObject(forKey: "standardTileSources.v1")
        defaults.removeObject(forKey: "offlineRegions.v1")

        // Filesystem work off the main actor — a large pack tree can take a
        // moment to delete and nothing waits on the result.
        Task.detached(priority: .utility) {
            purgeDisk()
        }
    }

    private static func purgeDisk() {
        let fm = FileManager.default
        if let offlinePackRoot {
            try? fm.removeItem(at: offlinePackRoot)
        }
        guard let dirs = try? fm.contentsOfDirectory(
            at: TileDiskCache.rootBase,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for dir in dirs where dir.lastPathComponent.hasPrefix(standardNamespacePrefix) {
            try? fm.removeItem(at: dir)
        }
    }
}
