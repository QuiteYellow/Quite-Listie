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

    func makeUIView(context: Context) -> SlippyMapHost {
        let host = SlippyMapHost(source: source)
        let view = host.map
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
        return host
    }

    func updateUIView(_ host: SlippyMapHost, context: Context) {
        let view = host.map
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

    static func dismantleUIView(_ host: SlippyMapHost, coordinator: Coordinator) {
        host.map.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastFocus: MapFocusState = .all
    }
}

// MARK: - Scroll edge effect host

/// Hosts the slippy map inside a scroll view that never scrolls.
///
/// iOS 26 keeps a title and toolbar glyphs legible over full-bleed content with
/// the scroll edge effect — the progressive blur "pocket" it draws into the top
/// and bottom of the *content*, not a background on the bar. UIKit only installs
/// it for content that registers as a scroll view, which is why `MKMapView` gets
/// one for free and a bare `UIView` renderer does not: the bars had nothing
/// behind them and the map ran straight through the title.
///
/// A scroll view with scrolling switched off and its content pinned to `bounds`
/// is inert — no pan gesture, no content offset, no bounce — but it is enough to
/// register, so both bars get the same treatment as the MapKit branch.
final class SlippyMapHost: UIScrollView {
    let map: SlippyMapView

    init(source: CustomTileSource) {
        map = SlippyMapView(source: source)
        super.init(frame: .zero)
        isScrollEnabled = false
        bounces = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        // Full-bleed content is the point: never inset it away from the bars,
        // or there is nothing under them for the effect to blur.
        contentInsetAdjustmentBehavior = .never
        // The map recognizes its own touches; don't let the scroll view sit on
        // them waiting to see whether a drag turns into a scroll.
        delaysContentTouches = false
        addSubview(map)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        map.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
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
    /// Whether the viewport is still an automatic fit to the pins rather than a
    /// framing the user chose. While it holds, a change to the entry set refits
    /// — which is what crops the map to a search's matches. Any direct
    /// manipulation clears it, so a view someone framed by hand is never yanked
    /// out from under them. This mirrors `MapCameraPosition.automatic`, which the
    /// MapKit renderer gets for free: it re-frames as content changes until the
    /// user takes the camera over.
    private var viewportIsAutoFit = true

    // Pinch gesture: we transform the tile layer on the GPU between commits
    // rather than re-tiling every event (the reference slippy-map technique —
    // re-tiling per event is what makes pinch jumpy/fast under load), and commit
    // the gesture into the map state each time it crosses a tile level, so the
    // level being zoomed into starts loading while the fingers are still down.
    // The transform tracks the moving two-finger centroid (so pinch + pan
    // together stay glued) and carries the current rotation (so heading mode
    // survives a pinch).
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
    /// True when the live pinch is a trackpad magnify rather than two fingers on
    /// glass. Mac Catalyst (and iPadOS with a trackpad) delivers those as
    /// `UIEventTypeTransform` events, which carry no `UITouch` objects at all, so
    /// the recognizer runs its entire life at `numberOfTouches == 0`. Both
    /// two-finger guards below have to stand down for it — the `>= 2` check in
    /// `.changed` would otherwise drop every update and leave the gesture a
    /// no-op, which is why trackpad pinch did nothing while every other gesture
    /// worked.
    private var pinchIsIndirect = false
    /// True while a pinch is live, so layout doesn't reset the tile layer's
    /// frame/transform out from under the gesture.
    private var isPinching = false
    /// The tile level the live pinch has laid out for, so it can tell when the
    /// gesture has scaled into a different one. Tracked separately from
    /// `laidOutZoom` because `updateTiles` may step out to a coarser level than
    /// the resolution asks for, and comparing against that would re-commit on a
    /// loop for the whole gesture.
    private var pinchTiledZoom = 0
    /// When the pinch last committed, so a scale hovering on a level boundary
    /// re-tiles at most a few times a second instead of every frame it wobbles.
    private var lastPinchRebase: CFTimeInterval = 0
    /// The recognizer's raw `scale` at the last commit. Live scale is measured
    /// from here rather than by writing `g.scale = 1`, because a trackpad
    /// magnify's scale is synthesized from accumulated `NSEvent` magnification
    /// and does not reliably take a write mid-gesture — and a reset that
    /// silently didn't stick re-applies the entire accumulated zoom on the next
    /// frame, which reads as a jolt at the level boundary and a runaway zoom
    /// after it. Reading an offset can't fail that way.
    private var pinchScaleBase: CGFloat = 1
    /// Rate of change of ln(resolution) through the pinch, per second, smoothed
    /// across events — the release value becomes the zoom glide. Measured here
    /// rather than read from `UIPinchGestureRecognizer.velocity` for the same
    /// reason the scroll-pan measures its own: that property is derived from a
    /// touch stream, and a trackpad magnify has no touches.
    private var pinchLogVel = 0.0
    private var pinchLastEvent: CFTimeInterval = 0
    private var pinchLastRes = 0.0

    /// Accumulated translation of the in-progress scroll-to-zoom gesture, so each
    /// event zooms by its own delta (trackpad / mouse wheel on Mac & iPad).
    private var scrollZoomLastY: CGFloat = 0

    /// Screen-space velocity of the in-progress trackpad scroll-pan, points/sec,
    /// smoothed across events. Measured here rather than read from the
    /// recognizer: `UIPanGestureRecognizer.velocity` is derived from a touch
    /// stream, and a scroll-driven pan has no touches — the same reason a
    /// trackpad pinch reports `numberOfTouches == 0`.
    private var scrollPanVelocity: CGPoint = .zero
    private var scrollPanLastEvent: CFTimeInterval = 0

    // Tile layers currently placed, and which of them hold their real image
    // (vs. a temporary upscaled-ancestor placeholder).
    private let tileHost = CALayer()
    /// The "paper" the grid sits on: `sheet` fills the sheet extent below the
    /// tiles and casts the drop shadow, `tileClip` holds the tiles and trims them
    /// to that same extent, `sheetEdge` draws the cut edge over their outermost
    /// pixel. All three are children of `tileHost`, so they pan, zoom and rotate
    /// with the map for free, and the shadow stays a single compositor primitive —
    /// with an explicit `shadowPath` it costs no offscreen pass per frame, which a
    /// `masksToBounds`-plus-`shadow` layer (or a SwiftUI `.shadow`) would.
    private let sheet = CALayer()
    private let tileClip = CALayer()
    /// The cut edge, as three concentric hairlines — dark outside, bright core,
    /// dark inside — so the boundary reads as the bevelled edge of a pane rather
    /// than a drawn border.
    ///
    /// Painted rather than a real `UIGlassEffect`. That effect only renders inside
    /// a `UIVisualEffectView`, which is a view and so cannot live in `tileHost`:
    /// it would give up the free pan, zoom and rotation these layers inherit, and
    /// would resample its backdrop every frame of a pan across a ring that can
    /// span the screen.
    private let sheetEdgeOuter = CALayer()
    private let sheetEdge = CALayer()
    private let sheetEdgeInner = CALayer()
    private var sheetEdges: [CALayer] { [sheetEdgeOuter, sheetEdge, sheetEdgeInner] }
    /// Low-detail coastline for everywhere the imagery doesn't reach. It sits
    /// *above* the paper and below the tiles: the sheet extent is the projection's
    /// bounds, not Great Britain, so a layer behind the paper would be hidden over
    /// the Irish Sea, the Channel and the whole blank band where imagery stops.
    private let world = CAShapeLayer()
    /// Corner rounding of the sheet, in points — screen-space, so the corner reads
    /// the same at every zoom. Matches the radius the map's own controls use.
    private static let sheetCornerRadius: CGFloat = 12

    /// Sea, land and coast tones, sampled from the tile imagery so the surround
    /// reads as a continuation of the map rather than a frame around it.
    ///
    /// Deliberately fixed rather than dynamic: the imagery has no dark variant, so
    /// a surround that followed the interface style would put a hard light/dark
    /// seam along the sheet edge in dark mode.
    ///
    /// These are sRGB. Sampling the imagery off a screenshot gives values in the
    /// *display's* space — on a wide-gamut monitor the sea read D2E9FB, which as
    /// sRGB is a visibly different colour from the tile it came from.
    ///
    /// Land is a neutral grey rather than the imagery's land tone on purpose. The
    /// imagery restyles land as coverage runs out — pale green at low zoom, flat
    /// white further in — so any single colour picked to match it is wrong at some
    /// zoom. Grey doesn't try: it reads as "outside the data", which is what it is,
    /// and the sheet edge becomes a deliberate boundary rather than a mismatch.
    private static let seaColor = UIColor(red: 0xC7/255, green: 0xEA/255, blue: 0xFC/255, alpha: 1)
    private static let landColor = UIColor(red: 0xDF/255, green: 0xE3/255, blue: 0xE6/255, alpha: 1)
    private static let coastColor = UIColor(red: 0xBA/255, green: 0xC1/255, blue: 0xC7/255, alpha: 1)
    private var tileLayers: [TileID: CALayer] = [:]
    private var realTiles: Set<TileID> = []
    /// Tiles we've already kicked off a fetch for, so a pan doesn't re-request
    /// the same (or a permanently-empty, e.g. offshore) tile every frame. Reset
    /// when the tile leaves view, so revisiting retries.
    private var requested: Set<TileID> = []
    /// The level the last `updateTiles` actually laid out.
    private var laidOutZoom: Int?
    /// Finished tiles from the level we just left, kept beneath the current grid
    /// until it has pictures of its own. Zooming *in* needs none of this — the
    /// coarser level is already cached, and `bestCachedAncestor` upscales it into
    /// place — but zooming out has nothing coarser to fall back on, so without a
    /// backdrop each level change flashes bare paper. This matters much more now
    /// that a pinch changes level while it is still running.
    private var staleTiles: [TileID: CALayer] = [:]

    // Overlay for constant-size pins + user dot.
    private let overlay = PassthroughView()
    private let userDot = BNGUserDotView()
    private var entries: [LocationEntry] = []
    /// Ids of the entries that currently have a location, so `setEntries` can
    /// tell a changed pin set apart from the same pins arriving again.
    private var placedEntryIDs: Set<UUID> = []
    private var pinViews: [UUID: BNGPinView] = [:]
    private var userBNG: (e: Double, n: Double)?

    private var source: CustomTileSource
    private var didInitialLayout = false
    private var pendingInitialFocus: (MapFocusState, MKCoordinateRegion?)?

    // Animation / momentum driver.
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private enum Motion { case idle, momentum, zoom, zoomGlide }
    private var motion: Motion = .idle
    private var velE = 0.0, velN = 0.0                       // momentum, BNG m/s
    private var zoomFromRes = 0.0, zoomToRes = 0.0            // zoom animation
    /// Zoom-glide rate, in ln(resolution) per second. Zoom is geometric, so the
    /// only velocity that decays evenly is the one measured in log space —
    /// metres/point per second would coast forever when zoomed out and barely
    /// move when zoomed in.
    private var zoomVel = 0.0
    /// Below this release rate a pinch was a settle, not a flick (≈ ×1.8/sec).
    private static let zoomGlideMinRate = 0.6
    /// Ease-out rate of the glide. Matches the pan momentum's decay, so a zoom
    /// flick and a pan flick come to rest over the same sort of interval.
    private static let zoomGlideDecay = 5.0
    /// Rate at which the glide has visually stopped and can be retired.
    private static let zoomGlideStopRate = 0.05
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
        // The view's own background is the sea the whole world sits in.
        // (Was a paper tone, UIColor(red: 0xF2/255, green: 0xEF/255, blue: 0xE9/255,
        // alpha: 1), back when everything off the sheet was blank chrome.)
        backgroundColor = Self.seaColor
        clipsToBounds = true

        // Don't mask to bounds — the view itself clips, and letting buffer tiles
        // overflow means a pinch-out transform reveals them instead of blank edges.
        tileHost.masksToBounds = false
        layer.addSublayer(tileHost)

        // zPosition rather than sublayer order, so tiles being added and removed
        // constantly can never sandwich these wrongly.
        sheet.zPosition = -1
        world.zPosition = -0.5
        tileClip.zPosition = 0
        // The paper takes the sea colour rather than a paper tone. The sheet extent
        // is a rectangle far larger than Great Britain, so a distinct paper fill
        // turns the Irish Sea, the Channel and the North Sea into a pale rectangle
        // sitting on top of the world — it reads as a rendering fault, not a map.
        // The sheet stays legible from its cut edge and shadow alone.
        sheet.backgroundColor = Self.seaColor.cgColor
        sheet.shadowOpacity = 0            // raised in updateSheet() when an edge is near
        sheet.shadowRadius = 14
        sheet.shadowColor = UIColor.black.cgColor
        sheet.shadowOffset = CGSize(width: 0, height: 5)
        sheetEdgeOuter.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor
        sheetEdge.borderColor = UIColor.white.withAlphaComponent(0.55).cgColor
        sheetEdgeInner.borderColor = UIColor.black.withAlphaComponent(0.10).cgColor
        for l in sheetEdges { l.zPosition = 1 }

        world.fillColor = Self.landColor.cgColor
        world.strokeColor = Self.coastColor.cgColor
        // Land rings and their holes are one path; even-odd renders the holes
        // correctly whichever way the source data happens to wind them.
        world.fillRule = .evenOdd
        world.actions = ["path": NSNull(), "lineWidth": NSNull()]
        tileHost.addSublayer(world)

        for l in [sheet, tileClip] + sheetEdges {
            // They all trace the same rounded rect, so the paper, the imagery
            // clipped to it and the bevel share one silhouette. The bevel's outer
            // and inner rings get their radius nudged in updateSheet() to stay
            // concentric with the core.
            l.cornerRadius = Self.sheetCornerRadius
            l.cornerCurve = .continuous
            let null = NSNull()
            l.actions = ["position": null, "bounds": null, "frame": null,
                         "hidden": null, "shadowPath": null, "borderWidth": null,
                         "masksToBounds": null, "sublayers": null,
                         "cornerRadius": null]
            tileHost.addSublayer(l)
        }
        sheet.isHidden = true
        for l in sheetEdges { l.isHidden = true }

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

    /// The visible area in north-up content coordinates (the space tile frames are
    /// computed in): the view's rectangle un-rotated, bounding-boxed so a rotated
    /// viewport is fully covered.
    private func contentBounds() -> CGRect {
        let xs: [CGFloat], ys: [CGFloat]
        let corners = [CGPoint(x: 0, y: 0),
                       CGPoint(x: bounds.width, y: 0),
                       CGPoint(x: 0, y: bounds.height),
                       CGPoint(x: bounds.width, y: bounds.height)]
            .map { rotate($0, by: -rotation) }
        xs = corners.map(\.x); ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
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

    /// Zoomed out far enough to see the whole sheet and a margin of surround, and
    /// no further — shrinking a fixed sheet to a stamp in an empty view is never a
    /// view anyone wants. This is the backstop for every zoom-out path: pinch,
    /// two-finger tap, scroll wheel, and an adopted viewport from the worldwide
    /// renderer that was framed around pins this projection can't show.
    private var maxRes: Double {
        guard bounds.width > 0, bounds.height > 0 else { return (matrix.resolutions.first ?? 896) * 4 }
        let b = BNGTileMatrix.sheetBounds
        return max((b.maxX - b.minX) / Double(bounds.width),
                   (b.maxY - b.minY) / Double(bounds.height)) * 1.1
    }

    private func clampRes(_ r: Double) -> Double { min(maxRes, max(minRes, r)) }

    /// Keep the map centre on the paper, so the sheet can be pushed to an edge of
    /// the screen but never off it.
    private func clampCenter() {
        let b = BNGTileMatrix.sheetBounds
        centerE = min(max(centerE, b.minX), b.maxX)
        centerN = min(max(centerN, b.minY), b.maxY)
    }

    /// Integer tile level whose native resolution is nearest the current display
    /// resolution (in log space), clamped to what the source provides.
    private func tileZoom() -> Int { tileZoom(for: resolution) }

    /// The same choice for an arbitrary resolution, so a live pinch can ask which
    /// level it is heading for before committing to it.
    private func tileZoom(for res: Double) -> Int {
        var best = matrix.minZoom
        var bestDiff = Double.greatestFiniteMagnitude
        for z in matrix.minZoom...matrix.maxZoom {
            let d = abs(log2(matrix.resolutions[z] / res))
            if d < bestDiff { bestDiff = d; best = z }
        }
        return best
    }

    // MARK: Native zoom depth

    /// Levels that have answered with real imagery, and up to a handful of the
    /// distinct tiles each level has answered "nothing" for.
    private var zoomHasImagery: Set<Int> = []
    private var zoomMissedTiles: [Int: Set<TileID>] = [:]

    /// The deepest level worth requesting. A matrix routinely advertises more
    /// levels than the source actually holds imagery for — nothing in WMTS
    /// capabilities says where a series' pictures stop — and requesting those
    /// levels returns nothing, which is why zooming in past a source's finest
    /// level showed bare background instead of a map.
    ///
    /// Past this level, tiles are taken from here and scaled up by the layer:
    /// blurry, but a map. Leaflet calls the cap `maxNativeZoom` and has you
    /// configure it; there's nothing to read it from here, so it's learned.
    private func deepestUsableZoom() -> Int {
        var z = matrix.maxZoom
        while z > matrix.minZoom, isBarren(z) { z -= 1 }
        return z
    }

    /// Whether a level has shown it holds nothing. Needs a *coarser* level to
    /// have worked, which is what separates "this series stops here" from "the
    /// network is down" — the latter would otherwise cap the zoom for the
    /// session over a few seconds of bad signal.
    private func isBarren(_ z: Int) -> Bool {
        guard !zoomHasImagery.contains(z),
              zoomMissedTiles[z]?.count ?? 0 >= 4 else { return false }
        return zoomHasImagery.contains { $0 < z }
    }

    /// Record a tile that came back empty. Returns true if this is the answer
    /// that tipped the level over into barren, so the caller can re-tile at once
    /// rather than leaving the view blank until the next gesture.
    private func noteEmpty(_ id: TileID) -> Bool {
        let wasBarren = isBarren(id.z)
        // Capped: a long pan across a sparse level shouldn't grow this without
        // limit, and four is already past the threshold.
        if zoomMissedTiles[id.z, default: []].count < 8 {
            zoomMissedTiles[id.z, default: []].insert(id)
        }
        return !wasBarren && isBarren(id.z)
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

        // The deepest level that has something to draw here. Stepping out beats
        // drawing nothing: coarser tiles scaled up are blurry, but they are a
        // map, and a level with no tiles in range leaves the viewport empty.
        var z = min(tileZoom(), deepestUsableZoom())
        var range = tileRange(at: z)
        while range == nil, z > matrix.minZoom {
            z -= 1
            range = tileRange(at: z)
        }
        // Nothing at any level reaches the viewport: leave what's on screen
        // alone rather than clearing to bare background.
        guard let r = range else { return }

        let tileMeters = Double(matrix.tileSize) * matrix.resolutions[z]
        let originX = matrix.originX(at: z)
        let originY = matrix.originY(at: z)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Tiles the viewport needs, each paired with its squared distance from
        // the map centre in tile units.
        let cx = (centerE - originX) / tileMeters
        let cy = (originY - centerN) / tileMeters
        var wanted: [(id: TileID, d2: Double)] = []
        wanted.reserveCapacity((r.txMax - r.txMin + 1) * (r.tyMax - r.tyMin + 1))
        for ty in r.tyMin...r.tyMax {
            for tx in r.txMin...r.txMax {
                let dx = Double(tx) + 0.5 - cx, dy = Double(ty) + 0.5 - cy
                wanted.append((TileID(z: z, x: tx, y: ty), dx * dx + dy * dy))
            }
        }
        let needed = Set(wanted.map(\.id))

        let levelChanged = laidOutZoom != nil && laidOutZoom != z
        laidOutZoom = z
        // One generation of backdrop only: the tiles about to be retired are a
        // closer stand-in for this level than tiles two levels away, and keeping
        // every generation would pile up layers across a fast multi-level pinch.
        if levelChanged { clearBackdrop() }

        // Retire what has left the view *before* asking for anything new. A zoom
        // step invalidates every tile at once, and those fetches are sitting on
        // the network slots the new level wants — cancelling first is the
        // difference between the new level starting now and starting once a
        // screenful of superseded tiles has finished arriving.
        for (id, layer) in tileLayers where !needed.contains(id) {
            let wasReal = realTiles.contains(id)
            tileLayers[id] = nil
            realTiles.remove(id)
            requested.remove(id)
            placeholderZoom[id] = nil
            store.cancelTile(z: id.z, x: id.x, y: id.y)
            // Off screen: forget the failure history too, so coming back gives a
            // clean attempt (and the table can't grow as the user pans).
            retryPolicy.forget(id)
            // A finished picture of ground the view still covers outlives the
            // level it belongs to: demote it to the backdrop rather than drop it,
            // so the incoming level draws over a map instead of over blank paper.
            if levelChanged, wasReal {
                layer.zPosition = -1
                staleTiles[id] = layer
            } else {
                layer.removeFromSuperlayer()
            }
        }

        // Centre outwards, so the map fills from where the eye already is rather
        // than sweeping in from a corner. Only a handful of requests run at once
        // and the rest queue in arrival order, so issue order is very nearly
        // service order.
        wanted.sort { $0.d2 < $1.d2 }
        for (id, _) in wanted { placeTile(id) }

        updateBackdrop()
        updateSheet()
        updateWorld()

        CATransaction.commit()
        repositionPins()
    }

    /// The tile index range covering the viewport at level `z`, or nil when this
    /// level has nothing to draw here: its grid stops short of the view, the view
    /// has left the sheet, or the range came out absurd.
    private func tileRange(at z: Int) -> (txMin: Int, txMax: Int, tyMin: Int, tyMax: Int)? {
        let tileMeters = Double(matrix.tileSize) * matrix.resolutions[z]

        // Viewport BNG bounds, padded by a tile so panning reveals ready tiles.
        // (screen → BNG is affine with the y axis flipped, so the content box's
        // top-left and bottom-right corners give all four extremes.)
        let visible = contentBounds()
        let topLeft = bng(atScreen: CGPoint(x: visible.minX, y: visible.minY))
        let bottomRight = bng(atScreen: CGPoint(x: visible.maxX, y: visible.maxY))

        // Nothing outside the sheet is ever visible, so don't fetch it. Tiles that
        // straddle the edge are still needed — the mask trims them.
        let sheet = BNGTileMatrix.sheetBounds
        let eLo = max(topLeft.e - tileMeters, sheet.minX)
        let eHi = min(bottomRight.e + tileMeters, sheet.maxX)
        let nLo = max(bottomRight.n - tileMeters, sheet.minY)
        let nHi = min(topLeft.n + tileMeters, sheet.maxY)
        guard eLo <= eHi, nLo <= nHi else { return nil }

        // Clamp to the grid: never below 0, and never past the advertised
        // MatrixWidth/Height (requests outside coverage are guaranteed 404s).
        let originX = matrix.originX(at: z)
        let originY = matrix.originY(at: z)
        let txMin = max(0, Int(floor((eLo - originX) / tileMeters)))
        let tyMin = max(0, Int(floor((originY - nHi) / tileMeters)))
        var txMax = Int(floor((eHi - originX) / tileMeters))
        var tyMax = Int(floor((originY - nLo) / tileMeters))
        if let cols = matrix.columns(at: z) { txMax = min(txMax, cols - 1) }
        if let rows = matrix.rows(at: z) { tyMax = min(tyMax, rows - 1) }
        guard txMin <= txMax, tyMin <= tyMax else { return nil }

        // Safety: never fan out to an unbounded grid (e.g. a degenerate
        // resolution). Coarser levels cover the same ground in fewer tiles, so
        // the caller's step-out converges instead of giving up.
        guard (txMax - txMin + 1) * (tyMax - tyMin + 1) <= 800 else { return nil }
        return (txMin, txMax, tyMin, tyMax)
    }

    /// Re-frame the backdrop the last level change left behind, and retire it once
    /// it has nothing left to say: every current tile has its own picture, or the
    /// map has moved off the ground it covers.
    ///
    /// The backdrop lives in `tileClip` alongside the real tiles, below them by
    /// zPosition, so it is trimmed by the sheet edge and moves with the map
    /// exactly as they do — it only needs re-framing at the new resolution.
    private func updateBackdrop() {
        guard !staleTiles.isEmpty else { return }
        if realTiles.count == tileLayers.count { clearBackdrop(); return }
        let cull = contentBounds().insetBy(dx: -bounds.width, dy: -bounds.height)
        for (id, layer) in staleTiles {
            let f = tileFrame(id)
            if f.intersects(cull) {
                layer.frame = f
            } else {
                layer.removeFromSuperlayer()
                staleTiles[id] = nil
            }
        }
    }

    private func clearBackdrop() {
        for (_, layer) in staleTiles { layer.removeFromSuperlayer() }
        staleTiles.removeAll()
    }

    /// Lay the paper sheet, the tile clip and the cut edge around the sheet extent.
    ///
    /// The extent is the projection's own bounds rather than the tile grid's. The
    /// grid is bigger — its origin is chosen to make whole tiles at every level —
    /// and imagery peters out somewhere inside it, so an edge drawn there shows a
    /// band of blank paper before the shadow. Cutting where the projection stops
    /// puts the edge well inside the imagery, so it's always a clean trim.
    ///
    /// The rect is clamped to a box several screens deep rather than drawn at its
    /// true size: at the finest zoom the extent is over a million points across, and
    /// handing the render server a layer (and a shadow) that large buys nothing —
    /// every clamped edge is far outside the viewport. The pad is deep enough that
    /// a pinch-out, which scales these layers on the GPU between re-tiles, can't drag
    /// a clamped edge into view before the gesture ends and this runs again.
    private func updateSheet() {
        let e = BNGTileMatrix.sheetBounds
        let topLeft = screen(e: e.minX, n: e.maxY)
        let bottomRight = screen(e: e.maxX, n: e.minY)

        let pad = max(bounds.width, bounds.height) * 6
        let limit = contentBounds().insetBy(dx: -pad, dy: -pad)
        let minX = max(topLeft.x, limit.minX), maxX = min(bottomRight.x, limit.maxX)
        let minY = max(topLeft.y, limit.minY), maxY = min(bottomRight.y, limit.maxY)
        guard maxX > minX, maxY > minY else {          // extent nowhere near the viewport
            sheet.isHidden = true
            sheetEdge.isHidden = true
            tileClip.masksToBounds = false
            return
        }

        // Every side clamped ⇒ the real edge is several screens away on all four
        // sides ⇒ there is nothing to trim and nothing to shade.
        let allClamped = minX > topLeft.x && maxX < bottomRight.x
            && minY > topLeft.y && maxY < bottomRight.y

        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        sheet.frame = rect
        // Circular-arc corners rather than the layers' continuous ones: at this
        // radius, under a 14pt blur, the two are indistinguishable, and this is a
        // path the render server already has a fast case for.
        sheet.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size),
                                  cornerWidth: Self.sheetCornerRadius,
                                  cornerHeight: Self.sheetCornerRadius,
                                  transform: nil)
        sheet.shadowOpacity = allClamped ? 0 : 0.22
        sheet.isHidden = false
        // Three touching hairlines: the outer ring sits just outside the cut, the
        // core on it, the inner just inside. A layer's border is drawn inside its
        // own bounds, so insetting each frame by one hairline stacks them without
        // overlap, and the radius shifts with the inset to stay concentric.
        let hair = 1 / ql_displayScale
        for (i, l) in sheetEdges.enumerated() {
            let inset = CGFloat(i - 1) * hair
            l.frame = rect.insetBy(dx: inset, dy: inset)
            l.cornerRadius = max(0, Self.sheetCornerRadius - inset)
            l.borderWidth = hair
            l.isHidden = allClamped
        }

        // A non-zero bounds origin lets the tiles keep addressing tileHost's
        // coordinate space, so their frames need no adjusting for living in here.
        tileClip.bounds = rect
        tileClip.position = CGPoint(x: rect.midX, y: rect.midY)
        // A rounded clip is a mask, so it costs an offscreen pass per frame however
        // the map is oriented — only clip when an edge can actually be on screen.
        // Heading-follow is always zoomed far inside the extent, where every side is
        // clamped and there's nothing to trim.
        tileClip.masksToBounds = !allClamped
    }

