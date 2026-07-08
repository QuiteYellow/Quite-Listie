//
//  BNGMapView.swift
//  QuiteListie
//
//  Fully native EPSG:27700 (British National Grid) slippy-map renderer.
//
//  Great Britain is a bounded flat grid, and the tiles are already published in
//  27700, so we render them at their native resolution with zero reprojection.
//  Rather than force a map into UIKit's single-large-image tiling stack
//  (UIScrollView + CATiledLayer, which caps out and blanks once the zoom
//  transform gets large), this is a proper slippy map — the same model Leaflet
//  and MapKit use internally:
//
//    * Map state is a centre (BNG metres) + a continuous resolution (m/point).
//    * Each layout picks the integer tile level nearest the current resolution,
//      lays out a grid of 256px CALayer tiles for the visible range, and sizes
//      them to the fractional zoom. Missing tiles show an upscaled slice of a
//      cached coarser ancestor (via contentsRect) so the map never blanks.
//    * Pan / pinch / momentum / double-tap are driven directly, so there is no
//      transformed-layer size ceiling — zoom runs the full 896 m/px → sub-metre
//      range.
//
//  Pins and the user-location dot live in a non-zooming overlay and are
//  repositioned from BNG → screen each frame, keeping a constant size.
//

import SwiftUI
import MapKit
import CoreLocation
import Combine

// MARK: - SwiftUI wrapper

/// SwiftUI wrapper for the native EPSG:27700 slippy map.
struct BNGMapView: UIViewRepresentable {
    let entries: [LocationEntry]
    let source: CustomTileSource
    let muted: Bool
    @Binding var selectedItemID: UUID?
    @Binding var visibleRegion: MKCoordinateRegion?
    @Binding var focusState: MapFocusState
    /// The item a popover is currently anchored to (iPad/Mac), or nil.
    var popoverItemID: UUID? = nil
    /// Reports that pin's live screen position so the parent can anchor a
    /// SwiftUI popover to it and keep it glued as the map moves.
    var onPopoverAnchorChange: ((CGPoint?) -> Void)? = nil

    func makeUIView(context: Context) -> SlippyMapView {
        let view = SlippyMapView(source: source)
        view.onSelect = { id in selectedItemID = id }
        view.onRegionChange = { region in visibleRegion = region }
        view.onUserPannedAway = {
            if focusState != .all { focusState = .all }
        }
        view.onPopoverAnchorChange = onPopoverAnchorChange
        view.popoverItemID = popoverItemID
        context.coordinator.lastFocus = focusState
        // Driving the view from makeUIView runs inside SwiftUI's update pass, so
        // any state callback (region / popover anchor) it triggers must be
        // deferred — writing @State synchronously here is undefined behavior.
        view.applyingRepresentableUpdate {
            view.setEntries(entries)
            view.applyInitialFocus(focusState, adopting: visibleRegion)
        }
        return view
    }

    func updateUIView(_ view: SlippyMapView, context: Context) {
        view.onPopoverAnchorChange = onPopoverAnchorChange
        // Same as makeUIView: this whole block runs during SwiftUI's view update,
        // so defer the state callbacks these calls fire (region, popover anchor)
        // to the next runloop tick instead of mutating @State mid-update.
        view.applyingRepresentableUpdate {
            view.updateSource(source)
            view.setEntries(entries)
            view.setPopoverItemID(popoverItemID)
            if context.coordinator.lastFocus != focusState {
                context.coordinator.lastFocus = focusState
                view.applyFocus(focusState, animated: true)
            }
        }
    }

    static func dismantleUIView(_ view: SlippyMapView, coordinator: Coordinator) {
        view.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastFocus: MapFocusState = .all
    }
}

// MARK: - Tile identity

private struct TileID: Hashable {
    let z: Int, x: Int, y: Int
}

// MARK: - Slippy map view

final class SlippyMapView: UIView, UIGestureRecognizerDelegate {
    var onSelect: ((UUID) -> Void)?
    var onRegionChange: ((MKCoordinateRegion) -> Void)?
    var onUserPannedAway: (() -> Void)?
    /// Reports the screen position of the pin the popover is anchored to (or nil).
    var onPopoverAnchorChange: ((CGPoint?) -> Void)?
    /// The item id the popover is anchored to (iPad/Mac).
    var popoverItemID: UUID?
    private var reportedAnchor: CGPoint?

    /// True only while SwiftUI is executing make/updateUIView. Callbacks that
    /// write SwiftUI @State (region, popover anchor) are deferred off this window,
    /// because mutating observed state during a view update is undefined behavior
    /// (and floods the log with "Modifying state during view update").
    private var isApplyingRepresentableUpdate = false

    /// Run a block that drives the view from make/updateUIView, deferring any
    /// SwiftUI state callbacks it triggers to the next runloop tick. Gesture- and
    /// display-link-driven reports still fire synchronously (frame-perfect).
    func applyingRepresentableUpdate(_ body: () -> Void) {
        isApplyingRepresentableUpdate = true
        body()
        isApplyingRepresentableUpdate = false
    }

    /// Emit a SwiftUI-state callback, deferring it a tick if we're mid view-update.
    private func emitToSwiftUI(_ block: @escaping () -> Void) {
        if isApplyingRepresentableUpdate {
            DispatchQueue.main.async(execute: block)
        } else {
            block()
        }
    }

    // Tile grid geometry (from the source's WMTS matrix, or BNG defaults).
    private var matrix: BNGTileMatrix
    private var store: BNGTileStore

    // Map state.
    private var centerE: Double = 400_000
    private var centerN: Double = 500_000
    /// Metres per point. Small = zoomed in.
    private var resolution: Double = 100
    /// Map content rotation, radians clockwise. 0 = north up. Non-zero only in
    /// (or after) heading-follow mode, so the direction faced points up.
    private var rotation: Double = 0

    /// Current follow/focus mode, mirrored from the SwiftUI binding.
    private var focus: MapFocusState = .all
    /// Apple-Maps-like follow zoom (metres/point) used by city mode.
    private let followResolution: Double = 2.5
    /// Heading-follow zooms in a little tighter (like Apple Maps' driving view).
    private let headingResolution: Double = 1.5
    /// When entering `.all` because the user panned (not via the button), keep
    /// the current viewport + rotation instead of refitting/resetting north.
    private var suppressRefitOnAll = false

