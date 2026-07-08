//
//  TileLayerTests.swift
//  QuiteListieTests
//
//  Custom tile layer stack: WMTS capabilities parsing (ResourceURL, styles,
//  matrix identifiers), provider-agnostic tile-URL construction, EPSG code
//  parsing, tile-cache poisoning guards, and the v3 → v4 source migration.
//

import XCTest
import MapKit
@testable import QuiteListie

// MARK: - Fixtures

/// OS-Maps-API-shaped capabilities: RESTful ResourceURL, numeric matrix
/// identifiers, shared origin across zooms.
private let osStyleXML = """
<?xml version="1.0" encoding="UTF-8"?>
<Capabilities xmlns="http://www.opengis.net/wmts/1.0" xmlns:ows="http://www.opengis.net/ows/1.1" version="1.0.0">
  <Contents>
    <Layer>
      <ows:Identifier>Outdoor_27700</ows:Identifier>
      <ows:Title>OS Outdoor</ows:Title>
      <Style isDefault="true"><ows:Identifier>true-colour</ows:Identifier></Style>
      <Format>image/png</Format>
      <TileMatrixSetLink><TileMatrixSet>27700</TileMatrixSet></TileMatrixSetLink>
      <ResourceURL format="image/png" resourceType="tile" template="https://api.example.co/maps/raster/v1/tiles/Outdoor_27700/{Style}/{TileMatrix}/{TileCol}/{TileRow}.png"/>
    </Layer>
    <TileMatrixSet>
      <ows:Identifier>27700</ows:Identifier>
      <ows:SupportedCRS>urn:ogc:def:crs:EPSG::27700</ows:SupportedCRS>
      <TileMatrix>
        <ows:Identifier>0</ows:Identifier>
        <ScaleDenominator>3200000</ScaleDenominator>
        <TopLeftCorner>-238375.0 1376256.0</TopLeftCorner>
        <TileWidth>256</TileWidth><TileHeight>256</TileHeight>
        <MatrixWidth>5</MatrixWidth><MatrixHeight>7</MatrixHeight>
      </TileMatrix>
      <TileMatrix>
        <ows:Identifier>1</ows:Identifier>
        <ScaleDenominator>1600000</ScaleDenominator>
        <TopLeftCorner>-238375.0 1376256.0</TopLeftCorner>
        <TileWidth>256</TileWidth><TileHeight>256</TileHeight>
        <MatrixWidth>9</MatrixWidth><MatrixHeight>13</MatrixHeight>
      </TileMatrix>
    </TileMatrixSet>
  </Contents>
</Capabilities>
"""

/// GeoServer-shaped capabilities: no ResourceURL (KVP only), namespaced
/// "EPSG:27700:N" matrix identifiers, matrices listed finest-first to prove
/// sorting isn't relying on document order.
private let geoServerStyleXML = """
<?xml version="1.0" encoding="UTF-8"?>
<Capabilities xmlns="http://www.opengis.net/wmts/1.0" xmlns:ows="http://www.opengis.net/ows/1.1" version="1.0.0">
  <Contents>
    <Layer>
      <ows:Identifier>historic:six-inch</ows:Identifier>
      <ows:Title>Six Inch Historic</ows:Title>
      <Style><ows:Identifier>raster</ows:Identifier></Style>
      <Format>image/jpeg</Format>
      <Format>image/png</Format>
      <TileMatrixSetLink><TileMatrixSet>EPSG:27700</TileMatrixSet></TileMatrixSetLink>
    </Layer>
    <TileMatrixSet>
      <ows:Identifier>EPSG:27700</ows:Identifier>
      <ows:SupportedCRS>urn:ogc:def:crs:EPSG::27700</ows:SupportedCRS>
      <TileMatrix>
        <ows:Identifier>EPSG:27700:1</ows:Identifier>
        <ScaleDenominator>1600000</ScaleDenominator>
        <TopLeftCorner>-100000.0 1300000.0</TopLeftCorner>
        <TileWidth>256</TileWidth><TileHeight>256</TileHeight>
        <MatrixWidth>9</MatrixWidth><MatrixHeight>13</MatrixHeight>
      </TileMatrix>
      <TileMatrix>
        <ows:Identifier>EPSG:27700:0</ows:Identifier>
        <ScaleDenominator>3200000</ScaleDenominator>
        <TopLeftCorner>-238375.0 1376256.0</TopLeftCorner>
        <TileWidth>256</TileWidth><TileHeight>256</TileHeight>
        <MatrixWidth>5</MatrixWidth><MatrixHeight>7</MatrixHeight>
      </TileMatrix>
    </TileMatrixSet>
  </Contents>
</Capabilities>
"""

/// A working WMTS server whose only layer is web-mercator — for the scan
/// message that explains *why* nothing was found.
private let mercatorOnlyXML = """
<?xml version="1.0" encoding="UTF-8"?>
<Capabilities xmlns="http://www.opengis.net/wmts/1.0" xmlns:ows="http://www.opengis.net/ows/1.1" version="1.0.0">
  <Contents>
    <Layer>
      <ows:Identifier>world</ows:Identifier>
      <ows:Title>World</ows:Title>
      <Style isDefault="true"><ows:Identifier>default</ows:Identifier></Style>
      <Format>image/png</Format>
      <TileMatrixSetLink><TileMatrixSet>GoogleMapsCompatible</TileMatrixSet></TileMatrixSetLink>
    </Layer>
    <TileMatrixSet>
      <ows:Identifier>GoogleMapsCompatible</ows:Identifier>
      <ows:SupportedCRS>urn:ogc:def:crs:EPSG::3857</ows:SupportedCRS>
      <TileMatrix>
        <ows:Identifier>0</ows:Identifier>
        <ScaleDenominator>559082264</ScaleDenominator>
        <TopLeftCorner>-20037508.34 20037508.34</TopLeftCorner>
        <TileWidth>256</TileWidth><TileHeight>256</TileHeight>
        <MatrixWidth>1</MatrixWidth><MatrixHeight>1</MatrixHeight>
      </TileMatrix>
    </TileMatrixSet>
  </Contents>
</Capabilities>
"""

/// MapProxy/NLS-shaped capabilities: RESTful ResourceURL, zero-padded matrix
/// identifiers ("00", "01"), and a TopLeftCorner that *differs per level* —
/// the case the per-zoom origin support exists for.
private let mapProxyStyleXML = """
<?xml version="1.0" encoding="UTF-8"?>
<Capabilities xmlns="http://www.opengis.net/wmts/1.0" xmlns:ows="http://www.opengis.net/ows/1.1" version="1.0.0">
  <Contents>
    <Layer>
      <ows:Identifier>gb_historic</ows:Identifier>
      <ows:Title>GB Historic</ows:Title>
      <Style><ows:Identifier>default</ows:Identifier></Style>
      <Format>image/png</Format>
      <TileMatrixSetLink><TileMatrixSet>bng_grid</TileMatrixSet></TileMatrixSetLink>
      <ResourceURL format="image/png" resourceType="tile" template="https://maps.example.org/wmts/gb_historic/bng_grid/{TileMatrix}/{TileCol}/{TileRow}.png"/>
    </Layer>
    <TileMatrixSet>
      <ows:Identifier>bng_grid</ows:Identifier>
      <ows:SupportedCRS>EPSG:27700</ows:SupportedCRS>
      <TileMatrix>
        <ows:Identifier>01</ows:Identifier>
        <ScaleDenominator>1600000</ScaleDenominator>
        <TopLeftCorner>-100000.0 1300000.0</TopLeftCorner>
        <TileWidth>256</TileWidth><TileHeight>256</TileHeight>
        <MatrixWidth>9</MatrixWidth><MatrixHeight>13</MatrixHeight>
      </TileMatrix>
      <TileMatrix>
        <ows:Identifier>00</ows:Identifier>
        <ScaleDenominator>3200000</ScaleDenominator>
        <TopLeftCorner>-238375.0 1376256.0</TopLeftCorner>
        <TileWidth>256</TileWidth><TileHeight>256</TileHeight>
        <MatrixWidth>5</MatrixWidth><MatrixHeight>7</MatrixHeight>
      </TileMatrix>
    </TileMatrixSet>
  </Contents>
</Capabilities>
"""