    /// Rebuild the coastline path in content coordinates.
    ///
    /// The path is rebuilt rather than the layer transformed: a CAShapeLayer
    /// rasterises its path once and a scale transform would just magnify that
    /// bitmap, so the coast would go soft the moment you zoomed. Re-projecting is
    /// a multiply-add per point over a few thousand points, which is far cheaper
    /// than it sounds and matches how the tiles are re-laid.
    private func updateWorld() {
        // Skip rings nowhere near the viewport. Zoomed in that leaves one or two.
        let visible = contentBounds().insetBy(dx: -bounds.width / 2, dy: -bounds.height / 2)
        let tl = bng(atScreen: CGPoint(x: visible.minX, y: visible.minY))
        let br = bng(atScreen: CGPoint(x: visible.maxX, y: visible.maxY))
        let box = CGRect(x: tl.e, y: br.n, width: br.e - tl.e, height: tl.n - br.n)

        // Coordinates are clamped to a box several screens deep for the same
        // reason the sheet rect is: at the finest zoom an untrimmed ring runs to
        // hundreds of thousands of points across, which is a lot of path for the
        // rasteriser to chew on and none of it visible. The box is convex and far
        // outside the viewport, so a segment between two clamped points cannot cut
        // back across anything on screen.
        let pad = max(bounds.width, bounds.height) * 4
        let limit = contentBounds().insetBy(dx: -pad, dy: -pad)

        let path = CGMutablePath()
        for ring in WorldOutline.rings where ring.bounds.intersects(box) {
            var started = false
            for p in ring.points {
                let s = screen(e: p.e, n: p.n)
                let c = CGPoint(x: min(max(s.x, limit.minX), limit.maxX),
                                y: min(max(s.y, limit.minY), limit.maxY))
                if started {
                    path.addLine(to: c)
                } else {
                    path.move(to: c)
                    started = true
                }
            }
            if started { path.closeSubpath() }
        }
        world.path = path
        // Stroke width is in the same space as the path, which is points already.
        world.lineWidth = 1 / ql_displayScale
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

    // MARK: Failed-tile retry

    /// See `TileRetryPolicy`: a failed tile is retried in place after a growing
    /// back-off, capped so a permanently-empty position isn't re-requested on
    /// every layout pass.
    private var retryPolicy = TileRetryPolicy<TileID>()
    /// One pending retry pass at a time — a screenful of failures should cost
    /// one sweep, not one per tile.
    private var retrySweepScheduled = false

    private func noteFailure(_ id: TileID) {
        let nextDelay = retryPolicy.noteFailure(id, now: CACurrentMediaTime())
        // Clearing this is what allows the retry; without it the tile is locked
        // out until it leaves the viewport.
        requested.remove(id)
        guard let nextDelay else { return }   // out of attempts
        scheduleRetrySweep(after: nextDelay)
    }

    /// Re-run tile placement once the back-off has elapsed, so a failed tile
    /// recovers on its own instead of waiting for the user to pan or zoom.
    private func scheduleRetrySweep(after delay: TimeInterval) {
        guard !retrySweepScheduled else { return }
        retrySweepScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retrySweepScheduled = false
            self.updateTiles()
        }
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
            tileClip.addSublayer(l)
            tileLayers[id] = l
            return l
        }()
        layer.frame = tileFrame(id)