    // Pinch gesture: we transform the tile layer on the GPU during the gesture
    // and only re-tile once it ends (the reference slippy-map technique —
    // re-tiling every event is what makes pinch jumpy/fast under load). The
    // transform tracks the moving two-finger centroid (so pinch + pan together
    // stay glued) and carries the current rotation (so heading mode survives a
    // pinch).
    private var pinchCentroid0: CGPoint = .zero
    private var pinchMapAnchor: (e: Double, n: Double) = (0, 0)
    private var pinchBaseRes: Double = 0
    private var userDotPinchBase: CGPoint?
    /// Last centroid/scale seen while ≥2 fingers were down. When a finger lifts to
    /// end the pinch, `location(in:)` snaps to the remaining touch — we settle from
    /// these instead so the map doesn't lurch on release.
    private var pinchLastCentroid: CGPoint = .zero
    private var pinchLastScale: CGFloat = 1
    /// When the last pinch ended, so a lingering finger can't immediately hijack
    /// the 1-finger pan and drag the map (the post-pinch "bounce back").
    private var lastPinchEndTime: CFTimeInterval = 0
    /// True while a pinch is live, so layout doesn't reset the tile layer's
    /// frame/transform out from under the gesture.
    private var isPinching = false

    /// Accumulated translation of the in-progress scroll-to-zoom gesture, so each
    /// event zooms by its own delta (trackpad / mouse wheel on Mac & iPad).
    private var scrollZoomLastY: CGFloat = 0

    // Tile layers currently placed, and which of them hold their real image
    // (vs. a temporary upscaled-ancestor placeholder).
    private let tileHost = CALayer()
    private var tileLayers: [TileID: CALayer] = [:]
    private var realTiles: Set<TileID> = []
    /// Tiles we've already kicked off a fetch for, so a pan doesn't re-request
    /// the same (or a permanently-empty, e.g. offshore) tile every frame. Reset
    /// when the tile leaves view, so revisiting retries.
    private var requested: Set<TileID> = []

    // Overlay for constant-size pins + user dot.
    private let overlay = PassthroughView()
    private let userDot = BNGUserDotView()
    private var entries: [LocationEntry] = []
    private var pinViews: [UUID: BNGPinView] = [:]
    private var userBNG: (e: Double, n: Double)?

    private var source: CustomTileSource
    private var didInitialLayout = false
    private var pendingInitialFocus: (MapFocusState, MKCoordinateRegion?)?

    // Animation / momentum driver.
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private enum Motion { case idle, momentum, zoom }
    private var motion: Motion = .idle
    private var velE = 0.0, velN = 0.0                       // momentum, BNG m/s
    private var zoomFromRes = 0.0, zoomToRes = 0.0            // zoom animation
    private var zoomStart: CFTimeInterval = 0
    private let zoomDuration: CFTimeInterval = 0.25
    private var zoomAnchorScreen: CGPoint = .zero
    private var zoomAnchorBNG: (e: Double, n: Double) = (0, 0)
    // Heading-follow rotation is eased toward the compass on the display link so
    // it's smooth at the display refresh rate rather than stepping at the (much
    // slower, noisy) heading-update rate. Only the GPU transform + pins move each
    // frame; tiles are re-laid only when rotation drifts past a threshold.
    private var isHeadingFollowing = false
    private var targetRotation = 0.0
    private var lastTiledRotation = 0.0
    private var lastHeadingDeg: Double?

    private var locationCancellable: AnyCancellable?
    private var headingCancellable: AnyCancellable?

    // Edge swipe-back coexists with map panning: the map's pan REQUIRES the nav
    // controller's *edge* pop gesture to fail (edge drag → back, elsewhere → pan).
    // iOS 26's `interactiveContentPopGestureRecognizer` is a *full-content*
    // back-swipe (recognizes a left drag anywhere), which can't coexist with a
    // pannable map — so it's disabled outright; the edge gesture still gives us
    // swipe-back. `swipeBackNav` is kept to re-assert that disable on layout.
    private weak var mapPan: UIPanGestureRecognizer?
    private weak var swipeBackNav: UINavigationController?
    private var didLinkSwipeBack = false

    init(source: CustomTileSource) {
        self.source = source
        self.matrix = source.validated?.matrix ?? .bngDefault
        self.store = BNGTileStore(source: source)
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 0xF2/255, green: 0xEF/255, blue: 0xE9/255, alpha: 1)
        clipsToBounds = true

        // Don't mask to bounds — the view itself clips, and letting buffer tiles
        // overflow means a pinch-out transform reveals them instead of blank edges.
        tileHost.masksToBounds = false
        layer.addSublayer(tileHost)

        overlay.frame = bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(overlay)
        overlay.addSubview(userDot)
        userDot.isHidden = true

        resolution = matrix.resolutions.first ?? 896
        addGestures()
        observeLocation()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func teardown() {
        stopDisplayLink()
        locationCancellable = nil
        headingCancellable = nil
        store.clear()
    }

