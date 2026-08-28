import Foundation
import CryptoKit

/// A user-added EPSG:27700 (British National Grid) tile layer, discovered by
/// scanning a WMTS endpoint. The user pastes one WMTS address (which already
/// carries the API key as `?key=…`); we read its capabilities, build a ZXY tile
/// template per advertised layer, and the user adds the ones they want with a
/// friendly name. Each added layer shows as its own choice in the app.
struct CustomTileSource: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Friendly, user-editable display name.
    var name: String
    /// The WMTS GetCapabilities address this layer was discovered from.
    var wmtsEndpoint: String
    /// The ZXY tile address with `{z}/{x}/{y}` placeholders (key embedded).
    var zxyTemplate: String
    /// Optional licence/credit line, drawn as a small caption on the map when
    /// set. The user's obligation to their provider — nothing is bundled.
    var attribution: String? = nil
    /// Tile-grid parameters read from the WMTS capabilities for this layer.
    var validated: ValidatedCapabilities? = nil

    struct ValidatedCapabilities: Codable, Equatable {
        var layerIdentifier: String     // WMTS layer identifier
        var layerTitle: String?
        var tileMatrixSetIdentifier: String
        var supportedCRS: String        // e.g. "urn:ogc:def:crs:EPSG::27700"
        var originX: Double
        var originY: Double
        var tileSize: Int
        var resolutions: [Double]        // metres/pixel per zoom (0..n)
        // v4 fields — optional so v3-era records still decode; when absent the
        // matrix falls back to the shared origin and unbounded grids, and `{z}`
        // substitutes the numeric level (the convention v3 assumed).
        /// TileMatrix identifier per zoom (WMTS identifiers are arbitrary
        /// strings, e.g. "EPSG:27700:5" — not necessarily the zoom number).
        var matrixIdentifiers: [String]? = nil
        /// Per-zoom tile-grid origins (WMTS allows TopLeftCorner to vary by level).
        var originsX: [Double]? = nil
        var originsY: [Double]? = nil
        /// Per-zoom grid dimensions, for skipping requests outside coverage.
        var matrixWidths: [Int]? = nil
        var matrixHeights: [Int]? = nil
        // v5 field — optional so v3/v4 records still decode.
        /// The layer's declared extent in BNG metres (`ows:BoundingBox`). This is
        /// the ground the service actually covers, identical at every zoom;
        /// `matrixWidths`/`matrixHeights` are tile counts rounded up, so they
        /// overshoot by a different amount at each level.
        var extent: Extent? = nil

        struct Extent: Codable, Equatable {
            var eMin: Double, eMax: Double, nMin: Double, nMax: Double
        }

        var matrix: BNGTileMatrix {
            let n = resolutions.count
            return BNGTileMatrix(
                originsX: originsX ?? Array(repeating: originX, count: n),
                originsY: originsY ?? Array(repeating: originY, count: n),
                tileSize: tileSize,
                resolutions: resolutions,
                matrixWidths: matrixWidths,
                matrixHeights: matrixHeights)
        }

        /// Everything we keep from a scan, in one place, so the settings scan and
        /// the back-fill of older records can't record different things.
        static func from(layer: WMTSCapabilities.Layer,
                         set: WMTSCapabilities.TileMatrixSet,
                         matrix: BNGTileMatrix) -> ValidatedCapabilities {
            ValidatedCapabilities(
                layerIdentifier: layer.identifier,
                layerTitle: layer.title,
                tileMatrixSetIdentifier: set.identifier,
                supportedCRS: set.supportedCRS,
                originX: matrix.originX(at: 0),
                originY: matrix.originY(at: 0),
                tileSize: matrix.tileSize,
                resolutions: matrix.resolutions,
                matrixIdentifiers: BNGTileMatrix.sortedMatrices(set).map(\.identifier),
                originsX: matrix.originsX,
                originsY: matrix.originsY,
                matrixWidths: matrix.matrixWidths,
                matrixHeights: matrix.matrixHeights,
                extent: layer.boundingBox.map {
                    Extent(eMin: $0.eMin, eMax: $0.eMax, nMin: $0.nMin, nMax: $0.nMax)
                })
        }
    }

    var isUsable: Bool {
        !zxyTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        zxyTemplate.contains("{z}") && zxyTemplate.contains("{x}") && zxyTemplate.contains("{y}")
    }

    /// Stable filesystem-safe identifier derived from the tile template — used
    /// as the disk-cache namespace so different sources cache separately.
    /// Recognised key/auth query params are stripped before hashing, so a key
    /// rotation doesn't orphan the layer's cache.
    var cacheNamespace: String {
        Self.namespaceHash(TileURLKeys.strippingAuthParams(fromTemplate: zxyTemplate))
    }

    /// The pre-key-stripping namespace this source's tiles were cached under.
    /// Kept so an existing cache directory can be renamed to `cacheNamespace`
    /// instead of orphaned (see `TileDiskCache.adoptLegacyNamespace`).
    var legacyCacheNamespace: String {
        Self.namespaceHash(zxyTemplate)
    }

    private static func namespaceHash(_ template: String) -> String {
        let digest = SHA256.hash(data: Data(template.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

enum CustomTileSourceStore {
    // v4: adds matrix identifiers + per-zoom origins/bounds to each layer's
    // validated capabilities. v3 records decode as-is (new fields optional).
    private static let key = "customTileSources.v4"
    private static let legacyV3Key = "customTileSources.v3"

    static func loadAll() -> [CustomTileSource] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([CustomTileSource].self, from: data) {
            return decoded
        }
        // One-time migration from v3. The v3 blob is left in place so nothing is
        // lost if the v4 write fails or the app downgrades.
        if let data = defaults.data(forKey: legacyV3Key),
           let decoded = try? JSONDecoder().decode([CustomTileSource].self, from: data) {
            if let reencoded = try? JSONEncoder().encode(decoded) {
                defaults.set(reencoded, forKey: key)
            }
            return decoded
        }
        return []
    }

    static func saveAll(_ sources: [CustomTileSource]) {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .customTileSourceChanged, object: nil)
    }

    /// Insert a new source, or replace an existing one with the same id.
    /// Adding a *new* source whose resolved template already exists updates
    /// that layer in place (keeping its id) instead of creating a duplicate.
    static func upsert(_ source: CustomTileSource) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == source.id }) {
            all[idx] = source
        } else if let idx = all.firstIndex(where: { $0.zxyTemplate == source.zxyTemplate }) {
            var merged = source
            merged.id = all[idx].id
            all[idx] = merged
        } else {
            all.append(source)
        }
        saveAll(all)
    }

    static func remove(id: UUID) {
        saveAll(loadAll().filter { $0.id != id })
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyV3Key)
        NotificationCenter.default.post(name: .customTileSourceChanged, object: nil)
    }
}

extension Notification.Name {
    static let customTileSourceChanged = Notification.Name("customTileSourceChanged")
}

/// Persisted map-layer choice for GlobalMapView, stored as a raw string in
/// AppStorage: `appleMaps` or a custom source's UUID. An id that no longer
/// resolves falls back to Apple Maps.
enum GlobalMapLayer {
    static let appleMaps = "appleMaps"
    static let storageKey = "globalMapLayer.v1"
}
