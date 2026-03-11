//
//  MapListView.swift
//  QuiteListie
//
//  Displays items with pinned locations on an iOS 17+ MapKit map.
//  Search filtering is driven by the existing search bar via searchText.
//  Label filtering is driven by the bottom-bar Menu in ShoppingListView via selectedLabelIDs.
//

import SwiftUI
import MapKit

struct MapListView: View {
    let items: [ShoppingItem]
    let labels: [ShoppingLabel]
    @Binding var selectedLabelIDs: Set<String>
    var showCompleted: Bool = false
    var searchText: String = ""
    var onEdit: ((ShoppingItem) -> Void)?

    @AppStorage("mapStyleMuted") private var mapStyleMuted: Bool = true

    @State private var selectedItemID: UUID?

    /// Keyed by label ID for O(1) colour lookup per marker.
    private var labelColorByID: [String: Color] {
        Dictionary(uniqueKeysWithValues: labels.map { ($0.id, Color(hex: $0.color)) })
    }

    private func markerTint(for item: ShoppingItem) -> Color {
        guard let labelId = item.labelId,
              let color = labelColorByID[labelId] else {
            return .accentColor
        }
        return color
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
        Map(selection: $selectedItemID) {
            ForEach(visibleItems) { item in
                if let loc = item.location {
                    Marker(
                        item.note,
                        coordinate: CLLocationCoordinate2D(
                            latitude: loc.latitude,
                            longitude: loc.longitude
                        )
                    )
                    .tint(markerTint(for: item))
                    .tag(item.id)
                }
            }
        }
        .mapStyle(.standard(emphasis: mapStyleMuted ? .muted : .automatic, pointsOfInterest: .excludingAll, showsTraffic: true))
        .mapControls { }
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: selectedItemID) { _, newID in
            guard let newID,
                  let item = visibleItems.first(where: { $0.id == newID }) else { return }
            selectedItemID = nil
            onEdit?(item)
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
