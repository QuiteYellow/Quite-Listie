//
//  TileLayerTester.swift
//  QuiteListie
//
//  One-shot layer probe behind the settings screen's "Test" button: pick a
//  single tile that should be inside the layer's coverage, fetch it
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

    // MARK: - Fetch

    static func test(source: CustomTileSource) async -> Outcome {
        let (z, x, y) = testTile(for: source)
        let url = TileFetcher.expandTemplate(
            source.zxyTemplate, z: z, x: x, y: y,
            zoomIdentifiers: source.validated?.matrixIdentifiers)
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
