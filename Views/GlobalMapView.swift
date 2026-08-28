//
//  GlobalMapView.swift
//  QuiteListie
//
//  Shows all items with pinned locations from every list in a single map.
//  Tapping a pin navigates to the item's source list and opens its editor.
//

import CoreLocation
import SwiftUI
import MapKit

struct GlobalMapView: View {
    var welcomeViewModel: WelcomeViewModel
    var searchText: String = ""
    /// Called when the user taps "Show Details" — opens the item editor without leaving the map.
    var onShowDetails: ((ListItem, UnifiedList) -> Void)?

    @Namespace private var mapScope

    @AppStorage("mapStyleMuted") private var mapStyleMuted: Bool = true
    @AppStorage(GlobalMapLayer.storageKey) private var selectedLayerRaw: String = GlobalMapLayer.appleMaps

    @State private var selectedItemID: UUID?
    @State private var selectedLabelIDs: Set<String> = []
    @State private var showCompleted: Bool = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var focusState: MapFocusState = .all
    @State private var popoverItem: ListItem? = nil
    @State private var popoverEntry: LocationEntry? = nil
    @State private var showPopover: Bool = false
    @State private var visibleRegion: MKCoordinateRegion?
    /// Set when the custom renderer goes away, so the MapKit branch adopts its
    /// final viewport on the appearance that follows — and only that one.
    ///
    /// The restore has to be this narrow. `cameraPosition` starts `.automatic`,
    /// which is not a one-off fit: it re-frames whenever the annotation set
    /// changes, and that is what crops the map to a search's matches. Writing a
    /// concrete `.region` into it ends that for good, so it may only happen when
    /// there is genuinely a viewport being handed over.
    @State private var adoptRegionOnAppear = false
    @State private var customSources: [CustomTileSource] = []
    /// Layer-health banner text ("layer X rejected your API key"), or nil.
    /// TileLayerHealth already rate-limits to once per source per session.
    @State private var healthBannerMessage: String? = nil
    /// Live screen position of the pin a popover is anchored to (custom map, iPad/Mac).
    @State private var customPopoverAnchor: CGPoint? = nil
    /// Set when the popover target changes (cycle / re-select) so the *next*
    /// anchor update — which lands a runloop later via the deferred callback —
    /// triggers exactly one re-present at the fresh position. A presented popover
    /// ignores `attachmentAnchor` changes, so relocating it needs a re-present.
    @State private var reanchorPending = false
    /// True during the transient dismiss→re-present that relocates the popover to
    /// a new pin, so that dismissal doesn't tear down the cycling state.
    @State private var reanchoring = false

    /// The custom layer the user has selected, if any (and if it still exists).
    private var selectedCustomSource: CustomTileSource? {
        customSources.first { $0.id.uuidString == selectedLayerRaw }
    }

    /// Any non-Apple layer is active (drives the toolbar icon fill).
    private var isCustomLayerActive: Bool { selectedLayerRaw != GlobalMapLayer.appleMaps }

