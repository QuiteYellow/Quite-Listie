//
//  TileLayerTester.swift
//  QuiteListie
//
//  One-shot layer probe behind the settings editors' "Test Layer" buttons:
//  pick a single tile that should be inside the layer's coverage, fetch it
//  once, and report what came back in user-facing terms. Deliberately outside
//  TileFetcher — no retries, no caching, no limiter; a test should show the
//  server's real answer, not the resilient pipeline's.
//

import Foundation
import ImageIO

enum TileLayerTester {

    enum Outcome: Equatable {
        case ok(pixelSize: Int)
        case http(Int)
        case notAnImage
        case badURL
        case network(String)

        var success: Bool {
            if case .ok = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .ok(let px):     return "Tile loaded and decoded (\(px)×\(px) px)."
            case .http(401), .http(403):
                                  return "Server rejected the request — check the API key."
            case .http(404):      return "No tile there (404) — the layer may not cover the test area."
            case .http(let s):    return "Server returned HTTP \(s)."
            case .notAnImage:     return "Server answered, but not with an image tile."
            case .badURL:         return "Couldn’t build a tile URL from this template."
            case .network(let m): return "Network error: \(m)"
            }
        }
    }

    // MARK: - Test-tile selection

    /// Roughly the middle of Great Britain (near Lancaster) in BNG metres —
    /// a safe in-coverage probe point for GB-wide tilesets.
    static let centralGB = (e: 389_000.0, n: 461_000.0)

    /// An in-range tile for a BNG (EPSG:27700) source: a mid-pyramid zoom, at
    /// the centre of the advertised grid when the capabilities carried bounds
    /// (partial-coverage layers centre their grid on their coverage), else the
    /// tile containing the central-GB point.
    static func testTile(for source: CustomTileSource) -> (z: Int, x: Int, y: Int) {
        let matrix = source.validated?.matrix ?? .bngDefault
        let z = matrix.maxZoom / 2
        if let cols = matrix.columns(at: z), let rows = matrix.rows(at: z) {
            return (z, cols / 2, rows / 2)
        }
        let metresPerTile = matrix.resolutions[z] * Double(matrix.tileSize)
        let x = Int((centralGB.e - matrix.originX(at: z)) / metresPerTile)
        let y = Int((matrix.originY(at: z) - centralGB.n) / metresPerTile)
        return (z, max(0, x), max(0, y))
    }

    /// An in-range tile for a web-mercator XYZ layer: a mid-range zoom at the
    /// given coordinate (the user's location when known, else central GB).
    static func testTile(for layer: StandardTileSource,
                         lat: Double? = nil, lon: Double? = nil) -> (z: Int, x: Int, y: Int) {
        let z = min(max((layer.minZoom + layer.maxZoom) / 2, layer.minZoom), layer.maxZoom)
        let (x, y) = webMercatorTileXY(lat: lat ?? 54.5, lon: lon ?? -2.5, z: z)
        return (z, x, y)
    }

    /// Web-mercator tile x/y for a lat/lon at zoom `z`.
    static func webMercatorTileXY(lat: Double, lon: Double, z: Int) -> (x: Int, y: Int) {
        let n = pow(2.0, Double(z))
        let x = Int(floor((lon + 180) / 360 * n))
        let latRad = lat * .pi / 180
        let y = Int(floor((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n))
        let maxIdx = Int(n) - 1
        return (min(max(x, 0), maxIdx), min(max(y, 0), maxIdx))
    }

    // MARK: - Fetch

    static func test(source: CustomTileSource) async -> Outcome {
        let (z, x, y) = testTile(for: source)
        let url = TileFetcher.expandTemplate(
            source.zxyTemplate, z: z, x: x, y: y,
            zoomIdentifiers: source.validated?.matrixIdentifiers)
        return await fetch(urlString: url)
    }

    static func test(layer: StandardTileSource,
                     lat: Double? = nil, lon: Double? = nil) async -> Outcome {
        let (z, x, y) = testTile(for: layer, lat: lat, lon: lon)
        let url = TileFetcher.expandTemplate(
            layer.urlTemplate, z: z, x: x, y: y,
            apiKey: layer.apiKey ?? "",
            subdomains: layer.subdomainTokens)
        return await fetch(urlString: url)
    }

    static func fetch(urlString: String) async -> Outcome {
        guard let url = URL(string: urlString) else { return .badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .http(status) }
            guard TileFetcher.looksLikeImage(data),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { return .notAnImage }
            return .ok(pixelSize: img.width)
        } catch {
            return .network(error.localizedDescription)
        }
    }
}