    // MARK: Navigation swipe-back interop

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { linkSwipeBack() }
    }

    /// Keep edge swipe-back working alongside map panning. The map's pan requires
    /// the *edge* pop gesture to fail (edge drag → back, elsewhere → pan). iOS 26's
    /// full-content back-swipe recognizes a left drag anywhere, so it can't coexist
    /// with panning — it's disabled instead (the edge gesture still gives us back).
    private func linkSwipeBack() {
        guard !didLinkSwipeBack, window != nil, let pan = mapPan else { return }

        // The nav controller is found by walking DOWN from the key window's root
        // (handling split / tab / presented / children); the responder-chain walk
        // up from a UIViewRepresentable is unreliable with SwiftUI containment,
        // especially a collapsed NavigationSplitView on iPhone.
        guard let nav = Self.findNavigationController() else { return }

        swipeBackNav = nav
        if let pop = nav.interactivePopGestureRecognizer {
            pan.require(toFail: pop)   // durable: edge gesture, dies with mapPan
        }
        assertContentSwipeDisabled()
        didLinkSwipeBack = true
    }

    /// Disable iOS 26's full-content back-swipe (incompatible with map panning).
    /// Re-called from layoutSubviews since SwiftUI re-enables it on layout passes.
    private func assertContentSwipeDisabled() {
        if #available(iOS 26.0, *) {
            swipeBackNav?.interactiveContentPopGestureRecognizer?.isEnabled = false
        }
    }

    /// Find the active navigation controller by walking down from the key window's
    /// root view controller (split → tab → presented → children → self).
    private static func findNavigationController() -> UINavigationController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?.rootViewController
        return findNav(in: root)
    }

    private static func findNav(in vc: UIViewController?) -> UINavigationController? {
        if let split = vc as? UISplitViewController {
            for child in split.viewControllers {
                if let nav = findNav(in: child) { return nav }
            }
        }
        if let tab = vc as? UITabBarController, let sel = tab.selectedViewController {
            if let nav = findNav(in: sel) { return nav }
        }
        if let presented = vc?.presentedViewController, let nav = findNav(in: presented) { return nav }
        for child in vc?.children ?? [] {
            if let nav = findNav(in: child) { return nav }
        }
        if let nav = vc as? UINavigationController { return nav }
        return vc?.navigationController
    }

    // MARK: Geometry

    private var midX: CGFloat { bounds.midX }
    private var midY: CGFloat { bounds.midY }

    /// North-up content position of a BNG point (before rotation is applied).
    private func screen(e: Double, n: Double) -> CGPoint {
        CGPoint(x: midX + CGFloat((e - centerE) / resolution),
                y: midY + CGFloat((centerN - n) / resolution))
    }

    /// Actual on-screen position of a BNG point, including map rotation.
    private func displayPoint(e: Double, n: Double) -> CGPoint {
        rotate(screen(e: e, n: n), by: rotation)
    }

    private func bng(atScreen p: CGPoint) -> (e: Double, n: Double) {
        (centerE + Double(p.x - midX) * resolution,
         centerN - Double(p.y - midY) * resolution)
    }

    /// Rotate a point about the view centre by `angle` radians (clockwise).
    private func rotate(_ p: CGPoint, by angle: Double) -> CGPoint {
        guard angle != 0 else { return p }
        let cx = midX, cy = midY
        let dx = Double(p.x - cx), dy = Double(p.y - cy)
        let ca = cos(angle), sa = sin(angle)
        return CGPoint(x: cx + CGFloat(dx * ca - dy * sa),
                       y: cy + CGFloat(dx * sa + dy * ca))
    }

    /// Set the map rotation instantly (mode entry / reset), re-tiling for it.
    private func setRotation(_ r: Double) {
        rotation = r
        targetRotation = r
        lastTiledRotation = r
        isHeadingFollowing = false
        if !isPinching {
            applyRotationTransform()
            updateTiles()
        }
    }

    /// Apply the current rotation as the tile layer's base transform and move the
    /// pins to match — the cheap per-frame work during a heading-follow ease (no
    /// re-tiling). Tiles are re-laid separately when rotation drifts far enough.
    private func applyRotationTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tileHost.transform = CATransform3DMakeRotation(CGFloat(rotation), 0, 0, 1)
        CATransaction.commit()
        repositionPins()
        updateUserDotHeading()
    }

    /// Ease the map toward the compass heading on the display link, so rotation is
    /// smooth at the refresh rate instead of stepping at the heading-update rate.
    private func followHeading(to r: Double) {
        // Always turn the short way: keep the target within ±π of where we are.
        var target = r
        while target - rotation > .pi { target -= 2 * .pi }
        while target - rotation < -.pi { target += 2 * .pi }
        targetRotation = target
        isHeadingFollowing = true
        startDisplayLink()
    }

    private func updateUserDotHeading() {
        // The wedge points along the physical heading in screen space; the map's
        // current rotation is added so in heading mode it settles pointing up.
        userDot.setHeading(lastHeadingDeg.map { $0 + rotation * 180 / .pi })
    }

    private var minRes: Double { (matrix.resolutions.last ?? 1.75) / 4 }   // 4× overzoom past finest
    private var maxRes: Double { (matrix.resolutions.first ?? 896) * 4 }   // out past whole-GB

    private func clampRes(_ r: Double) -> Double { min(maxRes, max(minRes, r)) }

    private func clampCenter() {
        centerE = min(max(centerE, -50_000), 750_000)
        centerN = min(max(centerN, -50_000), 1_300_000)
    }

    /// Integer tile level whose native resolution is nearest the current display
    /// resolution (in log space), clamped to what the source provides.
    private func tileZoom() -> Int {
        var best = matrix.minZoom
        var bestDiff = Double.greatestFiniteMagnitude
        for z in matrix.minZoom...matrix.maxZoom {
            let d = abs(log2(matrix.resolutions[z] / resolution))
            if d < bestDiff { bestDiff = d; best = z }
        }
        return best
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Retry until the nav controller is reachable to link swipe-back; once
        // linked, keep the content swipe-back disabled (SwiftUI re-enables it).
        if !didLinkSwipeBack { linkSwipeBack() } else { assertContentSwipeDisabled() }
        // Never touch the tile layer's frame while a pinch/rotation owns its
        // transform — resetting frame mid-gesture fights it. Set bounds+position
        // directly (transform-safe) rather than frame.
        if isPinching { return }
        tileHost.bounds = CGRect(origin: .zero, size: bounds.size)
        tileHost.position = CGPoint(x: bounds.midX, y: bounds.midY)

        if !didInitialLayout {
            didInitialLayout = true
            if let (state, region) = pendingInitialFocus {
                pendingInitialFocus = nil
                applyFocus(state, animated: false, adopting: region)
            } else {
                applyFocus(.all, animated: false)
            }
        }
        updateTiles()
    }

    // MARK: Tile placement

    private func updateTiles() {
        // During a pinch the gesture owns the tile transform + pin positions on
        // the GPU; any stray re-tile (e.g. a location update landing mid-gesture)
        // would fight it and make the map/pins jump, snapping back only on release.
        if isPinching { return }
        guard bounds.width > 0, resolution > 0 else { return }
        let z = tileZoom()
        let resZ = matrix.resolutions[z]
        let tileMeters = Double(matrix.tileSize) * resZ

        // Viewport BNG bounds from the four screen corners un-rotated into
        // north-up content space (so a rotated viewport is fully covered),
        // padded by a tile so panning reveals ready tiles.
        let corners = [CGPoint(x: 0, y: 0),
                       CGPoint(x: bounds.width, y: 0),
                       CGPoint(x: 0, y: bounds.height),
                       CGPoint(x: bounds.width, y: bounds.height)]
        let ens = corners.map { bng(atScreen: rotate($0, by: -rotation)) }
        let eMin = ens.map(\.e).min()! - tileMeters
        let eMax = ens.map(\.e).max()! + tileMeters
        let nMin = ens.map(\.n).min()! - tileMeters
        let nMax = ens.map(\.n).max()! + tileMeters

        // Clamp the tile range to the grid: never below 0, and never past the
        // advertised MatrixWidth/Height (requests outside coverage are
        // guaranteed 404s).
        let originX = matrix.originX(at: z)
        let originY = matrix.originY(at: z)
        let txMin = max(0, Int(floor((eMin - originX) / tileMeters)))
        let tyMin = max(0, Int(floor((originY - nMax) / tileMeters)))
        var txMax = Int(floor((eMax - originX) / tileMeters))
        var tyMax = Int(floor((originY - nMin) / tileMeters))
        if let cols = matrix.columns(at: z) { txMax = min(txMax, cols - 1) }
        if let rows = matrix.rows(at: z) { tyMax = min(tyMax, rows - 1) }

        // Safety: never fan out to an unbounded grid (e.g. a degenerate resolution).
        if (txMax - txMin + 1) * (tyMax - tyMin + 1) > 800 { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // An empty range (viewport entirely off-grid) still falls through so the
        // stale-tile drop below clears what's no longer visible.
        var needed = Set<TileID>()
        if txMin <= txMax, tyMin <= tyMax {
            for ty in tyMin...tyMax {
                for tx in txMin...txMax {
                    let id = TileID(z: z, x: tx, y: ty)
                    needed.insert(id)
                    placeTile(id)
                }
            }
        }
        // Drop tiles no longer in view.
        for (id, layer) in tileLayers where !needed.contains(id) {
            layer.removeFromSuperlayer()
            tileLayers[id] = nil
            realTiles.remove(id)
            requested.remove(id)
        }

        CATransaction.commit()
        repositionPins()
    }

    private func tileFrame(_ id: TileID) -> CGRect {
        let resZ = matrix.resolutions[id.z]
        let tileMeters = Double(matrix.tileSize) * resZ
        let eLeft = matrix.originX(at: id.z) + Double(id.x) * tileMeters
        let nTop = matrix.originY(at: id.z) - Double(id.y) * tileMeters
        let topLeft = screen(e: eLeft, n: nTop)
        let sizePt = CGFloat(tileMeters / resolution)
        // Expand a touch so fractional positions don't leave hairline seams.
        return CGRect(x: topLeft.x, y: topLeft.y, width: sizePt, height: sizePt)
            .insetBy(dx: -0.5, dy: -0.5)
    }

    private func placeTile(_ id: TileID) {
        let layer = tileLayers[id] ?? {
            let l = CALayer()
            l.contentsGravity = .resize
            l.masksToBounds = true
            l.contentsScale = ql_displayScale
            // Kill every implicit animation: tiles must snap to their computed
            // position each frame (otherwise CoreAnimation cross-fades/morphs
            // every change — the "weird animate-in" and the source of the lag).
            // Only the explicit load fade below animates.
            let null = NSNull()
            l.actions = ["contents": null, "contentsRect": null, "position": null,
                         "bounds": null, "frame": null, "hidden": null,
                         "onOrderIn": null, "onOrderOut": null, "sublayers": null]
            tileHost.addSublayer(l)
            tileLayers[id] = l
            return l
        }()
        layer.frame = tileFrame(id)

        guard !realTiles.contains(id) else { return }

        if let img = store.cachedImage(z: id.z, x: id.x, y: id.y) {
            layer.contents = img.cgImage
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            realTiles.insert(id)
            return
        }
        // No real tile yet: show an upscaled slice of the best cached ancestor
        // so the position is never blank, and fetch the real one (once).
        if layer.contents == nil, let anc = bestAncestor(id) {
            layer.contents = anc.image.cgImage
            layer.contentsRect = anc.rect
        }
        guard !requested.contains(id) else { return }
        requested.insert(id)
        store.requestTile(z: id.z, x: id.x, y: id.y) { [weak self] z, x, y in
            guard let self else { return }
            let id = TileID(z: z, x: x, y: y)
            guard let layer = self.tileLayers[id],
                  let img = self.store.cachedImage(z: z, x: x, y: y) else { return }
            let hadPlaceholder = layer.contents != nil
            layer.contents = img.cgImage
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            self.realTiles.insert(id)
            // Blank → tile: gentle fade in. Placeholder → sharp tile: snap
            // (fading the layer would dim the ancestor already shown).
            if !hadPlaceholder {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.0
                fade.toValue = 1.0
                fade.duration = 0.15
                layer.add(fade, forKey: "fade")
            }
        }
    }

    /// The nearest cached coarser tile covering `id`, with the normalized
    /// sub-rectangle of it that corresponds to `id` (for CALayer.contentsRect).
    ///
    /// Computed geometrically (via each level's own origin and resolution)
    /// rather than by bit-shifting indices: WMTS neither guarantees a shared
    /// origin across levels nor exact power-of-two resolution steps, so index
    /// arithmetic only holds for OS-style pyramids.
    private func bestAncestor(_ id: TileID) -> (image: UIImage, rect: CGRect)? {
        let sizeC = Double(matrix.tileSize) * matrix.resolutions[id.z]
        let eLeft = matrix.originX(at: id.z) + Double(id.x) * sizeC
        let nTop = matrix.originY(at: id.z) - Double(id.y) * sizeC
        var az = id.z - 1
        while az >= matrix.minZoom {
            defer { az -= 1 }
            let sizeA = Double(matrix.tileSize) * matrix.resolutions[az]
            // Ancestor tile containing this tile's top-left corner. The epsilon
            // absorbs float error when the corner lies exactly on a tile edge.
            let ax = Int(floor((eLeft - matrix.originX(at: az)) / sizeA + 1e-9))
            let ay = Int(floor((matrix.originY(at: az) - nTop) / sizeA + 1e-9))
            guard ax >= 0, ay >= 0,
                  let img = store.cachedImage(z: az, x: ax, y: ay) else { continue }
            let fx = (eLeft - (matrix.originX(at: az) + Double(ax) * sizeA)) / sizeA
            let fy = ((matrix.originY(at: az) - Double(ay) * sizeA) - nTop) / sizeA
            let f = sizeC / sizeA
            // Usable only when the child sits fully inside this ancestor tile
            // (always true for aligned pyramids; may fail on odd ladders).
            guard fx >= -1e-6, fy >= -1e-6, fx + f <= 1 + 1e-6, fy + f <= 1 + 1e-6 else { continue }
            return (img, CGRect(x: max(0, fx), y: max(0, fy), width: min(1, f), height: min(1, f)))
        }
        return nil
    }

    // MARK: Pins / dot

    func setEntries(_ newEntries: [LocationEntry]) {
        entries = newEntries
        let wanted = Set(newEntries.map(\.item.id))
        for (id, view) in pinViews where !wanted.contains(id) {
            view.removeFromSuperview()
            pinViews.removeValue(forKey: id)
        }
        for entry in newEntries {
            guard let loc = entry.item.location else { continue }
            let view = pinViews[entry.item.id] ?? {
                let v = BNGPinView(entry: entry)
                v.onTap = { [weak self] in self?.onSelect?(entry.item.id) }
                overlay.insertSubview(v, belowSubview: userDot)
                pinViews[entry.item.id] = v
                return v
            }()
            view.configure(with: entry)
            let bng = BNGProjection.wgs84ToBNG(lat: loc.latitude, lon: loc.longitude)
            view.mapE = bng.e
            view.mapN = bng.n
        }
        repositionPins()
    }

    private func repositionPins() {
        // The pinch handler positions pins itself during a gesture; skip so a
        // location/heading update landing mid-pinch can't reset them to base.
        if isPinching { return }
        // Balloon anchors at its tip and extends upward, so pad the top a little
        // more when deciding what's on-screen.
        let cull = overlay.bounds.inset(by: UIEdgeInsets(top: -80, left: -60, bottom: -60, right: -60))
        for (_, view) in pinViews {
            guard let e = view.mapE, let n = view.mapN else { view.isHidden = true; continue }
            let p = displayPoint(e: e, n: n)
            // Only touch on-screen pins each frame — projecting is cheap, but
            // moving/hiding hundreds of off-screen views would not be.
            if cull.contains(p) {
                // Layer is anchored at the balloon tip, so position IS the point.
                view.layer.position = p
                if view.isHidden { view.isHidden = false }
            } else if !view.isHidden {
                view.isHidden = true
            }
        }
        if let u = userBNG {
            let p = displayPoint(e: u.e, n: u.n)
            userDot.center = p
            userDot.isHidden = !overlay.bounds.insetBy(dx: -30, dy: -30).contains(p)
        } else {
            userDot.isHidden = true
        }
        reportPopoverAnchor()
    }

    func setPopoverItemID(_ id: UUID?) {
        guard popoverItemID != id else { return }
        popoverItemID = id
        reportPopoverAnchor()
    }

    /// Emit the live screen position of the popover's pin (or nil) when it moves,
    /// so a SwiftUI popover in the parent stays glued to the balloon tip.
    private func reportPopoverAnchor() {
        var anchor: CGPoint?
        if let id = popoverItemID, let pin = pinViews[id],
           let e = pin.mapE, let n = pin.mapN {
            let p = displayPoint(e: e, n: n)
            if bounds.insetBy(dx: -20, dy: -60).contains(p) { anchor = p }
        }
        let same: Bool
        switch (anchor, reportedAnchor) {
        case (nil, nil): same = true
        case let (a?, b?): same = abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
        default: same = false
        }
        if !same {
            reportedAnchor = anchor
            let cb = onPopoverAnchorChange
            emitToSwiftUI { cb?(anchor) }
        }
    }

    private func observeLocation() {
        let mgr = LocationPermissionManager.shared
        mgr.requestIfNeeded()
        locationCancellable = mgr.$currentLocation
            .receive(on: RunLoop.main)
            .sink { [weak self] loc in
                guard let self else { return }
                self.userBNG = loc.map { BNGProjection.wgs84ToBNG(lat: $0.coordinate.latitude,
                                                                  lon: $0.coordinate.longitude) }
                // Follow the user in city/heading modes (keeping whatever zoom
                // the user has pinched to — don't reset resolution here).
                if (self.focus == .city || self.focus == .heading), let u = self.userBNG, !self.isPinching {
                    self.centerE = u.e
                    self.centerN = u.n
                    self.clampCenter()
                    self.updateTiles()
                } else {
                    self.repositionPins()
                }
            }
        headingCancellable = mgr.$currentHeading
            .receive(on: RunLoop.main)
            .sink { [weak self] heading in
                guard let self else { return }
                let deg = self.headingDegrees(heading)
                self.lastHeadingDeg = deg
                // In heading mode, ease the map so the faced direction points up.
                // (Easing on the display link, not snapping per heading update, is
                // what makes the spin smooth rather than jittery.)
                if self.focus == .heading, let deg, !self.isPinching {
                    self.followHeading(to: -deg * .pi / 180)
                }
                self.updateUserDotHeading()
            }
    }

    private func headingDegrees(_ h: CLHeading?) -> Double? {
        guard let h else { return nil }
        let deg = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        return deg >= 0 ? deg : nil
    }

    // MARK: Source / entries

    func updateSource(_ newSource: CustomTileSource) {
        guard newSource != source else { return }
        source = newSource
        matrix = newSource.validated?.matrix ?? .bngDefault
        store = BNGTileStore(source: newSource)
        // Swap the tiles in place — keep the exact centre / zoom / rotation so
        // switching layers passes the current view through unchanged.
        for (_, layer) in tileLayers { layer.removeFromSuperlayer() }
        tileLayers.removeAll()
        realTiles.removeAll()
        requested.removeAll()
        // Clamp only in case the new matrix has a different resolution range.
        resolution = clampRes(resolution)
        updateTiles()
        reportRegion()
    }

    // MARK: Focus

    func applyInitialFocus(_ state: MapFocusState, adopting region: MKCoordinateRegion?) {
        if didInitialLayout {
            applyFocus(state, animated: false, adopting: region)
        } else {
            pendingInitialFocus = (state, region)
        }
    }

    func applyFocus(_ state: MapFocusState, animated: Bool, adopting region: MKCoordinateRegion? = nil) {
        guard bounds.width > 0 else { return }
        stopDisplayLink()
        focus = state
        switch state {
        case .all:
            if suppressRefitOnAll {
                // Entered .all by panning: keep the current viewport and rotation
                // (free-look, like Apple Maps leaving heading-follow via a drag).
                suppressRefitOnAll = false
            } else {
                setRotation(0)
                if let region { setViewport(region) } else { fitAllPins() }
            }
        case .city:
            setRotation(0)
            centreOnUser()
        case .heading:
            centreOnUser()
            if let deg = headingDegrees(LocationPermissionManager.shared.currentHeading) {
                setRotation(-deg * .pi / 180)
            }
        }
        userDot.setEnlarged(focus == .heading)
        clampCenter()
        updateTiles()
        reportRegion()
    }

    /// Leave follow mode because the user interacted directly. Keeps the current
    /// viewport and (frozen) rotation; the toolbar icon returns to .all.
    private func exitFollow() {
        userDot.setEnlarged(false)
        guard focus != .all else { onUserPannedAway?(); return }
        focus = .all
        suppressRefitOnAll = true
        onUserPannedAway?()
    }

    private func fitAllPins() {
        let coords = entries.compactMap(\.item.location)
        guard !coords.isEmpty else { return }
        let pts = coords.map { BNGProjection.wgs84ToBNG(lat: $0.latitude, lon: $0.longitude) }
        let eMin = pts.map(\.e).min()!, eMax = pts.map(\.e).max()!
        let nMin = pts.map(\.n).min()!, nMax = pts.map(\.n).max()!
        centerE = (eMin + eMax) / 2
        centerN = (nMin + nMax) / 2
        let spanE = eMax - eMin, spanN = nMax - nMin
        if spanE < 1 && spanN < 1 {
            resolution = clampRes(4_000 / Double(max(bounds.width, bounds.height))) // ~4km window
        } else {
            let resE = spanE / Double(bounds.width)
            let resN = spanN / Double(bounds.height)
            resolution = clampRes(max(resE, resN) * 1.3)
        }
    }

    private func centreOnUser() {
        guard let u = userBNG else {
            LocationPermissionManager.shared.requestIfNeeded()
            return
        }
        centerE = u.e
        centerN = u.n
        // Heading-follow zooms in tighter than plain city-follow.
        resolution = clampRes(focus == .heading ? headingResolution : followResolution)
    }

    private func setViewport(_ region: MKCoordinateRegion) {
        let c = BNGProjection.wgs84ToBNG(lat: region.center.latitude, lon: region.center.longitude)
        centerE = c.e
        centerN = c.n
        let north = BNGProjection.wgs84ToBNG(lat: region.center.latitude + region.span.latitudeDelta / 2,
                                             lon: region.center.longitude)
        let south = BNGProjection.wgs84ToBNG(lat: region.center.latitude - region.span.latitudeDelta / 2,
                                             lon: region.center.longitude)
        let spanN = abs(north.n - south.n)
        if spanN > 1, bounds.height > 0 {
            resolution = clampRes(spanN / Double(bounds.height))
        }
    }

    // MARK: Region reporting

    private func reportRegion() {
        guard bounds.width > 0 else { return }
        // Bounding box of the (possibly rotated) viewport, in BNG then WGS84.
        let corners = [CGPoint(x: 0, y: 0),
                       CGPoint(x: bounds.width, y: 0),
                       CGPoint(x: 0, y: bounds.height),
                       CGPoint(x: bounds.width, y: bounds.height)]
        let lls = corners.map { c -> (lat: Double, lon: Double) in
            let en = bng(atScreen: rotate(c, by: -rotation))
            return BNGProjection.bngToWgs84(e: en.e, n: en.n)
        }
        let lats = lls.map(\.lat), lons = lls.map(\.lon)
        let cLL = BNGProjection.bngToWgs84(e: centerE, n: centerN)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: cLL.lat, longitude: cLL.lon),
            span: MKCoordinateSpan(
                latitudeDelta: abs(lats.max()! - lats.min()!),
                longitudeDelta: abs(lons.max()! - lons.min()!)))
        let cb = onRegionChange
        emitToSwiftUI { cb?(region) }
    }

    // MARK: Gestures

    private func addGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        // One finger pans; two-finger gestures belong to pinch alone, so the two
        // don't both shove the centre around at once.
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        mapPan = pan

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        // Scroll-to-zoom for pointer devices (Mac trackpad / Catalyst, iPad with a
        // trackpad or mouse). A pan recognizer restricted to *indirect* scroll
        // events with `maximumNumberOfTouches = 0` only fires for scrolls — never
        // for a finger drag — so it coexists with the 1-finger pan without either
        // stealing the other's gesture. MapKit does this for us; the native slippy
        // map has to opt in.
        let scrollZoom = UIPanGestureRecognizer(target: self, action: #selector(handleScrollZoom(_:)))
        scrollZoom.allowedScrollTypesMask = .all
        scrollZoom.maximumNumberOfTouches = 0
        scrollZoom.delegate = self
        addGestureRecognizer(scrollZoom)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // Block the 1-finger pan while a pinch is live or just ended, so a finger
        // lingering as the pinch ends can't drag the map (the "bounce back").
        if g === mapPan {
            if isPinching { return false }
            if CACurrentMediaTime() - lastPinchEndTime < 0.3 { return false }
        }
        return true
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            stopDisplayLink()
            exitFollow()
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            // Un-rotate the screen delta into north-up content space so panning
            // moves the map correctly even when rotated (heading free-look).
            let d = unrotateVector(dx: Double(t.x), dy: Double(t.y))
            centerE -= d.dx * resolution
            centerN += d.dy * resolution
            clampCenter()
            updateTiles()
        case .ended, .cancelled:
            let v = g.velocity(in: self)
            let d = unrotateVector(dx: Double(v.x), dy: Double(v.y))
            velE = -d.dx * resolution
            velN = d.dy * resolution
            if hypot(v.x, v.y) > 80 { startMomentum() } else { reportRegion() }
        default:
            break
        }
    }

    /// Rotate a screen-space vector by −rotation (into north-up content space).
    private func unrotateVector(dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        guard rotation != 0 else { return (dx, dy) }
        let ca = cos(-rotation), sa = sin(-rotation)
        return (dx * ca - dy * sa, dx * sa + dy * ca)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            stopDisplayLink()
            // NB: pinch does NOT exit follow — heading mode (and its rotation)
            // survives a pinch; only the zoom changes.
            isPinching = true
            pinchCentroid0 = g.location(in: self)
            pinchLastCentroid = pinchCentroid0
            pinchLastScale = 1
            // World point under the centroid (un-rotated to north-up, then BNG).
            pinchMapAnchor = bng(atScreen: rotate(pinchCentroid0, by: -rotation))
            pinchBaseRes = resolution
            for (_, pin) in pinViews where !pin.isHidden { pin.pinchBase = pin.layer.position }
            userDotPinchBase = userDot.isHidden ? nil : userDot.center
        case .changed:
            // A finger lifting to end the pinch snaps `location(in:)` to the
            // remaining touch (a ~100px centroid jump at unchanged scale). Ignore
            // any sub-2-finger frame so that lurch never reaches the map.
            guard g.numberOfTouches >= 2 else { return }
            // Transform the already-laid-out tiles on the GPU (no re-tiling, so
            // it's smooth however fast the fingers move). The two-finger centroid
            // is tracked, so a simultaneous pan moves the map too, and the
            // current rotation is baked in so heading mode is preserved. Every
            // point maps by the screen-space similarity
            //   S(p) = s·p + tt,  tt = currentCentroid − s·centroid0
            // which keeps the world point under the centroid glued to the
            // (moving) centroid. Tiles and pins share S, so they stay locked.
            let current = g.location(in: self)
            pinchLastCentroid = current
            pinchLastScale = g.scale
            let targetRes = clampRes(pinchBaseRes / Double(g.scale))
            let s = CGFloat(pinchBaseRes / targetRes)
            let ttx = current.x - s * pinchCentroid0.x
            let tty = current.y - s * pinchCentroid0.y
            let rho = CGFloat(rotation)
            let cosr = cos(rho), sinr = sin(rho)
            // tileHost's transform is relative to its anchor (view centre c) and
            // carries the rotation: linear part = s·Rot(ρ), translation adds the
            // (s−1)·c anchor term.
            let hostAff = CGAffineTransform(
                a: s * cosr, b: s * sinr, c: -s * sinr, d: s * cosr,
                tx: (s - 1) * midX + ttx, ty: (s - 1) * midY + tty)
            // Pins are already at their rotated screen positions and stay upright,
            // so they only take the screen-space similarity S (no rotation term).
            let pinAff = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: ttx, ty: tty)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tileHost.transform = CATransform3DMakeAffineTransform(hostAff)
            for (_, pin) in pinViews {
                guard let base = pin.pinchBase else { continue }
                pin.layer.position = base.applying(pinAff)
            }
            if let base = userDotPinchBase {
                userDot.center = base.applying(pinAff)
            }
            CATransaction.commit()
        case .ended, .cancelled:
            // Settle from the last 2-finger centroid/scale, not `g.location`/`scale`
            // at release — a lifting finger has already snapped those to the
            // remaining touch, which would commit the lurch we skip in `.changed`.
            let current = pinchLastCentroid
            let targetRes = clampRes(pinchBaseRes / Double(pinchLastScale))
            isPinching = false
            lastPinchEndTime = CACurrentMediaTime()
            for (_, pin) in pinViews { pin.pinchBase = nil }
            userDotPinchBase = nil
            resolution = targetRes
            // Keep the anchored world point under the (final) centroid: un-rotate
            // the centroid to north-up content space, then solve for centre.
            let u = rotate(current, by: -rotation)
            centerE = pinchMapAnchor.e - Double(u.x - midX) * resolution
            centerN = pinchMapAnchor.n + Double(u.y - midY) * resolution
            clampCenter()
            // Restore the tile layer to its base (rotation-only) transform.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tileHost.transform = CATransform3DMakeRotation(CGFloat(rotation), 0, 0, 1)
            CATransaction.commit()
            updateTiles()
            reportRegion()
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        exitFollow()
        animateZoom(to: clampRes(resolution / 2), anchor: g.location(in: self))
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        exitFollow()
        animateZoom(to: clampRes(resolution * 2), anchor: g.location(in: self))
    }

    /// Trackpad / mouse-wheel zoom. Each scroll event's vertical delta scales the
    /// resolution about the pointer, keeping the world point under the cursor
    /// fixed (like MapKit / Apple Maps: scroll up zooms in). Applied directly per
    /// event rather than animated — the scroll stream is already smooth.
    @objc private func handleScrollZoom(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            stopDisplayLink()
            exitFollow()
            scrollZoomLastY = 0
        case .changed:
            let y = g.translation(in: self).y
            let dy = y - scrollZoomLastY
            scrollZoomLastY = y
            guard dy != 0 else { return }
            // Scroll up (dy < 0) → zoom in (smaller resolution). ~0.4%/point.
            let target = clampRes(resolution * exp(Double(dy) * 0.006))
            guard abs(target - resolution) > 1e-9 else { return }
            // Hold the point under the pointer fixed: capture it un-rotated into
            // north-up content space, change resolution, then solve for centre.
            let anchorScreen = rotate(g.location(in: self), by: -rotation)
            let anchorBNG = bng(atScreen: anchorScreen)
            resolution = target
            centerE = anchorBNG.e - Double(anchorScreen.x - midX) * resolution
            centerN = anchorBNG.n + Double(anchorScreen.y - midY) * resolution
            clampCenter()
            updateTiles()
        case .ended, .cancelled:
            reportRegion()
        default:
            break
        }
    }

    // MARK: Animation driver

    private func startMomentum() {
        motion = .momentum
        startDisplayLink()
    }

    private func animateZoom(to target: Double, anchor: CGPoint) {
        guard abs(target - resolution) > 1e-6 else { return }
        motion = .zoom
        zoomFromRes = resolution
        zoomToRes = target
        // Work in north-up content space so the tapped screen point stays fixed
        // even when the map is rotated.
        zoomAnchorScreen = rotate(anchor, by: -rotation)
        zoomAnchorBNG = bng(atScreen: zoomAnchorScreen)
        zoomStart = CACurrentMediaTime()
        startDisplayLink()
    }

    private func startDisplayLink() {
        lastTick = CACurrentMediaTime()
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        motion = .idle
        isHeadingFollowing = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = max(1.0 / 120, now - lastTick)
        lastTick = now

        // `active` stays true while any animation still has work, so the link is
        // only torn down once rotation easing AND pan/zoom motion are done.
        var active = false

        // Heading-follow: ease rotation toward the compass each frame (smooth at
        // refresh rate). Only the GPU transform + pins move per frame; tiles are
        // re-laid just when rotation has drifted far enough to expose empty edges.
        if isHeadingFollowing {
            let k = 1 - exp(-dt * 12)   // ~0.08s time constant
            rotation += (targetRotation - rotation) * k
            if abs(targetRotation - rotation) < 0.0008 {
                rotation = targetRotation
                isHeadingFollowing = false
            } else {
                active = true
            }
            applyRotationTransform()
            if abs(rotation - lastTiledRotation) > .pi / 30 {   // ~6°
                lastTiledRotation = rotation
                updateTiles()
            }
        }

        switch motion {
        case .zoom:
            let t = min(1, (now - zoomStart) / zoomDuration)
            let eased = t * (2 - t) // ease-out
            // Interpolate resolution geometrically (perceptually even).
            resolution = zoomFromRes * pow(zoomToRes / zoomFromRes, eased)
            // Hold the tapped point fixed.
            centerE = zoomAnchorBNG.e - Double(zoomAnchorScreen.x - midX) * resolution
            centerN = zoomAnchorBNG.n + Double(zoomAnchorScreen.y - midY) * resolution
            clampCenter()
            updateTiles()
            if t >= 1 { motion = .idle; reportRegion() } else { active = true }

        case .momentum:
            velE *= exp(-dt * 5)
            velN *= exp(-dt * 5)
            centerE += velE * dt
            centerN += velN * dt
            clampCenter()
            updateTiles()
            if hypot(velE, velN) / resolution < 6 { motion = .idle; reportRegion() } else { active = true }

        case .idle:
            break
        }

        if !active { stopDisplayLink() }
    }
}

