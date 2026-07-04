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

struct CustomTileSourceSettingsView: View {
    @State private var wmtsEndpoint: String = ""
    @State private var scanState: ScanState = .idle
    @State private var discovered: [DiscoveredLayer] = []
    @State private var added: [CustomTileSource] = []

    @State private var cacheBytes: Int64 = 0
    @State private var loadingCache: Bool = true
    @State private var showClearConfirm: Bool = false

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
                Text("Paste a British National Grid (EPSG:27700) “WMTS API” address that includes your key. Scanning lists every EPSG:27700 layer it offers so you can add the ones you want.")
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
                        HStack {
                            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
                            TextField("Layer name", text: nameBinding(for: src.id))
                                .submitLabel(.done)
                        }
                    }
                    .onDelete(perform: deleteAdded)
                } header: {
                    Label("Your Map Layers", systemImage: "map")
                } footer: {
                    Text("These appear in the map’s layer menu. Rename them to whatever you like.")
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
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("Clear Cache", systemImage: "trash.slash")
                }
                .disabled(cacheBytes == 0)
            } header: {
                Label("Cache", systemImage: "internaldrive")
            } footer: {
                Text("Tiles are stored on this device so panning back to a previously viewed area doesn’t re-download. Clearing the cache doesn’t remove your layers.")
            }
        }
        .navigationTitle("Custom Map Layers")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            added = CustomTileSourceStore.loadAll()
            if let existing = added.first { wmtsEndpoint = existing.wmtsEndpoint }
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
        do {
            let caps = try await WMTSCapabilitiesLoader.discover(fromWMTSEndpoint: endpoint)
            var found: [DiscoveredLayer] = []
            for layer in caps.layers {
                guard let set = caps.matrixSet(for: layer),
                      WMTSCapabilities.isEPSG27700(set.supportedCRS),
                      let matrix = BNGTileMatrix.fromCapabilities(set),
                      let zxy = deriveZXY(from: endpoint, layerID: layer.identifier, formats: layer.formats)
                else { continue }
                let vc = CustomTileSource.ValidatedCapabilities(
                    layerIdentifier: layer.identifier,
                    layerTitle: layer.title,
                    tileMatrixSetIdentifier: set.identifier,
                    supportedCRS: set.supportedCRS,
                    originX: matrix.originX,
                    originY: matrix.originY,
                    tileSize: matrix.tileSize,
                    resolutions: matrix.resolutions)
                found.append(DiscoveredLayer(
                    id: layer.identifier,
                    title: layer.title ?? layer.identifier,
                    zxyTemplate: zxy,
                    caps: vc))
            }
            discovered = found
            scanState = found.isEmpty
                ? .failed(message: "No EPSG:27700 layers found at this endpoint.")
                : .done(count: found.count)
        } catch let e as WMTSError {
            scanState = .failed(message: e.errorDescription ?? "Scan failed.")
        } catch {
            scanState = .failed(message: error.localizedDescription)
        }
    }

    /// Build the ZXY tile URL for a layer from the WMTS endpoint: swap the
    /// trailing `/wmts` path for `/zxy/{layer}/{z}/{x}/{y}.{ext}` and carry over
    /// just the `key` query item.
    private func deriveZXY(from wmts: String, layerID: String, formats: [String]) -> String? {
        guard let comps = URLComponents(string: wmts.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = comps.scheme, let host = comps.host else { return nil }
        var path = comps.path
        let lower = path.lowercased()
        if lower.hasSuffix("/wmts") { path = String(path.dropLast(5)) }
        else if lower.hasSuffix("/wmts/") { path = String(path.dropLast(6)) }
        let ext = tileExtension(for: formats)
        let port = comps.port.map { ":\($0)" } ?? ""
        var url = "\(scheme)://\(host)\(port)\(path)/zxy/\(layerID)/{z}/{x}/{y}.\(ext)"
        if let key = comps.queryItems?.first(where: { $0.name.caseInsensitiveCompare("key") == .orderedSame })?.value,
           !key.isEmpty {
            url += "?key=\(key)"
        }
        return url
    }

    private func tileExtension(for formats: [String]) -> String {
        let f = formats.map { $0.lowercased() }
        if f.contains(where: { $0.contains("png") }) { return "png" }
        if f.contains(where: { $0.contains("jpeg") || $0.contains("jpg") }) { return "jpg" }
        return "png"
    }

    // MARK: - Cache

    private func refreshCacheSize() async {
        loadingCache = true
        let size = await Task.detached(priority: .utility) {
            TileDiskCache.totalSizeBytes()
        }.value
        cacheBytes = size
        loadingCache = false
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
