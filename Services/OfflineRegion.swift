//
//  OfflineRegion.swift
//  QuiteListie
//
//  Model + tile enumeration for offline map packs: a named lat/lon rectangle
//  on one layer, downloaded as a full tile pyramid (min zoom → chosen max)
//  into pinned storage. Enumeration is lazy — a 20k-tile region must never be
//  materialised as an array — and works for both grids: web-mercator XYZ and
//  BNG (EPSG:27700) WMTS matrices with per-zoom origins/bounds.
//

import Foundation

/// A geographic rectangle in WGS84 degrees. Plain doubles (not MapKit types)
/// so the model stays Codable and testable without UIKit.
struct LatLonBounds: Codable, Equatable {
    var latMin: Double
    var latMax: Double
    var lonMin: Double
    var lonMax: Double
}

/// One offline pack: which layer, where, how deep, and its download/refresh
/// bookkeeping. `tileCount`/`sizeBytes` are estimates at creation, replaced by
/// exact numbers when the download completes.
struct OfflineRegion: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// The layer this pack belongs to — a `CustomTileSource` or
    /// `StandardTileSource` id (see `OfflineLayerRef.resolve`).
    var layerID: UUID
    var name: String
    var bounds: LatLonBounds
    var minZoom: Int
    var maxZoom: Int
    var tileCount: Int
    var sizeBytes: Int64
    var createdAt: Date = Date()
    var lastRefreshed: Date? = nil
    var autoRefresh: Bool = false
    /// False until every tile has been fetched (or confirmed absent) — an
    /// incomplete pack resumes on next launch, skipping tiles already on disk.
    var downloadComplete: Bool = false

    /// Stale = due for a conditional refresh (iOS scheduling is advisory, so
    /// "monthly" means "refresh packs >30 days stale when we get a slot").
    func isStale(asOf now: Date = Date(), maxAge: TimeInterval = 30 * 86_400) -> Bool {
        now.timeIntervalSince(lastRefreshed ?? createdAt) > maxAge
    }
}

enum OfflineRegionStore {
    private static let key = "offlineRegions.v1"

    static func loadAll() -> [OfflineRegion] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([OfflineRegion].self, from: data)) ?? []
    }

    static func saveAll(_ regions: [OfflineRegion]) {
        if let data = try? JSONEncoder().encode(regions) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .offlineRegionsChanged, object: nil)
    }

    static func upsert(_ region: OfflineRegion) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == region.id }) {
            all[idx] = region
        } else {
            all.append(region)
        }
        saveAll(all)
    }

    static func remove(id: UUID) {
        saveAll(loadAll().filter { $0.id != id })
    }
}

extension Notification.Name {
    static let offlineRegionsChanged = Notification.Name("offlineRegionsChanged")
}

// MARK: - Layer resolution

/// A region's `layerID` resolved back to its layer, unifying the two source
/// kinds behind what the download engine needs: a tile grid, a zoom range, a
/// pinned-storage namespace, and a fetcher.
enum OfflineLayerRef {
    case bng(CustomTileSource)
    case xyz(StandardTileSource)

    static func resolve(id: UUID) -> OfflineLayerRef? {
        if let src = CustomTileSourceStore.loadAll().first(where: { $0.id == id }) {
            return .bng(src)
        }
        if let layer = StandardTileSourceStore.loadAll().first(where: { $0.id == id }) {
            return .xyz(layer)
        }
        return nil
    }

    var displayName: String {
        switch self {
        case .bng(let src):   return src.name
        case .xyz(let layer): return layer.name
        }
    }

    /// The namespace the *renderers* read caches under — pinned packs must use
    /// the same one, or the pinned→cache read path never finds them.
    /// (`BNGTileStore` prefixes custom sources with "src-".)
    var namespace: String {
        switch self {
        case .bng(let src):   return "src-\(src.cacheNamespace)"
        case .xyz(let layer): return layer.cacheNamespace
        }
    }

    var grid: OfflineTileEnumerator.Grid {
        switch self {
        case .bng(let src):   return .bng(src.validated?.matrix ?? .bngDefault)
        case .xyz:            return .mercator
        }
    }

    /// The layer's native zoom range — the pyramid downloads from its floor.
    var zoomRange: ClosedRange<Int> {
        switch self {
        case .bng(let src):
            let matrix = src.validated?.matrix ?? .bngDefault
            return 0...matrix.maxZoom
        case .xyz(let layer):
            return layer.minZoom...max(layer.minZoom, layer.maxZoom)
        }
    }

    /// A fetcher aimed at `store` — the pack downloader/refresher passes the
    /// pinned store so tiles land there (and only there).
    func makeFetcher(targetStore: TileDiskCache) -> TileFetcher {
        switch self {
        case .bng(let src):
            return TileFetcher(urlTemplate: src.zxyTemplate,
                               apiKey: "",
                               cacheNamespace: namespace,
                               zoomIdentifiers: src.validated?.matrixIdentifiers,
                               healthSourceID: src.id.uuidString,
                               healthSourceName: src.name,
                               targetStore: targetStore)
        case .xyz(let layer):
            return TileFetcher(urlTemplate: layer.urlTemplate,
                               apiKey: layer.apiKey ?? "",
                               cacheNamespace: namespace,
                               subdomains: layer.subdomainTokens,
                               healthSourceID: layer.id.uuidString,
                               healthSourceName: layer.name,
                               targetStore: targetStore)
        }
    }
}

