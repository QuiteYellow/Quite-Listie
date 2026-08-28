//
//  WMTSCapabilities.swift
//  QuiteListie
//
//  Fetches and parses a WMTS 1.0.0 GetCapabilities XML document from an OGC
//  Web Map Tile Service endpoint. Used to validate a user-supplied custom tile
//  source and auto-detect the tile matrix (origin, resolutions, zoom range,
//  CRS) so we don't have to hardcode any provider's specifics.
//
//  We only need a subset of WMTS: layers, tile matrix sets, supported CRS.
//  Advertised styles and dimensions are ignored.
//

import Foundation

struct WMTSCapabilities {
    struct Layer {
        let identifier: String
        let title: String?
        let tileMatrixSetLinks: [String] // matrix set identifiers this layer supports
        let formats: [String]
        let styles: [Style]
        let resourceURLs: [ResourceURL]
        /// The layer's declared extent, when it advertises one in EPSG:27700.
        /// This is the ground the service actually covers — unlike the tile
        /// matrix, whose MatrixWidth/Height are tile *counts* rounded up, so each
        /// zoom level overshoots by a different amount.
        var boundingBox: BoundingBox? = nil
    }
    /// An `ows:BoundingBox` in BNG metres.
    struct BoundingBox: Equatable {
        let eMin: Double, eMax: Double, nMin: Double, nMax: Double
    }
    struct Style {
        let identifier: String
        let isDefault: Bool
    }
    /// A RESTful access template advertised by the server, e.g.
    /// `https://…/{Style}/{TileMatrixSet}/{TileMatrix}/{TileRow}/{TileCol}.png`.
    struct ResourceURL {
        let resourceType: String  // "tile" is the one we use
        let format: String?
        let template: String
    }
    struct TileMatrix {
        let identifier: String            // usually the zoom level as a string
        let scaleDenominator: Double
        let topLeftCorner: (x: Double, y: Double)
        let tileWidth: Int
        let tileHeight: Int
        let matrixWidth: Int
        let matrixHeight: Int
    }
    struct TileMatrixSet {
        let identifier: String
        let supportedCRS: String  // e.g. "urn:ogc:def:crs:EPSG::27700"
        let matrices: [TileMatrix]
    }

    let layers: [Layer]
    let tileMatrixSets: [TileMatrixSet]

    /// Convenience: find the tile matrix set a layer uses. Layer identifiers
    /// often embed the projection (e.g. `<Name>_27700`), and the matrix set
    /// link matches.
    func matrixSet(for layer: Layer) -> TileMatrixSet? {
        for id in layer.tileMatrixSetLinks {
            if let m = tileMatrixSets.first(where: { $0.identifier == id }) {
                return m
            }
        }
        return nil
    }

    /// True if the supportedCRS references EPSG:27700 (British National Grid).
    static func isEPSG27700(_ crs: String) -> Bool {
        epsgCode(crs) == 27700
    }

    /// Scan-failure message for a working WMTS server that yielded no usable
    /// EPSG:27700 layer: says *why* (wrong projection) rather than the generic
    /// "nothing found", naming the projections the server does offer.
    var noBNGLayersMessage: String {
        let others = Set(tileMatrixSets.compactMap { Self.epsgCode($0.supportedCRS) })
            .subtracting([27700])
        guard !others.isEmpty else {
            return "No EPSG:27700 layers found at this endpoint."
        }
        let list = others.sorted().map { "EPSG:\($0)" }.joined(separator: ", ")
        let layerNoun = layers.count == 1 ? "its layer uses" : "its \(layers.count) layers use"
        return "This WMTS server works, but \(layerNoun) \(list) — nothing in EPSG:27700 (British National Grid)."
    }