    /// The selected layer's attribution caption, if it has one. Apple Maps
    /// draws its own legal attribution, so only custom layers contribute.
    private var selectedLayerAttribution: String? {
        let text = selectedCustomSource?.attribution
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    /// Scheme for everything drawn *over* the map — bars, attribution, banner.
    ///
    /// Custom layers are raster tiles baked light by their provider; they have
    /// no dark variant, so in dark mode the chrome has to go light or it sits
    /// as dark-on-bright. Apple Maps restyles itself per appearance, so that
    /// branch tracks the real interface scheme.
    private var mapChromeScheme: ColorScheme {
        selectedCustomSource != nil ? .light : colorScheme
    }
    private var useSheet: Bool {
        UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
    }

    @AppStorage("navShowAppleMaps") private var navShowAppleMaps: Bool = true
    @AppStorage("navShowGoogleMaps") private var navShowGoogleMaps: Bool = true
    @AppStorage("navShowTomTomGo") private var navShowTomTomGo: Bool = true

    // MARK: - Derived Data

    private var labelsWithItems: [ListLabel] {
        let usedLabelIDs = Set(welcomeViewModel.locationEntries.compactMap { $0.item.labelId })
        return welcomeViewModel.allLocationLabels
            .filter { usedLabelIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func markerTint(for entry: LocationEntry) -> Color {
        guard let hex = entry.labelColor else { return .accentColor }
        return Color(hex: hex)
    }

    private var visibleEntries: [LocationEntry] {
        var result = welcomeViewModel.locationEntries
        if !showCompleted {
            result = result.filter { !$0.item.checked }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.item.note.localizedCaseInsensitiveContains(searchText) }
        }
        if !selectedLabelIDs.isEmpty {
            result = result.filter { entry in
                guard let id = entry.item.labelId else { return false }
                return selectedLabelIDs.contains(id)
            }
        }
        return result
    }

    private var hasActiveFilters: Bool {
        showCompleted || !selectedLabelIDs.isEmpty
    }

    // MARK: - Body

    var body: some View {
        Group {
            if !welcomeViewModel.hasLoadedCounts {
                Color.clear
            } else if welcomeViewModel.locationEntries.isEmpty {
                emptyState
            } else if let src = selectedCustomSource {
                customMapContent(source: src)
            } else {
                mapContent
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let attribution = selectedLayerAttribution {
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
                    .environment(\.colorScheme, mapChromeScheme)
            }
        }
        .overlay(alignment: .top) {
            if let message = healthBannerMessage {
                healthBanner(message)
                    .environment(\.colorScheme, mapChromeScheme)
            }
        }
        .navigationTitle("Locations")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            customSources = CustomTileSourceStore.loadAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .customTileSourceChanged)) { _ in
            customSources = CustomTileSourceStore.loadAll()
        }
        // Fetchers report terminal auth failures from their own actor/threads;
        // hop to main before touching view state.
        .onReceive(NotificationCenter.default
            .publisher(for: TileLayerHealth.authFailureNotification)
            .receive(on: DispatchQueue.main)) { note in
            guard let message = note.userInfo?[TileLayerHealth.messageKey] as? String else { return }
            withAnimation { healthBannerMessage = message }
        }
        .toolbar {
#if targetEnvironment(macCatalyst)
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    toggleFocus()
                } label: {
                    Image(systemName: focusState.icon)
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                filterMenu
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                layerMenu
            }
#else
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    toggleFocus()
                } label: {
                    Image(systemName: focusState.icon)
                }
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                filterMenu
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                layerMenu
            }
#endif
        }
        // No `.toolbarColorScheme` pin here: the scroll edge effect the bars now
        // sit in (see `SlippyMapHost`) adapts glyph luminance to whatever the map
        // is actually drawing underneath, on both branches. Forcing a scheme
        // fights that adaptation rather than helping it.
    }

    // MARK: - Layer health banner

    /// Dismissible warning that a layer's server has terminally rejected it
    /// (bad key, exhausted quota). Content comes from `TileLayerHealth`.
    private func healthBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
            Spacer(minLength: 4)
            Button {
                withAnimation { healthBannerMessage = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Layer picker

    private var layerMenu: some View {
        Menu {
            // Inline so the layers list directly under the button rather than in
            // a nested "Map Layer" submenu.
            Picker("Map Layer", selection: $selectedLayerRaw) {
                Label("Apple Maps", systemImage: "map")
                    .tag(GlobalMapLayer.appleMaps)
                ForEach(customSources) { src in
                    Label(src.name, systemImage: "square.stack.3d.up")
                        .tag(src.id.uuidString)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: isCustomLayerActive
                  ? "square.stack.3d.up.fill"
                  : "square.stack.3d.up")
        }
    }

    // MARK: - Custom layer branch

    /// Fully native EPSG:27700 renderer: a slippy map drawing tiles at their
    /// native British-National-Grid resolution, no on-device reprojection.
    private func customMapContent(source: CustomTileSource) -> some View {
        withPinInteraction(
            BNGMapView(
                entries: visibleEntries,
                source: source,
                muted: mapStyleMuted,
                selectedItemID: $selectedItemID,
                visibleRegion: $visibleRegion,
                focusState: $focusState,
                popoverItemID: useSheet ? nil : popoverItem?.id,
                onPopoverAnchorChange: { customPopoverAnchor = $0 }
            )
        )
        // Arm the hand-off: whatever this renderer was last looking at is what
        // the MapKit branch should come up on when the layer is switched back.
        .onDisappear { adoptRegionOnAppear = true }
    }

    /// Wrap a full-screen map (that reports through `selectedItemID` /
    /// `visibleRegion` / `focusState` / `customPopoverAnchor`) with the shared
    /// pin popover (iPad/Mac) and sheet (iPhone), plus the selection/cycling glue.
    @ViewBuilder
    private func withPinInteraction(_ map: some View) -> some View {
        map
        .ignoresSafeArea()
        // iPad/Mac: anchor the popover bubble to the pin, matching Apple Maps.
        // This map has no SwiftUI view living at the pin (pins are UIKit inside
        // the representable), so we attach the popover to a full-screen clear view
        // and point it at the pin via an explicit `.point` attachment — the pin's
        // fraction of the same full-screen space the map reports the anchor in.
        // (A padded/offset anchor frame does not survive macCatalyst's popover
        // placement — it detaches and parks the bubble in a corner.)
        .overlay {
            if !useSheet, let anchor = customPopoverAnchor {
                GeometryReader { geo in
                    Color.clear
                        .allowsHitTesting(false)
                        .popover(
                            isPresented: $showPopover,
                            attachmentAnchor: .point(UnitPoint(
                                x: geo.size.width > 0 ? anchor.x / geo.size.width : 0.5,
                                y: geo.size.height > 0 ? anchor.y / geo.size.height : 0.5)),
                            arrowEdge: .bottom
                        ) {
                            if let item = popoverItem, let entry = popoverEntry {
                                MapPinPopover(
                                    item: item,
                                    label: entry.labelName.map { name in
                                        ListLabel(id: entry.item.labelId ?? "", name: name, color: entry.labelColor ?? "", symbol: entry.labelSymbol)
                                    },
                                    navShowAppleMaps: navShowAppleMaps,
                                    navShowGoogleMaps: navShowGoogleMaps,
                                    navShowTomTomGo: navShowTomTomGo,
                                    isPresented: $showPopover,
                                    hasPrevious: hasPrevious,
                                    hasNext: hasNext,
                                    onPrevious: cyclePrevious,
                                    onNext: cycleNext
                                ) {
                                    handlePopoverShowDetails(item: item)
                                }
                            }
                        }
                }
                .ignoresSafeArea()
            }
        }
        // The new pin's anchor arrives a runloop after the item changes (deferred
        // callback). Once it's here, relocate the popover by briefly dismissing
        // and re-presenting (a live popover won't follow `attachmentAnchor`). Only
        // fires when a target change is pending, so panning never re-presents.
        .onChange(of: customPopoverAnchor) { _, _ in
            guard reanchorPending else { return }
            reanchorPending = false
            reanchoring = true
            showPopover = false
            DispatchQueue.main.async {
                showPopover = true
                reanchoring = false
            }
        }
        .onChange(of: selectedItemID) { _, newID in
            guard let newID,
                  let entry = visibleEntries.first(where: { $0.item.id == newID }) else { return }
            selectedItemID = nil
            // Re-selecting a different pin while one is open must relocate the
            // bubble too, same as cycling.
            if showPopover { reanchorPending = true }
            popoverItem = entry.item
            popoverEntry = entry
            startCycling(from: entry.item)
            showPopover = true
        }
        // Searching while following the user's location drops back to the fit-all
        // camera, so the matches are what you're looking at. Same rule the MapKit
        // branch gets from `cameraPosition = .automatic`; the custom renderer needs
        // it stated because it has no camera position to reset. Once in `.all` the
        // renderer re-frames on its own as the entry set narrows.
        .onChange(of: searchText) { _, newText in
            if !newText.isEmpty && focusState != .all {
                focusState = .all
            }
        }
        .onChange(of: showPopover) { _, isShowing in
            // Ignore the transient dismiss that relocates the popover to a new pin.
            if !isShowing && !reanchoring {
                popoverItem = nil
                popoverEntry = nil
                visitHistory = []
            }
        }
        // iPhone (compact): bottom sheet, same as the Apple Maps branch.
        .sheet(isPresented: useSheet ? $showPopover : .constant(false)) {
            if let item = popoverItem, let entry = popoverEntry {
                NavigationStack {
                    MapPinSheetContent(
                        item: item,
                        label: entry.labelName.map { name in
                            ListLabel(id: entry.item.labelId ?? "", name: name, color: entry.labelColor ?? "", symbol: entry.labelSymbol)
                        },
                        navShowAppleMaps: navShowAppleMaps,
                        navShowGoogleMaps: navShowGoogleMaps,
                        navShowTomTomGo: navShowTomTomGo,
                        hasPrevious: hasPrevious,
                        hasNext: hasNext,
                        onPrevious: cyclePrevious,
                        onNext: cycleNext
                    ) {
                        handleSheetShowDetails(item: item, entry: entry)
                    }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Nearby Cycling (visit-history stack)

    @State private var visitHistory: [UUID] = []

    /// Entries in the visible viewport.
    private var viewportEntries: [LocationEntry] {
        guard let region = visibleRegion else { return visibleEntries }
        let latDelta = region.span.latitudeDelta / 2
        let lonDelta = region.span.longitudeDelta / 2
        let center = region.center
        return visibleEntries.filter { entry in
            guard let loc = entry.item.location else { return false }
            return abs(loc.latitude - center.latitude) <= latDelta
                && abs(loc.longitude - center.longitude) <= lonDelta
        }
    }

    /// The nearest unvisited entry in the viewport from the current pin.
    private var nextEntry: LocationEntry? {
        guard let origin = popoverItem?.location else { return nil }
        let visited = Set(visitHistory)
        return viewportEntries
            .filter { !visited.contains($0.item.id) }
            .min { Self.dist2(origin, $0.item.location) < Self.dist2(origin, $1.item.location) }
    }

    private var hasPrevious: Bool { visitHistory.count > 1 }
    private var hasNext: Bool { nextEntry != nil }

    private func startCycling(from item: ListItem) {
        visitHistory = [item.id]
    }

    private func cyclePrevious() {
        guard visitHistory.count > 1 else { return }
        visitHistory.removeLast()
        if let prevID = visitHistory.last,
           let entry = viewportEntries.first(where: { $0.item.id == prevID }) {
            reanchorPending = true
            popoverItem = entry.item
            popoverEntry = entry
        }
    }

    private func cycleNext() {
        guard let next = nextEntry else { return }
        visitHistory.append(next.item.id)
        reanchorPending = true
        popoverItem = next.item
        popoverEntry = next
    }

    private func handlePopoverShowDetails(item: ListItem) {
        showPopover = false
        if let entry = popoverEntry {
            onShowDetails?(item, entry.list)
        }
    }

    private func handleSheetShowDetails(item: ListItem, entry: LocationEntry) {
        showPopover = false
        onShowDetails?(item, entry.list)
    }

    private static func dist2(_ a: Coordinate, _ b: Coordinate?) -> Double {
        guard let b else { return .greatestFiniteMagnitude }
        let dlat = a.latitude - b.latitude
        let dlon = a.longitude - b.longitude
        return dlat * dlat + dlon * dlon
    }

    // MARK: - Map

    private var mapContent: some View {
        Map(position: $cameraPosition, selection: $selectedItemID, scope: mapScope) {
            UserAnnotation()
            ForEach(visibleEntries) { entry in
                if let loc = entry.item.location {
                    let coord = CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
                    if let symbol = entry.labelSymbol {
                        Marker(entry.item.note, systemImage: symbol, coordinate: coord)
                            .tint(markerTint(for: entry))
                            .tag(entry.item.id)
                    } else {
                        Marker(entry.item.note, coordinate: coord)
                            .tint(markerTint(for: entry))
                            .tag(entry.item.id)
                    }
                }
            }

            // Invisible annotation at the selected pin to anchor the popover (iPad/Mac only)
            if !useSheet, let item = popoverItem, let loc = item.location {
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude), anchor: .bottom) {
                    Color.clear
                        .frame(width: 36, height: 36)
                        .allowsHitTesting(false)
                        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                            if let entry = popoverEntry {
                                MapPinPopover(
                                    item: item,
                                    label: entry.labelName.map { name in
                                        ListLabel(id: entry.item.labelId ?? "", name: name, color: entry.labelColor ?? "", symbol: entry.labelSymbol)
                                    },
                                    navShowAppleMaps: navShowAppleMaps,
                                    navShowGoogleMaps: navShowGoogleMaps,
                                    navShowTomTomGo: navShowTomTomGo,
                                    isPresented: $showPopover,
                                    hasPrevious: hasPrevious,
                                    hasNext: hasNext,
                                    onPrevious: cyclePrevious,
                                    onNext: cycleNext
                                ) {
                                    handlePopoverShowDetails(item: item)
                                }
                            }
                        }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(
            emphasis: mapStyleMuted ? .muted : .automatic,
            pointsOfInterest: .excludingAll,
            showsTraffic: true
        ))
        .mapControls {
            MapCompass(scope: mapScope)
        }
        .mapScope(mapScope)
        .onAppear {
            // Preserve zoom/center when switching back from the custom-tile
            // layer — and not on any other appearance, which would trade the
            // live `.automatic` fit for a frozen region. See `adoptRegionOnAppear`.
            guard adoptRegionOnAppear else { return }
            adoptRegionOnAppear = false
            if let region = visibleRegion {
                cameraPosition = .region(region)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        // Full-bleed like the BNG branch (which uses `.ignoresSafeArea()`).
        // If this only ignored the bottom, the same region would fit into a
        // shorter frame here than there, shifting the on-screen centre when
        // switching layers.
        .ignoresSafeArea()
        .onChange(of: selectedItemID) { _, newID in
            guard let newID,
                  let entry = visibleEntries.first(where: { $0.item.id == newID }) else { return }
            selectedItemID = nil
            popoverItem = entry.item
            popoverEntry = entry
            startCycling(from: entry.item)
            showPopover = true
        }
        .onChange(of: showPopover) { _, isShowing in
            if !isShowing {
                popoverItem = nil
                popoverEntry = nil
                visitHistory = []
            }
        }
        .onChange(of: searchText) { _, newText in
            if !newText.isEmpty && focusState != .all {
                cameraPosition = .automatic
                focusState = .all
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { _ in
                    if focusState == .heading {
                        focusState = .all
                    }
                }
        )
        // Sheet for iPhone (compact size class)
        .sheet(isPresented: useSheet ? $showPopover : .constant(false)) {
            if let item = popoverItem, let entry = popoverEntry {
                NavigationStack {
                    MapPinSheetContent(
                        item: item,
                        label: entry.labelName.map { name in
                            ListLabel(id: entry.item.labelId ?? "", name: name, color: entry.labelColor ?? "", symbol: entry.labelSymbol)
                        },
                        navShowAppleMaps: navShowAppleMaps,
                        navShowGoogleMaps: navShowGoogleMaps,
                        navShowTomTomGo: navShowTomTomGo,
                        hasPrevious: hasPrevious,
                        hasNext: hasNext,
                        onPrevious: cyclePrevious,
                        onNext: cycleNext
                    ) {
                        handleSheetShowDetails(item: item, entry: entry)
                    }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Toggle Focus

    private func toggleFocus() {
        LocationPermissionManager.shared.requestIfNeeded()
        focusState = focusState.next
        switch focusState {
        case .all:     cameraPosition = .automatic
        case .city:    cameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
        case .heading: applyHeadingCamera()
        }
    }

    private func applyHeadingCamera() {
        cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    }

    // MARK: - Filter Menu

    private var filterMenu: some View {
        Menu {
            Toggle(isOn: $showCompleted) {
                Label("Show Completed", systemImage: "checkmark.circle")
            }

            if !labelsWithItems.isEmpty {
                Divider()
                ForEach(labelsWithItems) { label in
                    Toggle(isOn: Binding(
                        get: { selectedLabelIDs.contains(label.id) },
                        set: { isOn in
                            if isOn { selectedLabelIDs.insert(label.id) }
                            else { selectedLabelIDs.remove(label.id) }
                        }
                    )) {
                        Label(label.name, systemImage: label.symbol ?? "circle.fill")
                    }
                }

                if hasActiveFilters {
                    Divider()
                    Button("Clear All Filters", role: .destructive) {
                        selectedLabelIDs = []
                        showCompleted = false
                    }
                }
            }
        } label: {
            Image(systemName: hasActiveFilters
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Locations")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Paste a Google Maps or Apple Maps link on an item to pin it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
