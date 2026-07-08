import Foundation
import CoreGraphics
import ImageIO

/// Fetches tiles from an arbitrary URL template and caches them (memory + disk) as decoded RGBA buffers.
/// URL template placeholders: {z} {x} {y} {-y} {s} {r} {apikey} — see `expandTemplate`.
actor TileFetcher {
    struct Bitmap {
        let bytes: [UInt8]  // RGBA, premultiplied, row-major
        let width: Int
        let height: Int
    }
    /// Decoded-CGImage view of a source tile, used by the corner-affine
    /// renderer so it can hand tiles straight to CGContext.draw without going
    /// through the RGBA byte array.
    struct Image {
        let cg: CGImage
        let width: Int
        let height: Int
    }

    private let urlTemplate: String
    private let apiKey: String
    /// WMTS TileMatrix identifier per zoom. When set, `{z}` substitutes
    /// `zoomIdentifiers[z]` (percent-encoded) instead of the numeric level —
    /// WMTS identifiers are arbitrary strings like "EPSG:27700:5".
    private let zoomIdentifiers: [String]?
    /// Subdomain tokens for `{s}` rotation (e.g. ["a","b","c"]).
    private let subdomains: [String]
    /// Identity of the layer this fetcher serves, for the health banner.
    /// nil (probes, tests) = terminal failures aren't reported.
    private let healthSourceID: String?
    private let healthSourceName: String?
    private let session: URLSession
    private let disk: TileDiskCache
    /// ETag/Last-Modified per cached tile, for conditional refresh (offline
    /// packs re-validate monthly; unchanged tiles cost a 304, not a download).
    private let manifest: TileValidatorManifest
    private let limiter: FetchLimiter
    private var memory: [String: Bitmap] = [:]
    private var imageMemory: [String: Image] = [:]
    private var order: [String] = []
    private let memoryLimit = 512

    /// `targetStore` redirects *all* disk traffic (reads, writes, manifest) to
    /// that store instead of the namespace-derived cache. The offline-pack
    /// downloader passes the pinned store here — otherwise every pack tile
    /// would be written twice (once pinned, once in the purgeable cache).
    /// `protocolClasses` lets tests stub the network via URLProtocol.
    init(urlTemplate: String, apiKey: String, cacheNamespace: String,
         legacyCacheNamespace: String? = nil,
         zoomIdentifiers: [String]? = nil, subdomains: [String] = [],
         healthSourceID: String? = nil, healthSourceName: String? = nil,
         targetStore: TileDiskCache? = nil,
         protocolClasses: [AnyClass]? = nil) {
        self.urlTemplate = urlTemplate
        self.apiKey = apiKey
        self.zoomIdentifiers = zoomIdentifiers
        self.subdomains = subdomains
        self.healthSourceID = healthSourceID
        self.healthSourceName = healthSourceName
        let cfg = URLSessionConfiguration.default
        // HTTP/2 multiplexes many streams over one connection, so this limits
        // connection pool churn rather than concurrent requests. Real
        // concurrency is capped by the FetchLimiter below.
        cfg.httpMaximumConnectionsPerHost = 6
        // Idle timeout — a well-behaved tile should return within 30s once it
        // starts flowing bytes. Anything much longer is a lost socket.
        cfg.timeoutIntervalForRequest = 30
        // Total time a request may spend from start (including queueing) to
        // finish. Keep bounded so lingering ghosts eventually die.
        cfg.timeoutIntervalForResource = 60
        // Don't wait around for connectivity — fail fast, let retry handle it.
        cfg.waitsForConnectivity = false
        if let protocolClasses { cfg.protocolClasses = protocolClasses }
        self.session = URLSession(configuration: cfg)
        let disk = targetStore ?? TileDiskCache(namespace: cacheNamespace,
                                                legacyNamespace: legacyCacheNamespace)
        self.disk = disk
        self.manifest = TileValidatorManifest(directory: disk.root)
        // Six concurrent requests. Matches typical browser per-origin
        // connection budget and keeps the tile API from being hammered when a
        // hundred tiles are requested at once.
        self.limiter = FetchLimiter(capacity: 6)
    }

    /// Fetch a tile as a decoded CGImage. Used by the corner-affine renderer,
    /// which hands source tiles straight to CGContext.draw without ever
    /// touching the RGBA byte array.
    func fetchImage(z: Int, x: Int, y: Int) async -> Image? {
        let key = "\(z)/\(x)/\(y)"
        if let hit = imageMemory[key] { return hit }

        if let data = disk.read(z: z, x: x, y: y), let img = decodeImage(data) {
            insertImageMemory(key: key, img: img)
            return img
        }
        // Fall through to network fetch — reuse the standard fetch pipeline
        // which handles retry/backoff/limiter and stores raw bytes on disk.
        guard let bmp = await fetch(z: z, x: x, y: y) else { return nil }
        // Bitmap→Image via disk (already saved) or via the disk-read path.
        // Cheapest: re-read the just-saved data and decode. Disk read of a
        // 20KB PNG is faster than reconstructing a CGImage from raw bytes.
        if let data = disk.read(z: z, x: x, y: y), let img = decodeImage(data) {
            insertImageMemory(key: key, img: img)
            return img
        }
        // Last resort: rebuild the CGImage from the RGBA bitmap.
        if let img = imageFromBitmap(bmp) {
            insertImageMemory(key: key, img: img)
            return img
        }
        return nil
    }

    func fetch(z: Int, x: Int, y: Int) async -> Bitmap? {
        let key = "\(z)/\(x)/\(y)"
        if let hit = memory[key] { return hit }

        if let data = disk.read(z: z, x: x, y: y), let bmp = decode(data) {
            insertMemory(key: key, bmp: bmp)
            return bmp
        }

        guard let data = await fetchFromNetwork(z: z, x: x, y: y),
              let bmp = decode(data) else { return nil }
        insertMemory(key: key, bmp: bmp)
        return bmp
    }

    /// Raw tile bytes — disk first, then network — without decoding or touching
    /// the in-memory bitmap cache. Used by the MKTileOverlay-backed built-in
    /// raster layer, which hands undecoded data straight to MapKit. Shares the
    /// same on-disk namespace as `fetch`, so the cache-size readout and the
    /// "clear cache" action cover both the native and MapKit tile paths.
    func data(z: Int, x: Int, y: Int) async -> Data? {
        if let data = disk.read(z: z, x: x, y: y) { return data }
        return await fetchFromNetwork(z: z, x: x, y: y)
    }

    /// Network fetch with the shared retry/backoff/limiter policy. On a 200 the
    /// bytes are written to the disk cache and returned; transient failures
    /// (network error, 5xx, 429) retry with backoff, everything else returns nil.
    private func fetchFromNetwork(z: Int, x: Int, y: Int) async -> Data? {
        let urlStr = Self.expandTemplate(urlTemplate, z: z, x: x, y: y,
                                         apiKey: apiKey,
                                         zoomIdentifiers: zoomIdentifiers,
                                         subdomains: subdomains)
        guard let url = URL(string: urlStr) else { return nil }

        // Exponential-backoff retry loop. Retries only on transient failures
        // (network errors, 5xx, 429). 4xx (except 429) are treated as permanent
        // — retrying an auth/quota/not-found error just wastes calls. Timeouts
        // are treated as permanent too: when they happen at scale they're a
        // backpressure signal, and retrying makes the pileup worse.
        let maxAttempts = 4  // initial + 3 retries: 250ms, 500ms, 1s worst case
        for attempt in 0..<maxAttempts {
            if Task.isCancelled { return nil }
            // Wait for a network slot. Only `capacity`-many hit the tile API at
            // a time; a tile flood queues here in the process instead of at the
            // socket layer or the server side.
            guard await limiter.acquire() else { return nil }
            let outcome: RequestOutcome
            do {
                let (data, resp) = try await session.data(from: url)
                outcome = .response(data: data, resp: resp)
            } catch is CancellationError {
                outcome = .cancelled
            } catch let e as URLError where e.code == .cancelled {
                outcome = .cancelled
            } catch let e as URLError where e.code == .timedOut {
                // Don't retry timeouts — the whole point is the queue is deep,
                // and retrying pushes new requests behind whatever else piled
                // up. Return nil, let MKit re-request when the tile comes back
                // into view.
                outcome = .fatal
            } catch {
                outcome = .transient
            }
            await limiter.release()

            var suggestedDelay: TimeInterval? = nil

            switch outcome {
            case .cancelled, .fatal:
                return nil
            case .response(let data, let resp):
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                // Even on success — surface the server's rate-limit headers to
                // the limiter so we back off before hitting a wall.
                await honourRateLimitHeaders(http)
                if status == 200 {
                    // Some WMTS servers return 200 with an XML ExceptionReport
                    // body. Caching that would poison the tile store permanently
                    // — only real image bytes go to disk. Not retried: the
                    // server answered; the answer just isn't a tile.
                    guard Self.looksLikeImage(data) else { return nil }
                    disk.write(z: z, x: x, y: y, data: data)
                    manifest.record(key: "\(z)/\(x)/\(y)",
                                    etag: http?.value(forHTTPHeaderField: "ETag"),
                                    lastModified: http?.value(forHTTPHeaderField: "Last-Modified"))
                    return data
                }
                // Terminal auth failure — the key is wrong/revoked/over quota,
                // and no amount of retrying fixes that. Surface it (once per
                // source per session) so the map can show a health banner.
                if status == 401 || status == 403 {
                    reportTerminalFailure(status: status)
                    return nil
                }
                let transient = status == 429 || (500..<600).contains(status)
                if !transient { return nil }
                // A 429 that survives every backoff retry is a quota problem,
                // not a blip — surface it like an auth failure.
                if status == 429 && attempt == maxAttempts - 1 {
                    reportTerminalFailure(status: 429)
                }
                // On 429/503 the server may have told us when to try again.
                suggestedDelay = retryAfter(from: http)
                fallthrough
            case .transient:
                break // retry below
            }

            if attempt < maxAttempts - 1 {
                let delaySec: Double
                if let s = suggestedDelay {
                    // Cap at 10s so a hostile Retry-After doesn't hang us.
                    delaySec = min(s, 10)
                } else {
                    let base = 0.25 * pow(2.0, Double(attempt)) // 0.25, 0.5, 1.0
                    let jitter = Double.random(in: 0.75...1.25)
                    delaySec = base * jitter
                }
                let ns = UInt64(delaySec * 1_000_000_000)
                do { try await Task.sleep(nanoseconds: ns) }
                catch { return nil }
            }
        }
        return nil
    }

    /// Forward a terminal failure to the session-wide health sink, when this
    /// fetcher knows which layer it serves.
    private func reportTerminalFailure(status: Int) {
        guard let healthSourceID else { return }
        TileLayerHealth.reportAuthFailure(sourceID: healthSourceID,
                                          name: healthSourceName ?? "Custom Layer",
                                          status: status)
    }

    // MARK: - Conditional refresh

    enum RefreshOutcome {
        case unchanged   // 304 — validator still current
        case updated     // 200 — tile changed, cache rewritten
        case missing     // 404/410 — server dropped it; cache entry removed
        case failed      // network error / non-image body / other status
    }

    /// Conditionally re-fetch one cached tile, sending its stored validators.
    /// An unchanged tile costs a 304 and no bandwidth — this is what makes a
    /// monthly offline-pack refresh affordable against an API quota. Callers
    /// doing a batch should `flushValidators()` at the end.
    func refreshTile(z: Int, x: Int, y: Int) async -> RefreshOutcome {
        let key = "\(z)/\(x)/\(y)"
        let urlStr = Self.expandTemplate(urlTemplate, z: z, x: x, y: y,
                                         apiKey: apiKey,
                                         zoomIdentifiers: zoomIdentifiers,
                                         subdomains: subdomains)
        guard let url = URL(string: urlStr) else { return .failed }
        var req = URLRequest(url: url)
        if let entry = manifest.entry(for: key) {
            if let etag = entry.etag {
                req.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = entry.lastModified {
                req.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        guard await limiter.acquire() else { return .failed }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
            await limiter.release()
        } catch {
            await limiter.release()
            return .failed
        }
        let http = resp as? HTTPURLResponse
        await honourRateLimitHeaders(http)

        switch http?.statusCode ?? 0 {
        case 304:
            manifest.markChecked(key: key)
            return .unchanged
        case 200 where Self.looksLikeImage(data):
            disk.write(z: z, x: x, y: y, data: data)
            manifest.record(key: key,
                            etag: http?.value(forHTTPHeaderField: "ETag"),
                            lastModified: http?.value(forHTTPHeaderField: "Last-Modified"))
            // Drop stale decoded copies so the next render picks up the new tile.
            memory.removeValue(forKey: key)
            imageMemory.removeValue(forKey: key)
            return .updated
        case 404, 410:
            disk.remove(z: z, x: x, y: y)
            manifest.remove(key: key)
            memory.removeValue(forKey: key)
            imageMemory.removeValue(forKey: key)
            return .missing
        default:
            return .failed
        }
    }

    /// Persist any batched manifest mutations (see `TileValidatorManifest.flush`).
    func flushValidators() {
        manifest.flush()
    }

    // MARK: - Response-header handling

    /// Parse a `Retry-After` header (integer seconds only — HTTP-date form is
    /// rare for API endpoints and we cap the delay anyway).
    private nonisolated func retryAfter(from http: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = http?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let secs = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return max(0, secs)
        }
        return nil
    }

    /// Read the server's `X-RateLimit-Remaining` header. If the remaining
    /// budget is running low, tell the FetchLimiter to throttle for a while.
    private func honourRateLimitHeaders(_ http: HTTPURLResponse?) async {
        guard let http else { return }
        // Header spelling varies across providers; check the common ones.
        let candidates = ["X-RateLimit-Remaining", "X-Rate-Limit-Remaining", "RateLimit-Remaining"]
        var remaining: Int?
        for k in candidates {
            if let v = http.value(forHTTPHeaderField: k), let n = Int(v) {
                remaining = n; break
            }
        }
        guard let remaining else { return }
        // Below ~20 remaining, drop the concurrency to a trickle for 30s.
        // Below ~5, an even harder brake.
        if remaining <= 5 {
            await limiter.throttle(to: 1, for: 30)
        } else if remaining <= 20 {
            await limiter.throttle(to: 2, for: 15)
        }
    }

    /// Expand a tile URL template. Shared by the fetch path and the settings
    /// editor's probe so both speak the same dialect:
    ///  * `{z}` `{x}` `{y}` — slippy-map coordinates ({z} becomes the WMTS
    ///    TileMatrix identifier when `zoomIdentifiers` is provided)
    ///  * `{-y}` — TMS flipped y (`2^z − 1 − y`); callers stay in XYZ convention
    ///  * `{s}` — subdomain, picked deterministically by `(x + y) % n` so
    ///    retries and cached entries always resolve the same host
    ///  * `{r}` — retina suffix (every current iOS display is 2×, so "@2x")
    ///  * `{apikey}` — the per-source key
    static func expandTemplate(_ template: String, z: Int, x: Int, y: Int,
                               apiKey: String = "",
                               zoomIdentifiers: [String]? = nil,
                               subdomains: [String] = [],
                               retinaToken: String = "@2x") -> String {
        let zToken: String
        if let ids = zoomIdentifiers, ids.indices.contains(z) {
            zToken = encodeMatrixIdentifier(ids[z])
        } else {
            zToken = String(z)
        }
        var s = template
            .replacingOccurrences(of: "{-y}", with: String((1 << z) - 1 - y))
            .replacingOccurrences(of: "{z}", with: zToken)
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y))
            .replacingOccurrences(of: "{apikey}", with: apiKey)
            .replacingOccurrences(of: "{r}", with: retinaToken)
        if !subdomains.isEmpty {
            s = s.replacingOccurrences(of: "{s}", with: subdomains[(x + y) % subdomains.count])
        }
        return s
    }

    /// True if the bytes carry a raster-image magic number (PNG/JPEG/GIF/WebP/
    /// TIFF). Guards the disk cache against non-tile 200 responses.
    static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }   // PNG
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }                 // JPEG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true }                 // GIF
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true } // WebP
        if b[0] == 0x49, b[1] == 0x49, b[2] == 0x2A { return true }                 // TIFF LE
        if b[0] == 0x4D, b[1] == 0x4D, b[2] == 0x2A { return true }                 // TIFF BE
        return false
    }

    /// Percent-encode a TileMatrix identifier for URL substitution. Encodes
    /// everything outside the RFC 3986 unreserved set, so identifiers like
    /// "EPSG:27700:5" are safe in both path and query positions.
    static func encodeMatrixIdentifier(_ identifier: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return identifier.addingPercentEncoding(withAllowedCharacters: unreserved) ?? identifier
    }

    private enum RequestOutcome {
        case response(data: Data, resp: URLResponse)
        case cancelled
        case fatal      // don't retry (timeout during pileup, unrecognised auth, etc.)
        case transient  // retry
    }

    private nonisolated func decode(_ data: Data) -> Bitmap? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBufferPointer { p in
            guard let ctx = CGContext(data: p.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Bitmap(bytes: bytes, width: w, height: h)
    }

    private nonisolated func decodeImage(_ data: Data) -> Image? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return Image(cg: cg, width: cg.width, height: cg.height)
    }

    private nonisolated func imageFromBitmap(_ bmp: Bitmap) -> Image? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        var bytes = bmp.bytes
        guard let ctx = bytes.withUnsafeMutableBufferPointer({ p -> CGContext? in
            CGContext(data: p.baseAddress,
                      width: bmp.width, height: bmp.height,
                      bitsPerComponent: 8,
                      bytesPerRow: bmp.width * 4,
                      space: cs,
                      bitmapInfo: bitmapInfo)
        }), let cg = ctx.makeImage() else { return nil }
        return Image(cg: cg, width: bmp.width, height: bmp.height)
    }

    private func insertMemory(key: String, bmp: Bitmap) {
        memory[key] = bmp
        order.append(key)
        if order.count > memoryLimit {
            let drop = order.removeFirst()
            memory.removeValue(forKey: drop)
            imageMemory.removeValue(forKey: drop)
        }
    }

    private func insertImageMemory(key: String, img: Image) {
        imageMemory[key] = img
        // Piggy-back on the LRU list so image entries evict alongside bitmaps.
        if memory[key] == nil {
            order.append(key)
            if order.count > memoryLimit {
                let drop = order.removeFirst()
                memory.removeValue(forKey: drop)
                imageMemory.removeValue(forKey: drop)
            }
        }
    }
}