    /// Extract the EPSG code from any of the forms servers use:
    /// `urn:ogc:def:crs:EPSG::27700`, `urn:ogc:def:crs:EPSG:6.18:27700`,
    /// `EPSG:27700`, `http://www.opengis.net/def/crs/EPSG/0/27700`.
    static func epsgCode(_ crs: String) -> Int? {
        guard crs.range(of: "EPSG", options: .caseInsensitive) != nil else { return nil }
        let parts = crs.split(whereSeparator: { $0 == ":" || $0 == "/" })
        guard let last = parts.last else { return nil }
        return Int(last)
    }
}

// MARK: - Tile URL construction

extension WMTSCapabilities {
    /// Build a `{z}/{x}/{y}` tile URL template for a layer, the standard way:
    /// prefer the RESTful `ResourceURL` template the server advertises, fall back
    /// to a KVP GetTile query. `{z}` is later replaced with the TileMatrix
    /// *identifier* for that zoom (not necessarily the numeric level) — see
    /// `TileFetcher.zoomIdentifiers`. The pasted endpoint's own query items
    /// (API keys etc.) are carried over, minus the capabilities-request params.
    static func tileTemplate(endpoint: String, layer: Layer, matrixSet: TileMatrixSet) -> String? {
        guard let comps = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.host != nil else { return nil }

        let style = layer.styles.first(where: \.isDefault)?.identifier
            ?? layer.styles.first?.identifier
            ?? "default"

        if let resource = layer.resourceURLs.first(where: { $0.resourceType == "tile" }) {
            var template = resource.template
            // WMTS placeholder names are defined capitalised, but be lenient.
            for (from, to) in [("{Style}", style),
                               ("{style}", style),
                               ("{TileMatrixSet}", matrixSet.identifier),
                               ("{tilematrixset}", matrixSet.identifier),
                               ("{TileMatrix}", "{z}"), ("{tilematrix}", "{z}"),
                               ("{TileRow}", "{y}"), ("{tilerow}", "{y}"),
                               ("{TileCol}", "{x}"), ("{tilecol}", "{x}")] {
                template = template.replacingOccurrences(of: from, with: to)
            }
            guard template.contains("{z}"), template.contains("{x}"), template.contains("{y}") else {
                return nil
            }
            return mergingEndpointQuery(from: comps, into: template)
        }

        // KVP GetTile fallback. Built by string so the {z}/{y}/{x} placeholders
        // stay literal — URLComponents would percent-encode the braces and the
        // fetcher's substitution would never find them.
        var base = comps
        base.query = nil
        base.fragment = nil
        guard let baseURL = base.url?.absoluteString else { return nil }
        var pairs = carriedQueryPairs(from: comps)
        let format = layer.formats.first { $0.lowercased().contains("png") }
            ?? layer.formats.first
            ?? "image/png"
        pairs += [("service", "WMTS"),
                  ("version", "1.0.0"),
                  ("request", "GetTile"),
                  ("layer", encodeQueryValue(layer.identifier)),
                  ("style", encodeQueryValue(style)),
                  ("tilematrixset", encodeQueryValue(matrixSet.identifier)),
                  ("format", encodeQueryValue(format)),
                  ("TileMatrix", "{z}"),
                  ("TileRow", "{y}"),
                  ("TileCol", "{x}")]
        return baseURL + "?" + pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// Append the endpoint's query items to a ResourceURL template, using `&`
    /// when the template already has a query and skipping any parameter name the
    /// template already carries (some servers bake the key into the template).
    private static func mergingEndpointQuery(from endpoint: URLComponents, into template: String) -> String {
        let pairs = carriedQueryPairs(from: endpoint)
        guard !pairs.isEmpty else { return template }
        var existing: Set<String> = []
        if let q = template.firstIndex(of: "?") {
            existing = Set(template[template.index(after: q)...]
                .split(separator: "&")
                .compactMap { $0.split(separator: "=").first.map { $0.lowercased() } })
        }
        var out = template
        for (name, value) in pairs where !existing.contains(name.lowercased()) {
            out += (out.contains("?") ? "&" : "?") + "\(name)=\(value)"
        }
        return out
    }

    /// The endpoint's query pairs worth carrying onto tile requests (auth keys
    /// and the like), minus the capabilities-request parameters. Percent-encoded
    /// form, preserving the original encoding.
    private static func carriedQueryPairs(from comps: URLComponents) -> [(String, String)] {
        (comps.percentEncodedQueryItems ?? []).compactMap { item in
            let name = item.name.lowercased()
            guard !["service", "request", "version"].contains(name) else { return nil }
            return (item.name, item.value ?? "")
        }
    }

    private static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum WMTSError: Error, LocalizedError {
    case badURL
    case http(status: Int, body: String)
    case xmlParse(String)
    case noCapabilities
    case network(URLError)

    var errorDescription: String? {
        switch self {
        case .badURL:               return "Couldn't build the WMTS URL."
        case .http(let s, let b):
            let snippet = b.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
            return "Server returned HTTP \(s). \(snippet)"
        case .xmlParse(let m):      return "This doesn't look like a WMTS endpoint — couldn't read a capabilities document (\(m))."
        case .noCapabilities:       return "The WMTS server responded but advertises no layers."
        case .network(let e):       return "Network error: \(e.localizedDescription)"
        }
    }
}

enum WMTSCapabilitiesLoader {
    /// Fetch the WMTS GetCapabilities from the user-pasted WMTS endpoint (which
    /// already carries the API key as `?key=…`). We only add the standard
    /// `service`/`request` query items if they're missing.
    static func discover(fromWMTSEndpoint endpoint: String) async throws -> WMTSCapabilities {
        guard var comps = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw WMTSError.badURL
        }
        var items = comps.queryItems ?? []
        func ensure(_ name: String, _ value: String) {
            if !items.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                items.append(URLQueryItem(name: name, value: value))
            }
        }
        ensure("service", "WMTS")
        ensure("request", "GetCapabilities")
        comps.queryItems = items
        guard let url = comps.url else { throw WMTSError.badURL }

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        let session = URLSession(configuration: cfg)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(from: url)
        } catch let e as URLError {
            throw WMTSError.network(e)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw WMTSError.http(status: status, body: body)
        }
        return try parse(data)
    }

    /// Parse a capabilities document. Split from `discover` so tests can feed
    /// fixture XML without a network round-trip.
    static func parse(_ data: Data) throws -> WMTSCapabilities {
        let parser = WMTSXMLDelegate()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = true
        if !xml.parse() {
            let msg = parser.error ?? xml.parserError?.localizedDescription ?? "unknown"
            throw WMTSError.xmlParse(msg)
        }
        let caps = parser.build()
        if caps.layers.isEmpty { throw WMTSError.noCapabilities }
        return caps
    }
}