// MARK: - Tile store (off-main fetch + cache)

/// Off-main-actor owner of the tile fetch + in-memory cache. Fetches run on
/// detached tasks; `ready` fires on the main actor so tile layers can update.
private final class BNGTileStore: @unchecked Sendable {
    private let fetcher: TileFetcher
    private let cache = TileImageCache()
    private let lock = NSLock()
    private var inflight: Set<String> = []

    init(source: CustomTileSource) {
        // The key is already embedded in the tile URL, so no apiKey to inject.
        // Matrix identifiers make {z} substitute the WMTS TileMatrix name for
        // each level (falls back to the numeric zoom when absent — v3 sources).
        fetcher = TileFetcher(urlTemplate: source.zxyTemplate,
                              apiKey: "",
                              cacheNamespace: "src-\(source.cacheNamespace)",
                              legacyCacheNamespace: "src-\(source.legacyCacheNamespace)",
                              zoomIdentifiers: source.validated?.matrixIdentifiers,
                              healthSourceID: source.id.uuidString,
                              healthSourceName: source.name)
    }

    func cachedImage(z: Int, x: Int, y: Int) -> UIImage? {
        cache.image(z: z, x: x, y: y)
    }

    func clear() {
        cache.removeAll()
        lock.lock(); inflight.removeAll(); lock.unlock()
    }