// MARK: - Capabilities parsing

final class WMTSCapabilitiesParsingTests: XCTestCase {

    func testParsesResourceURLAndStyle() throws {
        let caps = try WMTSCapabilitiesLoader.parse(Data(osStyleXML.utf8))
        XCTAssertEqual(caps.layers.count, 1)
        let layer = try XCTUnwrap(caps.layers.first)
        XCTAssertEqual(layer.identifier, "Outdoor_27700")
        XCTAssertEqual(layer.styles.count, 1)
        XCTAssertEqual(layer.styles.first?.identifier, "true-colour")
        XCTAssertEqual(layer.styles.first?.isDefault, true)
        XCTAssertEqual(layer.resourceURLs.count, 1)
        XCTAssertEqual(layer.resourceURLs.first?.resourceType, "tile")
        XCTAssertTrue(layer.resourceURLs.first?.template.contains("{TileMatrix}") ?? false)
    }

    func testParsesMatrixSetDetails() throws {
        let caps = try WMTSCapabilitiesLoader.parse(Data(geoServerStyleXML.utf8))
        let layer = try XCTUnwrap(caps.layers.first)
        let set = try XCTUnwrap(caps.matrixSet(for: layer))
        XCTAssertEqual(set.identifier, "EPSG:27700")
        XCTAssertTrue(WMTSCapabilities.isEPSG27700(set.supportedCRS))
        XCTAssertEqual(set.matrices.count, 2)
    }

    func testEPSGCodeParsing() {
        XCTAssertEqual(WMTSCapabilities.epsgCode("urn:ogc:def:crs:EPSG::27700"), 27700)
        XCTAssertEqual(WMTSCapabilities.epsgCode("urn:ogc:def:crs:EPSG:6.18:27700"), 27700)
        XCTAssertEqual(WMTSCapabilities.epsgCode("EPSG:27700"), 27700)
        XCTAssertEqual(WMTSCapabilities.epsgCode("http://www.opengis.net/def/crs/EPSG/0/27700"), 27700)
        XCTAssertEqual(WMTSCapabilities.epsgCode("urn:ogc:def:crs:EPSG::3857"), 3857)
        XCTAssertNil(WMTSCapabilities.epsgCode("CRS:84"))
        XCTAssertFalse(WMTSCapabilities.isEPSG27700("urn:ogc:def:crs:EPSG::3857"))
        // The old contains("27700") check would have matched this matrix-set-y string.
        XCTAssertFalse(WMTSCapabilities.isEPSG27700("urn:ogc:def:crs:EPSG:27700:3857"))
    }

    func testNoBNGLayersMessageNamesTheOfferedProjections() throws {
        let caps = try WMTSCapabilitiesLoader.parse(Data(mercatorOnlyXML.utf8))
        let message = caps.noBNGLayersMessage
        XCTAssertTrue(message.contains("EPSG:3857"))
        XCTAssertTrue(message.contains("EPSG:27700"))
        // A server offering nothing recognisable gets the plain message.
        let bare = WMTSCapabilities(layers: [], tileMatrixSets: [])
        XCTAssertEqual(bare.noBNGLayersMessage, "No EPSG:27700 layers found at this endpoint.")
    }

    func testXMLParseErrorSaysNotAWMTSEndpoint() {
        let desc = WMTSError.xmlParse("line 1").errorDescription ?? ""
        XCTAssertTrue(desc.contains("doesn't look like a WMTS endpoint"))
    }

    func testMapProxyStyleFixtureParsesPerZoomOriginsAndPaddedIdentifiers() throws {
        let caps = try WMTSCapabilitiesLoader.parse(Data(mapProxyStyleXML.utf8))
        let layer = try XCTUnwrap(caps.layers.first)
        let set = try XCTUnwrap(caps.matrixSet(for: layer))
        XCTAssertTrue(WMTSCapabilities.isEPSG27700(set.supportedCRS))
        // Zero-padded identifiers, coarsest-first regardless of document order.
        XCTAssertEqual(BNGTileMatrix.sortedMatrices(set).map(\.identifier), ["00", "01"])
        let matrix = try XCTUnwrap(BNGTileMatrix.fromCapabilities(set))
        // Origins genuinely differ per level — the case per-zoom support exists for.
        XCTAssertEqual(matrix.originsX, [-238375.0, -100000.0])
        XCTAssertEqual(matrix.originsY, [1376256.0, 1300000.0])
        // ResourceURL template becomes a working {z}/{x}/{y} template with the
        // endpoint's key carried over.
        let template = try XCTUnwrap(WMTSCapabilities.tileTemplate(
            endpoint: "https://maps.example.org/wmts?key=K", layer: layer, matrixSet: set))
        XCTAssertEqual(template,
            "https://maps.example.org/wmts/gb_historic/bng_grid/{z}/{x}/{y}.png?key=K")
        // Padded identifiers substitute verbatim for {z}.
        XCTAssertEqual(
            TileFetcher.expandTemplate(template, z: 1, x: 3, y: 2,
                                       zoomIdentifiers: matrix.resolutions.indices.map { String(format: "%02d", $0) }),
            "https://maps.example.org/wmts/gb_historic/bng_grid/01/3/2.png?key=K")
    }
}

// MARK: - Tile URL construction

final class WMTSTileTemplateTests: XCTestCase {

    private func osLayerAndSet() throws -> (WMTSCapabilities.Layer, WMTSCapabilities.TileMatrixSet) {
        let caps = try WMTSCapabilitiesLoader.parse(Data(osStyleXML.utf8))
        let layer = try XCTUnwrap(caps.layers.first)
        let set = try XCTUnwrap(caps.matrixSet(for: layer))
        return (layer, set)
    }

    func testResourceURLPreferredWithQueryCarryOver() throws {
        let (layer, set) = try osLayerAndSet()
        let endpoint = "https://api.example.co/maps/raster/v1/wmts?key=SECRET&service=WMTS&request=GetCapabilities"
        let template = WMTSCapabilities.tileTemplate(endpoint: endpoint, layer: layer, matrixSet: set)
        XCTAssertEqual(template,
            "https://api.example.co/maps/raster/v1/tiles/Outdoor_27700/true-colour/{z}/{x}/{y}.png?key=SECRET")
    }

    func testResourceURLSkipsParamsAlreadyInTemplate() {
        let layer = WMTSCapabilities.Layer(
            identifier: "L", title: nil, tileMatrixSetLinks: ["S"], formats: ["image/png"],
            styles: [.init(identifier: "default", isDefault: true)],
            resourceURLs: [.init(resourceType: "tile", format: "image/png",
                                 template: "https://t.example/{TileMatrix}/{TileCol}/{TileRow}.png?key=EMBEDDED")])
        let set = WMTSCapabilities.TileMatrixSet(identifier: "S",
                                                 supportedCRS: "EPSG:27700", matrices: [])
        let template = WMTSCapabilities.tileTemplate(
            endpoint: "https://t.example/wmts?key=PASTED", layer: layer, matrixSet: set)
        XCTAssertEqual(template, "https://t.example/{z}/{x}/{y}.png?key=EMBEDDED")
    }

