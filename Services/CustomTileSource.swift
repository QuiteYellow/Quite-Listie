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
        // substitutes the numeric level (the OS convention v3 assumed).
        /// TileMatrix identifier per zoom (WMTS identifiers are arbitrary
        /// strings, e.g. "EPSG:27700:5" — not necessarily the zoom number).
        var matrixIdentifiers: [String]? = nil
        /// Per-zoom tile-grid origins (WMTS allows TopLeftCorner to vary by level).
        var originsX: [Double]? = nil
        var originsY: [Double]? = nil
        /// Per-zoom grid dimensions, for skipping requests outside coverage.
        var matrixWidths: [Int]? = nil
        var matrixHeights: [Int]? = nil

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

    fileprivate static func namespaceHash(_ template: String) -> String {
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
/// AppStorage: `appleMaps`, a built-in raster layer id, or a custom source's UUID.
enum GlobalMapLayer {
    static let appleMaps = "appleMaps"
    static let storageKey = "globalMapLayer.v1"
}

/// A user-added web-mercator (EPSG:3857) XYZ raster layer, shown on standard
/// MapKit via `MKTileOverlay`. Unlike `CustomTileSource` (EPSG:27700 WMTS, which
/// needs a fully native slippy map), these are the "standard projection" the
/// world already uses, so the user just pastes an XYZ template, names it, and
/// MapKit handles projection/panning/zoom. The list ships empty — no tile URLs
/// are baked in; the user adds their own.
struct StandardTileSource: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Friendly, user-editable display name.
    var name: String
    /// XYZ tile address with `{z}/{x}/{y}` placeholders.
    var urlTemplate: String
    /// Deepest zoom the tileset publishes. Past this, `RasterTileMapView`
    /// overzooms (upscales the deepest tiles) rather than requesting deeper ones
    /// that would 404 and leave blank gaps.
    var maxZoom: Int
    /// Shallowest zoom the tileset publishes.
    var minZoom: Int
    /// Optional API key, substituted for `{apikey}` in the template. Kept out of
    /// the template itself so the cache namespace survives a key rotation.
    var apiKey: String? = nil
    /// Subdomain tokens for `{s}`: per-character ("abc") or comma-separated
    /// ("mt0,mt1"). nil/empty = template has no `{s}` or the default host.
    var subdomains: String? = nil
    /// Tile edge in pixels, detected when the layer is added (256 unless the
    /// tileset serves 512/retina tiles). Drives `MKTileOverlay.tileSize` — a
    /// 512px tileset rendered as 256 would display everything at half scale.
    var tilePixelSize: Int? = nil
    /// Optional licence/credit line, drawn as a small caption on the map when
    /// set. The user's obligation to their provider — nothing is bundled.
    var attribution: String? = nil

    var isUsable: Bool {
        let t = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.contains("{z}") && t.contains("{x}")
            && (t.contains("{y}") || t.contains("{-y}"))
    }

    /// ATS blocks plain-http tile servers at runtime with no way to relax it
    /// from code, so anything but https is a guaranteed silent blank map.
    var usesSecureScheme: Bool {
        urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("https://")
    }

    /// Parsed `{s}` tokens: "abc" → ["a","b","c"], "mt0,mt1" → ["mt0","mt1"].
    var subdomainTokens: [String] {
        guard let s = subdomains?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return [] }
        if s.contains(",") {
            return s.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return s.map(String.init)
    }

    /// Stable filesystem-safe cache namespace derived from the template, so
    /// different layers cache separately (and re-namespace if the URL changes),
    /// all under the same managed cache root covered by size/clear reporting.
    /// Recognised key/auth query params are stripped before hashing — `{apikey}`
    /// already keeps the key out of the template, this covers keys pasted
    /// directly into the URL.
    var cacheNamespace: String {
        "std-" + CustomTileSource.namespaceHash(
            TileURLKeys.strippingAuthParams(fromTemplate: urlTemplate))
    }

    /// The pre-key-stripping namespace this layer's tiles were cached under
    /// (see `TileDiskCache.adoptLegacyNamespace`).
    var legacyCacheNamespace: String {
        "std-" + CustomTileSource.namespaceHash(urlTemplate)
    }
}

enum StandardTileSourceStore {
    private static let key = "standardTileSources.v1"

    static func loadAll() -> [StandardTileSource] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([StandardTileSource].self, from: data)) ?? []
    }

    static func saveAll(_ sources: [StandardTileSource]) {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // Reuse the existing signal so the map picker refreshes for either kind.
        NotificationCenter.default.post(name: .customTileSourceChanged, object: nil)
    }

    /// Insert a new source, or replace an existing one with the same id.
    /// Adding a *new* layer whose template already exists updates that layer in
    /// place (keeping its id) instead of creating a duplicate.
    static func upsert(_ source: StandardTileSource) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == source.id }) {
            all[idx] = source
        } else if let idx = all.firstIndex(where: { $0.urlTemplate == source.urlTemplate }) {
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

    static func source(withID id: String) -> StandardTileSource? {
        loadAll().first { $0.id.uuidString == id }
    }
}
