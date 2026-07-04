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

    /// True if the supportedCRS URN references EPSG:27700 (British National Grid).
    static func isEPSG27700(_ urn: String) -> Bool {
        urn.contains("27700")
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
        case .xmlParse(let m):      return "Couldn't read the capabilities document (\(m))."
        case .noCapabilities:       return "No layers advertised at this URL."
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

    private var tileMatrixSets: [WMTSCapabilities.TileMatrixSet] = []
    private var currentTMSIdent: String?
    private var currentTMSCRS: String?
    private var currentTMSMatrices: [WMTSCapabilities.TileMatrix] = []

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
        case "Layer":
            if let id = currentLayerIdent {
                layers.append(.init(
                    identifier: id, title: currentLayerTitle,
                    tileMatrixSetLinks: currentLayerLinks,
                    formats: currentLayerFormats))
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