    func requestTile(z: Int, x: Int, y: Int,
                     ready: @escaping @MainActor @Sendable (Int, Int, Int) -> Void) {
        let key = "\(z)/\(x)/\(y)"
        lock.lock()
        if inflight.contains(key) { lock.unlock(); return }
        inflight.insert(key)
        lock.unlock()

        Task.detached(priority: .userInitiated) { [self] in
            let image = await fetcher.fetchImage(z: z, x: x, y: y)
            finish(key)
            guard let image else { return }
            cache.set(z: z, x: x, y: y, image: UIImage(cgImage: image.cg))
            await MainActor.run { ready(z, x, y) }
        }
    }

    private func finish(_ key: String) {
        lock.lock(); inflight.remove(key); lock.unlock()
    }
}

// MARK: - Tile image cache (thread-safe LRU)

private final class TileImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: UIImage] = [:]
    private var order: [String] = []
    private let limit = 400

    func image(z: Int, x: Int, y: Int) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return map["\(z)/\(x)/\(y)"]
    }

    func set(z: Int, x: Int, y: Int, image: UIImage) {
        let key = "\(z)/\(x)/\(y)"
        lock.lock(); defer { lock.unlock() }
        if map[key] == nil { order.append(key) }
        map[key] = image
        if order.count > limit {
            let drop = order.removeFirst()
            map.removeValue(forKey: drop)
        }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll(); order.removeAll()
    }
}