    func testKVPFallbackWhenNoResourceURL() throws {
        let caps = try WMTSCapabilitiesLoader.parse(Data(geoServerStyleXML.utf8))
        let layer = try XCTUnwrap(caps.layers.first)
        let set = try XCTUnwrap(caps.matrixSet(for: layer))
        let endpoint = "https://gs.example/geoserver/gwc/service/wmts?key=SECRET&request=GetCapabilities"
        let template = try XCTUnwrap(WMTSCapabilities.tileTemplate(
            endpoint: endpoint, layer: layer, matrixSet: set))
        XCTAssertTrue(template.hasPrefix("https://gs.example/geoserver/gwc/service/wmts?"))
        XCTAssertTrue(template.contains("key=SECRET"))
        XCTAssertTrue(template.contains("service=WMTS"))
        XCTAssertTrue(template.contains("request=GetTile"))
        XCTAssertTrue(template.contains("layer=historic:six-inch"))
        XCTAssertTrue(template.contains("style=raster"))
        XCTAssertTrue(template.contains("tilematrixset=EPSG:27700"))
        XCTAssertTrue(template.contains("format=image/png"))  // png preferred over jpeg
        XCTAssertTrue(template.contains("TileMatrix={z}"))
        XCTAssertTrue(template.contains("TileRow={y}"))
        XCTAssertTrue(template.contains("TileCol={x}"))
        // The capabilities-request param must not leak onto tile requests.
        XCTAssertFalse(template.contains("request=GetCapabilities"))
    }

    func testMatrixIdentifierEncoding() {
        XCTAssertEqual(TileFetcher.encodeMatrixIdentifier("EPSG:27700:5"), "EPSG%3A27700%3A5")
        XCTAssertEqual(TileFetcher.encodeMatrixIdentifier("5"), "5")
    }
}

// MARK: - Tile matrix

final class BNGTileMatrixTests: XCTestCase {

    func testFromCapabilitiesSortsAndKeepsPerZoomData() throws {
        let caps = try WMTSCapabilitiesLoader.parse(Data(geoServerStyleXML.utf8))
        let set = try XCTUnwrap(caps.tileMatrixSets.first)
        let matrix = try XCTUnwrap(BNGTileMatrix.fromCapabilities(set))
        // Document order was finest-first; the matrix must be coarsest-first.
        XCTAssertEqual(matrix.resolutions, [3200000 * 0.00028, 1600000 * 0.00028])
        XCTAssertEqual(matrix.originsX, [-238375.0, -100000.0])
        XCTAssertEqual(matrix.originsY, [1376256.0, 1300000.0])
        XCTAssertEqual(matrix.matrixWidths, [5, 9])
        XCTAssertEqual(matrix.matrixHeights, [7, 13])
        XCTAssertEqual(matrix.columns(at: 1), 9)
        XCTAssertEqual(matrix.rows(at: 0), 7)
        // Identifier order must match: coarsest zoom 0 is "EPSG:27700:0".
        XCTAssertEqual(BNGTileMatrix.sortedMatrices(set).map(\.identifier),
                       ["EPSG:27700:0", "EPSG:27700:1"])
    }

    func testV3RecordFallsBackToSharedOriginUnboundedGrid() {
        // A v3-era record has only the scalar origin and no identifiers/bounds.
        let v3 = CustomTileSource.ValidatedCapabilities(
            layerIdentifier: "L", layerTitle: nil,
            tileMatrixSetIdentifier: "S", supportedCRS: "EPSG:27700",
            originX: -238375, originY: 1376256, tileSize: 256,
            resolutions: [896, 448, 224])
        let matrix = v3.matrix
        XCTAssertEqual(matrix.originX(at: 2), -238375)
        XCTAssertEqual(matrix.originY(at: 2), 1376256)
        XCTAssertNil(matrix.columns(at: 1))
        XCTAssertNil(matrix.rows(at: 1))
        XCTAssertEqual(matrix.maxZoom, 2)
    }
}

// MARK: - Template expansion (XYZ dialect)

final class TemplateExpansionTests: XCTestCase {

    func testPlainXYZ() {
        XCTAssertEqual(
            TileFetcher.expandTemplate("https://t.example/{z}/{x}/{y}.png", z: 3, x: 2, y: 1),
            "https://t.example/3/2/1.png")
    }

    func testTMSFlippedY() {
        // {-y} = 2^z − 1 − y → at z3, y1 → 6. {y} must not match inside {-y}.
        XCTAssertEqual(
            TileFetcher.expandTemplate("https://t.example/{z}/{x}/{-y}.png", z: 3, x: 2, y: 1),
            "https://t.example/3/2/6.png")
    }

    func testSubdomainPickIsDeterministicPerTile() {
        let subs = ["a", "b", "c"]
        let template = "https://{s}.t.example/{z}/{x}/{y}.png"
        let first = TileFetcher.expandTemplate(template, z: 1, x: 2, y: 3, subdomains: subs)
        let again = TileFetcher.expandTemplate(template, z: 1, x: 2, y: 3, subdomains: subs)
        XCTAssertEqual(first, again)
        XCTAssertEqual(first, "https://c.t.example/1/2/3.png")  // (2+3) % 3 = 2 → "c"
        // Neighbouring tile rotates to a different host.
        XCTAssertEqual(
            TileFetcher.expandTemplate(template, z: 1, x: 3, y: 3, subdomains: subs),
            "https://a.t.example/1/3/3.png")                     // (3+3) % 3 = 0 → "a"
    }

    func testApiKeyAndRetina() {
        XCTAssertEqual(
            TileFetcher.expandTemplate("https://t.example/{z}/{x}/{y}{r}.png?key={apikey}",
                                       z: 0, x: 0, y: 0, apiKey: "K123"),
            "https://t.example/0/0/0@2x.png?key=K123")
    }

    func testZoomIdentifierSubstitution() {
        XCTAssertEqual(
            TileFetcher.expandTemplate("https://t.example/{z}/{x}/{y}.png", z: 1, x: 4, y: 5,
                                       zoomIdentifiers: ["EPSG:27700:0", "EPSG:27700:1"]),
            "https://t.example/EPSG%3A27700%3A1/4/5.png")
        // Out-of-range zoom falls back to the numeric level.
        XCTAssertEqual(
            TileFetcher.expandTemplate("https://t.example/{z}/{x}/{y}.png", z: 9, x: 4, y: 5,
                                       zoomIdentifiers: ["EPSG:27700:0"]),
            "https://t.example/9/4/5.png")
    }
}

// MARK: - Key hygiene (Phase 3)

final class TileURLKeysTests: XCTestCase {

    func testStrippingDropsAuthParamsKeepsTheRest() {
        XCTAssertEqual(
            TileURLKeys.strippingAuthParams(
                fromTemplate: "https://t.example/{z}/{x}/{y}.png?key=SECRET&format=png"),
            "https://t.example/{z}/{x}/{y}.png?format=png")
        // Case-insensitive, and every recognised spelling goes.
        XCTAssertEqual(
            TileURLKeys.strippingAuthParams(
                fromTemplate: "https://t.example/w?KEY=a&Token=b&api_key=c&style=x"),
            "https://t.example/w?style=x")
        // All-auth query loses the "?" entirely.
        XCTAssertEqual(
            TileURLKeys.strippingAuthParams(fromTemplate: "https://t.example/w?key=a"),
            "https://t.example/w")
        // No query → untouched.
        XCTAssertEqual(
            TileURLKeys.strippingAuthParams(fromTemplate: "https://t.example/{z}/{x}/{y}.png"),
            "https://t.example/{z}/{x}/{y}.png")
    }

