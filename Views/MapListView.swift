//
//  MapListView.swift
//  QuiteListie
//
//  Displays items with pinned locations on an iOS 17+ MapKit map.
//  Search filtering is driven by the existing search bar via searchText.
//  Label filtering is driven by the bottom-bar Menu in ListView via selectedLabelIDs.
//

import CoreLocation
import SwiftUI
import MapKit

struct MapListView: View {
    let items: [ListItem]
    let labels: [ListLabel]
    @Binding var selectedLabelIDs: Set<String>
    @Binding var cameraPosition: MapCameraPosition
    var showCompleted: Bool = false
    var searchText: String = ""
    var onEdit: ((ListItem) -> Void)?
    var onAddAtLocation: ((Coordinate) -> Void)? = nil
    var isLoaded: Bool = true
    var onUserCameraInteraction: (() -> Void)? = nil

    @Namespace private var mapScope

    @AppStorage("mapStyleMuted") private var mapStyleMuted: Bool = true

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var useSheet: Bool {
        UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
    }

    @State private var selectedItemID: UUID?
    @State private var popoverItem: ListItem? = nil
    @State private var showPopover: Bool = false
    @State private var visibleRegion: MKCoordinateRegion?
    @GestureState private var pressLocation: CGPoint? = nil

    @AppStorage("navShowAppleMaps") private var navShowAppleMaps: Bool = true
    @AppStorage("navShowGoogleMaps") private var navShowGoogleMaps: Bool = true
    @AppStorage("navShowTomTomGo") private var navShowTomTomGo: Bool = true

    /// Keyed by label ID for O(1) lookup per marker.
    private var labelByID: [String: ListLabel] {
        Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
    }

    private func markerTint(for item: ListItem) -> Color {
        guard let labelId = item.labelId, let label = labelByID[labelId] else {
            return .accentColor
        }
        return Color(hex: label.color)
    }

    // Active location items — excludes deleted items and, by default, completed ones.
    private var allLocationItems: [ListItem] {
        items.filter { $0.location != nil && !$0.isDeleted }
    }

