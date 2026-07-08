//
//  RasterTileMapView.swift
//  QuiteListie
//
//  A standard MapKit map with a raster XYZ tile overlay (web-mercator, EPSG:3857).
//  Unlike the custom EPSG:27700 sources — which need a fully native slippy map —
//  a normal web-mercator tileset drops straight onto `MKMapView` via
//  `MKTileOverlay`, so MapKit handles projection, panning, zoom, the user dot and
//  pin management for us.
//
//  It deliberately mirrors `BNGMapView`'s binding interface (selection, region,
//  focus, popover anchor) so `GlobalMapView` can share the exact same popover /
//  sheet presentation for both layer kinds.
//

import SwiftUI
import MapKit

struct RasterTileMapView: UIViewRepresentable {
    let entries: [LocationEntry]
    /// The layer to draw: template (with `{z}/{x}/{y}` and friends), zoom range,
    /// key/subdomains, tile pixel size and cache namespace all come from here.
    let layer: StandardTileSource
    let muted: Bool
    @Binding var selectedItemID: UUID?
    @Binding var visibleRegion: MKCoordinateRegion?
    @Binding var focusState: MapFocusState
    /// The item a popover is anchored to (iPad/Mac), or nil.
    var popoverItemID: UUID? = nil
    /// Reports that pin's live screen position so the parent can glue a SwiftUI
    /// popover to it as the map moves.
    var onPopoverAnchorChange: ((CGPoint?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        // The historical imagery is light, and the standard base map only shows
        // for the first frame before our tiles cover it. Force light mode so that
        // transient base is light (not a dark-mode black flash) before the cream
        // base overlay and historical tiles paint over it.
        map.overrideUserInterfaceStyle = .light
        map.register(SpotAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: SpotAnnotationView.reuseID)

        // Match the Apple-Maps branch: optionally muted, no POIs, traffic on.
        let config = MKStandardMapConfiguration(emphasisStyle: muted ? .muted : .default)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = true
        map.preferredConfiguration = config

        // Historical OS imagery is light, so gaps should read cream (matching the
        // native EPSG:27700 renderer), not MapKit's dark default. Forcing light
        // mode (above) plus a cream background handles that — and, crucially, we
        // do NOT lay a separate solid-cream overlay: a second instantly-loading
        // overlay defeats MapKit's tile retention, making it flash to cream on
        // every zoom/pan instead of smoothly holding the previous imagery while
        // new tiles load. With just a background colour, MapKit keeps the old
        // tiles (scaled) during transitions, the way the BNG renderer does.
        map.backgroundColor = UIColor(red: 0xF2/255, green: 0xEF/255, blue: 0xE9/255, alpha: 1)

        // Custom loader so tiles land in the shared managed disk cache and so we
        // can overzoom past the tileset's max (iOS won't auto-upscale like
        // Android). Crucially it never returns nil/an error to MapKit — that is
        // what makes MKTileOverlay flicker on every zoom/pan; misses return a
        // transparent tile instead (see `CachingTileOverlay`).
        context.coordinator.installOverlay(on: map, for: self)

        LocationPermissionManager.shared.requestIfNeeded()
        context.coordinator.sync(annotationsOn: map, entries: entries)
        context.coordinator.lastFocus = focusState
        // Coming back from another layer: restore the shared viewport instead of
        // refitting to all pins, so zoom/centre survive a layer switch. Only .all
        // adopts the region; city/heading still snap to the user.
        if focusState == .all, let region = visibleRegion {
            map.setRegion(region, animated: false)
        } else {
            context.coordinator.applyFocus(focusState, on: map, animated: false)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        // Switching tilesets (or changing anything that alters tile requests —
        // key, subdomains, zoom range, tile size) reuses this same MKMapView, so
        // the overlay has to be rebuilt. Renames don't qualify, hence comparing
        // the tile config rather than the whole layer.
        if context.coordinator.installedTileConfig != Coordinator.tileConfig(of: layer) {
            context.coordinator.installOverlay(on: map, for: self)
        }
        context.coordinator.sync(annotationsOn: map, entries: entries)
        if context.coordinator.lastFocus != focusState {
            context.coordinator.lastFocus = focusState
            context.coordinator.applyFocus(focusState, on: map, animated: true)
        }
        // Reporting the anchor writes SwiftUI @State; deferring off the current
        // view-update pass avoids "Modifying state during view update".
        DispatchQueue.main.async { context.coordinator.reportPopoverAnchor(on: map) }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RasterTileMapView
        var tileOverlay: MKTileOverlay?
        /// Tile config of the installed overlay — everything that changes what
        /// bytes a tile request produces (but not the display name).
        var installedTileConfig: String?
        var lastFocus: MapFocusState = .all

        static func tileConfig(of layer: StandardTileSource) -> String {
            [layer.urlTemplate, layer.apiKey ?? "", layer.subdomains ?? "",
             String(layer.tilePixelSize ?? 256),
             String(layer.minZoom), String(layer.maxZoom)].joined(separator: "|")
        }
        private var annotationsByID: [UUID: SpotAnnotation] = [:]
        /// Set when focus flips to `.all` because the user panned out of a follow
        /// mode, so the next `.all` apply keeps the current viewport instead of
        /// refitting to all pins (matching Apple Maps' free-look).
        private var suppressRefit = false
        /// Last anchor sent to SwiftUI, to skip redundant per-frame writes.
        private var reportedAnchor: CGPoint?

        init(_ parent: RasterTileMapView) { self.parent = parent }

        // MARK: Overlay

        /// Build the tile overlay for `view`'s current tileset and install it,
        /// removing any previous one. Called on first layout and whenever the
        /// selected layer changes (the MKMapView itself is reused across layers).
        func installOverlay(on map: MKMapView, for view: RasterTileMapView) {
            if let old = tileOverlay { map.removeOverlay(old) }
            let overlay = CachingTileOverlay(layer: view.layer)
            overlay.canReplaceMapContent = true
            overlay.minimumZ = view.layer.minZoom
            // Raise the ceiling above the tileset's native max so MapKit actually
            // *requests* the overzoom levels. Without this, MapKit's tile model
            // caps requests at the native max and never asks `CachingTileOverlay`
            // for the deeper tiles it upscales — so zooming past max stays blank
            // until you zoom back out (which caches the native tile), then in
            // again. The loader turns these deep requests into upscaled crops of
            // the deepest ancestor.
            overlay.maximumZ = view.layer.maxZoom + 4
            tileOverlay = overlay
            installedTileConfig = Self.tileConfig(of: view.layer)
            map.addOverlay(overlay, level: .aboveLabels)
        }

        // MARK: Rendering

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let spot = annotation as? SpotAnnotation else { return nil } // skip user dot
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: SpotAnnotationView.reuseID, for: annotation) as! SpotAnnotationView
            view.configure(with: spot)
            return view
        }

        // MARK: Selection

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let spot = view.annotation as? SpotAnnotation else { return }
            parent.selectedItemID = spot.item.id
            // The app drives detail from `selectedItemID`; don't keep MapKit's own
            // selection (no callout), so re-tapping the same pin fires again.
            mapView.deselectAnnotation(view.annotation, animated: false)
        }