    func testRedactionReplacesValuesOnly() {
        XCTAssertEqual(
            TileURLKeys.redactingAuthParams(
                in: "https://t.example/w?key=SECRET123&format=png"),
            "https://t.example/w?key=•••&format=png")
        // Works inside prose (scan errors that echo a URL).
        XCTAssertEqual(
            TileURLKeys.redactingAuthParams(
                in: "Could not load https://t.example/w?apikey=abc — timed out."),
            "Could not load https://t.example/w?apikey=••• — timed out.")
        // Non-auth params and bare prose stay untouched.
        let clean = "https://t.example/w?format=png with key material elsewhere"
        XCTAssertEqual(TileURLKeys.redactingAuthParams(in: clean), clean)
    }

    func testCustomSourceNamespaceSurvivesKeyRotation() {
        func src(_ template: String) -> CustomTileSource {
            CustomTileSource(name: "L", wmtsEndpoint: "https://t.example/wmts",
                             zxyTemplate: template)
        }
        let a = src("https://t.example/{z}/{x}/{y}.png?key=AAA&format=png")
        let b = src("https://t.example/{z}/{x}/{y}.png?key=BBB&format=png")
        XCTAssertEqual(a.cacheNamespace, b.cacheNamespace)
        XCTAssertNotEqual(a.legacyCacheNamespace, b.legacyCacheNamespace)
        XCTAssertNotEqual(a.cacheNamespace, a.legacyCacheNamespace)
        // Different tile path still caches separately.
        XCTAssertNotEqual(a.cacheNamespace,
                          src("https://t.example/other/{z}/{x}/{y}.png").cacheNamespace)
        // Keyless template: nothing stripped, so legacy == current (adoption no-ops).
        let c = src("https://t.example/{z}/{x}/{y}.png")
        XCTAssertEqual(c.cacheNamespace, c.legacyCacheNamespace)
    }

    func testStandardSourceNamespaceSurvivesKeyRotation() {
        func src(_ template: String) -> StandardTileSource {
            StandardTileSource(name: "L", urlTemplate: template, maxZoom: 19, minZoom: 0)
        }
        let a = src("https://t.example/{z}/{x}/{y}.png?access_token=AAA")
        let b = src("https://t.example/{z}/{x}/{y}.png?access_token=BBB")
        XCTAssertEqual(a.cacheNamespace, b.cacheNamespace)
        XCTAssertTrue(a.cacheNamespace.hasPrefix("std-"))
        XCTAssertTrue(a.legacyCacheNamespace.hasPrefix("std-"))
        XCTAssertNotEqual(a.legacyCacheNamespace, b.legacyCacheNamespace)
    }
}

// MARK: - Layer health (Phase 3)

final class TileLayerHealthTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TileLayerHealth.reset()
    }

    override func tearDown() {
        TileLayerHealth.reset()
        super.tearDown()
    }

    func testReportsOncePerSourcePerSession() {
        let note = expectation(
            forNotification: TileLayerHealth.authFailureNotification, object: nil) { n in
            n.userInfo?[TileLayerHealth.sourceIDKey] as? String == "s1"
        }
        XCTAssertTrue(TileLayerHealth.reportAuthFailure(sourceID: "s1", name: "Hills", status: 401))
        // Same source again — swallowed, whatever the status.
        XCTAssertFalse(TileLayerHealth.reportAuthFailure(sourceID: "s1", name: "Hills", status: 403))
        XCTAssertFalse(TileLayerHealth.reportAuthFailure(sourceID: "s1", name: "Hills", status: 429))
        // A different source still gets its report.
        XCTAssertTrue(TileLayerHealth.reportAuthFailure(sourceID: "s2", name: "Coast", status: 403))
        wait(for: [note], timeout: 1)
    }

    func testResetAllowsAFreshReport() {
        XCTAssertTrue(TileLayerHealth.reportAuthFailure(sourceID: "s1", name: "L", status: 401))
        TileLayerHealth.reset(sourceID: "s1")
        XCTAssertTrue(TileLayerHealth.reportAuthFailure(sourceID: "s1", name: "L", status: 401))
    }

    func testMessagesNameTheLayerAndTheProblem() {
        let auth = TileLayerHealth.message(name: "OS Outdoor", status: 403)
        XCTAssertTrue(auth.contains("OS Outdoor"))
        XCTAssertTrue(auth.contains("rejected your API key"))
        let quota = TileLayerHealth.message(name: "OS Outdoor", status: 429)
        XCTAssertTrue(quota.contains("rate limit"))
    }
}

// MARK: - Test-layer probe tile selection (Phase 3)

final class TileLayerTesterTests: XCTestCase {

    func testBNGTestTileUsesGridCentreWhenBoundsKnown() {
        let source = CustomTileSource(
            name: "L", wmtsEndpoint: "e", zxyTemplate: "t/{z}/{x}/{y}",
            validated: .init(
                layerIdentifier: "L", layerTitle: nil,
                tileMatrixSetIdentifier: "S", supportedCRS: "EPSG:27700",
                originX: -238375, originY: 1376256, tileSize: 256,
                resolutions: [896, 448, 224],
                matrixWidths: [5, 9, 17], matrixHeights: [7, 13, 25]))
        let tile = TileLayerTester.testTile(for: source)
        XCTAssertEqual(tile.z, 1)          // mid-pyramid
        XCTAssertEqual(tile.x, 9 / 2)
        XCTAssertEqual(tile.y, 13 / 2)
    }

    func testBNGTestTileFallsBackToCentralGB() {
        let source = CustomTileSource(
            name: "L", wmtsEndpoint: "e", zxyTemplate: "t/{z}/{x}/{y}",
            validated: .init(
                layerIdentifier: "L", layerTitle: nil,
                tileMatrixSetIdentifier: "S", supportedCRS: "EPSG:27700",
                originX: -238375, originY: 1376256, tileSize: 256,
                resolutions: [896, 448, 224]))   // no bounds (v3-era record)
        let tile = TileLayerTester.testTile(for: source)
        XCTAssertEqual(tile.z, 1)
        // Tile containing (389000, 461000) at 448 m/px, 256 px tiles.
        XCTAssertEqual(tile.x, Int((389_000.0 + 238_375.0) / (448 * 256)))
        XCTAssertEqual(tile.y, Int((1_376_256.0 - 461_000.0) / (448 * 256)))
    }

    func testStandardTestTileClampsToZoomRange() {
        let layer = StandardTileSource(name: "L", urlTemplate: "t/{z}/{x}/{y}",
                                       maxZoom: 12, minZoom: 4)
        let tile = TileLayerTester.testTile(for: layer, lat: 54.5, lon: -2.5)
        XCTAssertEqual(tile.z, 8)
        let expected = TileLayerTester.webMercatorTileXY(lat: 54.5, lon: -2.5, z: 8)
        XCTAssertEqual(tile.x, expected.x)
        XCTAssertEqual(tile.y, expected.y)
    }

    func testWebMercatorTileXY() {
        XCTAssertEqual(TileLayerTester.webMercatorTileXY(lat: 0, lon: 0, z: 0).x, 0)
        XCTAssertEqual(TileLayerTester.webMercatorTileXY(lat: 0, lon: 0, z: 0).y, 0)
        // (0,0) at z1 is the top-left corner of the bottom-right quadrant.
        let origin = TileLayerTester.webMercatorTileXY(lat: 0, lon: 0, z: 1)
        XCTAssertEqual(origin.x, 1)
        XCTAssertEqual(origin.y, 1)
        // Extreme latitudes clamp into the grid rather than under/overflowing.
        let pole = TileLayerTester.webMercatorTileXY(lat: 89.9, lon: 0, z: 3)
        XCTAssertEqual(pole.y, 0)
    }
}

// MARK: - Great Britain bounds hint (Phase 5)

final class GreatBritainBoundsTests: XCTestCase {

