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
#if canImport(AppKit)
import AppKit
#endif

struct GlobalMapView: View {
    var welcomeViewModel: WelcomeViewModel
    var searchText: String = ""
    /// Called when the user taps a map pin — navigate to the source list and open the item.
    var onTapItem: ((ShoppingItem, UnifiedList) -> Void)?

    @Namespace private var mapScope

    @AppStorage("mapStyleMuted") private var mapStyleMuted: Bool = true

    @State private var selectedItemID: UUID?
    @State private var selectedLabelIDs: Set<String> = []
    @State private var showCompleted: Bool = false
    @State private var cameraPosition: MapCameraPosition = .automatic

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
            if welcomeViewModel.locationEntries.isEmpty {
                emptyState
            } else {
                mapContent
            }
        }
        .navigationTitle("Locations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    LocationPermissionManager.shared.requestIfNeeded()
                    cameraPosition = .userLocation(fallback: .automatic)
                } label: {
                    Image(systemName: "location.fill")
                }
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                filterMenu
            }
        }
    }

    // MARK: - Map

    private var mapContent: some View {
        Map(position: $cameraPosition, selection: $selectedItemID, scope: mapScope) {
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
        }
        .mapStyle(.standard(
            emphasis: mapStyleMuted ? .muted : .automatic,
            pointsOfInterest: .excludingAll,
            showsTraffic: true
        ))
        .mapControls { }
        .overlay(alignment: .bottomLeading) {
            MapCompass(scope: mapScope)
                .onContinuousHover { phase in
                    #if canImport(AppKit)
                    if case .ended = phase { NSCursor.arrow.set() }
                    #endif
                }
                .padding(.bottom, 62)
                .padding(.leading, 8)
        }
        .mapScope(mapScope)
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: selectedItemID) { _, newID in
            guard let newID,
                  let entry = visibleEntries.first(where: { $0.item.id == newID }) else { return }
            selectedItemID = nil
            onTapItem?(entry.item, entry.list)
        }
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
