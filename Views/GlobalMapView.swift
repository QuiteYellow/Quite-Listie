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
    var onShowDetails: ((ShoppingItem, UnifiedList) -> Void)?

    @Namespace private var mapScope

    @AppStorage("mapStyleMuted") private var mapStyleMuted: Bool = true

    @State private var selectedItemID: UUID?
    @State private var selectedLabelIDs: Set<String> = []
    @State private var showCompleted: Bool = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var focusState: MapFocusState = .all
    @State private var popoverItem: ShoppingItem? = nil
    @State private var popoverEntry: LocationEntry? = nil
    @State private var showPopover: Bool = false
    @State private var visibleRegion: MKCoordinateRegion?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var useSheet: Bool {
        UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
    }

    @AppStorage("navShowAppleMaps") private var navShowAppleMaps: Bool = true
    @AppStorage("navShowGoogleMaps") private var navShowGoogleMaps: Bool = true
    @AppStorage("navShowTomTomGo") private var navShowTomTomGo: Bool = true

    // MARK: - Derived Data

    private var labelsWithItems: [ShoppingLabel] {
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
            if !welcomeViewModel.hasLoadedLocations {
                Color.clear
            } else if welcomeViewModel.locationEntries.isEmpty {
                emptyState
            } else {
                mapContent
            }
        }
        .navigationTitle("Locations")
        .navigationBarTitleDisplayMode(.inline)
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
#endif
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

    private func startCycling(from item: ShoppingItem) {
        visitHistory = [item.id]
    }

    private func cyclePrevious() {
        guard visitHistory.count > 1 else { return }
        visitHistory.removeLast()
        if let prevID = visitHistory.last,
           let entry = viewportEntries.first(where: { $0.item.id == prevID }) {
            popoverItem = entry.item
            popoverEntry = entry
        }
    }

    private func cycleNext() {
        guard let next = nextEntry else { return }
        visitHistory.append(next.item.id)
        popoverItem = next.item
        popoverEntry = next
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
                                        ShoppingLabel(id: entry.item.labelId ?? "", name: name, color: entry.labelColor ?? "", symbol: entry.labelSymbol)
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
                                    showPopover = false
                                    if let entry = popoverEntry {
                                        onShowDetails?(item, entry.list)
                                    }
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
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        .ignoresSafeArea(edges: .bottom)
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
                            ShoppingLabel(id: entry.item.labelId ?? "", name: name, color: entry.labelColor ?? "", symbol: entry.labelSymbol)
                        },
                        navShowAppleMaps: navShowAppleMaps,
                        navShowGoogleMaps: navShowGoogleMaps,
                        navShowTomTomGo: navShowTomTomGo,
                        hasPrevious: hasPrevious,
                        hasNext: hasNext,
                        onPrevious: cyclePrevious,
                        onNext: cycleNext
                    ) {
                        showPopover = false
                        onShowDetails?(item, entry.list)
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