        // MARK: Region / follow

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // Fires continuously while panning/zooming — keep the popover glued.
            reportPopoverAnchor(on: mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.visibleRegion = mapView.region
            reportPopoverAnchor(on: mapView)
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // MapKit drops to `.none` when the user pans out of a follow mode; mirror
            // that back to `.all` without refitting (free-look), like Apple Maps.
            // Deferred: this can fire while MapKit reacts to a mode change we set
            // from updateUIView, so writing @State inline would be a view-update
            // mutation.
            guard mode == .none, parent.focusState != .all else { return }
            suppressRefit = true
            DispatchQueue.main.async { [weak self] in self?.parent.focusState = .all }
        }

        // MARK: Annotations

        func sync(annotationsOn map: MKMapView, entries: [LocationEntry]) {
            let wanted = Set(entries.map(\.item.id))
            for (id, ann) in annotationsByID where !wanted.contains(id) {
                map.removeAnnotation(ann)
                annotationsByID[id] = nil
            }
            for entry in entries {
                guard let loc = entry.item.location else { continue }
                if let existing = annotationsByID[entry.item.id] {
                    existing.coordinate = CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
                    existing.update(from: entry)
                    (map.view(for: existing) as? SpotAnnotationView)?.configure(with: existing)
                } else {
                    let ann = SpotAnnotation(entry: entry)
                    annotationsByID[entry.item.id] = ann
                    map.addAnnotation(ann)
                }
            }
        }

        // MARK: Focus

        func applyFocus(_ state: MapFocusState, on map: MKMapView, animated: Bool) {
            switch state {
            case .all:
                map.setUserTrackingMode(.none, animated: animated)
                if suppressRefit {
                    suppressRefit = false   // user panned here: keep the viewport
                } else {
                    let pins = map.annotations.filter { $0 is SpotAnnotation }
                    if !pins.isEmpty { map.showAnnotations(pins, animated: animated) }
                }
            case .city:
                LocationPermissionManager.shared.requestIfNeeded()
                map.setUserTrackingMode(.follow, animated: animated)
            case .heading:
                LocationPermissionManager.shared.requestIfNeeded()
                map.setUserTrackingMode(.followWithHeading, animated: animated)
            }
        }

        // MARK: Popover anchor

