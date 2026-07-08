//
//  OfflineRegionManager.swift
//  QuiteListie
//
//  Download + refresh engine for offline map packs. Downloads enumerate the
//  region's pyramid lazily and fetch through `TileFetcher` (limiter/backoff
//  for free) into *pinned* storage — never the purgeable cache. Progress is
//  observable, downloads are cancellable, and an interrupted pack resumes on
//  next launch by skipping tiles already on disk.
//
//  Refresh re-validates cached tiles with conditional requests (Phase 4's
//  ETag/If-None-Match manifest): an unchanged tile costs a 304, which is what
//  makes a monthly refresh affordable against an API quota.
//

import Foundation
import UIKit
import UserNotifications

@MainActor
final class OfflineRegionManager: ObservableObject {
    static let shared = OfflineRegionManager()

    struct Progress: Equatable {
        var completed: Int      // fetched or already on disk
        var failed: Int
        var total: Int
        var bytes: Int64
        var fraction: Double {
            total > 0 ? min(1, Double(completed + failed) / Double(total)) : 0
        }
        /// Live size estimate: seeded at ~30 KB/tile, replaced by the real
        /// running average once enough tiles have landed to trust it.
        var estimatedTotalBytes: Int64 {
            if completed >= 100, bytes > 0 {
                return Int64(Double(bytes) / Double(completed) * Double(total))
            }
            return Int64(total) * Self.seedBytesPerTile
        }
        static let seedBytesPerTile: Int64 = 30 * 1024
    }

    @Published private(set) var progress: [UUID: Progress] = [:]
    @Published private(set) var refreshingRegionIDs: Set<UUID> = []

    private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    /// End-of-life handles for the `beginBackgroundTask` grace claims.
    private var bgTaskIDs: [UUID: UIBackgroundTaskIdentifier] = [:]
    private var healthObserver: NSObjectProtocol?

