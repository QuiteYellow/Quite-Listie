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

    @State private var cacheBytes: Int64 = 0
    @State private var cacheRows: [CacheRow] = []
    @State private var loadingCache: Bool = true
    @State private var showClearConfirm: Bool = false
    /// Set from the user's location (when known): true only when they're
    /// clearly outside EPSG:27700 coverage, which earns a footer hint.
    @State private var isOutsideGreatBritain: Bool = false
    /// Per-layer "Test layer" probe state, keyed by source id.
    @State private var wmtsTests: [UUID: LayerTestState] = [:]

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
            if let existing = added.first { wmtsEndpoint = existing.wmtsEndpoint }
            // Only hint when a location is known *and* clearly outside GB —
            // no location means no hint, not a scary warning.
            if let loc = LocationPermissionManager.shared.currentLocation {
                isOutsideGreatBritain = !BNGProjection.isLikelyInGreatBritain(
                    lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            }
            await refreshCacheSize()
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
                let vc = CustomTileSource.ValidatedCapabilities.from(
                    layer: layer, set: set, matrix: matrix)
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
        let sizes = await Task.detached(priority: .utility) {
            // Carry any pre-key-stripping cache directories over to their new
            // namespace first, so they attribute to their layer here instead of
            // showing up as "Removed Layers".
            for src in custom {
                TileDiskCache.adoptLegacyNamespace("src-\(src.legacyCacheNamespace)",
                                                   forNew: "src-\(src.cacheNamespace)")
            }
            return TileDiskCache.sizesByNamespace()
        }.value
        cacheBytes = sizes.values.reduce(0, +)
        cacheRows = Self.buildCacheRows(sizes: sizes, custom: added)
        loadingCache = false
    }

    /// Attribute each cache namespace to its layer; anything left (layers since
    /// deleted, or pre-rename hashes) is lumped into one clearable row.
    private static func buildCacheRows(sizes: [String: Int64],
                                       custom: [CustomTileSource]) -> [CacheRow] {
        var remaining = sizes
        var rows: [CacheRow] = []
        for src in custom {
            // BNGTileStore namespaces custom sources with a "src-" prefix.
            if let bytes = remaining.removeValue(forKey: "src-\(src.cacheNamespace)"), bytes > 0 {
                rows.append(CacheRow(id: "src-\(src.cacheNamespace)", name: src.name, bytes: bytes))
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

/// Inline outcome row for a "Test layer" probe.
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
