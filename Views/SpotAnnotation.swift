//
//  SpotAnnotation.swift
//  QuiteListie
//
//  The coloured balloon marker used to plot a pinned list item on the map.
//  `SpotAnnotationView` is an `MKMarkerAnnotationView`, so it renders the exact
//  Apple Maps balloon (tint, glyph, shadow, shape). BNGMapView hosts one of
//  these — outside an MKMapView — so the native EPSG:27700 map and Apple's own
//  map draw identical pins.
//

import MapKit
import SwiftUI

final class SpotAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    let item: ListItem
    var title: String?
    var tintHex: String?
    var symbolName: String?

    init(entry: LocationEntry) {
        let loc = entry.item.location!
        self.coordinate = CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
        self.item = entry.item
        self.title = entry.item.note
        self.tintHex = entry.labelColor
        self.symbolName = entry.labelSymbol
        super.init()
    }

    func update(from entry: LocationEntry) {
        title = entry.item.note
        tintHex = entry.labelColor
        symbolName = entry.labelSymbol
    }
}

final class SpotAnnotationView: MKMarkerAnnotationView {
    static let reuseID = "spot"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        displayPriority = .required
        collisionMode = .circle
        // Icon only — no titles. Users get details via tap → sheet/popover,
        // matching Apple Maps' clean map view.
        titleVisibility = .hidden
        subtitleVisibility = .hidden
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    func configure(with spot: SpotAnnotation) {
        markerTintColor = spot.tintHex.map { UIColor(Color(hex: $0)) } ?? .systemBlue
        glyphImage = spot.symbolName.flatMap { UIImage(systemName: $0) }
    }
}