        guard !realTiles.contains(id) else { return }

        if let img = store.cachedImage(z: id.z, x: id.x, y: id.y) {
            layer.contents = img.cgImage
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            realTiles.insert(id)
            placeholderZoom[id] = nil
            return
        }
        // No real tile yet: show an upscaled slice of the best cached ancestor
        // so the position is never blank, and fetch the real one (once).
        if layer.contents == nil, let anc = bestCachedAncestor(id) {
            layer.contents = anc.image.cgImage
            layer.contentsRect = anc.rect
            placeholderZoom[id] = anc.z
        }
        guard !requested.contains(id),
              retryPolicy.mayRequest(id, now: CACurrentMediaTime()) else { return }
        requested.insert(id)
        store.requestTile(z: id.z, x: id.x, y: id.y) { [weak self] z, x, y, outcome in
            guard let self else { return }
            let id = TileID(z: z, x: x, y: y)
            switch outcome {
            case .loaded:
                self.zoomHasImagery.insert(z)
                self.placeholderZoom[id] = nil
            case .missing:
                // Nothing here at this level. Cover the position from the level
                // above straight away, then — if this level has now proved barren
                // outright — re-tile so the whole view drops to the deepest level
                // that does hold imagery, rather than paying for a doomed request
                // and a fallback for every tile from here on.
                let nowBarren = self.noteEmpty(id)
                self.noteFailure(id)
                self.fillFromAncestor(id, from: z - 1)
                if nowBarren { self.updateTiles() }
                return
            case .cancelled:
                // Superseded, not failed. The drop that cancelled it already
                // cleared `requested`, so if this position comes back into view
                // it is asked for again with a clean slate — charging it a retry
                // attempt would instead lock it out of the level it lands on.
                return
            }
            self.retryPolicy.noteSuccess(id)
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

    /// The tile at level `az` covering `id`, with the normalized sub-rectangle of
    /// it that corresponds to `id` (for CALayer.contentsRect). Nil when that
    /// level has no such tile.
    ///
    /// Computed geometrically (via each level's own origin and resolution)
    /// rather than by bit-shifting indices: WMTS neither guarantees a shared
    /// origin across levels nor exact power-of-two resolution steps, so index
    /// arithmetic only holds for aligned power-of-two pyramids.
    private func ancestorTile(_ id: TileID, at az: Int) -> (id: TileID, rect: CGRect)? {
        guard az >= matrix.minZoom, az < id.z else { return nil }
        let sizeC = Double(matrix.tileSize) * matrix.resolutions[id.z]
        let eLeft = matrix.originX(at: id.z) + Double(id.x) * sizeC
        let nTop = matrix.originY(at: id.z) - Double(id.y) * sizeC
        let sizeA = Double(matrix.tileSize) * matrix.resolutions[az]
        // Ancestor tile containing this tile's top-left corner. The epsilon
        // absorbs float error when the corner lies exactly on a tile edge.
        let ax = Int(floor((eLeft - matrix.originX(at: az)) / sizeA + 1e-9))
        let ay = Int(floor((matrix.originY(at: az) - nTop) / sizeA + 1e-9))
        guard ax >= 0, ay >= 0 else { return nil }
        if let cols = matrix.columns(at: az), ax >= cols { return nil }
        if let rows = matrix.rows(at: az), ay >= rows { return nil }
        let fx = (eLeft - (matrix.originX(at: az) + Double(ax) * sizeA)) / sizeA
        let fy = ((matrix.originY(at: az) - Double(ay) * sizeA) - nTop) / sizeA
        let f = sizeC / sizeA
        // Usable only when the child sits fully inside this ancestor tile
        // (always true for aligned pyramids; may fail on odd ladders).
        guard fx >= -1e-6, fy >= -1e-6, fx + f <= 1 + 1e-6, fy + f <= 1 + 1e-6 else { return nil }
        return (TileID(z: az, x: ax, y: ay),
                CGRect(x: max(0, fx), y: max(0, fy), width: min(1, f), height: min(1, f)))
    }

    /// The nearest already-cached coarser tile covering `id`. Free to consult, so
    /// it runs for every tile before anything is requested.
    private func bestCachedAncestor(_ id: TileID) -> (image: UIImage, rect: CGRect, z: Int)? {
        var az = id.z - 1
        while az >= matrix.minZoom {
            defer { az -= 1 }
            guard let a = ancestorTile(id, at: az),
                  let img = store.cachedImage(z: a.id.z, x: a.id.x, y: a.id.y) else { continue }
            return (img, a.rect, az)
        }
        return nil
    }

    /// The level currently standing in for a tile that has no picture of its own,
    /// so the fallback chain knows when to stop looking.
    private var placeholderZoom: [TileID: Int] = [:]

    /// Fill a tile the source has nothing for from the level above — requesting
    /// that level if it isn't already to hand, which is the part `bestCachedAncestor`
    /// can't do. Matrices routinely advertise more levels than a series holds
    /// pictures for, and the disk cache is not visible from the main thread, so
    /// "no imagery here" and "not in memory" both used to end as blank paper.
    ///
    /// Walks up a level at a time and stops at the first that answers, so the
    /// usual case is one extra request. Tiles already showing a coarse stand-in
    /// only ask for the levels that would improve on it.
    private func fillFromAncestor(_ id: TileID, from az: Int) {
        guard az >= matrix.minZoom, az > (placeholderZoom[id] ?? matrix.minZoom - 1),
              let layer = tileLayers[id], !realTiles.contains(id) else { return }
        guard let a = ancestorTile(id, at: az) else {
            fillFromAncestor(id, from: az - 1)      // this level doesn't cover it
            return
        }
        if let img = store.cachedImage(z: a.id.z, x: a.id.x, y: a.id.y) {
            layer.contents = img.cgImage
            layer.contentsRect = a.rect
            placeholderZoom[id] = az
            return
        }
        store.requestTile(z: a.id.z, x: a.id.x, y: a.id.y) { [weak self] _, _, _, outcome in
            guard let self else { return }
            switch outcome {
            case .loaded:
                // Re-check: the tile may have got its own picture, been panned
                // away, or found a better stand-in while this was in the air.
                guard let layer = self.tileLayers[id], !self.realTiles.contains(id),
                      az > (self.placeholderZoom[id] ?? self.matrix.minZoom - 1),
                      let img = self.store.cachedImage(z: a.id.z, x: a.id.x, y: a.id.y) else { return }
                layer.contents = img.cgImage
                layer.contentsRect = a.rect
                self.placeholderZoom[id] = az
            case .missing:
                _ = self.noteEmpty(a.id)
                self.fillFromAncestor(id, from: az - 1)
            case .cancelled:
                break
            }
        }
    }

    // MARK: Pins / dot

    /// Whether a BNG point falls on the sheet. Off it there's no map to sit on,
    /// and `wgs84ToBNG` is extrapolating a projection outside the ground it's
    /// fitted to, so the coordinates are fiction as well as invisible.
    private static func isOnSheet(e: Double, n: Double) -> Bool {
        let b = BNGTileMatrix.sheetBounds
        return e >= b.minX && e <= b.maxX && n >= b.minY && n <= b.maxY
    }

    func setEntries(_ newEntries: [LocationEntry]) {
        // Which items are pinned, not how they're styled: a label being renamed
        // or recoloured is not a reason to move the map.
        let placed = Set(newEntries.filter { $0.item.location != nil }.map(\.item.id))
        let placementChanged = placed != placedEntryIDs
        placedEntryIDs = placed

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
            // Off-sheet stays nil: that's already the "nowhere to put it" case for
            // repositionPins, the popover anchor and the fit-all zoom.
            let onSheet = Self.isOnSheet(e: bng.e, n: bng.n)
            view.mapE = onSheet ? bng.e : nil
            view.mapN = onSheet ? bng.n : nil
        }

        // Re-frame the new set. This is the search crop: filtering the list
        // hands us a smaller `entries` and the map closes in on what's left,
        // without anything having to tell it a search happened.
        if placementChanged, focus == .all, viewportIsAutoFit, bounds.width > 0 {
            stopDisplayLink()
            fitAllPins()
            clampCenter()
            updateTiles()      // repositions the pins itself
            reportRegion()
            return
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
        // Same rule for the dot: a user abroad has no position on this sheet.
        // (`userBNG` itself is left alone, so follow modes still have something to
        // centre on — clamped to the sheet — rather than silently doing nothing.)
        if let u = userBNG, Self.isOnSheet(e: u.e, n: u.n) {
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
        // Every fetch still running belongs to a layer that's about to vanish;
        // let them finish and they'd spend the next few seconds of bandwidth and
        // decode time on imagery nobody will see.
        store.clear()
        store = BNGTileStore(source: newSource)
        // Swap the tiles in place — keep the exact centre / zoom / rotation so
        // switching layers passes the current view through unchanged.
        for (_, layer) in tileLayers { layer.removeFromSuperlayer() }
        tileLayers.removeAll()
        realTiles.removeAll()
        requested.removeAll()
        // The backdrop is imagery from the layer being switched away from — the
        // one thing that must not survive under the new one.
        clearBackdrop()
        laidOutZoom = nil
        placeholderZoom.removeAll()
        retryPolicy.removeAll()
        // Where imagery stops is a property of the source, not of the app.
        zoomHasImagery.removeAll()
        zoomMissedTiles.removeAll()
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
                let adopted = region.map(setViewport) ?? false
                if !adopted { fitAllPins() }
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
        // The framing is now the user's, so the entry set changing must not
        // re-frame it. Set before the guard: panning while already in `.all` is
        // the commonest way to take the camera over, and it returns early.
        viewportIsAutoFit = false
        guard focus != .all else { onUserPannedAway?(); return }
        focus = .all
        suppressRefitOnAll = true
        onUserPannedAway?()
    }

    private func fitAllPins() {
        // Off-sheet pins are excluded, not just hidden: one item abroad would
        // otherwise stretch the fit until nothing on the sheet is legible.
        let pts = entries.compactMap(\.item.location)
            .map { BNGProjection.wgs84ToBNG(lat: $0.latitude, lon: $0.longitude) }
            .filter { Self.isOnSheet(e: $0.e, n: $0.n) }
        guard !pts.isEmpty else { return }
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
        viewportIsAutoFit = true
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

    /// Adopt a viewport reported by the other renderer, so switching layers passes
    /// the current view through unchanged. Returns false when the region isn't a
    /// view of this sheet and the caller should fit the pins instead.
    ///
    /// The binding this arrives on is shared with the worldwide renderer, which
    /// fits it to every pin — including ones this projection can't show. A region
    /// framed around the UK *and* Switzerland centres in the Channel: adopting it
    /// parks the sheet in a corner (the centre clamps to the nearest sheet corner)
    /// at a zoom set by a pin that isn't drawn. There's no honest way to carry such
    /// a view across, so we don't try; a region that lies entirely on the sheet is
    /// adopted exactly, which is the case where continuity means anything.
    private func setViewport(_ region: MKCoordinateRegion) -> Bool {
        let lat = region.center.latitude, lon = region.center.longitude
        let dLat = region.span.latitudeDelta / 2, dLon = region.span.longitudeDelta / 2
        let sw = BNGProjection.wgs84ToBNG(lat: lat - dLat, lon: lon - dLon)
        let ne = BNGProjection.wgs84ToBNG(lat: lat + dLat, lon: lon + dLon)
        let eLo = min(sw.e, ne.e), eHi = max(sw.e, ne.e)
        let nLo = min(sw.n, ne.n), nHi = max(sw.n, ne.n)
        guard Self.isOnSheet(e: eLo, n: nLo), Self.isOnSheet(e: eHi, n: nHi) else { return false }

        centerE = (eLo + eHi) / 2
        centerN = (nLo + nHi) / 2
        if bounds.width > 0, bounds.height > 0, eHi - eLo > 1, nHi - nLo > 1 {
            resolution = clampRes(max((eHi - eLo) / Double(bounds.width),
                                      (nHi - nLo) / Double(bounds.height)))
        }
        return true
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

        // Zero-duration press: recognizes the instant a touch lands, purely so it
        // can arrest a glide. It never consumes the touch — `cancelsTouchesInView`
        // off, no delays, recognizes alongside everything — so pan, pinch, taps
        // and the pin hit-testing behave exactly as before.
        let touchDown = UILongPressGestureRecognizer(target: self, action: #selector(handleTouchDown(_:)))
        touchDown.minimumPressDuration = 0
        touchDown.cancelsTouchesInView = false
        touchDown.delaysTouchesBegan = false
        touchDown.delaysTouchesEnded = false
        touchDown.delegate = self
        addGestureRecognizer(touchDown)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        // A small, quick pinch satisfies this recognizer too — two touches, ended
        // before the tap timeout, moved less than its slop — and `shouldRecognize
        // SimultaneouslyWith` returns true for every pair, so the live pinch never
        // cancels it the way UIKit would by default. It therefore fired at the end
        // of a gentle pinch and animated a full ×2 zoom *out* on top of whatever
        // the pinch had just done: the map appeared to snap to the next step, and
        // only for small pinches, which is what made it look intermittent.
        // Waiting on the pinch to fail is the exact rule we want — a pinch that
        // recognized is not a tap, and one that never began fails as the touches
        // lift, which is when the tap would fire anyway.
        twoFingerTap.require(toFail: pinch)
        addGestureRecognizer(twoFingerTap)

        // Scroll handling for pointer devices (Mac trackpad / Catalyst, iPad with
        // a trackpad or mouse). A pan recognizer restricted to *indirect* scroll
        // events with `maximumNumberOfTouches = 0` only fires for scrolls — never
        // for a finger drag — so it coexists with the 1-finger pan without either
        // stealing the other's gesture. MapKit does this for us; the native slippy
        // map has to opt in.
        //
        // Two of them, because a wheel and a trackpad mean different things by the
        // same event. `UIScrollType` is what tells them apart — `.discrete`
        // "originate from devices like a scroll wheel mouse", `.continuous` "from
        // devices like trackpads" — and the macOS convention (MapKit's included)
        // is wheel zooms, two-finger swipe pans. Pinch is the trackpad's zoom.
        let wheelZoom = UIPanGestureRecognizer(target: self, action: #selector(handleScrollZoom(_:)))
        wheelZoom.allowedScrollTypesMask = .discrete
        wheelZoom.maximumNumberOfTouches = 0
        wheelZoom.delegate = self
        addGestureRecognizer(wheelZoom)

        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollPan.allowedScrollTypesMask = .continuous
        scrollPan.maximumNumberOfTouches = 0
        scrollPan.delegate = self
        addGestureRecognizer(scrollPan)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // Block the 1-finger pan while a pinch is live or just ended, so a finger
        // lingering as the pinch ends can't drag the map (the "bounce back").
        // A trackpad magnify leaves no finger behind to do that, so it doesn't
        // earn the cool-off — charging it one would just deaden click-drag for a
        // third of a second after every zoom.
        if g === mapPan {
            if isPinching { return false }
            if !pinchIsIndirect, CACurrentMediaTime() - lastPinchEndTime < 0.3 { return false }
        }
        return true
    }

    /// Touching the map stops a glide dead, the way every inertial scroller does —
    /// otherwise the map keeps sliding out from under a finger that has clearly
    /// asked it to stop.
    ///
    /// On Mac this catches a click. A bare two-finger *rest* on a trackpad can't
    /// be caught: it produces no touch and no scroll event, and UIKit exposes no
    /// scroll phase to see it through. Starting to scroll does stop the glide, via
    /// `handleScrollPan`'s `.began`.
    @objc private func handleTouchDown(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        arrestMomentum()
    }

    /// Stop a glide where it is. Retires the momentum rather than tearing the
    /// display link down: a heading-follow ease may be riding the same link, and
    /// `tick` stops it on its own once nothing is left to animate.
    private func arrestMomentum() {
        guard motion == .momentum || motion == .zoomGlide else { return }
        motion = .idle
        velE = 0
        velN = 0
        zoomVel = 0
        reportRegion()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            stopDisplayLink()
            exitFollow()
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            panBy(dx: t.x, dy: t.y)
        case .ended, .cancelled:
            flingBy(velocity: g.velocity(in: self))
        default:
            break
        }
    }

    /// Trackpad two-finger scroll pans, matching macOS and MapKit: a continuous
    /// scroll comes from a trackpad, where the gesture reads as a drag, not a
    /// zoom. UIKit synthesizes the pan translation from the scroll deltas in the
    /// same sense a drag would produce, so this is the finger-pan maths verbatim.
    @objc private func handleScrollPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            stopDisplayLink()
            exitFollow()
            g.setTranslation(.zero, in: self)
            scrollPanVelocity = .zero
            scrollPanLastEvent = CACurrentMediaTime()
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            panBy(dx: t.x, dy: t.y)
            let now = CACurrentMediaTime()
            let dt = now - scrollPanLastEvent
            scrollPanLastEvent = now
            // Ignore a gap long enough that the delta says nothing about speed
            // (first event of the gesture, or a stall), and smooth the rest so one
            // stuttering frame can't decide the fling.
            if dt > 0.001, dt < 0.1 {
                let instant = CGPoint(x: t.x / CGFloat(dt), y: t.y / CGFloat(dt))
                let k: CGFloat = 0.35
                scrollPanVelocity.x += (instant.x - scrollPanVelocity.x) * k
                scrollPanVelocity.y += (instant.y - scrollPanVelocity.y) * k
            }
        case .ended, .cancelled:
            // Fingers came to rest on the trackpad before lifting: the last
            // velocity we saw is stale, and flinging on it would throw the map
            // after the user deliberately stopped it.
            if CACurrentMediaTime() - scrollPanLastEvent > 0.05 { scrollPanVelocity = .zero }
            flingBy(velocity: scrollPanVelocity)
        default:
            break
        }
    }

    /// Hand a release velocity (screen points/second) to the momentum driver, or
    /// just settle when the gesture ended too slowly to be a fling. Shared, so a
    /// trackpad flick and a finger flick decay identically.
    private func flingBy(velocity v: CGPoint) {
        let d = unrotateVector(dx: Double(v.x), dy: Double(v.y))
        velE = -d.dx * resolution
        velN = d.dy * resolution
        if hypot(v.x, v.y) > 80 { startMomentum() } else { reportRegion() }
    }

    /// Move the map by a screen-space drag delta. Shared by the finger pan and
    /// the trackpad scroll-pan, which differ only in how they end.
    private func panBy(dx: CGFloat, dy: CGFloat) {
        // Un-rotate the screen delta into north-up content space so panning moves
        // the map correctly even when rotated (heading free-look).
        let d = unrotateVector(dx: Double(dx), dy: Double(dy))
        centerE -= d.dx * resolution
        centerN += d.dy * resolution
        clampCenter()
        updateTiles()
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
            // survives a pinch; only the zoom changes. It does still hand the
            // zoom to the user, so an auto-fit no longer applies.
            viewportIsAutoFit = false
            isPinching = true
            // No touches at all ⇒ a trackpad magnify, not fingers. A touch pinch
            // only begins once two touches have moved enough to count as one, so
            // this can't misread one.
            pinchIsIndirect = g.numberOfTouches == 0
            pinchCentroid0 = g.location(in: self)
            pinchLastCentroid = pinchCentroid0
            pinchLastScale = 1
            pinchScaleBase = 1
            pinchLogVel = 0
            pinchLastEvent = CACurrentMediaTime()
            pinchLastRes = resolution
            // World point under the centroid (un-rotated to north-up, then BNG).
            pinchMapAnchor = bng(atScreen: rotate(pinchCentroid0, by: -rotation))
            pinchBaseRes = resolution
            pinchTiledZoom = min(tileZoom(), deepestUsableZoom())
            // Starts the rate limit armed, so a twitch on touch-down can't re-tile
            // before the gesture has shown which way it's going.
            lastPinchRebase = CACurrentMediaTime()
            for (_, pin) in pinViews where !pin.isHidden { pin.pinchBase = pin.layer.position }
            userDotPinchBase = userDot.isHidden ? nil : userDot.center
        case .changed:
            // A finger lifting to end the pinch snaps `location(in:)` to the
            // remaining touch (a ~100px centroid jump at unchanged scale). Ignore
            // any sub-2-finger frame so that lurch never reaches the map — but
            // only for a real touch pinch. A trackpad magnify has no touches to
            // count and no finger to lift, so it reports 0 throughout and this
            // guard would eat the whole gesture.
            guard pinchIsIndirect || g.numberOfTouches >= 2 else { return }
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
            let targetRes = clampRes(pinchBaseRes / scaleSinceCommit(g.scale))
            noteZoomRate(targetRes)
            // Scaled into a different tile level: commit what the gesture has done
            // so far and lay that level out now, so its detail arrives while the
            // fingers are still moving rather than all at once on release.
            let wantZoom = min(tileZoom(for: targetRes), deepestUsableZoom())
            if wantZoom != pinchTiledZoom,
               CACurrentMediaTime() - lastPinchRebase > 0.1 {
                pinchTiledZoom = wantZoom
                rebasePinch(centroid: current, targetRes: targetRes, rawScale: g.scale)
                return
            }
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
            let targetRes = clampRes(pinchBaseRes / scaleSinceCommit(pinchLastScale))
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
            startZoomGlide(anchor: u)
        default:
            break
        }
    }

    /// Fold this event's zoom rate into the smoothed estimate that becomes the
    /// glide on release. Called before the level-commit branch, so a frame that
    /// commits still contributes its rate like any other.
    private func noteZoomRate(_ targetRes: Double) {
        let now = CACurrentMediaTime()
        let dt = now - pinchLastEvent
        // Skip a gap too long to say anything about speed (the first event, or a
        // stall), and smooth the rest so one stuttering frame can't set the glide.
        if dt > 0.001, dt < 0.1, pinchLastRes > 0, targetRes > 0 {
            let instant = log(targetRes / pinchLastRes) / dt
            pinchLogVel += (instant - pinchLogVel) * 0.35
        }
        pinchLastEvent = now
        pinchLastRes = targetRes
    }

    /// How far the pinch has scaled since the last commit (or since it began).
    /// `pinchBaseRes` moves with each commit, so the scale applied to it has to be
    /// measured from the same instant.
    private func scaleSinceCommit(_ raw: CGFloat) -> Double {
        max(Double(raw / pinchScaleBase), 0.0001)
    }

    /// Carry a released pinch on a little, the way AppKit's magnification does: a
    /// flick keeps zooming and eases out, instead of stopping dead the instant the
    /// fingers lift.
    ///
    /// `anchor` is the release centroid in north-up content space. The glide holds
    /// that point fixed for its whole run, exactly as the pinch did — zooming
    /// about the view centre instead would slide the map sideways as it settled.
    ///
    /// Trackpad only, and deliberately so: coasting is the *Mac* idiom (touch pinch
    /// on iOS, MapKit's included, stops dead where the fingers lift), and neither
    /// half of the rate estimate this glide rides on survives contact with glass.
    /// A touch pinch `.ended`s as the first finger *starts* lifting, so the last
    /// frames past the `>= 2` guard are the gesture's noisiest — a drifting
    /// lift-off centroid over a ~4ms `dt` reads as a large rate in *either*
    /// direction, and a negative one glides back out from where the user let go.
    /// The stall check below can't catch it either: a finger resting on glass still
    /// emits `touchesMoved` jitter, so `pinchLastEvent` keeps refreshing and the
    /// rate never goes stale. A trackpad held still emits no events at all.
    private func startZoomGlide(anchor: CGPoint) {
        guard pinchIsIndirect else { return }
        // Fingers came to rest before lifting: the last rate we saw is stale, and
        // gliding on it would zoom past where the user deliberately stopped.
        if CACurrentMediaTime() - pinchLastEvent > 0.05 { pinchLogVel = 0 }
        guard abs(pinchLogVel) > Self.zoomGlideMinRate else { return }
        zoomVel = pinchLogVel
        zoomAnchorScreen = anchor
        zoomAnchorBNG = bng(atScreen: anchor)
        motion = .zoomGlide
        startDisplayLink()
    }

    /// Commit the in-flight pinch into the map state, lay out the level it has
    /// reached, and re-baseline the gesture so it carries on from there.
    ///
    /// Zoom is a GPU transform between commits because re-tiling every frame is
    /// what makes a pinch stutter — but a transform only ever rescales the
    /// pictures already on screen, which is why detail used to arrive in one lump
    /// on release. Committing at each level boundary is the middle ground: the
    /// arithmetic is exactly what `.ended` does, so the map does not move, and the
    /// level being zoomed into starts fetching with the fingers still down.
    private func rebasePinch(centroid: CGPoint, targetRes: Double, rawScale: CGFloat) {
        lastPinchRebase = CACurrentMediaTime()
        // Everything from here measures against this instant. Written before the
        // state below so a re-entrant read can't see the old offset with the new
        // base resolution.
        pinchScaleBase = max(rawScale, 0.0001)
        resolution = targetRes
        // Keep the anchored world point under the centroid, exactly as `.ended`
        // does: un-rotate the centroid to north-up content space, solve for centre.
        let u = rotate(centroid, by: -rotation)
        centerE = pinchMapAnchor.e - Double(u.x - midX) * resolution
        centerN = pinchMapAnchor.n + Double(u.y - midY) * resolution
        clampCenter()

        // From here the gesture is a fresh pinch off the committed state. The
        // anchor is re-read *after* the clamp, so running into a sheet edge
        // doesn't leave the rest of the gesture solving for a point the map has
        // already refused to show.
        pinchBaseRes = resolution
        pinchCentroid0 = centroid
        pinchMapAnchor = bng(atScreen: u)

        // `isPinching` is what keeps a stray re-tile from fighting the gesture's
        // transform; this re-tile *is* the gesture, so lower it across the call.
        isPinching = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tileHost.transform = CATransform3DMakeRotation(CGFloat(rotation), 0, 0, 1)
        CATransaction.commit()
        updateTiles()          // repositions the pins onto the committed state
        isPinching = true
        for (_, pin) in pinViews { pin.pinchBase = pin.isHidden ? nil : pin.layer.position }
        userDotPinchBase = userDot.isHidden ? nil : userDot.center
        // Deliberately no `reportRegion()`: the viewport binding drives a SwiftUI
        // update pass, and running one at every level boundary is exactly the
        // mid-gesture cost this design exists to avoid. `.ended` reports the
        // settled region.
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

        case .zoomGlide:
            zoomVel *= exp(-dt * Self.zoomGlideDecay)
            let next = clampRes(resolution * exp(zoomVel * dt))
            // Clamped to the same value ⇒ the glide has run into the zoom limit
            // and there is nothing left for it to do.
            let atLimit = next == resolution
            resolution = next
            // Hold the release centroid fixed, as the pinch did.
            centerE = zoomAnchorBNG.e - Double(zoomAnchorScreen.x - midX) * resolution
            centerN = zoomAnchorBNG.n + Double(zoomAnchorScreen.y - midY) * resolution
            clampCenter()
            updateTiles()
            if atLimit || abs(zoomVel) < Self.zoomGlideStopRate {
                motion = .idle
                reportRegion()
            } else { active = true }

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

/// How a tile request ended.
private enum TileOutcome {
    /// Bytes arrived and are in the cache.
    case loaded
    /// The server had nothing there, or the fetch failed for good.
    case missing
    /// Superseded by a zoom or pan before it finished. Distinct from `missing`
    /// because it says nothing about the tile — treating it as a failure would
    /// put a perfectly good position into retry back-off.
    case cancelled
}

/// Off-main-actor owner of the tile fetch + in-memory cache. Fetches run on
/// detached tasks; `ready` fires on the main actor so tile layers can update.
private final class BNGTileStore: @unchecked Sendable {
    private let fetcher: TileFetcher
    private let cache = TileImageCache()
    private let lock = NSLock()
    // `fileprivate`, matching `TileOutcome` and the enclosing class: a member
    // may not be more visible than the types in its signature, and everything
    // here is scoped to this file anyway.
    fileprivate typealias Done = @MainActor @Sendable (Int, Int, Int, TileOutcome) -> Void

    /// One fetch per tile, however many callers want it. Four sibling tiles with
    /// no imagery of their own all fall back to the same parent, so a second
    /// caller has to be able to wait on a fetch already running rather than be
    /// dropped — it would never hear back and its tile would stay blank.
    ///
    /// The token distinguishes generations of the same key: a cancelled fetch
    /// and its replacement can be alive at once, and only the current one may
    /// clear the entry when it finishes.
    private struct Inflight {
        let token: UInt64
        let task: Task<Void, Never>
        var dones: [Done]
    }
    private var inflight: [String: Inflight] = [:]
    private var nextToken: UInt64 = 0

    init(source: CustomTileSource) {
        // The key is already embedded in the tile URL, so nothing to inject.
        // Matrix identifiers make {z} substitute the WMTS TileMatrix name for
        // each level (falls back to the numeric zoom when absent — v3 sources).
        fetcher = TileFetcher(urlTemplate: source.zxyTemplate,
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
        lock.lock()
        let tasks = inflight.values.map(\.task)
        inflight.removeAll()
        lock.unlock()
        for t in tasks { t.cancel() }
    }

    /// Call off a fetch the view no longer wants. Cancellation reaches all the
    /// way down: `TileFetcher` checks it around each attempt, `FetchLimiter`
    /// hands back a waiting slot, and `URLSession` tears down a request already
    /// on the wire. That released slot is the point — it's what lets a new zoom
    /// level start fetching immediately instead of behind the old one.
    func cancelTile(z: Int, x: Int, y: Int) {
        lock.lock()
        let entry = inflight.removeValue(forKey: "\(z)/\(x)/\(y)")
        lock.unlock()
        entry?.task.cancel()
    }

    /// `done` reports the outcome whatever it is. A fetch that comes back empty
    /// has to be reported too, or the caller can't tell "still loading" from
    /// "this one failed" — and a failed tile that is never retried stays blank
    /// for as long as it remains on screen.
    fileprivate func requestTile(z: Int, x: Int, y: Int, done: @escaping Done) {
        let key = "\(z)/\(x)/\(y)"
        lock.lock()
        if inflight[key] != nil {
            inflight[key]?.dones.append(done)
            lock.unlock()
            return
        }
        nextToken += 1
        let token = nextToken
        // Created under the lock: the task's own `finish` takes the same lock, so
        // it cannot run ahead of this assignment and strand the entry.
        inflight[key] = Inflight(token: token, task: Task.detached(priority: .userInitiated) { [self] in
            let image = await fetcher.fetchImage(z: z, x: x, y: y)
            let waiting = finish(key, token: token)
            if let image {
                cache.set(z: z, x: x, y: y, image: UIImage(cgImage: image.cg))
            }
            // A cancelled fetch returns nil like a missing one; only the task's
            // own cancellation flag tells them apart. An image outranks the flag:
            // cancelling a request that turned out to be a cache hit still leaves
            // a real tile, and its layer may well have survived the drop.
            let outcome: TileOutcome = image != nil ? .loaded
                                     : (Task.isCancelled ? .cancelled : .missing)
            await MainActor.run { for d in waiting { d(z, x, y, outcome) } }
        }, dones: [done])
        lock.unlock()
    }

    /// Claim the callbacks waiting on this fetch, if it's still the current
    /// generation — a cancelled fetch finishing late must not evict, or answer
    /// for, its own replacement.
    private func finish(_ key: String, token: UInt64) -> [Done] {
        lock.lock(); defer { lock.unlock() }
        guard let entry = inflight[key], entry.token == token else { return [] }
        inflight[key] = nil
        return entry.dones
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