        func reportPopoverAnchor(on map: MKMapView) {
            guard let cb = parent.onPopoverAnchorChange else { return }
            // No popover target → nothing to glue; don't churn @State every frame.
            guard let id = parent.popoverItemID, let ann = annotationsByID[id] else {
                emit(nil, cb)
                return
            }
            let p = map.convert(ann.coordinate, toPointTo: map)
            // Off-screen (with a little slack for the balloon) → no anchor.
            emit(map.bounds.insetBy(dx: -20, dy: -60).contains(p) ? p : nil, cb)
        }

        /// Send an anchor only when it actually changed (sub-pixel dedupe).
        private func emit(_ anchor: CGPoint?, _ cb: (CGPoint?) -> Void) {
            let same: Bool
            switch (anchor, reportedAnchor) {
            case (nil, nil): same = true
            case let (a?, b?): same = abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
            default: same = false
            }
            guard !same else { return }
            reportedAnchor = anchor
            cb(anchor)
        }
    }
}

/// An `MKTileOverlay` that fetches through `TileFetcher` (so tiles land in the
/// shared managed disk cache) and adds two things MapKit won't do for a custom
/// raster tileset:
///
///  * **Overzoom.** Past the tileset's deepest zoom, iOS leaves tiles blank
///    (unlike Android, which upscales). We fetch the deepest ancestor and
///    upscale the relevant crop, so zooming in stays filled.
///  * **Flicker-free misses.** Returning nil/an error from `loadTile` makes
///    MapKit blink the tile on every redraw (the documented cause of the
///    zoom/pan flashing). We always return valid data — a transparent tile for
///    genuine misses — so the map stays calm and the cream background shows
///    through where there's no imagery.
final class CachingTileOverlay: MKTileOverlay {
    private let fetcher: TileFetcher
    /// Deepest zoom the tileset publishes; past this we overzoom from ancestors.
    private let maxNativeZ: Int
    /// Tile edge in pixels (256, or 512 for retina tilesets). Must match what
    /// the server actually serves or everything renders at the wrong scale.
    private let pixelSize: Int

    /// A fully transparent tile, returned for misses instead of an error.
    private let blankTile: Data

    init(layer: StandardTileSource) {
        fetcher = TileFetcher(urlTemplate: layer.urlTemplate,
                              apiKey: layer.apiKey ?? "",
                              cacheNamespace: layer.cacheNamespace,
                              legacyCacheNamespace: layer.legacyCacheNamespace,
                              subdomains: layer.subdomainTokens,
                              healthSourceID: layer.id.uuidString,
                              healthSourceName: layer.name)
        maxNativeZ = layer.maxZoom
        pixelSize = layer.tilePixelSize ?? 256
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        blankTile = UIGraphicsImageRenderer(
            size: CGSize(width: pixelSize, height: pixelSize),
            format: format).pngData { _ in }
        super.init(urlTemplate: layer.urlTemplate)
        tileSize = CGSize(width: pixelSize, height: pixelSize)
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        Task {
            let data = await self.tileData(z: path.z, x: path.x, y: path.y)
            // Never hand back nil/an error — that makes MapKit flicker the tile
            // on every redraw. Fall back to a transparent tile for misses.
            result(data ?? self.blankTile, nil)
        }
    }

    /// A tile's bytes — the native tile within the published range, or, past it,
    /// an upscaled crop of the deepest native ancestor. Returns nil only when
    /// even the ancestor is unavailable (offshore / not-yet-cached), which the
    /// caller turns into a transparent tile.
    private func tileData(z: Int, x: Int, y: Int) async -> Data? {
        if z <= maxNativeZ {
            return await fetcher.data(z: z, x: x, y: y)
        }
        // Overzoom: the ancestor at maxNativeZ that contains this tile, and the
        // sub-quadrant of it that this tile maps to.
        let k = z - maxNativeZ
        let ax = x >> k, ay = y >> k
        guard let ancestor = await fetcher.data(z: maxNativeZ, x: ax, y: ay) else { return nil }
        return upscaledCrop(ancestor, subX: x - (ax << k), subY: y - (ay << k), scale: 1 << k)
    }

    /// Crop the `1/scale`-sized (subX, subY) cell out of a source tile and
    /// stretch it to a full tile. Runs off the main actor (called from the
    /// loadTile Task) so the decode/redraw doesn't block UI.
    private func upscaledCrop(_ data: Data, subX: Int, subY: Int, scale: Int) -> Data? {
        guard let src = UIImage(data: data)?.cgImage else { return nil }
        let cellW = max(1, src.width / scale)
        let cellH = max(1, src.height / scale)
        let crop = CGRect(x: subX * cellW, y: subY * cellH, width: cellW, height: cellH)
        guard let cell = src.cropping(to: crop) else { return nil }
        let size = CGSize(width: pixelSize, height: pixelSize)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            UIImage(cgImage: cell).draw(in: CGRect(origin: .zero, size: size))
        }.pngData()
    }
}