// MARK: - SAX-style parser
//
// WMTS 1.0.0 uses the WMTS and OWS 1.1 namespaces heavily. We're lenient about
// namespace prefixes — everything is matched on the localName only.

private final class WMTSXMLDelegate: NSObject, XMLParserDelegate {
    var error: String?

    private var elementPath: [String] = []
    private var textAccum: String = ""

    private var layers: [WMTSCapabilities.Layer] = []
    private var currentLayerIdent: String?
    private var currentLayerTitle: String?
    private var currentLayerLinks: [String] = []
    private var currentLayerFormats: [String] = []
    private var currentLayerStyles: [WMTSCapabilities.Style] = []
    private var currentLayerResourceURLs: [WMTSCapabilities.ResourceURL] = []
    private var currentStyleIsDefault = false
    private var currentStyleIdent: String?

    private var tileMatrixSets: [WMTSCapabilities.TileMatrixSet] = []
    private var currentTMSIdent: String?
    private var currentTMSCRS: String?
    private var currentTMSMatrices: [WMTSCapabilities.TileMatrix] = []

    private var currentLayerBBox: WMTSCapabilities.BoundingBox?
    private var currentBBoxCRS: String?
    private var currentBBoxLower: (Double, Double)?
    private var currentBBoxUpper: (Double, Double)?