    func testGBLocationsAreIn() {
        XCTAssertTrue(BNGProjection.isLikelyInGreatBritain(lat: 51.5074, lon: -0.1278))  // London
        XCTAssertTrue(BNGProjection.isLikelyInGreatBritain(lat: 55.9533, lon: -3.1883))  // Edinburgh
        XCTAssertTrue(BNGProjection.isLikelyInGreatBritain(lat: 51.4816, lon: -3.1791))  // Cardiff
        XCTAssertTrue(BNGProjection.isLikelyInGreatBritain(lat: 54.1509, lon: -4.4815))  // Isle of Man
        XCTAssertTrue(BNGProjection.isLikelyInGreatBritain(lat: 55.31, lon: -5.79))      // Mull of Kintyre
    }

    func testNonGBLocationsAreOut() {
        XCTAssertFalse(BNGProjection.isLikelyInGreatBritain(lat: 54.5973, lon: -5.9301)) // Belfast (Irish Grid)
        XCTAssertFalse(BNGProjection.isLikelyInGreatBritain(lat: 53.3498, lon: -6.2603)) // Dublin
        XCTAssertFalse(BNGProjection.isLikelyInGreatBritain(lat: 48.8566, lon: 2.3522))  // Paris
        XCTAssertFalse(BNGProjection.isLikelyInGreatBritain(lat: 40.7128, lon: -74.0060)) // New York
    }
}

// MARK: - StandardTileSource model

final class StandardTileSourceTests: XCTestCase {

    private func source(_ template: String, subdomains: String? = nil) -> StandardTileSource {
        StandardTileSource(name: "T", urlTemplate: template, maxZoom: 19, minZoom: 0,
                           subdomains: subdomains)
    }

    func testIsUsableAcceptsFlippedY() {
        XCTAssertTrue(source("https://t.example/{z}/{x}/{y}.png").isUsable)
        XCTAssertTrue(source("https://t.example/{z}/{x}/{-y}.png").isUsable)
        XCTAssertFalse(source("https://t.example/{z}/{x}.png").isUsable)
        XCTAssertFalse(source("").isUsable)
    }

    func testSecureScheme() {
        XCTAssertTrue(source("https://t.example/{z}/{x}/{y}.png").usesSecureScheme)
        XCTAssertFalse(source("http://t.example/{z}/{x}/{y}.png").usesSecureScheme)
        XCTAssertFalse(source("t.example/{z}/{x}/{y}.png").usesSecureScheme)
    }

    func testSubdomainTokenParsing() {
        XCTAssertEqual(source("x", subdomains: "abc").subdomainTokens, ["a", "b", "c"])
        XCTAssertEqual(source("x", subdomains: "mt0, mt1").subdomainTokens, ["mt0", "mt1"])
        XCTAssertEqual(source("x", subdomains: " ").subdomainTokens, [])
        XCTAssertEqual(source("x", subdomains: nil).subdomainTokens, [])
    }

    func testV1RecordDecodesWithoutNewFields() throws {
        // A v1-era record has no apiKey/subdomains/tilePixelSize keys at all.
        let v1JSON = """
        {"id":"\(UUID().uuidString)","name":"Old","urlTemplate":"https://t.example/{z}/{x}/{y}.png","maxZoom":18,"minZoom":2}
        """
        let decoded = try JSONDecoder().decode(StandardTileSource.self, from: Data(v1JSON.utf8))
        XCTAssertEqual(decoded.name, "Old")
        XCTAssertNil(decoded.apiKey)
        XCTAssertNil(decoded.subdomains)
        XCTAssertNil(decoded.tilePixelSize)
        XCTAssertNil(decoded.attribution)
        XCTAssertEqual(decoded.maxZoom, 18)
    }
}

// MARK: - Cache poisoning guard

final class TileImageSniffTests: XCTestCase {

    func testAcceptsRealImageMagicBytes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        XCTAssertTrue(TileFetcher.looksLikeImage(png))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(TileFetcher.looksLikeImage(jpeg))
        var webp = Data("RIFF".utf8); webp += Data([0, 0, 0, 0]); webp += Data("WEBP".utf8)
        XCTAssertTrue(TileFetcher.looksLikeImage(webp))
    }

    func testRejectsXMLExceptionReportAndJunk() {
        let xml = Data("<?xml version=\"1.0\"?><ExceptionReport>TileOutOfRange</ExceptionReport>".utf8)
        XCTAssertFalse(TileFetcher.looksLikeImage(xml))
        XCTAssertFalse(TileFetcher.looksLikeImage(Data("<html>403</html>".utf8)))
        XCTAssertFalse(TileFetcher.looksLikeImage(Data()))
        XCTAssertFalse(TileFetcher.looksLikeImage(Data([0x89, 0x50])))  // too short
    }
}

// MARK: - Disk cache: LRU trim, legacy fallback, per-namespace ops

