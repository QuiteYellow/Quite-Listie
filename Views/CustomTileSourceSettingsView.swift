//
//  CustomTileSourceSettingsView.swift
//  QuiteListie
//
//  Configure EPSG:27700 (British National Grid) map layers. The user pastes a
//  single WMTS endpoint (which already carries the API key as `?key=…`); we scan
//  its capabilities, list every EPSG:27700 layer it offers, and the user adds
//  the ones they want. Each added layer — with a friendly, editable name —
//  appears as its own choice on the map. BNG only: non-27700 layers are
//  filtered out of the scan.
//

import SwiftUI
import CoreLocation

struct CustomTileSourceSettingsView: View {
    @State private var wmtsEndpoint: String = ""
    @State private var scanState: ScanState = .idle
    @State private var discovered: [DiscoveredLayer] = []
    @State private var added: [CustomTileSource] = []
    @State private var standardLayers: [StandardTileSource] = []
    @State private var showAddStandard: Bool = false
    @State private var editingLayer: StandardTileSource? = nil

    @State private var cacheBytes: Int64 = 0
    @State private var cacheRows: [CacheRow] = []
    @State private var loadingCache: Bool = true
    @State private var showClearConfirm: Bool = false
    /// Set from the user's location (when known): true only when they're
    /// clearly outside EPSG:27700 coverage, which earns a footer hint.
    @State private var isOutsideGreatBritain: Bool = false
    /// Per-layer "Test layer" probe state, keyed by source id.
    @State private var wmtsTests: [UUID: LayerTestState] = [:]

    @ObservedObject private var offlineManager = OfflineRegionManager.shared
    @State private var offlineRegions: [OfflineRegion] = []
    @State private var showRegionPicker = false
    @State private var cacheCap: Int64 = TileDiskCache.capBytes

    enum LayerTestState: Equatable {
        case running
        case done(TileLayerTester.Outcome)
    }

    /// One layer's slice of the tile cache (or the leftovers of removed layers).
    struct CacheRow: Identifiable {
        let id: String       // cache namespace (directory name)
        let name: String
        let bytes: Int64
        /// Namespaces of removed layers, lumped into one clearable row.
        var orphanNamespaces: [String]? = nil
    }

    enum ScanState: Equatable {
        case idle
        case running
        case done(count: Int)
        case failed(message: String)
    }

    /// A EPSG:27700 layer found by scanning the WMTS endpoint, with the ZXY tile
    /// template derived for it and its tile-grid parameters read from the caps.
    struct DiscoveredLayer: Identifiable {
        let id: String            // WMTS layer identifier
        let title: String
        let zxyTemplate: String
        let caps: CustomTileSource.ValidatedCapabilities
    }

    // A fake colon (U+A789) keeps the example from being read as a live URL.
    private let exampleWMTS = "https\u{A789}//api.example.co/maps/wmts?key=…"