// MARK: - Tile enumeration

enum OfflineTileEnumerator {

    enum Grid {
        case mercator
        case bng(BNGTileMatrix)
    }

    /// The tile x/y ranges covering `bounds` at zoom `z`, or nil when the
    /// region falls entirely outside the grid at that level (BNG matrices are
    /// bounded; a region off the advertised grid downloads nothing there).
    static func ranges(bounds: LatLonBounds, grid: Grid, z: Int)
        -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        switch grid {
        case .mercator:
            return mercatorRanges(bounds: bounds, z: z)
        case .bng(let matrix):
            return bngRanges(bounds: bounds, matrix: matrix, z: z)
        }
    }

    /// Total tiles for the full pyramid — the picker's live estimate and the
    /// download progress denominator. The deepest level dominates (≈ ×1.33).
    static func tileCount(bounds: LatLonBounds, grid: Grid, zooms: ClosedRange<Int>) -> Int {
        var total = 0
        for z in zooms {
            guard let r = ranges(bounds: bounds, grid: grid, z: z) else { continue }
            total += r.x.count * r.y.count
        }
        return total
    }

    /// Lazy pyramid enumeration, coarsest level first (a partially downloaded
    /// pack is a usable low-zoom map long before it finishes). Never
    /// materialises the tile list.
    static func tiles(bounds: LatLonBounds, grid: Grid, zooms: ClosedRange<Int>)
        -> AnySequence<(z: Int, x: Int, y: Int)> {
        AnySequence { () -> AnyIterator<(z: Int, x: Int, y: Int)> in
            var z = zooms.lowerBound - 1
            var level: (x: ClosedRange<Int>, y: ClosedRange<Int>)? = nil
            var x = 0, y = 0
            return AnyIterator { () -> (z: Int, x: Int, y: Int)? in
                while true {
                    if level == nil {
                        repeat {
                            z += 1
                            if z > zooms.upperBound { return nil }
                            level = ranges(bounds: bounds, grid: grid, z: z)
                        } while level == nil
                        x = level!.x.lowerBound
                        y = level!.y.lowerBound
                    }
                    guard let r = level else { return nil }
                    if y > r.y.upperBound {
                        level = nil
                        continue
                    }
                    let tile = (z: z, x: x, y: y)
                    x += 1
                    if x > r.x.upperBound {
                        x = r.x.lowerBound
                        y += 1
                    }
                    return tile
                }
            }
        }
    }

    // MARK: Grid math

    private static func mercatorRanges(bounds: LatLonBounds, z: Int)
        -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        // webMercatorTileXY clamps into the grid, so corners are always valid.
        let topLeft = TileLayerTester.webMercatorTileXY(lat: bounds.latMax, lon: bounds.lonMin, z: z)
        let bottomRight = TileLayerTester.webMercatorTileXY(lat: bounds.latMin, lon: bounds.lonMax, z: z)
        return (min(topLeft.x, bottomRight.x)...max(topLeft.x, bottomRight.x),
                min(topLeft.y, bottomRight.y)...max(topLeft.y, bottomRight.y))
    }

    private static func bngRanges(bounds: LatLonBounds, matrix: BNGTileMatrix, z: Int)
        -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        guard matrix.resolutions.indices.contains(z) else { return nil }
        // Project all four corners — the BNG grid isn't axis-aligned with
        // lat/lon, so the bounding box comes from corner extremes.
        let corners = [(bounds.latMin, bounds.lonMin), (bounds.latMin, bounds.lonMax),
                       (bounds.latMax, bounds.lonMin), (bounds.latMax, bounds.lonMax)]
            .map { BNGProjection.wgs84ToBNG(lat: $0.0, lon: $0.1) }
        let eMin = corners.map(\.e).min()!
        let eMax = corners.map(\.e).max()!
        let nMin = corners.map(\.n).min()!
        let nMax = corners.map(\.n).max()!

        let metresPerTile = matrix.resolutions[z] * Double(matrix.tileSize)
        var x0 = Int(floor((eMin - matrix.originX(at: z)) / metresPerTile))
        var x1 = Int(floor((eMax - matrix.originX(at: z)) / metresPerTile))
        var y0 = Int(floor((matrix.originY(at: z) - nMax) / metresPerTile))
        var y1 = Int(floor((matrix.originY(at: z) - nMin) / metresPerTile))

        // Clip to the advertised grid; unbounded matrices only enforce ≥ 0.
        x0 = max(0, x0)
        y0 = max(0, y0)
        if let cols = matrix.columns(at: z) { x1 = min(cols - 1, x1) }
        if let rows = matrix.rows(at: z) { y1 = min(rows - 1, y1) }
        guard x0 <= x1, y0 <= y1 else { return nil }
        return (x0...x1, y0...y1)
    }
}