final class TileDiskCacheTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TileDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Write a file of `kb` kilobytes with a given age in days.
    private func plant(_ relPath: String, kb: Int, ageDays: Double) throws {
        let url = tempRoot.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: kb * 1024).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -ageDays * 86_400)],
            ofItemAtPath: url.path)
    }

    private func exists(_ relPath: String) -> Bool {
        FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent(relPath).path)
    }

    func testTrimEvictsOldestFirstAndSparesManifest() throws {
        try plant("ns1/3/1/1", kb: 100, ageDays: 30)   // oldest — should go
        try plant("ns1/3/1/2", kb: 100, ageDays: 10)   // next oldest — should go
        try plant("ns2/5/9/9", kb: 100, ageDays: 1)    // recent — stays
        // Ancient but spared. Kept small: it counts toward the tree total while
        // never being evictable, so an outsized one would force the trim to eat
        // recent tiles to satisfy the cap.
        try plant("ns1/manifest.json", kb: 1, ageDays: 400)

        // Cap fits ~1.5 tiles: the two oldest must go, the recent one survives.
        TileDiskCache.trim(under: tempRoot, toBytes: 150 * 1024)

        XCTAssertFalse(exists("ns1/3/1/1"))
        XCTAssertFalse(exists("ns1/3/1/2"))
        XCTAssertTrue(exists("ns2/5/9/9"))
        XCTAssertTrue(exists("ns1/manifest.json"))
    }

    func testTrimNoOpUnderCap() throws {
        try plant("ns1/1/1/1", kb: 10, ageDays: 100)
        TileDiskCache.trim(under: tempRoot, toBytes: 1024 * 1024)
        XCTAssertTrue(exists("ns1/1/1/1"))
    }

    func testReadFallsBackToLegacyPNGName() throws {
        let cache = TileDiskCache(root: tempRoot.appendingPathComponent("ns", isDirectory: true))
        // Simulate a pre-Phase-4 cache entry: z/x/y.png
        try plant("ns/7/3/4.png", kb: 1, ageDays: 0)
        XCTAssertNotNil(cache.read(z: 7, x: 3, y: 4))
        // New writes are extensionless and readable.
        cache.write(z: 8, x: 1, y: 2, data: Data([0x01, 0x02]))
        XCTAssertEqual(cache.read(z: 8, x: 1, y: 2), Data([0x01, 0x02]))
        // remove() clears both namings.
        cache.remove(z: 7, x: 3, y: 4)
        cache.remove(z: 8, x: 1, y: 2)
        XCTAssertNil(cache.read(z: 7, x: 3, y: 4))
        XCTAssertNil(cache.read(z: 8, x: 1, y: 2))
    }

    func testReadPrefersPinnedRootAndTrimNeverTouchesIt() throws {
        // Distinct cache and pinned trees, like Caches/ vs Application Support/.
        let cacheRoot = tempRoot.appendingPathComponent("cache/ns", isDirectory: true)
        let pinnedRoot = tempRoot.appendingPathComponent("pinned/ns", isDirectory: true)
        let store = TileDiskCache(root: cacheRoot, pinnedRoot: pinnedRoot)

        // Same tile in both: the pinned copy (deliberately refreshed) wins.
        try plant("pinned/ns/5/1/2", kb: 1, ageDays: 0)
        let pinnedURL = tempRoot.appendingPathComponent("pinned/ns/5/1/2")
        try Data("pinned-bytes".utf8).write(to: pinnedURL)
        store.write(z: 5, x: 1, y: 2, data: Data("cache-bytes".utf8))
        XCTAssertEqual(store.read(z: 5, x: 1, y: 2), Data("pinned-bytes".utf8))

        // A cache-only tile still reads.
        store.write(z: 6, x: 0, y: 0, data: Data("only-cached".utf8))
        XCTAssertEqual(store.read(z: 6, x: 0, y: 0), Data("only-cached".utf8))

        // Trim the cache tree to nothing: pinned tiles must survive, and reads
        // must keep serving them (Phase 7's pinned-root exclusion guarantee).
        TileDiskCache.trim(under: tempRoot.appendingPathComponent("cache"), toBytes: 0)
        XCTAssertNil(store.read(z: 6, x: 0, y: 0))
        XCTAssertEqual(store.read(z: 5, x: 1, y: 2), Data("pinned-bytes".utf8))
    }

    func testContainsChecksBothNamings() throws {
        let store = TileDiskCache(root: tempRoot.appendingPathComponent("c", isDirectory: true))
        XCTAssertFalse(store.contains(z: 1, x: 2, y: 3))
        store.write(z: 1, x: 2, y: 3, data: Data([0x01]))
        XCTAssertTrue(store.contains(z: 1, x: 2, y: 3))
        try plant("c/4/5/6.png", kb: 1, ageDays: 0)   // legacy naming
        XCTAssertTrue(store.contains(z: 4, x: 5, y: 6))
        XCTAssertEqual(store.fileSize(z: 4, x: 5, y: 6), 1024)
    }

    func testAdoptLegacyNamespaceRenamesOldDirectory() throws {
        try plant("oldhash/3/1/1", kb: 1, ageDays: 0)
        TileDiskCache.adoptLegacyNamespace("oldhash", forNew: "newhash", under: tempRoot)
        XCTAssertFalse(exists("oldhash/3/1/1"))
        XCTAssertTrue(exists("newhash/3/1/1"))
        // Idempotent: running again (old dir gone) is a no-op.
        TileDiskCache.adoptLegacyNamespace("oldhash", forNew: "newhash", under: tempRoot)
        XCTAssertTrue(exists("newhash/3/1/1"))
    }

    func testAdoptLegacyNamespaceNeverClobbersAnExistingCache() throws {
        try plant("oldhash/3/1/1", kb: 1, ageDays: 0)
        try plant("newhash/9/9/9", kb: 1, ageDays: 0)
        TileDiskCache.adoptLegacyNamespace("oldhash", forNew: "newhash", under: tempRoot)
        XCTAssertTrue(exists("oldhash/3/1/1"))   // left in place
        XCTAssertTrue(exists("newhash/9/9/9"))
        XCTAssertFalse(exists("newhash/3/1/1"))
    }

    func testSizesByNamespace() throws {
        try plant("aaa/1/1/1", kb: 64, ageDays: 0)
        try plant("bbb/1/1/1", kb: 32, ageDays: 0)
        let sizes = TileDiskCache.sizesByNamespace(under: tempRoot)
        // Allocated size is ≥ logical size (block rounding); compare loosely.
        XCTAssertGreaterThanOrEqual(sizes["aaa"] ?? 0, 64 * 1024)
        XCTAssertGreaterThanOrEqual(sizes["bbb"] ?? 0, 32 * 1024)
        XCTAssertGreaterThan(sizes["aaa"] ?? 0, sizes["bbb"] ?? 0)
    }
}

// MARK: - Validator manifest

final class TileValidatorManifestTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTripThroughFlush() {
        let m = TileValidatorManifest(directory: dir)
        m.record(key: "3/1/2", etag: "\"abc\"", lastModified: nil)
        m.record(key: "4/0/0", etag: nil, lastModified: "Tue, 07 Jul 2026 10:00:00 GMT")
        m.flush()

        let reloaded = TileValidatorManifest(directory: dir)
        XCTAssertEqual(reloaded.entry(for: "3/1/2")?.etag, "\"abc\"")
        XCTAssertEqual(reloaded.entry(for: "4/0/0")?.lastModified, "Tue, 07 Jul 2026 10:00:00 GMT")
        XCTAssertNil(reloaded.entry(for: "9/9/9"))
    }

    func testValidatorlessResponsesAreNotRecorded() {
        let m = TileValidatorManifest(directory: dir)
        m.record(key: "1/1/1", etag: nil, lastModified: nil)
        XCTAssertNil(m.entry(for: "1/1/1"))
    }

    func testRemoveAndMarkChecked() {
        let m = TileValidatorManifest(directory: dir)
        m.record(key: "2/2/2", etag: "\"x\"", lastModified: nil)
        let before = m.entry(for: "2/2/2")!.checked
        m.markChecked(key: "2/2/2")
        XCTAssertGreaterThanOrEqual(m.entry(for: "2/2/2")!.checked, before)
        m.remove(key: "2/2/2")
        XCTAssertNil(m.entry(for: "2/2/2"))
        m.flush()
        XCTAssertNil(TileValidatorManifest(directory: dir).entry(for: "2/2/2"))
    }
}

// MARK: - v3 → v4 store migration

final class CustomTileSourceMigrationTests: XCTestCase {

    private let v3Key = "customTileSources.v3"
    private let v4Key = "customTileSources.v4"
    private var savedV3: Data?
    private var savedV4: Data?

    override func setUp() {
        super.setUp()
        // The store uses UserDefaults.standard; preserve whatever the host app has.
        savedV3 = UserDefaults.standard.data(forKey: v3Key)
        savedV4 = UserDefaults.standard.data(forKey: v4Key)
        UserDefaults.standard.removeObject(forKey: v3Key)
        UserDefaults.standard.removeObject(forKey: v4Key)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let savedV3 { defaults.set(savedV3, forKey: v3Key) } else { defaults.removeObject(forKey: v3Key) }
        if let savedV4 { defaults.set(savedV4, forKey: v4Key) } else { defaults.removeObject(forKey: v4Key) }
        super.tearDown()
    }

    private func makeV3Source() -> CustomTileSource {
        CustomTileSource(
            name: "OS Outdoor",
            wmtsEndpoint: "https://api.example.co/maps/raster/v1/wmts?key=K",
            zxyTemplate: "https://api.example.co/maps/raster/v1/zxy/Outdoor_27700/{z}/{x}/{y}.png?key=K",
            validated: .init(
                layerIdentifier: "Outdoor_27700", layerTitle: "OS Outdoor",
                tileMatrixSetIdentifier: "27700", supportedCRS: "urn:ogc:def:crs:EPSG::27700",
                originX: -238375, originY: 1376256, tileSize: 256,
                resolutions: [896, 448]))
    }

    func testV3BlobMigratesToV4AndSurvives() throws {
        let original = makeV3Source()
        UserDefaults.standard.set(try JSONEncoder().encode([original]), forKey: v3Key)

        let loaded = CustomTileSourceStore.loadAll()
        XCTAssertEqual(loaded, [original])
        // Migration wrote the v4 blob and left v3 in place (downgrade safety).
        XCTAssertNotNil(UserDefaults.standard.data(forKey: v4Key))
        XCTAssertNotNil(UserDefaults.standard.data(forKey: v3Key))

        // Second load reads v4 and is idempotent.
        XCTAssertEqual(CustomTileSourceStore.loadAll(), [original])
    }