    private var canScan: Bool {
        !wmtsEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField(exampleWMTS, text: $wmtsEndpoint, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(1...4)
                    .font(.system(.footnote, design: .monospaced))

                Button {
                    Task { await scan() }
                } label: {
                    HStack {
                        Label {
                            Text(scanButtonLabel)
                        } icon: {
                            switch scanState {
                            case .running: ProgressView().controlSize(.small)
                            case .done:    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            case .failed:  Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
                            case .idle:    Image(systemName: "sparkle.magnifyingglass")
                            }
                        }
                        Spacer()
                    }
                }
                .disabled(!canScan || scanState == .running)

                if case .failed(let message) = scanState {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Label("WMTS Endpoint", systemImage: "point.3.connected.trianglepath.dotted")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste a British National Grid (EPSG:27700) “WMTS API” address that includes your key. Scanning lists every EPSG:27700 layer it offers so you can add the ones you want.")
                    Text("British National Grid covers Great Britain only — Northern Ireland services use the Irish Grid and won’t appear here.")
                    if isOutsideGreatBritain {
                        Text("Your location looks to be outside Great Britain, so these layers won’t cover where you are.")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !discovered.isEmpty {
                Section {
                    ForEach(discovered) { layer in
                        discoveredRow(layer)
                    }
                } header: {
                    Label("Discovered Layers", systemImage: "square.stack.3d.up")
                } footer: {
                    Text("EPSG:27700 layers only — anything in another projection is hidden.")
                }
            }

            if !added.isEmpty {
                Section {
                    ForEach(added) { src in
                        addedRow(src)
                    }
                    .onDelete(perform: deleteAdded)
                } header: {
                    Label("Your Map Layers", systemImage: "map")
                } footer: {
                    Text("These appear in the map’s layer menu. Rename them to whatever you like. Attribution shows as a small caption on the map — check what credit your provider’s licence requires.")
                }
            }

            Section {
                ForEach(standardLayers) { layer in
                    Button {
                        editingLayer = layer
                    } label: {
                        HStack {
                            Image(systemName: "map").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(layer.name).foregroundStyle(.primary)
                                // Display-only key redaction; the editor keeps
                                // the full value.
                                Text(TileURLKeys.redactingAuthParams(in: layer.urlTemplate))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete(perform: deleteStandard)

                Button {
                    showAddStandard = true
                } label: {
                    Label("Add Standard Layer", systemImage: "plus.circle.fill")
                }
            } header: {
                Label("Standard Projection Layers", systemImage: "globe")
            } footer: {
                Text("Web-Mercator (EPSG:3857) XYZ layers — the standard projection MapKit draws directly. Paste a tile URL with {z}/{x}/{y} placeholders and name it. Add as many as you like; they appear in the map’s layer menu.")
            }

            Section {
                ForEach(offlineRegions) { region in
                    offlineRegionRow(region)
                }
                Button {
                    showRegionPicker = true
                } label: {
                    Label("Add Offline Map", systemImage: "square.and.arrow.down")
                }
                .disabled(added.isEmpty && standardLayers.isEmpty)
            } header: {
                Label("Offline Maps", systemImage: "arrow.down.circle")
            } footer: {
                Text("Downloads an area of one layer for use without signal. Stored outside the cache, never auto-evicted. Check your map provider’s terms before bulk downloading — many tile services restrict it.")
            }

            Section {
                HStack {
                    Text("Cache Size")
                    Spacer()
                    if loadingCache {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(formatBytes(cacheBytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Picker("Cache Limit", selection: $cacheCap) {
                    Text("Small (0.5 GB)").tag(TileDiskCache.capChoices[0])
                    Text("Medium (1 GB)").tag(TileDiskCache.capChoices[1])
                    Text("Large (3 GB)").tag(TileDiskCache.capChoices[2])
                }
                .onChange(of: cacheCap) { old, new in
                    TileDiskCache.setCapBytes(new)
                    // Shrinking must bite immediately, not at the next debounce.
                    if new < old {
                        Task.detached(priority: .utility) { TileDiskCache.trim() }
                        Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            await refreshCacheSize()
                        }
                    }
                }
                ForEach(cacheRows) { row in
                    HStack {
                        Text(row.name)
                            .foregroundStyle(row.orphanNamespaces == nil ? .primary : .secondary)
                        Spacer()
                        Text(formatBytes(row.bytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            clearCacheRow(row)
                        } label: {
                            Label("Clear", systemImage: "trash.slash")
                        }
                    }
                }
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("Clear Cache", systemImage: "trash.slash")
                }
                .disabled(cacheBytes == 0)
            } header: {
                Label("Cache", systemImage: "internaldrive")
            } footer: {
                Text("Tiles are stored on this device (up to \(formatBytes(TileDiskCache.capBytes)), oldest evicted first) so panning back to a previously viewed area doesn’t re-download. Swipe a layer to clear just its tiles; clearing never removes the layers themselves.")
            }
        }
        .navigationTitle("Custom Map Layers")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            added = CustomTileSourceStore.loadAll()
            standardLayers = StandardTileSourceStore.loadAll()
            offlineRegions = OfflineRegionStore.loadAll()
            if let existing = added.first { wmtsEndpoint = existing.wmtsEndpoint }
            // Only hint when a location is known *and* clearly outside GB —
            // no location means no hint, not a scary warning.
            if let loc = LocationPermissionManager.shared.currentLocation {
                isOutsideGreatBritain = !BNGProjection.isLikelyInGreatBritain(
                    lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            }
            await refreshCacheSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlineRegionsChanged)
            .receive(on: DispatchQueue.main)) { _ in
            offlineRegions = OfflineRegionStore.loadAll()
        }
        .sheet(isPresented: $showRegionPicker) {
            OfflineRegionPickerView()
        }
        .sheet(isPresented: $showAddStandard) {
            StandardLayerEditorView { newLayer in
                StandardTileSourceStore.upsert(newLayer)
                standardLayers = StandardTileSourceStore.loadAll()
            }
        }
        .sheet(item: $editingLayer) { layer in
            StandardLayerEditorView(
                editing: layer,
                onDelete: {
                    StandardTileSourceStore.remove(id: layer.id)
                    standardLayers = StandardTileSourceStore.loadAll()
                },
                onSave: { updated in
                    StandardTileSourceStore.upsert(updated)
                    standardLayers = StandardTileSourceStore.loadAll()
                })
        }
        .confirmationDialog("Clear the tile cache?",
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                TileDiskCache.clearAll()
                Task { await refreshCacheSize() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all cached tiles from every layer. Tiles will be re-downloaded on next view.")
        }
    }

    // MARK: - Offline regions

    @ViewBuilder
    private func offlineRegionRow(_ region: OfflineRegion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(region.name)
                Spacer()
                if offlineManager.isDownloading(region.id) {
                    Button("Cancel") {
                        offlineManager.cancelDownload(regionID: region.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                } else if !region.downloadComplete {
                    Button("Resume") {
                        offlineManager.startDownload(region)
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
            Text(regionDetail(region))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let p = offlineManager.progress[region.id] {
                ProgressView(value: p.fraction)
                Text("\(p.completed.formatted()) of \(p.total.formatted()) tiles · \(formatBytes(p.bytes)) of ~\(formatBytes(p.estimatedTotalBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if region.downloadComplete {
                Toggle("Refresh monthly", isOn: autoRefreshBinding(for: region.id))
                    .font(.footnote)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                offlineManager.delete(region)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func regionDetail(_ region: OfflineRegion) -> String {
        let layerName = OfflineLayerRef.resolve(id: region.layerID)?.displayName ?? "missing layer"
        var parts = [layerName,
                     "z\(region.minZoom)–\(region.maxZoom)",
                     "\(region.tileCount.formatted()) tiles",
                     formatBytes(region.sizeBytes)]
        if let refreshed = region.lastRefreshed {
            parts.append("refreshed \(refreshed.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    /// Write-through auto-refresh toggle. First enable asks for notification
    /// permission (refresh results arrive as local notifications) and arms
    /// the background-processing slot.
    private func autoRefreshBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { offlineRegions.first(where: { $0.id == id })?.autoRefresh ?? false },
            set: { enabled in
                guard var region = offlineRegions.first(where: { $0.id == id }) else { return }
                region.autoRefresh = enabled
                OfflineRegionStore.upsert(region)
                if enabled {
                    OfflineRegionManager.requestNotificationPermissionIfNeeded()
                    BackgroundRefreshManager.scheduleOfflineTileRefresh()
                }
            })
    }

    // MARK: - Rows

    @ViewBuilder
    private func addedRow(_ src: CustomTileSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
                TextField("Layer name", text: nameBinding(for: src.id))
                    .submitLabel(.done)
                Spacer()
                if wmtsTests[src.id] == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Test") { runTest(for: src) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            TextField("Attribution (optional)", text: attributionBinding(for: src.id))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if case .done(let outcome) = wmtsTests[src.id] {
                TestResultLabel(outcome: outcome)
            }
        }
    }

    /// Fetch one in-range tile for an added WMTS layer and report inline.
    private func runTest(for src: CustomTileSource) {
        wmtsTests[src.id] = .running
        Task {
            let outcome = await TileLayerTester.test(source: src)
            wmtsTests[src.id] = .done(outcome)
        }
    }

    @ViewBuilder
    private func discoveredRow(_ layer: DiscoveredLayer) -> some View {
        let isAdded = added.contains { $0.zxyTemplate == layer.zxyTemplate }
        Button {
            if !isAdded { add(layer) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(layer.title)
                        .foregroundStyle(.primary)
                    Text(layer.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isAdded {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(isAdded)
    }

    /// A name binding that writes straight through to the store on every edit,
    /// so renames persist without needing an explicit submit.
    private func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { added.first(where: { $0.id == id })?.name ?? "" },
            set: { newName in
                guard let idx = added.firstIndex(where: { $0.id == id }) else { return }
                added[idx].name = newName
                CustomTileSourceStore.upsert(added[idx])
            })
    }

    /// Write-through binding for the per-layer attribution caption.
    private func attributionBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { added.first(where: { $0.id == id })?.attribution ?? "" },
            set: { newValue in
                guard let idx = added.firstIndex(where: { $0.id == id }) else { return }
                added[idx].attribution = newValue.isEmpty ? nil : newValue
                CustomTileSourceStore.upsert(added[idx])
            })
    }

    private func deleteStandard(_ offsets: IndexSet) {
        for i in offsets { StandardTileSourceStore.remove(id: standardLayers[i].id) }
        standardLayers = StandardTileSourceStore.loadAll()
    }

    private var scanButtonLabel: String {
        switch scanState {
        case .idle:               return "Scan for Layers"
        case .running:            return "Scanning…"
        case .done(let count):    return "Scan again (\(count) found)"
        case .failed:             return "Retry scan"
        }
    }

    // MARK: - Actions

    private func add(_ layer: DiscoveredLayer) {
        let source = CustomTileSource(
            name: layer.title,
            wmtsEndpoint: wmtsEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            zxyTemplate: layer.zxyTemplate,
            validated: layer.caps)
        CustomTileSourceStore.upsert(source)
        added = CustomTileSourceStore.loadAll()
    }

    private func deleteAdded(_ offsets: IndexSet) {
        for i in offsets { CustomTileSourceStore.remove(id: added[i].id) }
        added = CustomTileSourceStore.loadAll()
    }

    // MARK: - Scan

    private func scan() async {
        scanState = .running
        discovered = []
        let endpoint = wmtsEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        // ATS can't be relaxed at runtime, so a plain-http endpoint would scan
        // over TLS-less HTTP only to produce layers whose tiles never load.
        guard endpoint.lowercased().hasPrefix("https://") else {
            scanState = .failed(message: "Use an https:// address — iOS blocks insecure connections.")
            return
        }
        do {
            let caps = try await WMTSCapabilitiesLoader.discover(fromWMTSEndpoint: endpoint)
            var found: [DiscoveredLayer] = []
            for layer in caps.layers {
                guard let set = caps.matrixSet(for: layer),
                      WMTSCapabilities.isEPSG27700(set.supportedCRS),
                      let matrix = BNGTileMatrix.fromCapabilities(set),
                      let template = WMTSCapabilities.tileTemplate(
                        endpoint: endpoint, layer: layer, matrixSet: set)
                else { continue }
                let sorted = BNGTileMatrix.sortedMatrices(set)
                let vc = CustomTileSource.ValidatedCapabilities(
                    layerIdentifier: layer.identifier,
                    layerTitle: layer.title,
                    tileMatrixSetIdentifier: set.identifier,
                    supportedCRS: set.supportedCRS,
                    originX: matrix.originX(at: 0),
                    originY: matrix.originY(at: 0),
                    tileSize: matrix.tileSize,
                    resolutions: matrix.resolutions,
                    matrixIdentifiers: sorted.map(\.identifier),
                    originsX: matrix.originsX,
                    originsY: matrix.originsY,
                    matrixWidths: matrix.matrixWidths,
                    matrixHeights: matrix.matrixHeights)
                found.append(DiscoveredLayer(
                    id: layer.identifier,
                    title: layer.title ?? layer.identifier,
                    zxyTemplate: template,
                    caps: vc))
            }
            discovered = found
            // The endpoint *is* a working WMTS server at this point — an empty
            // result means the wrong projection, and the message says which.
            scanState = found.isEmpty
                ? .failed(message: caps.noBNGLayersMessage)
                : .done(count: found.count)
        } catch let e as WMTSError {
            scanState = .failed(message: TileURLKeys.redactingAuthParams(
                in: e.errorDescription ?? "Scan failed."))
        } catch {
            // URLError descriptions can echo the request URL, key included.
            scanState = .failed(message: TileURLKeys.redactingAuthParams(
                in: error.localizedDescription))
        }
    }

    // MARK: - Cache

    private func refreshCacheSize() async {
        loadingCache = true
        let custom = added
        let standard = standardLayers
        let sizes = await Task.detached(priority: .utility) {
            // Carry any pre-key-stripping cache directories over to their new
            // namespace first, so they attribute to their layer here instead of
            // showing up as "Removed Layers".
            for src in custom {
                TileDiskCache.adoptLegacyNamespace("src-\(src.legacyCacheNamespace)",
                                                   forNew: "src-\(src.cacheNamespace)")
            }
            for layer in standard {
                TileDiskCache.adoptLegacyNamespace(layer.legacyCacheNamespace,
                                                   forNew: layer.cacheNamespace)
            }
            return TileDiskCache.sizesByNamespace()
        }.value
        cacheBytes = sizes.values.reduce(0, +)
        cacheRows = Self.buildCacheRows(sizes: sizes, custom: added, standard: standardLayers)
        loadingCache = false
    }

    /// Attribute each cache namespace to its layer; anything left (layers since
    /// deleted, or pre-rename hashes) is lumped into one clearable row.
    private static func buildCacheRows(sizes: [String: Int64],
                                       custom: [CustomTileSource],
                                       standard: [StandardTileSource]) -> [CacheRow] {
        var remaining = sizes
        var rows: [CacheRow] = []
        for src in custom {
            // BNGTileStore namespaces custom sources with a "src-" prefix.
            if let bytes = remaining.removeValue(forKey: "src-\(src.cacheNamespace)"), bytes > 0 {
                rows.append(CacheRow(id: "src-\(src.cacheNamespace)", name: src.name, bytes: bytes))
            }
        }
        for layer in standard {
            if let bytes = remaining.removeValue(forKey: layer.cacheNamespace), bytes > 0 {
                rows.append(CacheRow(id: layer.cacheNamespace, name: layer.name, bytes: bytes))
            }
        }
        rows.sort { $0.bytes > $1.bytes }
        let orphans = remaining.filter { $0.value > 0 }
        if !orphans.isEmpty {
            rows.append(CacheRow(id: "orphans",
                                 name: "Removed Layers",
                                 bytes: orphans.values.reduce(0, +),
                                 orphanNamespaces: Array(orphans.keys)))
        }
        return rows
    }

    private func clearCacheRow(_ row: CacheRow) {
        let namespaces = row.orphanNamespaces ?? [row.id]
        Task {
            await Task.detached(priority: .utility) {
                for ns in namespaces { TileDiskCache.clear(namespace: ns) }
            }.value
            await refreshCacheSize()
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

#Preview {
    NavigationStack { CustomTileSourceSettingsView() }
}

/// Inline outcome row for a "Test layer" probe, shared by both editors.
/// Redacts any URL that leaks into the message (e.g. a network error echoing
/// the request) — display-only, the underlying value is untouched.
private struct TestResultLabel: View {
    let outcome: TileLayerTester.Outcome

    var body: some View {
        Label(TileURLKeys.redactingAuthParams(in: outcome.message),
              systemImage: outcome.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(outcome.success ? Color.green : Color.red)
    }
}

/// Sheet for adding or editing a standard-projection (web-mercator) XYZ layer.
/// The user only has to paste a `{z}/{x}/{y}` template — the zoom range is probed
/// from the tileset and the name is derived from the host, both auto-filling as
/// soon as a *new* URL is entered (and still fully editable). Passing `editing`
/// pre-fills the fields and saves back to the same layer.
private struct StandardLayerEditorView: View {
    let editing: StandardTileSource?
    var onSave: (StandardTileSource) -> Void
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var urlTemplate: String
    @State private var minZoom: Int
    @State private var maxZoom: Int
    @State private var apiKey: String
    @State private var subdomains: String
    @State private var attribution: String
    /// Tile edge in pixels found by the probe (nil until detected; editing an
    /// existing layer starts from its saved value).
    @State private var detectedPixelSize: Int?
    @State private var detectState: DetectState = .idle
    @State private var testState: CustomTileSourceSettingsView.LayerTestState? = nil

    enum DetectState: Equatable { case idle, detecting, done, failed }

    init(editing: StandardTileSource? = nil,
         onDelete: (() -> Void)? = nil,
         onSave: @escaping (StandardTileSource) -> Void) {
        self.editing = editing
        self.onDelete = onDelete
        self.onSave = onSave
        _name = State(initialValue: editing?.name ?? "")
        _urlTemplate = State(initialValue: editing?.urlTemplate ?? "")
        _minZoom = State(initialValue: editing?.minZoom ?? 0)
        _maxZoom = State(initialValue: editing?.maxZoom ?? 19)
        _apiKey = State(initialValue: editing?.apiKey ?? "")
        _subdomains = State(initialValue: editing?.subdomains ?? "")
        _attribution = State(initialValue: editing?.attribution ?? "")
        _detectedPixelSize = State(initialValue: editing?.tilePixelSize)
    }

    private var isEditing: Bool { editing != nil }

    // A fake colon (U+A789) keeps the placeholder from being read as a live URL.
    private let examplePlaceholder = "https\u{A789}//tiles.example.com/{z}/{x}/{y}.png"

    private var trimmedTemplate: String {
        urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draft: StandardTileSource {
        StandardTileSource(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            urlTemplate: trimmedTemplate,
            maxZoom: maxZoom, minZoom: minZoom,
            apiKey: apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : apiKey.trimmingCharacters(in: .whitespaces),
            subdomains: subdomains.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : subdomains.trimmingCharacters(in: .whitespaces),
            tilePixelSize: detectedPixelSize,
            attribution: attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : attribution.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Insecure/schemeless templates are rejected outright: ATS blocks plain
    /// http at runtime with no way to relax it from code, so saving one would
    /// just produce a silently blank map.
    private var schemeProblem: Bool {
        draft.isUsable && !draft.usesSecureScheme
    }

    // Only a usable https URL is required — the name auto-fills from the host if blank.
    private var canSave: Bool { draft.isUsable && draft.usesSecureScheme && minZoom <= maxZoom }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                        .submitLabel(.next)
                    TextField("Attribution (optional)", text: $attribution)
                        .submitLabel(.next)
                } footer: {
                    Text("Leave the name blank to fill it from the URL. Attribution shows as a small caption on the map — check what credit your provider’s licence requires.")
                }

                Section {
                    TextField(examplePlaceholder, text: $urlTemplate, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(1...4)
                        .font(.system(.footnote, design: .monospaced))
                    if schemeProblem {
                        Label("Use an https:// address — iOS blocks insecure tile servers.",
                              systemImage: "lock.slash")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Label("Tile URL", systemImage: "link")
                } footer: {
                    Text("A web-mercator (EPSG:3857) XYZ template with {z}, {x} and {y} placeholders. Also understood: {-y} (flipped y), {s} (subdomain), {r} (retina), {apikey}.")
                }

                Section {
                    TextField("API key (for {apikey})", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    TextField("Subdomains (for {s}), e.g. abc", text: $subdomains)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                } header: {
                    Label("Placeholders", systemImage: "curlybraces")
                } footer: {
                    Text("Only used when the URL contains the matching placeholder. Keeping the key out of the URL means cached tiles survive a key change. Subdomains: letters (abc) or comma-separated (mt0,mt1).")
                }

                Section {
                    if detectState == .detecting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Detecting zoom levels…").foregroundStyle(.secondary)
                        }
                    }
                    Stepper("Min Zoom: \(minZoom)", value: $minZoom, in: 0...maxZoom)
                    Stepper("Max Zoom: \(maxZoom)", value: $maxZoom, in: max(minZoom, 1)...24)
                } header: {
                    Label("Zoom Range", systemImage: "arrow.up.left.and.arrow.down.right")
                } footer: {
                    Text(zoomFooter)
                }

                Section {
                    Button {
                        runLayerTest()
                    } label: {
                        HStack {
                            Label("Test Layer", systemImage: "dot.radiowaves.left.and.right")
                            Spacer()
                            if testState == .running {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(!canSave || testState == .running)
                    if case .done(let outcome) = testState {
                        TestResultLabel(outcome: outcome)
                    }
                } footer: {
                    Text("Fetches one tile with these settings and checks it decodes.")
                }

                if isEditing, let onDelete {
                    Section {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Label("Delete Layer", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Standard Layer" : "Add Standard Layer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { onSave(finalisedDraft()); dismiss() }
                        .disabled(!canSave)
                }
            }
            // Re-detect whenever the URL/key/subdomains settle; `.task(id:)`
            // cancels the prior probe automatically so only the latest is measured.
            .task(id: probeKey) { await autodetect() }
        }
    }

    private var zoomFooter: String {
        switch detectState {
        case .failed:
            return "Couldn’t detect the zoom range for this URL — set it by hand. Zooming past the max upscales the deepest tiles instead of leaving gaps."
        default:
            return "Probed from the tileset. Zooming in past the max upscales the deepest tiles instead of leaving gaps."
        }
    }

    /// Fetch one in-range tile with the current draft settings and report inline.
    private func runLayerTest() {
        testState = .running
        let draft = self.draft
        let coord = LocationPermissionManager.shared.currentLocation?.coordinate
        Task {
            let outcome = await TileLayerTester.test(
                layer: draft, lat: coord?.latitude, lon: coord?.longitude)
            testState = .done(outcome)
        }
    }

    /// Build the source to save: keep the existing id when editing, and fill the
    /// name from the host if the user left it blank.
    private func finalisedDraft() -> StandardTileSource {
        var d = draft
        d.id = editing?.id ?? UUID()
        if d.name.isEmpty { d.name = Self.autoName(from: d.urlTemplate) }
        return d
    }

    // MARK: Auto-detection

    /// Everything the probe depends on — changing any of it re-probes.
    private var probeKey: String {
        "\(trimmedTemplate)|\(apiKey)|\(subdomains)"
    }

    /// Debounced probe: once the URL is a usable template, measure its published
    /// zoom range + tile pixel size and (if the name is blank) fill a name.
    private func autodetect() async {
        // Whatever changed invalidates any previous "Test Layer" verdict.
        testState = nil
        let template = trimmedTemplate
        // Editing an existing layer: don't re-probe the unchanged saved config —
        // that would clobber the zoom range the user already set. Probing resumes
        // once they actually change something the probe depends on.
        if let editing,
           template == editing.urlTemplate,
           apiKey.trimmingCharacters(in: .whitespaces) == (editing.apiKey ?? ""),
           subdomains.trimmingCharacters(in: .whitespaces) == (editing.subdomains ?? "") {
            detectState = .idle
            return
        }
        guard template.contains("{z}"), template.contains("{x}"),
              template.contains("{y}") || template.contains("{-y}"),
              !schemeProblem else {
            detectState = .idle
            return
        }
        detectState = .detecting
        // Debounce so we don't probe on every keystroke.
        do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
        if Task.isCancelled { return }

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = Self.autoName(from: template)
        }

        // Probe at a land coordinate likely to have coverage: the user's location
        // if known, else Great Britain (a safe default for this app). Read here on
        // the main actor and hand the plain values to the off-main probe.
        let coord: (lat: Double, lon: Double)
        if let loc = LocationPermissionManager.shared.currentLocation {
            coord = (loc.coordinate.latitude, loc.coordinate.longitude)
        } else {
            coord = (54.5, -2.5)
        }

        if let found = await Self.probeTileset(template: template,
                                               apiKey: apiKey.trimmingCharacters(in: .whitespaces),
                                               subdomains: draft.subdomainTokens,
                                               lat: coord.lat, lon: coord.lon) {
            if Task.isCancelled { return }
            minZoom = found.min
            maxZoom = found.max
            detectedPixelSize = found.pixelSize
            detectState = .done
        } else {
            detectState = Task.isCancelled ? .idle : .failed
        }
    }

    /// A friendly name from the URL host, e.g. `tiles.example.com` → "Example",
    /// `mapseries-tilesets.s3…` → "Mapseries Tilesets".
    private static func autoName(from template: String) -> String {
        let sample = template
            .replacingOccurrences(of: "{z}", with: "0")
            .replacingOccurrences(of: "{x}", with: "0")
            .replacingOccurrences(of: "{y}", with: "0")
        guard var host = URL(string: sample)?.host else { return "Custom Layer" }
        for prefix in ["www.", "tiles.", "tile.", "api.", "maps.", "map."] where host.hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
            break
        }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        let words = label.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? "Custom Layer" : words.joined(separator: " ")
    }

    /// Probe which zoom levels return a real tile at the given land coordinate,
    /// and what pixel size the tiles are. Requests run concurrently but capped
    /// (same per-origin politeness as the tile fetch path); the min/max of the
    /// hits is the range, the pixel size comes from the deepest hit.
    private nonisolated static func probeTileset(
        template: String, apiKey: String, subdomains: [String],
        lat: Double, lon: Double
    ) async -> (min: Int, max: Int, pixelSize: Int)? {
        let limiter = FetchLimiter(capacity: 4)
        var hits: [(z: Int, px: Int)] = []
        await withTaskGroup(of: (Int, Int)?.self) { group in
            for z in 0...20 {
                group.addTask {
                    guard await limiter.acquire() else { return nil }
                    defer { Task { await limiter.release() } }
                    let (x, y) = TileLayerTester.webMercatorTileXY(lat: lat, lon: lon, z: z)
                    let url = TileFetcher.expandTemplate(template, z: z, x: x, y: y,
                                                         apiKey: apiKey,
                                                         subdomains: subdomains)
                    guard let px = await tilePixelWidth(urlString: url) else { return nil }
                    return (z, px)
                }
            }
            for await hit in group {
                if let hit { hits.append((z: hit.0, px: hit.1)) }
            }
        }
        guard let lo = hits.map(\.z).min(), let hi = hits.map(\.z).max() else { return nil }
        let deepest = hits.max { $0.z < $1.z }!
        return (lo, hi, deepest.px)
    }

    /// The pixel width of the tile at this URL, or nil if it isn't a real tile
    /// (non-200, undecodable, or an XML/HTML body pretending to be one).
    private nonisolated static func tilePixelWidth(urlString: String) async -> Int? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  TileFetcher.looksLikeImage(data),
                  let cg = UIImage(data: data)?.cgImage else { return nil }
            return cg.width
        } catch {
            return nil
        }
    }
}