// MARK: - Overlay views

/// Passes touches through to the map underneath except when a pin is hit.
private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// A map marker that hosts a `SpotAnnotationView` (an `MKMarkerAnnotationView`),
/// so the tint, glyph, shadow and shape are the exact Apple Maps balloon — no
/// reimplementation. This wrapper only owns positioning and tap handling.
///
/// Standalone (outside an MKMapView), `MKMarkerAnnotationView` self-positions so
/// its balloon *tip* sits at this wrapper's origin. So rather than guess an
/// anchor, we read the marker's laid-out frame, take its bottom-centre as the
/// tip, and pin the wrapper's layer anchor there — then `layer.position` places
/// the tip exactly on the map point at every zoom (no zoom-dependent drift).
final class BNGPinView: UIView {
    var onTap: (() -> Void)?
    /// Cached BNG position, so repositioning per frame is a plain projection.
    var mapE: Double?
    var mapN: Double?
    /// Map-point screen position captured at pinch start, to move the pin during
    /// the GPU-scaled pinch without re-projecting.
    var pinchBase: CGPoint?

    private let annotation: SpotAnnotation
    private let marker: SpotAnnotationView
    private var didAnchorToTip = false

    init(entry: LocationEntry) {
        annotation = SpotAnnotation(entry: entry)
        marker = SpotAnnotationView(annotation: annotation, reuseIdentifier: nil)
        marker.isUserInteractionEnabled = false
        marker.configure(with: annotation)
        if marker.bounds.width < 1 || marker.bounds.height < 1 {
            marker.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        }
        super.init(frame: marker.bounds)
        clipsToBounds = false
        addSubview(marker)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Once the marker has laid out, anchor our layer at the balloon tip
        // (bottom-centre of the marker's frame, in wrapper coordinates) so
        // layer.position == the map point. Preserve position across the anchor
        // change so nothing jumps; repositionPins sets the real point next.
        guard !didAnchorToTip, marker.frame.width > 1, bounds.width > 0 else { return }
        didAnchorToTip = true
        let mf = marker.frame
        let tip = CGPoint(x: mf.midX, y: mf.maxY)
        let pos = layer.position
        layer.anchorPoint = CGPoint(x: tip.x / bounds.width, y: tip.y / bounds.height)
        layer.position = pos
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The balloon renders above/around the wrapper's own bounds, so hit-test
        // the marker's actual frame (padded) rather than our bounds.
        marker.frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    func configure(with entry: LocationEntry) {
        if let loc = entry.item.location {
            annotation.coordinate = CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
        }
        annotation.update(from: entry)
        marker.configure(with: annotation)
    }

    @objc private func tapped() { onTap?() }
}

/// Blue user-location dot with an optional heading wedge.
final class BNGUserDotView: UIView {
    private let dot = UIView()
    private let wedge = CAShapeLayer()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        wedge.fillColor = UIColor.systemBlue.withAlphaComponent(0.35).cgColor
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 11, y: 11))
        path.addLine(to: CGPoint(x: 3, y: -6))
        path.addLine(to: CGPoint(x: 19, y: -6))
        path.close()
        wedge.path = path.cgPath
        wedge.isHidden = true
        layer.addSublayer(wedge)

        dot.frame = CGRect(x: 4, y: 4, width: 14, height: 14)
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = 7
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 3
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.3
        dot.layer.shadowRadius = 2
        addSubview(dot)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var headingRadians: CGFloat = 0
    private var enlarged = false

    func setHeading(_ degrees: CLLocationDirection?) {
        if let degrees, degrees >= 0 {
            wedge.isHidden = false
            headingRadians = CGFloat(degrees) * .pi / 180
        } else {
            wedge.isHidden = true
        }
        applyTransform()
    }

    /// Grow the dot (and its heading wedge) in heading-follow mode.
    func setEnlarged(_ on: Bool) {
        guard enlarged != on else { return }
        enlarged = on
        applyTransform()
    }

    private func applyTransform() {
        let s: CGFloat = enlarged ? 1.6 : 1.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DConcat(
            CATransform3DMakeScale(s, s, 1),
            CATransform3DMakeRotation(headingRadians, 0, 0, 1))
        CATransaction.commit()
    }
}

// MARK: - Helpers

private extension UIView {
    /// Display scale without touching the Catalyst-deprecated `UIScreen.main`.
    var ql_displayScale: CGFloat {
        let scale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        return scale > 0 ? scale : 2
    }
}