    func testFreshInstallLoadsEmpty() {
        XCTAssertEqual(CustomTileSourceStore.loadAll(), [])
        XCTAssertNil(UserDefaults.standard.data(forKey: v4Key))
    }

    func testUpsertDedupesOnResolvedTemplate() {
        let original = makeV3Source()
        CustomTileSourceStore.upsert(original)

        // "Adding" the same resolved template under a fresh id must update the
        // existing layer in place, not create a duplicate.
        var again = original
        again.id = UUID()
        again.name = "Renamed"
        CustomTileSourceStore.upsert(again)

        let all = CustomTileSourceStore.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, original.id)
        XCTAssertEqual(all.first?.name, "Renamed")

        // A genuinely different template still appends.
        var other = original
        other.id = UUID()
        other.zxyTemplate = "https://api.example.co/other/{z}/{x}/{y}.png?key=K"
        CustomTileSourceStore.upsert(other)
        XCTAssertEqual(CustomTileSourceStore.loadAll().count, 2)
    }
}

// MARK: - Standard-layer store dedupe

final class StandardTileSourceStoreTests: XCTestCase {

    private let key = "standardTileSources.v1"
    private var saved: Data?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testUpsertDedupesOnTemplate() {
        let original = StandardTileSource(
            name: "Hills", urlTemplate: "https://t.example/{z}/{x}/{y}.png",
            maxZoom: 19, minZoom: 0)
        StandardTileSourceStore.upsert(original)

        var again = original
        again.id = UUID()
        again.name = "Hills v2"
        StandardTileSourceStore.upsert(again)

        let all = StandardTileSourceStore.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, original.id)
        XCTAssertEqual(all.first?.name, "Hills v2")

        // Same id keeps updating in place (the ordinary edit path).
        var edited = all[0]
        edited.maxZoom = 16
        StandardTileSourceStore.upsert(edited)
        XCTAssertEqual(StandardTileSourceStore.loadAll(), [edited])
    }
}

// MARK: - Offline region: tile enumeration (Phase 7)

final class OfflineTileEnumeratorTests: XCTestCase {

    /// Nearly the whole world: exact power-of-four pyramid counts.
    private let world = LatLonBounds(latMin: -85, latMax: 85, lonMin: -179.9, lonMax: 179.9)
    /// A Lake-District-sized rectangle.
    private let lakes = LatLonBounds(latMin: 54.3, latMax: 54.7, lonMin: -3.4, lonMax: -2.8)

    private var osMatrix: BNGTileMatrix {
        // The osStyleXML grid: z0 5×7, z1 9×13, shared/near origins.
        BNGTileMatrix(originsX: [-238375, -238375], originsY: [1376256, 1376256],
                      tileSize: 256, resolutions: [896, 448],
                      matrixWidths: [5, 9], matrixHeights: [7, 13])
    }

    func testMercatorPyramidCounts() {
        XCTAssertEqual(OfflineTileEnumerator.tileCount(bounds: world, grid: .mercator, zooms: 0...0), 1)
        XCTAssertEqual(OfflineTileEnumerator.tileCount(bounds: world, grid: .mercator, zooms: 0...2), 1 + 4 + 16)
        // A small region's count grows roughly ×4 per level; the deepest level dominates.
        let perLevel = (10...14).map {
            OfflineTileEnumerator.tileCount(bounds: lakes, grid: .mercator, zooms: $0...$0)
        }
        let total = OfflineTileEnumerator.tileCount(bounds: lakes, grid: .mercator, zooms: 10...14)
        XCTAssertEqual(total, perLevel.reduce(0, +))
        XCTAssertGreaterThan(perLevel.last!, total / 2)   // deepest level dominates
    }

    func testBNGRangesClipToAdvertisedGrid() {
        // A box comfortably larger than the whole grid (the z1 matrix runs
        // 9×13 tiles from its origin — well out into the North Sea): the
        // enumeration must clip to exactly the advertised grid, no more.
        let hugeBounds = LatLonBounds(latMin: 45, latMax: 63, lonMin: -12, lonMax: 10)
        XCTAssertEqual(
            OfflineTileEnumerator.tileCount(bounds: hugeBounds, grid: .bng(osMatrix), zooms: 0...0),
            5 * 7)
        XCTAssertEqual(
            OfflineTileEnumerator.tileCount(bounds: hugeBounds, grid: .bng(osMatrix), zooms: 0...1),
            5 * 7 + 9 * 13)
        // A small region needs far fewer tiles than the full grid.
        let small = OfflineTileEnumerator.tileCount(bounds: lakes, grid: .bng(osMatrix), zooms: 1...1)
        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThan(small, 9 * 13)
        // Far outside BNG coverage: nothing to download.
        let alps = LatLonBounds(latMin: 45.8, latMax: 46.0, lonMin: 7.5, lonMax: 7.9)
        XCTAssertEqual(OfflineTileEnumerator.tileCount(bounds: alps, grid: .bng(osMatrix), zooms: 0...1), 0)
        // Zooms past the matrix contribute nothing (no phantom levels).
        XCTAssertEqual(
            OfflineTileEnumerator.tileCount(bounds: lakes, grid: .bng(osMatrix), zooms: 0...9),
            OfflineTileEnumerator.tileCount(bounds: lakes, grid: .bng(osMatrix), zooms: 0...1))
    }

    func testLazyEnumerationMatchesCountAndIsCoarsestFirst() {
        let tiles = Array(OfflineTileEnumerator.tiles(bounds: lakes, grid: .mercator, zooms: 3...6))
        XCTAssertEqual(tiles.count,
                       OfflineTileEnumerator.tileCount(bounds: lakes, grid: .mercator, zooms: 3...6))
        XCTAssertEqual(tiles.first?.z, 3)
        XCTAssertEqual(tiles.last?.z, 6)
        // Monotone non-decreasing zoom: a partial download is a usable shallow map.
        XCTAssertTrue(zip(tiles, tiles.dropFirst()).allSatisfy { $0.z <= $1.z })
        // No duplicates.
        XCTAssertEqual(Set(tiles.map { "\($0.z)/\($0.x)/\($0.y)" }).count, tiles.count)
    }

    func testResumeSkipsTilesAlreadyOnDisk() throws {
        // The downloader's resume predicate: contains() on the pinned store.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumeTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TileDiskCache(root: root)

        let all = Array(OfflineTileEnumerator.tiles(bounds: lakes, grid: .mercator, zooms: 8...10))
        XCTAssertGreaterThan(all.count, 4)
        for tile in all.prefix(3) {
            store.write(z: tile.z, x: tile.x, y: tile.y, data: Data([0xAB]))
        }
        let pending = all.filter { !store.contains(z: $0.z, x: $0.x, y: $0.y) }
        XCTAssertEqual(pending.count, all.count - 3)
    }
}

// MARK: - Offline region model + store

final class OfflineRegionModelTests: XCTestCase {

    private let key = "offlineRegions.v1"
    private var saved: Data?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private func makeRegion() -> OfflineRegion {
        OfflineRegion(layerID: UUID(), name: "Lakes",
                      bounds: LatLonBounds(latMin: 54.3, latMax: 54.7, lonMin: -3.4, lonMax: -2.8),
                      minZoom: 0, maxZoom: 12, tileCount: 1234, sizeBytes: 37_000_000)
    }

    func testStoreRoundTrip() {
        let region = makeRegion()
        OfflineRegionStore.upsert(region)
        XCTAssertEqual(OfflineRegionStore.loadAll(), [region])

        var updated = region
        updated.downloadComplete = true
        updated.lastRefreshed = Date(timeIntervalSince1970: 1_700_000_000)
        OfflineRegionStore.upsert(updated)
        XCTAssertEqual(OfflineRegionStore.loadAll(), [updated])

        OfflineRegionStore.remove(id: region.id)
        XCTAssertEqual(OfflineRegionStore.loadAll(), [])
    }