    // Items visible on the map after completed / search / label filters are applied.
    private var visibleItems: [ListItem] {
        var result = allLocationItems
        if !showCompleted {
            result = result.filter { !$0.checked }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.note.localizedCaseInsensitiveContains(searchText) }
        }
        if !selectedLabelIDs.isEmpty {
            result = result.filter { item in
                guard let id = item.labelId else { return false }
                return selectedLabelIDs.contains(id)
            }
        }
        return result
    }

    var body: some View {
        if !isLoaded {
            Color.clear
        } else if allLocationItems.isEmpty {
            emptyState
        } else {
            mapContent
        }
    }

    // MARK: - Nearby Cycling (visit-history stack)

    /// Stack of visited item IDs. The current item is always at the top.
    @State private var visitHistory: [UUID] = []

    /// Items in the visible viewport.
    private var viewportItems: [ListItem] {
        guard let region = visibleRegion else { return visibleItems }
        let latDelta = region.span.latitudeDelta / 2
        let lonDelta = region.span.longitudeDelta / 2
        let center = region.center
        return visibleItems.filter { item in
            guard let loc = item.location else { return false }
            return abs(loc.latitude - center.latitude) <= latDelta
                && abs(loc.longitude - center.longitude) <= lonDelta
        }
    }

    /// The nearest unvisited item in the viewport from the current pin.
    private var nextItem: ListItem? {
        guard let origin = popoverItem?.location else { return nil }
        let visited = Set(visitHistory)
        return viewportItems
            .filter { !visited.contains($0.id) }
            .min { Self.dist2(origin, $0.location) < Self.dist2(origin, $1.location) }
    }

    private var hasPrevious: Bool { visitHistory.count > 1 }
    private var hasNext: Bool { nextItem != nil }

    private func startCycling(from item: ListItem) {
        visitHistory = [item.id]
    }

    private func cyclePrevious() {
        guard visitHistory.count > 1 else { return }
        visitHistory.removeLast()
        if let prevID = visitHistory.last,
           let item = viewportItems.first(where: { $0.id == prevID }) {
            popoverItem = item
        }
    }

    private func cycleNext() {
        guard let next = nextItem else { return }
        visitHistory.append(next.id)
        popoverItem = next
    }

    private static func dist2(_ a: Coordinate, _ b: Coordinate?) -> Double {
        guard let b else { return .greatestFiniteMagnitude }
        let dlat = a.latitude - b.latitude
        let dlon = a.longitude - b.longitude
        return dlat * dlat + dlon * dlon
    }

    // MARK: - Map

    private var mapContent: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, selection: $selectedItemID, scope: mapScope) {
                UserAnnotation()
                ForEach(visibleItems) { item in
                    if let loc = item.location {
                        let coord = CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
                        if let symbol = labelByID[item.labelId ?? ""]?.symbol {
                            Marker(item.note, systemImage: symbol, coordinate: coord)
                                .tint(markerTint(for: item))
                                .tag(item.id)
                        } else {
                            Marker(item.note, coordinate: coord)
                                .tint(markerTint(for: item))
                                .tag(item.id)
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
                                MapPinPopover(
                                    item: item,
                                    label: item.labelId.flatMap { labelByID[$0] },
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
                                    onEdit?(item)
                                }
                            }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(emphasis: mapStyleMuted ? .muted : .automatic, pointsOfInterest: .excludingAll, showsTraffic: true))
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
                      let item = visibleItems.first(where: { $0.id == newID }) else { return }
                selectedItemID = nil
                popoverItem = item
                startCycling(from: item)
                showPopover = true
            }
            .onChange(of: showPopover) { _, isShowing in
                if !isShowing {
                    popoverItem = nil
                    visitHistory = []
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($pressLocation) { value, state, _ in
                        state = value.startLocation
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { _ in onUserCameraInteraction?() }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        guard let onAddAtLocation,
                              let point = pressLocation,
                              let clCoord = proxy.convert(point, from: .local) else { return }
                        onAddAtLocation(Coordinate(latitude: clCoord.latitude, longitude: clCoord.longitude))
                    }
            )
            // Sheet for iPhone (compact size class)
            .sheet(isPresented: useSheet ? $showPopover : .constant(false)) {
                if let item = popoverItem {
                    NavigationStack {
                        MapPinSheetContent(
                            item: item,
                            label: item.labelId.flatMap { labelByID[$0] },
                            navShowAppleMaps: navShowAppleMaps,
                            navShowGoogleMaps: navShowGoogleMaps,
                            navShowTomTomGo: navShowTomTomGo,
                            hasPrevious: hasPrevious,
                            hasNext: hasNext,
                            onPrevious: cyclePrevious,
                            onNext: cycleNext
                        ) {
                            showPopover = false
                            onEdit?(item)
                        }
                    }
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                }
            }
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
            Text("No items are pinned yet. Open an item and tap Location to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Map Pin Sheet (iPhone)

struct MapPinSheetContent: View {
    @Environment(\.dismiss) private var dismiss
    let item: ListItem
    let label: ListLabel?
    let navShowAppleMaps: Bool
    let navShowGoogleMaps: Bool
    let navShowTomTomGo: Bool
    var hasPrevious: Bool = false
    var hasNext: Bool = false
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    let onShowDetails: () -> Void

    private var sourceURLLabel: String {
        guard let url = item.sourceURL, let parsed = URL(string: url) else { return "View in Maps" }
        let host = parsed.host ?? ""
        if host.contains("google.com") || host.contains("goo.gl") { return "View in Google Maps" }
        if host.contains("apple.com") || host.contains("link.maps.apple") { return "View in Apple Maps" }
        return "View in Maps"
    }

    var body: some View {
        List {
            Section {
                Text(item.note)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if let coord = item.location {
                Section {
                    if navShowAppleMaps {
                        Button { openInAppleMaps(coord) } label: {
                            Label("Navigate with Apple Maps", systemImage: "map")
                        }
                    }
                    if navShowGoogleMaps {
                        Button { openInGoogleMaps(coord) } label: {
                            Label("Navigate with Google Maps", systemImage: "globe")
                        }
                    }
                    #if !targetEnvironment(macCatalyst)
                    if navShowTomTomGo {
                        Button { navigateInTomTomGo(coord) } label: {
                            Label("Navigate with TomTom Go", systemImage: "car.fill")
                        }
                    }
                    #endif
                }

                if let url = item.sourceURL, !url.isEmpty {
                    Section {
                        Button { openURL(url) } label: {
                            Label(sourceURLLabel, systemImage: "safari")
                        }
                    }
                }
            }

            Section {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onShowDetails()
                    }
                } label: {
                    Label("Show Details", systemImage: "info.circle")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .symbolRenderingMode(.hierarchical)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { onPrevious?() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!hasPrevious)

                Button { onNext?() } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!hasNext)
            }
        }
    }

    private func openInAppleMaps(_ coord: Coordinate) {
        var components = URLComponents(string: "maps://")!
        components.queryItems = [
            URLQueryItem(name: "daddr", value: "\(coord.latitude),\(coord.longitude)")
        ]
        if let url = components.url { UIApplication.shared.open(url) }
    }

    private func openInGoogleMaps(_ coord: Coordinate) {
        let destination = "\(coord.latitude),\(coord.longitude)"
        if let appURL = URL(string: "comgooglemaps://?daddr=\(destination)&directionsmode=driving"),
           UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else if let webURL = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(destination)") {
            UIApplication.shared.open(webURL)
        }
    }

    private func navigateInTomTomGo(_ coord: Coordinate) {
        let destination = "\(coord.latitude),\(coord.longitude)"
        if let url = URL(string: "tomtomgo://x-callback-url/navigate?destination=\(destination)") {
            UIApplication.shared.open(url)
        }
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Map Pin Popover (iPad/Mac)

struct MapPinPopover: View {
    let item: ListItem
    let label: ListLabel?
    let navShowAppleMaps: Bool
    let navShowGoogleMaps: Bool
    let navShowTomTomGo: Bool
    @Binding var isPresented: Bool
    var hasPrevious: Bool = false
    var hasNext: Bool = false
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    let onShowDetails: () -> Void

    private var tintColor: Color {
        if let label { Color(hex: label.color) } else { .accentColor }
    }

    private var sourceURLLabel: String {
        guard let url = item.sourceURL, let parsed = URL(string: url) else { return "View in Maps" }
        let host = parsed.host ?? ""
        if host.contains("google.com") || host.contains("goo.gl") { return "View in Google Maps" }
        if host.contains("apple.com") || host.contains("link.maps.apple") { return "View in Apple Maps" }
        return "View in Maps"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title with prev/next arrows
            HStack {
                Button { onPrevious?() } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(!hasPrevious)
                .opacity(hasPrevious ? 1 : 0.3)

                Text(item.note)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)

                Button { onNext?() } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(!hasNext)
                .opacity(hasNext ? 1 : 0.3)
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // Navigate section
            if let coord = item.location {
                VStack(spacing: 0) {
                    if navShowAppleMaps {
                        popoverButton("Navigate with Apple Maps", icon: "map") {
                            openInAppleMaps(coord)
                        }
                    }
                    if navShowGoogleMaps {
                        popoverButton("Navigate with Google Maps", icon: "globe") {
                            openInGoogleMaps(coord)
                        }
                    }
                    #if !targetEnvironment(macCatalyst)
                    if navShowTomTomGo {
                        popoverButton("Navigate with TomTom Go", icon: "car.fill") {
                            navigateInTomTomGo(coord)
                        }
                    }
                    #endif
                }

                // View source URL section
                if let url = item.sourceURL, !url.isEmpty {
                    Divider()
                    popoverButton(sourceURLLabel, icon: "safari") {
                        openURL(url)
                    }
                }
            }

            Divider()

            // Show details
            popoverButton("Show Details", icon: "info.circle") {
                onShowDetails()
            }
            .padding(.bottom, 4)
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private func popoverButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Navigation Helpers

    private func openInAppleMaps(_ coord: Coordinate) {
        var components = URLComponents(string: "maps://")!
        components.queryItems = [
            URLQueryItem(name: "daddr", value: "\(coord.latitude),\(coord.longitude)")
        ]
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }

    private func openInGoogleMaps(_ coord: Coordinate) {
        let destination = "\(coord.latitude),\(coord.longitude)"
        if let appURL = URL(string: "comgooglemaps://?daddr=\(destination)&directionsmode=driving"),
           UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else if let webURL = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(destination)") {
            UIApplication.shared.open(webURL)
        }
    }

    private func navigateInTomTomGo(_ coord: Coordinate) {
        let destination = "\(coord.latitude),\(coord.longitude)"
        if let url = URL(string: "tomtomgo://x-callback-url/navigate?destination=\(destination)") {
            UIApplication.shared.open(url)
        }
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}
