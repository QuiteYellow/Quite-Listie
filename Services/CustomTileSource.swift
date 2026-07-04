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

        var matrix: BNGTileMatrix {
            BNGTileMatrix(originX: originX, originY: originY,
                          tileSize: tileSize, resolutions: resolutions)
        }
    }

    var isUsable: Bool {
        !zxyTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        zxyTemplate.contains("{z}") && zxyTemplate.contains("{x}") && zxyTemplate.contains("{y}")
    }

    /// Stable filesystem-safe identifier derived from the tile template — used
    /// as the disk-cache namespace so different sources cache separately.
    var cacheNamespace: String {
        let digest = SHA256.hash(data: Data(zxyTemplate.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Extract the ZXY style name from the tile template (the segment right
    /// after `/zxy/`). Returns nil if the template doesn't follow the OS pattern.
    var zxyStyleName: String? {
        guard let zxyRange = zxyTemplate.range(of: "/zxy/") else { return nil }
        let rest = zxyTemplate[zxyRange.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return String(rest[..<slash])
    }
}

enum CustomTileSourceStore {
    // v3: a list of added layers (each discovered by scanning a WMTS endpoint).
    private static let key = "customTileSources.v3"

    static func loadAll() -> [CustomTileSource] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CustomTileSource].self, from: data)) ?? []
    }

    static func saveAll(_ sources: [CustomTileSource]) {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .customTileSourceChanged, object: nil)
    }

    /// Insert a new source, or replace an existing one with the same id.
    static func upsert(_ source: CustomTileSource) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == source.id }) {
            all[idx] = source
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
        NotificationCenter.default.post(name: .customTileSourceChanged, object: nil)
    }
}

extension Notification.Name {
    static let customTileSourceChanged = Notification.Name("customTileSourceChanged")
}

/// Persisted map-layer choice for GlobalMapView, stored as a raw string in
/// AppStorage: either `appleMaps` or a custom source's UUID string.
enum GlobalMapLayer {
    static let appleMaps = "appleMaps"
    static let storageKey = "globalMapLayer.v1"
}