    private init() {
        // Terminal auth failures during pack work become local notifications —
        // background refresh has no map to hang a banner on. TileLayerHealth
        // already rate-limits to once per source per session.
        healthObserver = NotificationCenter.default.addObserver(
            forName: TileLayerHealth.authFailureNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.hasActivePackWork,
                      let message = note.userInfo?[TileLayerHealth.messageKey] as? String
                else { return }
                Self.postLocalNotification(title: "Offline map problem", body: message)
            }
        }
    }

    private var hasActivePackWork: Bool {
        !downloadTasks.isEmpty || !refreshingRegionIDs.isEmpty
    }

    func isDownloading(_ regionID: UUID) -> Bool {
        downloadTasks[regionID] != nil
    }

    // MARK: - Download

    func startDownload(_ region: OfflineRegion) {
        guard downloadTasks[region.id] == nil,
              let layer = OfflineLayerRef.resolve(id: region.layerID) else { return }

        progress[region.id] = Progress(completed: 0, failed: 0,
                                       total: region.tileCount, bytes: 0)

        // Grace window if the app is backgrounded mid-download; expiry cancels
        // cleanly and the pack resumes on next launch.
        let app = UIApplication.shared
        bgTaskIDs[region.id] = app.beginBackgroundTask(withName: "offline-pack-download") {
            MainActor.assumeIsolated { [weak self] in
                self?.downloadTasks[region.id]?.cancel()
                self?.endBackgroundTask(for: region.id)
            }
        }

        let regionID = region.id
        downloadTasks[regionID] = Task { [weak self] in
            let outcome = await Self.runDownload(region: region, layer: layer) { snapshot in
                Task { @MainActor [weak self] in
                    self?.progress[regionID] = snapshot
                }
            }
            guard let self else { return }
            // Re-read the record — auto-refresh may have been toggled, or the
            // region deleted, while the download ran.
            if var current = OfflineRegionStore.loadAll().first(where: { $0.id == regionID }) {
                current.sizeBytes = outcome.bytes
                if outcome.finished && outcome.failed == 0 {
                    current.downloadComplete = true
                    current.tileCount = outcome.completed
                }
                OfflineRegionStore.upsert(current)
            }
            self.downloadTasks[regionID] = nil
            self.progress[regionID] = nil
            self.endBackgroundTask(for: regionID)
        }
    }

    func cancelDownload(regionID: UUID) {
        downloadTasks[regionID]?.cancel()
    }

    /// Kick any pack that never finished (killed mid-download, expired grace
    /// window). Tiles already on disk are skipped, so this is cheap when
    /// nearly done. Called once at launch.
    func resumeIncompleteDownloads() {
        for region in OfflineRegionStore.loadAll()
        where !region.downloadComplete && downloadTasks[region.id] == nil {
            startDownload(region)
        }
    }

    func delete(_ region: OfflineRegion) {
        downloadTasks[region.id]?.cancel()
        OfflineRegionStore.remove(id: region.id)
        // Packs share a namespace per layer; only drop the tiles when no other
        // region still needs them.
        let layerStillUsed = OfflineRegionStore.loadAll()
            .contains { $0.layerID == region.layerID }
        if !layerStillUsed, let layer = OfflineLayerRef.resolve(id: region.layerID) {
            let namespace = layer.namespace
            Task.detached(priority: .utility) {
                TileDiskCache.clearPinned(namespace: namespace)
            }
        }
    }

    private func endBackgroundTask(for regionID: UUID) {
        if let id = bgTaskIDs.removeValue(forKey: regionID), id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
        }
        bgTaskIDs[regionID] = nil
    }

    /// The region's zoom span intersected with what the layer publishes, never
    /// inverted (a degenerate region collapses to one level, not a crash).
    private nonisolated static func clampedZooms(
        region: OfflineRegion, layer: OfflineLayerRef) -> ClosedRange<Int> {
        let lower = max(region.minZoom, layer.zoomRange.lowerBound)
        let upper = max(lower, min(region.maxZoom, layer.zoomRange.upperBound))
        return lower...upper
    }

    private struct DownloadOutcome {
        let completed: Int
        let failed: Int
        let bytes: Int64
        let finished: Bool   // ran the whole enumeration (not cancelled)
    }

    /// The download loop, off the main actor. A small task-group window keeps
    /// the fetcher's limiter busy without racing the (non-Sendable) lazy
    /// iterator: tiles are pulled one at a time from the loop that owns it.
    private nonisolated static func runDownload(
        region: OfflineRegion, layer: OfflineLayerRef,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async -> DownloadOutcome {
        let store = TileDiskCache.pinnedStore(namespace: layer.namespace)
        let fetcher = layer.makeFetcher(targetStore: store)
        let zooms = Self.clampedZooms(region: region, layer: layer)

        var completed = 0
        var failed = 0
        var bytes: Int64 = 0
        var exhausted = false

        var iterator = OfflineTileEnumerator.tiles(
            bounds: region.bounds, grid: layer.grid, zooms: zooms).makeIterator()

        await withTaskGroup(of: Int64?.self) { group in
            var inFlight = 0

            func addNext() {
                guard !Task.isCancelled, let tile = iterator.next() else {
                    if !Task.isCancelled { exhausted = true }
                    return
                }
                inFlight += 1
                group.addTask {
                    // Resume support: a tile already in the pack is done.
                    if store.contains(z: tile.z, x: tile.x, y: tile.y) {
                        return store.fileSize(z: tile.z, x: tile.x, y: tile.y) ?? 0
                    }
                    guard let data = await fetcher.data(z: tile.z, x: tile.x, y: tile.y)
                    else { return nil }
                    return Int64(data.count)
                }
            }

            for _ in 0..<8 { addNext() }
            var sinceReport = 0
            while inFlight > 0 {
                guard let result = await group.next() else { break }
                inFlight -= 1
                if let size = result {
                    completed += 1
                    bytes += size
                } else {
                    failed += 1
                }
                sinceReport += 1
                if sinceReport >= 16 || inFlight == 0 {
                    sinceReport = 0
                    onProgress(Progress(completed: completed, failed: failed,
                                        total: region.tileCount, bytes: bytes))
                }
                addNext()
            }
        }
        await fetcher.flushValidators()
        return DownloadOutcome(completed: completed, failed: failed,
                               bytes: bytes, finished: exhausted)
    }

    // MARK: - Refresh

    struct RefreshSummary {
        var regions = 0
        var updated = 0
        var unchanged = 0
        var removed = 0
        var failed = 0
    }

    /// Refresh every stale auto-refresh pack. The workhorse behind both the
    /// BGProcessingTask and the launch-time staleness fallback.
    @discardableResult
    func refreshStaleRegions() async -> RefreshSummary {
        var summary = RefreshSummary()
        let stale = OfflineRegionStore.loadAll()
            .filter { $0.autoRefresh && $0.downloadComplete && $0.isStale() }
        for region in stale {
            guard let result = await refresh(region) else { continue }
            summary.regions += 1
            summary.updated += result.updated
            summary.unchanged += result.unchanged
            summary.removed += result.removed
            summary.failed += result.failed
        }
        if summary.regions > 0 {
            let packs = summary.regions == 1 ? "map" : "maps"
            Self.postLocalNotification(
                title: "Offline \(packs) refreshed",
                body: summary.updated == 0
                    ? "Everything was already up to date."
                    : "\(summary.updated) tile\(summary.updated == 1 ? "" : "s") updated.")
        }
        return summary
    }

    /// One region's conditional-refresh pass. Existing tiles revalidate
    /// (304 = free); tiles missing from the pack are fetched fresh.
    func refresh(_ region: OfflineRegion)
        async -> (updated: Int, unchanged: Int, removed: Int, failed: Int)? {
        guard !refreshingRegionIDs.contains(region.id),
              downloadTasks[region.id] == nil,
              let layer = OfflineLayerRef.resolve(id: region.layerID) else { return nil }
        refreshingRegionIDs.insert(region.id)
        defer { refreshingRegionIDs.remove(region.id) }

        let result = await Self.runRefresh(region: region, layer: layer)

        if var current = OfflineRegionStore.loadAll().first(where: { $0.id == region.id }) {
            current.lastRefreshed = Date()
            current.sizeBytes = result.bytes
            OfflineRegionStore.upsert(current)
        }
        return (result.updated, result.unchanged, result.removed, result.failed)
    }

    private struct RefreshResult {
        var updated = 0
        var unchanged = 0
        var removed = 0
        var failed = 0
        var bytes: Int64 = 0
    }

    private nonisolated static func runRefresh(
        region: OfflineRegion, layer: OfflineLayerRef
    ) async -> RefreshResult {
        let store = TileDiskCache.pinnedStore(namespace: layer.namespace)
        let fetcher = layer.makeFetcher(targetStore: store)
        let zooms = Self.clampedZooms(region: region, layer: layer)

        var result = RefreshResult()
        var iterator = OfflineTileEnumerator.tiles(
            bounds: region.bounds, grid: layer.grid, zooms: zooms).makeIterator()

        await withTaskGroup(of: (TileFetcher.RefreshOutcome, Int64).self) { group in
            var inFlight = 0

            func addNext() {
                guard !Task.isCancelled, let tile = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    if store.contains(z: tile.z, x: tile.x, y: tile.y) {
                        let outcome = await fetcher.refreshTile(z: tile.z, x: tile.x, y: tile.y)
                        let size = store.fileSize(z: tile.z, x: tile.x, y: tile.y) ?? 0
                        return (outcome, size)
                    }
                    // Gap in the pack (failed during download, or removed then
                    // republished): fetch it fresh.
                    if let data = await fetcher.data(z: tile.z, x: tile.x, y: tile.y) {
                        return (.updated, Int64(data.count))
                    }
                    return (.failed, 0)
                }
            }

            for _ in 0..<6 { addNext() }
            while inFlight > 0 {
                guard let (outcome, size) = await group.next() else { break }
                inFlight -= 1
                switch outcome {
                case .updated:   result.updated += 1
                case .unchanged: result.unchanged += 1
                case .missing:   result.removed += 1
                case .failed:    result.failed += 1
                }
                result.bytes += size
                addNext()
            }
        }
        await fetcher.flushValidators()
        return result
    }

    // MARK: - Launch maintenance

    /// Resume interrupted packs and run the staleness fallback. iOS background
    /// scheduling is advisory — this launch-time pass is the reliable path.
    func performLaunchMaintenance() {
        resumeIncompleteDownloads()
        Task { await refreshStaleRegions() }
    }

    // MARK: - Notifications

    /// Ask for notification permission the moment auto-refresh is first
    /// enabled — not at launch. Refresh still works silently if denied.
    static func requestNotificationPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    private static func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Fails silently when permission was denied — by design.
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "offline-tiles-\(UUID().uuidString)",
            content: content, trigger: nil))
    }
}
