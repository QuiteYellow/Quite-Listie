//
//  TileMatrix.swift
//  QuiteListie
//
//  Parameters describing a BNG (EPSG:27700) tile pyramid. Derived from a
//  service's WMTS capabilities when available, falling back to these standard
//  British National Grid values.
//

import Foundation

struct BNGTileMatrix {
    /// BNG easting of the top-left corner of tile (0,0) at every zoom level.
    let originX: Double
    /// BNG northing of the top-left corner of tile (0,0) at every zoom level.
    let originY: Double
    /// Tile side length in pixels (typically 256).
    let tileSize: Int
    /// Resolution in metres/pixel for each zoom level. resolutions[z] applies at zoom z.
    let resolutions: [Double]

    var minZoom: Int { 0 }
    var maxZoom: Int { resolutions.count - 1 }

    /// The standard British National Grid raster tile matrix (origin
    /// (-238375, 1376256), 256px tiles, 896…1.75 m/px). Used as a safe default
    /// when we haven't yet fetched the live capabilities.
    static let bngDefault = BNGTileMatrix(
        originX: -238_375,
        originY: 1_376_256,
        tileSize: 256,
        resolutions: [896, 448, 224, 112, 56, 28, 14, 7, 3.5, 1.75]
    )

    /// Build from a WMTS-parsed tile matrix set.
    ///
    /// WMTS reports each matrix's origin (`TopLeftCorner`) and scale
    /// denominator. Resolution in metres/pixel equals
    /// `scaleDenominator × 0.00028` (WMTS standard pixel size = 0.28 mm).
    static func fromCapabilities(_ set: WMTSCapabilities.TileMatrixSet) -> BNGTileMatrix? {
        guard !set.matrices.isEmpty else { return nil }
        // Sort by scaleDenominator descending (coarsest first, zoom 0 → n).
        let sorted = set.matrices.sorted { $0.scaleDenominator > $1.scaleDenominator }
        let first = sorted[0]
        // OS matrices share a common origin across zooms, but be safe and use
        // the first (coarsest) one — the tile (0,0) corner is anchored there.
        let originX = first.topLeftCorner.x
        let originY = first.topLeftCorner.y
        // WMTS pixel is 0.28mm; metre-per-pixel = scaleDenominator * 0.28e-3
        let resolutions = sorted.map { $0.scaleDenominator * 0.00028 }
        let tileSize = first.tileWidth
        return BNGTileMatrix(
            originX: originX, originY: originY,
            tileSize: tileSize, resolutions: resolutions
        )
    }
}
