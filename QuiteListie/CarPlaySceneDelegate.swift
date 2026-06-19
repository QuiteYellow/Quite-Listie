import CarPlay
import Combine
import CoreLocation
import MapKit
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, @preconcurrency CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private weak var templateScene: CPTemplateApplicationScene?

    private var listTemplate: CPListTemplate?
    private var poiTemplate: CPPointOfInterestTemplate?
    private var entriesByID: [String: LocationEntry] = [:]
    private var locationSink: AnyCancellable?
    private var pinsObserver: NSObjectProtocol?

    /// The currently-pushed per-label items list, so refresh() can update it in place
    /// when location moves or the user toggles a pin from the iOS app.
    private var pushedLabelList: (template: CPListTemplate, labelName: String)?

    /// Throttling state. Apple's CarPlay guide requires:
    /// — data items in the CarPlay UI refresh at most once per 10s
    /// — POIs refresh at most once per 60s (when the pin set itself hasn't changed)
    private var lastRefreshAt: Date = .distantPast
    private var pendingRefreshTask: Task<Void, Never>?
    private var lastPOIFingerprint: [String] = []
    private var lastPOIUpdateAt: Date = .distantPast

    /// Max pins CarPlay's POI template displays at once.
    private static let poiCap = 12
    /// Max rows per CPListSection — leaves headroom for the section header against
    /// the ~12 row interaction budget while driving.
    private static let listSectionCap = 11
    private static let refreshThrottleSeconds: TimeInterval = 10
    private static let poiThrottleSeconds: TimeInterval = 60

    // MARK: - Scene lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        AppLogger.ui.info("CarPlay scene connected")
        self.templateScene = templateApplicationScene
        self.interfaceController = interfaceController

        let poi = makePOITemplate()
        let list = makeListTemplate()
        self.poiTemplate = poi
        self.listTemplate = list

        let tabs = CPTabBarTemplate(templates: [poi, list])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)

        beginObserving()
        Task {
            // CarPlay can launch the app process on its own — the iOS scene's
            // WelcomeView never runs, so no one has called loadAllLists() yet
            // and allLists is empty. Kick the load from here.
            await UnifiedListProvider.shared.loadAllLists()
            await refresh()
        }
    }

    private func makeListTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Locations", sections: [])
        template.tabImage = Self.tabImage(systemName: "list.bullet")
        template.tabTitle = "List"
        template.emptyViewTitleVariants = ["No locations"]
        template.emptyViewSubtitleVariants = ["Add items with locations to your lists to see them here."]
        return template
    }

    private func makePOITemplate() -> CPPointOfInterestTemplate {
        let template = CPPointOfInterestTemplate(
            title: "Pinned",
            pointsOfInterest: [],
            selectedIndex: NSNotFound
        )
        template.tabImage = Self.tabImage(systemName: "map")
        template.tabTitle = "Map"
        return template
    }

    // MARK: - Image sizing (Apple guide §image sizing — must match maximumImageSize)

    private static func cpListImage(systemName: String) -> UIImage? {
        let target = CPListItem.maximumImageSize
        let pointSize = min(target.width, target.height) * 0.7
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return UIImage(systemName: systemName, withConfiguration: config)
    }

    private static func tabImage(systemName: String) -> UIImage? {
        // Tab images render at a system-controlled size; SF Symbols scale fine,
        // but constrain to a reasonable point size to match CarPlay's tab area.
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        return UIImage(systemName: systemName, withConfiguration: config)
    }


    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        AppLogger.ui.info("CarPlay scene disconnected")
        self.interfaceController = nil
        self.templateScene = nil
        self.listTemplate = nil
        self.poiTemplate = nil
        self.entriesByID = [:]
        locationSink?.cancel()
        locationSink = nil
        if let pinsObserver {
            NotificationCenter.default.removeObserver(pinsObserver)
        }
        pinsObserver = nil
    }

    // MARK: - Observation

    private func beginObserving() {
        // Location-driven refreshes are throttled (Apple: max once per 10s).
        locationSink = LocationPermissionManager.shared.$currentLocation
            .compactMap { $0 }
            .removeDuplicates { $0.distance(from: $1) < 50 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }

        // Pin edits in the iOS app are user-driven — bypass the throttle so the
        // driver sees their change reflected immediately.
        pinsObserver = NotificationCenter.default.addObserver(
            forName: .carPlayPinsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }

        trackProviderChanges()
    }

    private func trackProviderChanges() {
        withObservationTracking {
            _ = UnifiedListProvider.shared.allLists
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
                self?.trackProviderChanges()
            }
        }
    }

    /// Coalesces rapid refresh triggers (location ticks, provider updates) into
    /// at most one refresh per 10 seconds, per Apple's data-refresh cadence rule.
    private func scheduleRefresh() {
        pendingRefreshTask?.cancel()
        let elapsed = Date().timeIntervalSince(lastRefreshAt)
        if elapsed >= Self.refreshThrottleSeconds {
            pendingRefreshTask = Task { @MainActor [weak self] in
                await self?.refresh()
            }
        } else {
            let delay = Self.refreshThrottleSeconds - elapsed
            pendingRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        lastRefreshAt = Date()

        let provider = UnifiedListProvider.shared
        var all: [LocationEntry] = []
        for list in provider.allLists {
            let items = await provider.fetchItemsForDisplay(for: list)
            let labels = await provider.fetchLabelsForDisplay(for: list)
            all.append(contentsOf: WelcomeViewModel.locationEntries(from: items, labels: labels, list: list))
        }

        var byID: [String: LocationEntry] = [:]
        for entry in all { byID[entry.item.id.uuidString] = entry }
        self.entriesByID = byID

        let pinnedItemOrder = CarPlayPinnedStore.orderedIDs()
        let pinnedItemSet = Set(pinnedItemOrder)
        let pinnedLabelOrder = CarPlayPinnedLabelStore.orderedNames()
        let pinnedLabelSet = Set(pinnedLabelOrder)
        let here = LocationPermissionManager.shared.currentLocation
        let byDistance: (LocationEntry, LocationEntry) -> Bool = { (a, b) in
            if let here {
                return self.distance(a, from: here) < self.distance(b, from: here)
            }
            return a.item.note.localizedCaseInsensitiveCompare(b.item.note) == .orderedAscending
        }

        // Map tab: pinned items in the user's chosen order. Only re-issue
        // setPointsOfInterest when the pin set itself changes OR ≥60s have
        // elapsed since the last POI update (Apple's POI refresh cadence rule).
        let pinnedItems: [LocationEntry] = pinnedItemOrder.compactMap { byID[$0] }
        let cappedItems = Array(pinnedItems.prefix(Self.poiCap))
        let fingerprint = cappedItems.map { $0.item.id.uuidString }
        let elapsedSincePOI = Date().timeIntervalSince(lastPOIUpdateAt)
        if fingerprint != lastPOIFingerprint || elapsedSincePOI >= Self.poiThrottleSeconds {
            let pois = cappedItems.compactMap { makePOI(for: $0, here: here) }
            poiTemplate?.setPointsOfInterest(pois, selectedIndex: NSNotFound)
            lastPOIFingerprint = fingerprint
            lastPOIUpdateAt = Date()
        }

        // List tab: drill-down by label. Pinned labels (user-ordered) in a top
        // section, remaining labels alphabetical below. Each section capped at
        // listSectionCap to honour the per-list driving budget.
        let grouped = Dictionary(grouping: all) { $0.labelName ?? "" }
        let allLabelNames = grouped.keys.sorted { lhs, rhs in
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        let pinnedLabelRows: [CPListItem] = pinnedLabelOrder.compactMap { name in
            guard let entries = grouped[name], !entries.isEmpty else { return nil }
            return makeLabelRow(name: name, entries: entries, here: here)
        }
        let otherLabelRows: [CPListItem] = allLabelNames.compactMap { name in
            guard !pinnedLabelSet.contains(name) else { return nil }
            guard let entries = grouped[name], !entries.isEmpty else { return nil }
            return makeLabelRow(name: name, entries: entries, here: here)
        }

        var sections: [CPListSection] = []
        if !pinnedLabelRows.isEmpty {
            sections.append(CPListSection(
                items: Array(pinnedLabelRows.prefix(Self.listSectionCap)),
                header: "Pinned",
                sectionIndexTitle: nil
            ))
        }
        if !otherLabelRows.isEmpty {
            sections.append(CPListSection(
                items: Array(otherLabelRows.prefix(Self.listSectionCap)),
                header: pinnedLabelRows.isEmpty ? nil : "Other",
                sectionIndexTitle: nil
            ))
        }
        listTemplate?.updateSections(sections)

        // Rebuild the currently-pushed per-label items list, if any, so distance
        // changes appear without forcing the user to back out and re-enter.
        if let pushed = pushedLabelList {
            let key = pushed.labelName == "Unlabeled" ? "" : pushed.labelName
            let entries = grouped[key] ?? []
            pushed.template.updateSections([
                makeItemsSection(entries: entries, here: here, pinnedIDs: pinnedItemSet, byDistance: byDistance)
            ])
        }
    }

    private func makeLabelRow(name: String, entries: [LocationEntry], here: CLLocation?) -> CPListItem {
        let displayName = name.isEmpty ? "Unlabeled" : name
        let count = entries.count
        let detail: String
        if let here, let nearest = entries.compactMap({ entry -> CLLocationDistance? in
            guard let c = entry.item.location else { return nil }
            return here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
        }).min() {
            detail = "\(count) · \(formatDistance(nearest))"
        } else {
            detail = count == 1 ? "1 location" : "\(count) locations"
        }

        let icon: UIImage?
        if let symbol = entries.first?.labelSymbol, !symbol.isEmpty {
            icon = Self.cpListImage(systemName: symbol)
        } else {
            icon = nil
        }

        let row = CPListItem(text: displayName, detailText: detail, image: icon)
        row.handler = { [weak self] _, completion in
            Task { @MainActor [weak self] in
                self?.presentLabelItems(labelName: displayName, entries: entries)
                completion()
            }
        }
        return row
    }

    private func makeItemsSection(
        entries: [LocationEntry],
        here: CLLocation?,
        pinnedIDs: Set<String>,
        byDistance: (LocationEntry, LocationEntry) -> Bool
    ) -> CPListSection {
        let sorted = entries.sorted(by: byDistance)
        let items = sorted.prefix(Self.listSectionCap).map {
            makeListItem(for: $0, here: here, pinned: pinnedIDs.contains($0.item.id.uuidString))
        }
        return CPListSection(items: Array(items), header: nil, sectionIndexTitle: nil)
    }

    private func presentLabelItems(labelName: String, entries: [LocationEntry]) {
        let here = LocationPermissionManager.shared.currentLocation
        let pinnedIDs = CarPlayPinnedStore.ids()
        let byDistance: (LocationEntry, LocationEntry) -> Bool = { (a, b) in
            if let here {
                return self.distance(a, from: here) < self.distance(b, from: here)
            }
            return a.item.note.localizedCaseInsensitiveCompare(b.item.note) == .orderedAscending
        }
        let template = CPListTemplate(
            title: labelName,
            sections: [makeItemsSection(entries: entries, here: here, pinnedIDs: pinnedIDs, byDistance: byDistance)]
        )
        pushedLabelList = (template, labelName)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func makePOI(for entry: LocationEntry, here: CLLocation?) -> CPPointOfInterest? {
        guard let coord = entry.item.location else { return nil }
        let mapItem = MKMapItem(
            location: CLLocation(latitude: coord.latitude, longitude: coord.longitude),
            address: nil
        )
        mapItem.name = entry.item.note

        let subtitle: String
        if let here {
            let meters = here.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            subtitle = "\(formatDistance(meters)) · \(entry.list.summary.name)"
        } else {
            subtitle = entry.list.summary.name
        }

        let poi = CPPointOfInterest(
            location: mapItem,
            title: entry.item.note,
            subtitle: subtitle,
            summary: entry.labelName,
            detailTitle: entry.item.note,
            detailSubtitle: entry.list.summary.name,
            detailSummary: entry.labelName,
            pinImage: nil
        )

        poi.primaryButton = CPTextButton(title: "Navigate", textStyle: .confirm) { [weak self] _ in
            Task { @MainActor [weak self] in self?.presentNavigateActionSheet(for: entry) }
        }
        return poi
    }

    private func distance(_ entry: LocationEntry, from here: CLLocation) -> CLLocationDistance {
        guard let c = entry.item.location else { return .greatestFiniteMagnitude }
        return here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    private func makeListItem(for entry: LocationEntry, here: CLLocation?, pinned: Bool) -> CPListItem {
        let detail: String
        if let here, let c = entry.item.location {
            let meters = here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            detail = "\(formatDistance(meters)) · \(entry.list.summary.name)"
        } else {
            detail = entry.list.summary.name
        }
        let icon: UIImage? = pinned ? Self.cpListImage(systemName: "pin.fill") : nil
        let item = CPListItem(text: entry.item.note, detailText: detail, image: icon)
        item.userInfo = entry.item.id.uuidString
        item.handler = { [weak self] _, completion in
            Task { @MainActor [weak self] in
                self?.presentNavigateActionSheet(for: entry)
                completion()
            }
        }
        return item
    }

    // MARK: - Navigation routing (modal action sheet — does not consume push depth)

    private struct NavApp {
        let id: String
        let title: String
        let symbol: String
        let url: String
    }

    private static func navApps(for coord: Coordinate) -> [NavApp] {
        let destination = "\(coord.latitude),\(coord.longitude)"
        return [
            NavApp(id: "appleMaps", title: "Apple Maps", symbol: "applelogo",
                   url: "http://maps.apple.com/?daddr=\(destination)&dirflg=d"),
            NavApp(id: "googleMaps", title: "Google Maps", symbol: "globe",
                   url: "comgooglemaps://?daddr=\(destination)&directionsmode=driving"),
            NavApp(id: "tomtom", title: "TomTom", symbol: "car.fill",
                   url: "tomtomgo://x-callback-url/navigate?destination=\(destination)"),
        ]
    }

    private func enabledNavApps(for coord: Coordinate) -> [NavApp] {
        let defaults = UserDefaults.standard
        let showApple = defaults.object(forKey: "navShowAppleMaps") as? Bool ?? true
        let showGoogle = defaults.object(forKey: "navShowGoogleMaps") as? Bool ?? true
        let showTomTom = defaults.object(forKey: "navShowTomTomGo") as? Bool ?? true
        return Self.navApps(for: coord).filter { app in
            switch app.id {
            case "appleMaps": return showApple
            case "googleMaps": return showGoogle
            case "tomtom": return showTomTom
            default: return false
            }
        }
    }

    private func presentNavigateActionSheet(for entry: LocationEntry) {
        guard let coord = entry.item.location else { return }
        let apps = enabledNavApps(for: coord)
        guard !apps.isEmpty else {
            AppLogger.ui.warning("CarPlay navigate: no enabled nav apps")
            return
        }

        let preference = UserDefaults.standard.string(forKey: "defaultNavigationApp") ?? "ask"
        let here = LocationPermissionManager.shared.currentLocation

        var title = entry.item.note
        if let here, let c = entry.item.location {
            let meters = here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            title = "\(entry.item.note) · \(formatDistance(meters))"
        }
        let message = entry.list.summary.name

        var actions: [CPAlertAction] = []
        // If the user has a default app set (and it's enabled), or only one app
        // is enabled, present a single confirmation button. Otherwise list every
        // enabled app so the driver chooses with one tap.
        if preference != "ask", let match = apps.first(where: { $0.id == preference }) {
            actions.append(CPAlertAction(title: "Navigate via \(match.title)", style: .default) { [weak self] _ in
                self?.openNavURL(match.url, label: match.title)
            })
        } else if apps.count == 1 {
            let only = apps[0]
            actions.append(CPAlertAction(title: "Navigate via \(only.title)", style: .default) { [weak self] _ in
                self?.openNavURL(only.url, label: only.title)
            })
        } else {
            for app in apps {
                actions.append(CPAlertAction(title: app.title, style: .default) { [weak self] _ in
                    self?.openNavURL(app.url, label: app.title)
                })
            }
        }
        actions.append(CPAlertAction(title: "Cancel", style: .cancel) { _ in })

        let sheet = CPActionSheetTemplate(title: title, message: message, actions: actions)
        interfaceController?.presentTemplate(sheet, animated: true, completion: nil)
    }

    private func openNavURL(_ string: String, label: String) {
        AppLogger.ui.info("CarPlay navigate: \(label, privacy: .public)")
        guard let url = URL(string: string), let scene = templateScene else {
            return
        }
        scene.open(url, options: nil) { success in
            AppLogger.ui.info("CarPlay nav \(label, privacy: .public) success=\(success, privacy: .public)")
        }
    }

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 { return "\(Int(meters)) m" }
        return String(format: "%.1f km", meters / 1000)
    }
}

// MARK: - Pinned storage (device-local, not synced via .listie JSON)

extension Notification.Name {
    /// Posted whenever the CarPlay pinned-places or pinned-labels list changes.
    /// The CarPlay scene observes this so edits made in the iOS app (Settings →
    /// CarPlay Pins) take effect immediately on a live in-car session.
    static let carPlayPinsChanged = Notification.Name("carPlayPinsChanged")
}

/// Ordered list of item UUIDs the user has pinned for CarPlay.
/// Order is user-controlled (drag-to-reorder in CarPlayPinsView) and respected
/// by both the map tab (POI order) and any UI that surfaces "your pinned places".
enum CarPlayPinnedStore {
    private static let key = "carplayPinnedItemIDs"

    /// Hard cap matches CPPointOfInterestTemplate's display limit.
    static let maxCount = 12

    static func orderedIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func ids() -> Set<String> {
        Set(orderedIDs())
    }

    static func setOrderedIDs(_ ids: [String]) {
        let trimmed = Array(ids.prefix(maxCount))
        UserDefaults.standard.set(trimmed, forKey: key)
        NotificationCenter.default.post(name: .carPlayPinsChanged, object: nil)
    }
}

/// Ordered list of label names the user has pinned for CarPlay.
/// Pinned labels appear in a dedicated "Pinned" section at the top of the
/// CarPlay list tab, in the user's chosen order.
enum CarPlayPinnedLabelStore {
    private static let key = "carplayPinnedLabelNames"

    /// Leaves at least 5 slots in the ~12-row CarPlay budget for non-pinned
    /// labels plus structural rows (section headers).
    static let maxCount = 6

    static func orderedNames() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func names() -> Set<String> {
        Set(orderedNames())
    }

    static func setOrderedNames(_ names: [String]) {
        let trimmed = Array(names.prefix(maxCount))
        UserDefaults.standard.set(trimmed, forKey: key)
        NotificationCenter.default.post(name: .carPlayPinsChanged, object: nil)
    }
}