    func testStaleness() {
        var region = makeRegion()
        region.createdAt = Date(timeIntervalSinceNow: -40 * 86_400)
        // Never refreshed: staleness measures from creation.
        XCTAssertTrue(region.isStale())
        region.lastRefreshed = Date(timeIntervalSinceNow: -5 * 86_400)
        XCTAssertFalse(region.isStale())
        region.lastRefreshed = Date(timeIntervalSinceNow: -31 * 86_400)
        XCTAssertTrue(region.isStale())
    }

    @MainActor
    func testPickerFrameBoundsMath() {
        // 400×800 map, 200×200 centered frame → half the lon span, a quarter
        // of the lat span, centered on the map centre.
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 54, longitude: -2),
            span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        let bounds = OfflineRegionPickerView.boundsUnderFrame(
            region: region,
            mapSize: CGSize(width: 400, height: 800),
            frame: CGRect(x: 100, y: 300, width: 200, height: 200))
        XCTAssertEqual(bounds.latMin, 53.75, accuracy: 1e-9)
        XCTAssertEqual(bounds.latMax, 54.25, accuracy: 1e-9)
        XCTAssertEqual(bounds.lonMin, -2.5, accuracy: 1e-9)
        XCTAssertEqual(bounds.lonMax, -1.5, accuracy: 1e-9)
    }

    func testBNGLayerRefNamespaceMatchesRendererConvention() {
        let src = CustomTileSource(name: "L", wmtsEndpoint: "e",
                                   zxyTemplate: "https://t.example/{z}/{x}/{y}.png")
        CustomTileSourceStore.upsert(src)
        defer { CustomTileSourceStore.remove(id: src.id) }
        // BNGTileStore caches under "src-<hash>"; the pinned pack must match or
        // the renderer's pinned→cache read path never finds offline tiles.
        if case .bng(let resolved)? = OfflineLayerRef.resolve(id: src.id) {
            XCTAssertEqual(resolved.id, src.id)
        } else {
            XCTFail("custom source did not resolve as BNG layer")
        }
        XCTAssertEqual(OfflineLayerRef.bng(src).namespace, "src-\(src.cacheNamespace)")
    }
}

// MARK: - Cache cap setting

final class TileCacheCapTests: XCTestCase {

    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: TileDiskCache.capBytesDefaultsKey)
        UserDefaults.standard.removeObject(forKey: TileDiskCache.capBytesDefaultsKey)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: TileDiskCache.capBytesDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: TileDiskCache.capBytesDefaultsKey)
        }
        super.tearDown()
    }

    func testDefaultsToHalfGigabyteAndRoundTrips() {
        XCTAssertEqual(TileDiskCache.capBytes, 500 * 1024 * 1024)
        TileDiskCache.setCapBytes(TileDiskCache.capChoices[2])
        XCTAssertEqual(TileDiskCache.capBytes, 3 * 1024 * 1024 * 1024)
        // The default matches the "small" choice, so existing installs land on
        // a valid picker selection.
        XCTAssertEqual(TileDiskCache.defaultCapBytes, TileDiskCache.capChoices[0])
    }
}

// MARK: - Conditional refresh + double-storage (URLProtocol stub)

/// Stubs the network for `TileFetcher`'s injected session: every request goes
/// through `handler`. Tests run serially, so the shared handler is safe.
final class StubTileProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TileRefreshNetworkTests: XCTestCase {

    private var storeRoot: URL!
    /// Enough bytes to pass the image sniff (PNG magic + padding).
    private let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                                0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])

    override func setUpWithError() throws {
        storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubTileProtocol.handler = nil
        try? FileManager.default.removeItem(at: storeRoot)
    }

    private func makeFetcher(store: TileDiskCache) -> TileFetcher {
        TileFetcher(urlTemplate: "https://stub.example/{z}/{x}/{y}.png",
                    apiKey: "", cacheNamespace: "unused-when-target-store-set",
                    targetStore: store,
                    protocolClasses: [StubTileProtocol.self])
    }

    func testRefresh304LeavesTileAndCostsNoDownload() async {
        let store = TileDiskCache(root: storeRoot)
        let fetcher = makeFetcher(store: store)

        // Initial fetch: 200 with an ETag → cached + validator recorded.
        let etag = "\"v1\""
        StubTileProtocol.handler = { [fakePNG] _ in
            (200, ["ETag": etag], fakePNG)
        }
        let first = await fetcher.data(z: 3, x: 1, y: 2)
        XCTAssertEqual(first, fakePNG)
        XCTAssertEqual(store.read(z: 3, x: 1, y: 2), fakePNG)

        // Refresh: server sees the validator and answers 304 with no body.
        final class HeaderBox: @unchecked Sendable { var value: String? }
        let sawIfNoneMatch = HeaderBox()
        StubTileProtocol.handler = { request in
            sawIfNoneMatch.value = request.value(forHTTPHeaderField: "If-None-Match")
            return (304, [:], Data())
        }
        let outcome = await fetcher.refreshTile(z: 3, x: 1, y: 2)
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(sawIfNoneMatch.value, etag)
        XCTAssertEqual(store.read(z: 3, x: 1, y: 2), fakePNG)   // untouched
    }

    func testRefresh200RewritesAnd404Removes() async {
        let store = TileDiskCache(root: storeRoot)
        let fetcher = makeFetcher(store: store)

        StubTileProtocol.handler = { [fakePNG] _ in (200, ["ETag": "\"v1\""], fakePNG) }
        _ = await fetcher.data(z: 4, x: 0, y: 0)

        // Changed on the server: 200 with new bytes replaces the cached tile.
        var newTile = fakePNG
        newTile.append(contentsOf: [0xFF, 0xEE])
        StubTileProtocol.handler = { [newTile] _ in (200, ["ETag": "\"v2\""], newTile) }
        let updated = await fetcher.refreshTile(z: 4, x: 0, y: 0)
        XCTAssertEqual(updated, .updated)
        XCTAssertEqual(store.read(z: 4, x: 0, y: 0), newTile)

        // Dropped by the server: 404 removes the pack entry.
        StubTileProtocol.handler = { _ in (404, [:], Data()) }
        let missing = await fetcher.refreshTile(z: 4, x: 0, y: 0)
        XCTAssertEqual(missing, .missing)
        XCTAssertNil(store.read(z: 4, x: 0, y: 0))
    }

    func testTargetStoreWritesOnlyThere_DoubleStorageRegression() async {
        let store = TileDiskCache(root: storeRoot)
        let fetcher = makeFetcher(store: store)
        // A namespace that must never materialise under the cache root: the
        // pack downloader's fetcher writes to its target store and nowhere else.
        let cacheDir = TileDiskCache.rootBase
            .appendingPathComponent("unused-when-target-store-set", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)

        StubTileProtocol.handler = { [fakePNG] _ in (200, [:], fakePNG) }
        let data = await fetcher.data(z: 5, x: 6, y: 7)
        XCTAssertEqual(data, fakePNG)
        XCTAssertTrue(store.contains(z: 5, x: 6, y: 7))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path),
                       "pack tiles must not be duplicated into the purgeable cache")
    }

    func testValidatorManifestLivesNextToThePack() async {
        let store = TileDiskCache(root: storeRoot)
        let fetcher = makeFetcher(store: store)
        StubTileProtocol.handler = { [fakePNG] _ in (200, ["ETag": "\"m\""], fakePNG) }
        _ = await fetcher.data(z: 1, x: 0, y: 0)
        await fetcher.flushValidators()
        // One manifest per pack/namespace, stored beside the tiles it validates.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: storeRoot.appendingPathComponent(TileDiskCache.manifestFilename).path))
    }
}
