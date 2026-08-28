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
    /// BNG easting of the top-left corner of tile (0,0), per zoom level. WMTS
    /// allows TopLeftCorner to differ per level, so this is indexed by zoom.
    let originsX: [Double]
    /// BNG northing of the top-left corner of tile (0,0), per zoom level.
    let originsY: [Double]
    /// Tile side length in pixels (typically 256).
    let tileSize: Int
    /// Resolution in metres/pixel for each zoom level. resolutions[z] applies at zoom z.
    let resolutions: [Double]
    /// Grid dimensions per zoom (MatrixWidth/MatrixHeight), when the service
    /// advertises them. nil = unbounded (only x/y ≥ 0 is enforced).
    let matrixWidths: [Int]?
    let matrixHeights: [Int]?

    var minZoom: Int { 0 }
    var maxZoom: Int { resolutions.count - 1 }

    func originX(at z: Int) -> Double {
        originsX.indices.contains(z) ? originsX[z] : (originsX.first ?? 0)
    }
    func originY(at z: Int) -> Double {
        originsY.indices.contains(z) ? originsY[z] : (originsY.first ?? 0)
    }
    /// Grid width/height in tiles at zoom `z`, or nil when unknown.
    func columns(at z: Int) -> Int? {
        guard let w = matrixWidths, w.indices.contains(z) else { return nil }
        return w[z]
    }
    func rows(at z: Int) -> Int? {
        guard let h = matrixHeights, h.indices.contains(z) else { return nil }
        return h[z]
    }

    /// The rectangle the map is cut to — the British National Grid as a sheet.
    ///
    /// Two standards bound it, and each takes the sides where it reaches further:
    ///
    /// - EPSG:27700's area of use (E −68,652…652,865, N −16,704…1,140,267) goes
    ///   furthest west and south, out over the UKCS to 9°W and 49°45'N.
    /// - The grid itself spans 700 × 1300 km from its false origin — the lettered
    ///   100 km squares, SV through JM. It goes furthest north and east, and it has
    ///   to: the area of use stops short of Lowestoft (E ≈ 655,000) and slices
    ///   through Shetland (Unst reaches N ≈ 1,220,000).
    ///
    /// This, not the tile grid's extent, is where the map is cut. A pyramid's
    /// origin is chosen to make whole tiles at every level, so its grid overshoots
    /// all of the above and imagery peters out somewhere inside it — an edge drawn
    /// there shows a band of blank paper before the shadow.
    static let sheetBounds = (minX: -68_652.35, minY: -16_703.89,
                              maxX: 700_000.0, maxY: 1_300_000.0)

    /// The standard British National Grid raster tile matrix (origin
    /// (-238375, 1376256), 256px tiles, 896…1.75 m/px). Used as a safe default
    /// when we haven't yet fetched the live capabilities.
    static let bngDefault: BNGTileMatrix = {
        let resolutions: [Double] = [896, 448, 224, 112, 56, 28, 14, 7, 3.5, 1.75]
        return BNGTileMatrix(
            originsX: Array(repeating: -238_375, count: resolutions.count),
            originsY: Array(repeating: 1_376_256, count: resolutions.count),
            tileSize: 256,
            resolutions: resolutions,
            matrixWidths: nil,
            matrixHeights: nil)
    }()

    /// Matrices ordered coarsest-first (zoom 0 → n). This ordering defines what
    /// "zoom z" means everywhere — resolutions, identifiers, origins and bounds
    /// arrays must all be built from it.
    static func sortedMatrices(_ set: WMTSCapabilities.TileMatrixSet) -> [WMTSCapabilities.TileMatrix] {
        set.matrices.sorted { $0.scaleDenominator > $1.scaleDenominator }
    }

    /// Build from a WMTS-parsed tile matrix set.
    ///
    /// WMTS reports each matrix's origin (`TopLeftCorner`) and scale
    /// denominator. Resolution in metres/pixel equals
    /// `scaleDenominator × 0.00028` (WMTS standard pixel size = 0.28 mm).
    static func fromCapabilities(_ set: WMTSCapabilities.TileMatrixSet) -> BNGTileMatrix? {
        guard !set.matrices.isEmpty else { return nil }
        let sorted = sortedMatrices(set)
        // WMTS pixel is 0.28mm; metre-per-pixel = scaleDenominator * 0.28e-3
        return BNGTileMatrix(
            originsX: sorted.map(\.topLeftCorner.x),
            originsY: sorted.map(\.topLeftCorner.y),
            tileSize: sorted[0].tileWidth,
            resolutions: sorted.map { $0.scaleDenominator * 0.00028 },
            matrixWidths: sorted.map(\.matrixWidth),
            matrixHeights: sorted.map(\.matrixHeight))
    }
}
