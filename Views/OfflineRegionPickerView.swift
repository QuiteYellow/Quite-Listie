//
//  OfflineRegionPickerView.swift
//  QuiteListie
//
//  Picks a rectangle of map to download for offline use: a fixed red-bordered
//  frame sits mid-screen while the map pans/zooms normally underneath it.
//  Whatever geography ends up under the frame when the user saves becomes the
//  region. The whole overlay is hit-testing-disabled — it must never eat a
//  map gesture.
//

import SwiftUI
import MapKit

struct OfflineRegionPickerView: View {
    @Environment(\.dismiss) private var dismiss

    /// Fraction of the shorter screen edge the capture frame occupies.
    private static let frameFraction: CGFloat = 0.76
    /// Ceiling on one region's tile count. Generous by design (the sources are
    /// the user's own keys/servers), but still bounded: past this, quota burn,
    /// multi-hour foreground downloads, and monthly-refresh cost stop being
    /// "big" and start being "runaway".
    static let hardTileCap = 100_000

    @State private var selectedLayerID: UUID?
    @State private var name: String = ""
    @State private var maxZoom: Int = 0
    // Seeded over Great Britain so the picker opens somewhere useful even
    // before any pan; both map kinds adopt it via their `.all` focus path.
    @State private var visibleRegion: MKCoordinateRegion? = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 54.5, longitude: -2.5),
        span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8))
    @State private var focusState: MapFocusState = .all
    @State private var mapGeometry: (size: CGSize, frame: CGRect) = (.zero, .zero)

    private let customSources = CustomTileSourceStore.loadAll()
    private let standardSources = StandardTileSourceStore.loadAll()

    private var selectedLayer: OfflineLayerRef? {
        guard let id = selectedLayerID else { return nil }
        return OfflineLayerRef.resolve(id: id)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let layer = selectedLayer {
                    mapWithFrame(layer)
                } else {
                    ContentUnavailableView(
                        "No Map Layers",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Add a custom or standard layer first — offline maps download from your own layers."))
                }
            }
            .navigationTitle("New Offline Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { save() }
                        .disabled(!canSave)
                }
            }
            .safeAreaInset(edge: .bottom) { controlPanel }
            .onAppear {
                if selectedLayerID == nil {
                    selectedLayerID = customSources.first?.id ?? standardSources.first?.id
                }
                resetZoomForLayer()
            }
            .onChange(of: selectedLayerID) { _, _ in resetZoomForLayer() }
        }
    }

    // MARK: - Map + frame overlay

    @ViewBuilder
    private func mapWithFrame(_ layer: OfflineLayerRef) -> some View {
        GeometryReader { geo in
            Group {
                switch layer {
                case .bng(let source):
                    BNGMapView(entries: [], source: source, muted: true,
                               selectedItemID: .constant(nil),
                               visibleRegion: $visibleRegion,
                               focusState: $focusState)
                case .xyz(let raster):
                    RasterTileMapView(entries: [], layer: raster, muted: true,
                                      selectedItemID: .constant(nil),
                                      visibleRegion: $visibleRegion,
                                      focusState: $focusState)
                }
            }
            .overlay {
                let frame = Self.captureFrame(in: geo.size)
                ZStack {
                    // Dim everything outside the frame (even-odd hole).
                    HoleShape(hole: frame)
                        .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                    Rectangle()
                        .path(in: frame)
                        .stroke(Color.red, lineWidth: 2)
                }
                // The overlay is purely visual — every gesture belongs to the map.
                .allowsHitTesting(false)
            }
            .onAppear { mapGeometry = (geo.size, Self.captureFrame(in: geo.size)) }
            .onChange(of: geo.size) { _, newSize in
                mapGeometry = (newSize, Self.captureFrame(in: newSize))
            }
        }
        .ignoresSafeArea(edges: .horizontal)
    }

    /// The fixed capture frame: a square on the shorter edge, centered.
    static func captureFrame(in size: CGSize) -> CGRect {
        let side = min(size.width, size.height) * frameFraction
        return CGRect(x: (size.width - side) / 2,
                      y: (size.height - side) / 2,
                      width: side, height: side)
    }

    /// Geography under the frame, from the map's reported region and the
    /// frame's fraction of the view. Under rotation the reported region is the
    /// viewport's bounding box, so this over-covers slightly — the safe
    /// direction for an offline pack.
    static func boundsUnderFrame(region: MKCoordinateRegion,
                                 mapSize: CGSize, frame: CGRect) -> LatLonBounds {
        let fracW = mapSize.width > 0 ? Double(frame.width / mapSize.width) : 1
        let fracH = mapSize.height > 0 ? Double(frame.height / mapSize.height) : 1
        let halfLat = region.span.latitudeDelta * fracH / 2
        let halfLon = region.span.longitudeDelta * fracW / 2
        return LatLonBounds(latMin: region.center.latitude - halfLat,
                            latMax: region.center.latitude + halfLat,
                            lonMin: region.center.longitude - halfLon,
                            lonMax: region.center.longitude + halfLon)
    }

    // MARK: - Controls

    private var currentBounds: LatLonBounds? {
        guard let region = visibleRegion, mapGeometry.size != .zero else { return nil }
        return Self.boundsUnderFrame(region: region,
                                     mapSize: mapGeometry.size,
                                     frame: mapGeometry.frame)
    }

    private var estimatedTiles: Int {
        guard let layer = selectedLayer, let bounds = currentBounds else { return 0 }
        let zooms = layer.zoomRange.lowerBound...max(layer.zoomRange.lowerBound, maxZoom)
        return OfflineTileEnumerator.tileCount(bounds: bounds, grid: layer.grid, zooms: zooms)
    }

    private var overCap: Bool { estimatedTiles > Self.hardTileCap }

    private var canSave: Bool {
        selectedLayer != nil && currentBounds != nil && estimatedTiles > 0 && !overCap
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name (e.g. Lake District)", text: $name)
                .textFieldStyle(.roundedBorder)

            if customSources.count + standardSources.count > 1 {
                Picker("Layer", selection: $selectedLayerID) {
                    ForEach(customSources) { src in
                        Text(src.name).tag(Optional(src.id))
                    }
                    ForEach(standardSources) { layer in
                        Text(layer.name).tag(Optional(layer.id))
                    }
                }
                .pickerStyle(.menu)
            }

            if let layer = selectedLayer {
                Stepper("Max Zoom: \(maxZoom)", value: $maxZoom, in: layer.zoomRange)
                HStack {
                    Image(systemName: overCap ? "exclamationmark.triangle.fill" : "square.grid.3x3")
                        .foregroundStyle(overCap ? .red : .secondary)
                    Text(estimateText)
                        .font(.footnote)
                        .foregroundStyle(overCap ? .red : .secondary)
                        .monospacedDigit()
                }
            }

            Text("Zooming past the max upscales tiles offline. Check your map provider’s terms before bulk downloading — many tile services restrict it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial)
    }

    private var estimateText: String {
        guard estimatedTiles > 0 else { return "Pan the map to a covered area." }
        let sizeEstimate = Int64(estimatedTiles) * OfflineRegionManager.Progress.seedBytesPerTile
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        let tiles = estimatedTiles.formatted()
        if overCap {
            return "~\(tiles) tiles — over the \(Self.hardTileCap.formatted()) tile limit. Zoom in or lower the max zoom."
        }
        return "~\(tiles) tiles · ~\(f.string(fromByteCount: sizeEstimate))"
    }

    private func resetZoomForLayer() {
        guard let layer = selectedLayer else { return }
        maxZoom = layer.zoomRange.upperBound
    }

    private func save() {
        guard let layer = selectedLayer, let id = selectedLayerID,
              let bounds = currentBounds else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = estimatedTiles
        let region = OfflineRegion(
            layerID: id,
            name: trimmedName.isEmpty ? layer.displayName : trimmedName,
            bounds: bounds,
            minZoom: layer.zoomRange.lowerBound,
            maxZoom: maxZoom,
            tileCount: count,
            sizeBytes: Int64(count) * OfflineRegionManager.Progress.seedBytesPerTile)
        OfflineRegionStore.upsert(region)
        OfflineRegionManager.shared.startDownload(region)
        dismiss()
    }
}

/// The whole view with a rectangular hole cut out — even-odd fill dims the
/// map everywhere except under the capture frame.
private struct HoleShape: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        p.addRect(hole)
        return p
    }
}

#Preview {
    OfflineRegionPickerView()
}
