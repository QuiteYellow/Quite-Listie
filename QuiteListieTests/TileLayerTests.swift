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

/// RESTful-ResourceURL-shaped capabilities: numeric matrix
/// identifiers, shared origin across zooms.
private let restfulStyleXML = """
<?xml version="1.0" encoding="UTF-8"?>
<Capabilities xmlns="http://www.opengis.net/wmts/1.0" xmlns:ows="http://www.opengis.net/ows/1.1" version="1.0.0">
  <Contents>
    <Layer>
      <ows:Identifier>Terrain_27700</ows:Identifier>
      <ows:Title>Terrain</ows:Title>
      <ows:BoundingBox crs="urn:ogc:def:crs:EPSG::3857">
        <ows:LowerCorner>-1198263.03 6365004.03</ows:LowerCorner>
        <ows:UpperCorner>213000.0 8702260.01</ows:UpperCorner>
      </ows:BoundingBox>
      <ows:BoundingBox crs="urn:ogc:def:crs:EPSG::27700">
        <ows:LowerCorner>-238375.0000149319 0.0</ows:LowerCorner>
        <ows:UpperCorner>900000.00000057 1376256.0000176653</ows:UpperCorner>
      </ows:BoundingBox>
      <ows:WGS84BoundingBox crs="urn:ogc:def:crs:OGC:2:84">
        <ows:LowerCorner>-10.76 49.52</ows:LowerCorner>
        <ows:UpperCorner>1.91 61.33</ows:UpperCorner>
      </ows:WGS84BoundingBox>
      <Style isDefault="true"><ows:Identifier>true-colour</ows:Identifier></Style>
      <Format>image/png</Format>
      <TileMatrixSetLink><TileMatrixSet>27700</TileMatrixSet></TileMatrixSetLink>
      <ResourceURL format="image/png" resourceType="tile" template="https://api.example.co/maps/raster/v1/tiles/Terrain_27700/{Style}/{TileMatrix}/{TileCol}/{TileRow}.png"/>
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
        let caps = try WMTSCapabilitiesLoader.parse(Data(restfulStyleXML.utf8))
        XCTAssertEqual(caps.layers.count, 1)
        let layer = try XCTUnwrap(caps.layers.first)
        XCTAssertEqual(layer.identifier, "Terrain_27700")
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

// MARK: - Declared extent (what the edge fade is laid against)

final class LayerExtentTests: XCTestCase {

    func testParsesTheEPSG27700BoundingBoxAndIgnoresOthers() throws {
        let caps = try WMTSCapabilitiesLoader.parse(Data(restfulStyleXML.utf8))
        let box = try XCTUnwrap(caps.layers.first?.boundingBox)
        // The 3857 and WGS84 boxes in the same layer must not be picked up.
        XCTAssertEqual(box.eMin, -238_375, accuracy: 0.01)
        XCTAssertEqual(box.eMax, 900_000, accuracy: 0.01)
        XCTAssertEqual(box.nMin, 0, accuracy: 0.01)
        XCTAssertEqual(box.nMax, 1_376_256, accuracy: 0.01)
    }

    func testLayerWithoutABoundingBoxHasNone() throws {
        let caps = try WMTSCapabilitiesLoader.parse(Data(geoServerStyleXML.utf8))
        XCTAssertNil(caps.layers.first?.boundingBox)
    }

    func testValidatedCapabilitiesCarryTheExtent() throws {
        let caps = try WMTSCapabilitiesLoader.parse(Data(restfulStyleXML.utf8))
        let layer = try XCTUnwrap(caps.layers.first)
        let set = try XCTUnwrap(caps.matrixSet(for: layer))
        let matrix = try XCTUnwrap(BNGTileMatrix.fromCapabilities(set))
        let v = CustomTileSource.ValidatedCapabilities.from(layer: layer, set: set, matrix: matrix)
        let extent = try XCTUnwrap(v.extent)
        XCTAssertEqual(extent.eMax, 900_000, accuracy: 0.01)
        XCTAssertEqual(extent.nMin, 0, accuracy: 0.01)
        // The grid fields the fade falls back on still come through.
        XCTAssertEqual(v.matrixWidths, [5, 9])
        XCTAssertEqual(v.matrixHeights, [7, 13])
    }

    /// The extent is a v5 addition; records written before it must still load.
    func testV4RecordWithoutAnExtentStillDecodes() throws {
        let json = """
        {"layerIdentifier":"L","tileMatrixSetIdentifier":"S",
         "supportedCRS":"urn:ogc:def:crs:EPSG::27700",
         "originX":-238375,"originY":1376256,"tileSize":256,
         "resolutions":[896,448],"matrixWidths":[5,9],"matrixHeights":[7,13]}
        """
        let v = try JSONDecoder().decode(
            CustomTileSource.ValidatedCapabilities.self, from: Data(json.utf8))
        XCTAssertNil(v.extent)
        XCTAssertEqual(v.matrixWidths, [5, 9])
    }
}

// MARK: - Tile URL construction

final class WMTSTileTemplateTests: XCTestCase {

    private func osLayerAndSet() throws -> (WMTSCapabilities.Layer, WMTSCapabilities.TileMatrixSet) {
        let caps = try WMTSCapabilitiesLoader.parse(Data(restfulStyleXML.utf8))
        let layer = try XCTUnwrap(caps.layers.first)
        let set = try XCTUnwrap(caps.matrixSet(for: layer))
        return (layer, set)
    }

    func testResourceURLPreferredWithQueryCarryOver() throws {
        let (layer, set) = try osLayerAndSet()
        let endpoint = "https://api.example.co/maps/raster/v1/wmts?key=SECRET&service=WMTS&request=GetCapabilities"
        let template = WMTSCapabilities.tileTemplate(endpoint: endpoint, layer: layer, matrixSet: set)
        XCTAssertEqual(template,
            "https://api.example.co/maps/raster/v1/tiles/Terrain_27700/true-colour/{z}/{x}/{y}.png?key=SECRET")
    }

    func testResourceURLSkipsParamsAlreadyInTemplate() {
        let layer = WMTSCapabilities.Layer(
            identifier: "L", title: nil, tileMatrixSetLinks: ["S"], formats: ["image/png"],
            styles: [.init(identifier: "default", isDefault: true)],
            resourceURLs: [.init(resourceType: "tile", format: "image/png",
                                 template: "https://t.example/{TileMatrix}/{TileCol}/{TileRow}.png?key=EMBEDDED")],
            boundingBox: nil)
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

// MARK: - Template expansion

final class TemplateExpansionTests: XCTestCase {

    func testPlainXYZ() {
        XCTAssertEqual(
            TileFetcher.expandTemplate("https://t.example/{z}/{x}/{y}.png", z: 3, x: 2, y: 1),
            "https://t.example/3/2/1.png")
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
        let auth = TileLayerHealth.message(name: "Terrain", status: 403)
        XCTAssertTrue(auth.contains("Terrain"))
        XCTAssertTrue(auth.contains("rejected your API key"))
        let quota = TileLayerHealth.message(name: "Terrain", status: 429)
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

// MARK: - Failed-tile retry back-off

final class TileRetryPolicyTests: XCTestCase {

    private func policy() -> TileRetryPolicy<Int> {
        TileRetryPolicy(maxAttempts: 3, baseDelay: 2)
    }

    func testUntriedTileMayBeRequested() {
        XCTAssertTrue(policy().mayRequest(1, now: 0))
    }

    /// The bug this exists for: a failed tile must become requestable again
    /// without having to leave the viewport first.
    func testFailedTileBecomesRequestableAfterTheBackOff() {
        var p = policy()
        p.noteFailure(1, now: 100)
        XCTAssertFalse(p.mayRequest(1, now: 100))       // immediately after
        XCTAssertFalse(p.mayRequest(1, now: 101.9))     // still inside 2s
        XCTAssertTrue(p.mayRequest(1, now: 102))        // 2s elapsed
    }

    func testBackOffDoublesThenAttemptsAreCapped() {
        var p = policy()
        XCTAssertEqual(p.noteFailure(1, now: 0), 2)     // retry in 2s
        XCTAssertEqual(p.noteFailure(1, now: 2), 4)     // then in 4s
        XCTAssertNil(p.noteFailure(1, now: 6))          // third strike: give up
        // Capped means capped, however long we wait — no request storm on a
        // position the layer genuinely has nothing for.
        XCTAssertFalse(p.mayRequest(1, now: 6))
        XCTAssertFalse(p.mayRequest(1, now: 10_000))
    }

    func testSuccessClearsTheHistory() {
        var p = policy()
        p.noteFailure(1, now: 0)
        p.noteFailure(1, now: 2)
        p.noteSuccess(1)
        XCTAssertTrue(p.mayRequest(1, now: 2))
        XCTAssertEqual(p.trackedCount, 0)
    }

    /// Leaving the viewport forgets the tile, so returning to it retries at once
    /// (the escape hatch users found by zooming out and back in) and the table
    /// cannot grow as they pan.
    func testForgettingRestoresAnImmediateAttempt() {
        var p = policy()
        p.noteFailure(1, now: 0)
        p.noteFailure(1, now: 2)
        p.noteFailure(1, now: 6)
        XCTAssertFalse(p.mayRequest(1, now: 6))
        p.forget(1)
        XCTAssertTrue(p.mayRequest(1, now: 6))
        XCTAssertEqual(p.trackedCount, 0)
    }

    func testFailuresAreTrackedPerTile() {
        var p = policy()
        p.noteFailure(1, now: 0)
        XCTAssertFalse(p.mayRequest(1, now: 0))
        XCTAssertTrue(p.mayRequest(2, now: 0))
        XCTAssertEqual(p.trackedCount, 1)
    }

    /// A whole screenful of failures still resolves in a bounded number of
    /// requests rather than re-asking on every layout pass.
    func testBoundedTotalAttemptsForAPermanentlyEmptyTile() {
        var p = policy()
        var now: TimeInterval = 0
        var requests = 0
        for _ in 0..<200 {                    // 200 layout passes
            if p.mayRequest(1, now: now) {
                requests += 1
                p.noteFailure(1, now: now)
            }
            now += 0.5
        }
        XCTAssertEqual(requests, 3)           // exactly maxAttempts
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

    func testTrimEvictsOldestFirst() throws {
        try plant("ns1/3/1/1", kb: 100, ageDays: 30)   // oldest — should go
        try plant("ns1/3/1/2", kb: 100, ageDays: 10)   // next oldest — should go
        try plant("ns2/5/9/9", kb: 100, ageDays: 1)    // recent — stays

        // Cap fits ~1.5 tiles: the two oldest must go, the recent one survives.
        TileDiskCache.trim(under: tempRoot, toBytes: 150 * 1024)

        XCTAssertFalse(exists("ns1/3/1/1"))
        XCTAssertFalse(exists("ns1/3/1/2"))
        XCTAssertTrue(exists("ns2/5/9/9"))
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
        // A tile never written is a miss under either naming.
        XCTAssertNil(cache.read(z: 9, x: 9, y: 9))
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
            name: "Terrain",
            wmtsEndpoint: "https://api.example.co/maps/raster/v1/wmts?key=K",
            zxyTemplate: "https://api.example.co/maps/raster/v1/zxy/Terrain_27700/{z}/{x}/{y}.png?key=K",
            validated: .init(
                layerIdentifier: "Terrain_27700", layerTitle: "Terrain",
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