    private var currentTMIdent: String?
    private var currentTMScaleDen: Double?
    private var currentTMTopLeft: (Double, Double)?
    private var currentTMTileWidth: Int?
    private var currentTMTileHeight: Int?
    private var currentTMMatrixWidth: Int?
    private var currentTMMatrixHeight: Int?

    func build() -> WMTSCapabilities {
        WMTSCapabilities(layers: layers, tileMatrixSets: tileMatrixSets)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let local = localName(elementName)
        elementPath.append(local)
        textAccum = ""

        switch local {
        case "Layer":
            currentLayerIdent = nil
            currentLayerTitle = nil
            currentLayerLinks = []
            currentLayerFormats = []
            currentLayerStyles = []
            currentLayerResourceURLs = []
            currentLayerBBox = nil
        case "BoundingBox" where elementPath.count >= 2
                             && elementPath[elementPath.count - 2] == "Layer":
            // A layer may advertise several, one per CRS; only 27700 is ours.
            currentBBoxCRS = attributeDict["crs"]
            currentBBoxLower = nil
            currentBBoxUpper = nil
        case "Style":
            currentStyleIsDefault = (attributeDict["isDefault"] as NSString?)?.boolValue ?? false
            currentStyleIdent = nil
        case "ResourceURL":
            // Empty element carried entirely in attributes.
            if elementPath.count >= 2, elementPath[elementPath.count - 2] == "Layer",
               let type = attributeDict["resourceType"],
               let template = attributeDict["template"] {
                currentLayerResourceURLs.append(.init(
                    resourceType: type,
                    format: attributeDict["format"],
                    template: template))
            }
        case "TileMatrixSet" where isDirectChildOfContents():
            currentTMSIdent = nil
            currentTMSCRS = nil
            currentTMSMatrices = []
        case "TileMatrix":
            currentTMIdent = nil
            currentTMScaleDen = nil
            currentTMTopLeft = nil
            currentTMTileWidth = nil
            currentTMTileHeight = nil
            currentTMMatrixWidth = nil
            currentTMMatrixHeight = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textAccum += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        defer { elementPath.removeLast(); textAccum = "" }
        let local = localName(elementName)
        let text = textAccum.trimmingCharacters(in: .whitespacesAndNewlines)

        // Layer children — differentiate by parent
        if elementPath.count >= 2 && elementPath[elementPath.count - 2] == "Layer" {
            switch local {
            case "Identifier":  currentLayerIdent = text
            case "Title":       currentLayerTitle = text
            case "Format":      currentLayerFormats.append(text)
            default: break
            }
        }
        // BoundingBox corners (Layer/BoundingBox/{Lower,Upper}Corner)
        if elementPath.count >= 2 && elementPath[elementPath.count - 2] == "BoundingBox" {
            let parts = text.split(separator: " ").compactMap { Double($0) }
            if parts.count == 2 {
                if local == "LowerCorner" { currentBBoxLower = (parts[0], parts[1]) }
                if local == "UpperCorner" { currentBBoxUpper = (parts[0], parts[1]) }
            }
        }

        // Style children (Layer/Style/Identifier)
        if elementPath.count >= 2 && elementPath[elementPath.count - 2] == "Style",
           local == "Identifier" {
            currentStyleIdent = text
        }
        // TileMatrixSetLink → TileMatrixSet reference
        if elementPath.count >= 3 &&
           elementPath[elementPath.count - 2] == "TileMatrixSetLink" &&
           local == "TileMatrixSet" {
            currentLayerLinks.append(text)
        }

        // TileMatrixSet children (only when we're inside Contents/TileMatrixSet
        // and not inside the Layer/…/TileMatrixSetLink one)
        if isInsideContentsMatrixSet() {
            switch local {
            case "Identifier" where elementPath.count >= 2 &&
                                    elementPath[elementPath.count - 2] == "TileMatrixSet":
                currentTMSIdent = text
            case "SupportedCRS":
                currentTMSCRS = text
            default: break
            }
        }

        // TileMatrix children
        if elementPath.count >= 2 && elementPath[elementPath.count - 2] == "TileMatrix" {
            switch local {
            case "Identifier":
                currentTMIdent = text
            case "ScaleDenominator":
                currentTMScaleDen = Double(text)
            case "TopLeftCorner":
                let parts = text.split(separator: " ").compactMap { Double($0) }
                if parts.count == 2 { currentTMTopLeft = (parts[0], parts[1]) }
            case "TileWidth":     currentTMTileWidth = Int(text)
            case "TileHeight":    currentTMTileHeight = Int(text)
            case "MatrixWidth":   currentTMMatrixWidth = Int(text)
            case "MatrixHeight":  currentTMMatrixHeight = Int(text)
            default: break
            }
        }

        // Element-close finalisation
        switch local {
        case "BoundingBox" where elementPath.count >= 2
                             && elementPath[elementPath.count - 2] == "Layer":
            if let crs = currentBBoxCRS, WMTSCapabilities.isEPSG27700(crs),
               let lo = currentBBoxLower, let hi = currentBBoxUpper {
                currentLayerBBox = .init(eMin: min(lo.0, hi.0), eMax: max(lo.0, hi.0),
                                         nMin: min(lo.1, hi.1), nMax: max(lo.1, hi.1))
            }
            currentBBoxCRS = nil
            currentBBoxLower = nil
            currentBBoxUpper = nil
        case "TileMatrix":
            if let id = currentTMIdent, let s = currentTMScaleDen,
               let tl = currentTMTopLeft,
               let tw = currentTMTileWidth, let th = currentTMTileHeight,
               let mw = currentTMMatrixWidth, let mh = currentTMMatrixHeight {
                currentTMSMatrices.append(.init(
                    identifier: id, scaleDenominator: s,
                    topLeftCorner: tl, tileWidth: tw, tileHeight: th,
                    matrixWidth: mw, matrixHeight: mh))
            }
        case "TileMatrixSet" where isDirectChildOfContents(includingSelf: true):
            if let id = currentTMSIdent, let crs = currentTMSCRS {
                tileMatrixSets.append(.init(
                    identifier: id, supportedCRS: crs, matrices: currentTMSMatrices))
            }
        case "Style":
            if let id = currentStyleIdent, elementPath.count >= 2,
               elementPath[elementPath.count - 2] == "Layer" {
                currentLayerStyles.append(.init(identifier: id, isDefault: currentStyleIsDefault))
            }
            currentStyleIdent = nil
        case "Layer":
            if let id = currentLayerIdent {
                layers.append(.init(
                    identifier: id, title: currentLayerTitle,
                    tileMatrixSetLinks: currentLayerLinks,
                    formats: currentLayerFormats,
                    styles: currentLayerStyles,
                    resourceURLs: currentLayerResourceURLs,
                    boundingBox: currentLayerBBox))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError.localizedDescription
    }

    // MARK: - Utilities

    /// Strip a possible namespace prefix, e.g. `wmts:Layer` → `Layer`.
    private func localName(_ elementName: String) -> String {
        if let colon = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: colon)...])
        }
        return elementName
    }

    /// True when we're currently sitting under `Contents/TileMatrixSet` (the
    /// definition of a matrix set), not the `Layer/…/TileMatrixSetLink/TileMatrixSet`
    /// reference to one.
    private func isInsideContentsMatrixSet() -> Bool {
        guard let contentsIdx = elementPath.firstIndex(of: "Contents") else { return false }
        // Direct child of Contents must be TileMatrixSet — not a Layer subtree.
        guard contentsIdx + 1 < elementPath.count,
              elementPath[contentsIdx + 1] == "TileMatrixSet" else { return false }
        return true
    }

    private func isDirectChildOfContents(includingSelf: Bool = false) -> Bool {
        let path = includingSelf ? elementPath : elementPath.dropLast()
        if path.count >= 2 && path[path.count - 2] == "Contents" {
            return true
        }
        return false
    }
}
