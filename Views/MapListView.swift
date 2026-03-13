//
//  MapListView.swift
//  QuiteListie
//
//  Displays items with pinned locations on an iOS 17+ MapKit map.
//  Search filtering is driven by the existing search bar via searchText.
//  Label filtering is driven by the bottom-bar Menu in ShoppingListView via selectedLabelIDs.
//

import CoreLocation
import SwiftUI
import MapKit

struct MapListView: View {
    let items: [ShoppingItem]
    let labels: [ShoppingLabel]
    @Binding var selectedLabelIDs: Set<String>
    @Binding var cameraPosition: MapCameraPosition
    var showCompleted: Bool = false
    var searchText: String = ""
    var onEdit: ((ShoppingItem) -> Void)?
    var onAddAtLocation: ((Coordinate) -> Void)? = nil

    @Namespace private var mapScope

    @AppStorage("mapStyleMuted") private var mapStyleMuted: Bool = true

    @State private var selectedItemID: UUID?
    @GestureState private var pressLocation: CGPoint? = nil

    /// Keyed by label ID for O(1) lookup per marker.
    private var labelByID: [String: ShoppingLabel] {
        Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
    }

    private func markerTint(for item: ShoppingItem) -> Color {
        guard let labelId = item.labelId, let label = labelByID[labelId] else {
            return .accentColor
        }
        return Color(hex: label.color)
    }

    // Active location items — excludes deleted items and, by default, completed ones.
    private var allLocationItems: [ShoppingItem] {
        items.filter { $0.location != nil && !$0.isDeleted }
    }

    // Items visible on the map after completed / search / label filters are applied.
    private var visibleItems: [ShoppingItem] {
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
        if allLocationItems.isEmpty {
            emptyState
        } else {
            mapContent
        }
    }

    // MARK: - Map

    private var mapContent: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, selection: $selectedItemID, scope: mapScope) {
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
            }
            .mapStyle(.standard(emphasis: mapStyleMuted ? .muted : .automatic, pointsOfInterest: .excludingAll, showsTraffic: true))
            .mapControls {
                MapCompass(scope: mapScope)
            }
            .mapScope(mapScope)
            .ignoresSafeArea(edges: .bottom)

            .onChange(of: selectedItemID) { _, newID in
                guard let newID,
                      let item = visibleItems.first(where: { $0.id == newID }) else { return }
                selectedItemID = nil
                onEdit?(item)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($pressLocation) { value, state, _ in
                        state = value.startLocation
                    }
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
