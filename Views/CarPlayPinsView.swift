import SwiftUI

struct CarPlayPinsView: View {
    @State private var allEntries: [LocationEntry] = []
    @State private var pinnedItemIDs: [String] = CarPlayPinnedStore.orderedIDs()
    @State private var pinnedLabelNames: [String] = CarPlayPinnedLabelStore.orderedNames()
    @State private var showingPlacePicker = false
    @State private var showingLabelPicker = false

    private var entryByID: [String: LocationEntry] {
        Dictionary(allEntries.map { ($0.item.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var availablePlaces: [LocationEntry] {
        let pinned = Set(pinnedItemIDs)
        return allEntries
            .filter { !pinned.contains($0.item.id.uuidString) }
            .sorted { $0.item.note.localizedCaseInsensitiveCompare($1.item.note) == .orderedAscending }
    }

    private var availableLabels: [String] {
        let pinned = Set(pinnedLabelNames)
        let all = Set(allEntries.compactMap { $0.labelName })
        return all.subtracting(pinned).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        List {
            placesSection
            labelsSection
        }
        .navigationTitle("CarPlay Pins")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(isPresented: $showingPlacePicker) {
            PlacePickerSheet(candidates: availablePlaces) { entry in
                addPlace(entry)
                showingPlacePicker = false
            }
        }
        .sheet(isPresented: $showingLabelPicker) {
            LabelPickerSheet(candidates: availableLabels, exemplar: { name in
                allEntries.first { $0.labelName == name }
            }) { name in
                addLabel(name)
                showingLabelPicker = false
            }
        }
        .task { await loadEntries() }
    }

    private var placesSection: some View {
        Section {
            if pinnedItemIDs.isEmpty {
                Text("No pinned places yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pinnedItemIDs, id: \.self) { id in
                    if let entry = entryByID[id] {
                        placeRow(entry: entry)
                    } else {
                        Text("Unknown item")
                            .foregroundStyle(.tertiary)
                    }
                }
                .onMove(perform: movePlaces)
                .onDelete(perform: deletePlaces)
            }

            if pinnedItemIDs.count < CarPlayPinnedStore.maxCount {
                Button {
                    showingPlacePicker = true
                } label: {
                    Label("Add Place", systemImage: "plus")
                }
            }
        } header: {
            sectionHeader(title: "Pinned Places", count: pinnedItemIDs.count, max: CarPlayPinnedStore.maxCount)
        } footer: {
            Text("Pinned places appear on the CarPlay map tab in this order. Drag to reorder, swipe to remove.")
        }
    }

    private var labelsSection: some View {
        Section {
            if pinnedLabelNames.isEmpty {
                Text("No pinned labels yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pinnedLabelNames, id: \.self) { name in
                    labelRow(name: name)
                }
                .onMove(perform: moveLabels)
                .onDelete(perform: deleteLabels)
            }

            if pinnedLabelNames.count < CarPlayPinnedLabelStore.maxCount {
                Button {
                    showingLabelPicker = true
                } label: {
                    Label("Add Label", systemImage: "plus")
                }
            }
        } header: {
            sectionHeader(title: "Pinned Labels", count: pinnedLabelNames.count, max: CarPlayPinnedLabelStore.maxCount)
        } footer: {
            Text("Pinned labels appear at the top of the CarPlay list tab in this order.")
        }
    }

    private func sectionHeader(title: String, count: Int, max: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count) / \(max)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func placeRow(entry: LocationEntry) -> some View {
        HStack(spacing: 12) {
            labelIcon(symbol: entry.labelSymbol, colorHex: entry.labelColor, fallback: "mappin.circle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.note)
                Text(entry.list.summary.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func labelRow(name: String) -> some View {
        let exemplar = allEntries.first { $0.labelName == name }
        let count = allEntries.filter { $0.labelName == name }.count
        return HStack(spacing: 12) {
            labelIcon(symbol: exemplar?.labelSymbol, colorHex: exemplar?.labelColor, fallback: "tag.fill")
            Text(name)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func labelIcon(symbol: String?, colorHex: String?, fallback: String) -> some View {
        let systemName: String = (symbol?.isEmpty == false ? symbol! : fallback)
        let tint: Color = colorHex.flatMap { Color(hex: $0) } ?? .secondary
        Image(systemName: systemName)
            .frame(width: 24)
            .foregroundStyle(tint)
    }

    private func movePlaces(from: IndexSet, to: Int) {
        pinnedItemIDs.move(fromOffsets: from, toOffset: to)
        CarPlayPinnedStore.setOrderedIDs(pinnedItemIDs)
    }

    private func deletePlaces(at offsets: IndexSet) {
        pinnedItemIDs.remove(atOffsets: offsets)
        CarPlayPinnedStore.setOrderedIDs(pinnedItemIDs)
    }

    private func moveLabels(from: IndexSet, to: Int) {
        pinnedLabelNames.move(fromOffsets: from, toOffset: to)
        CarPlayPinnedLabelStore.setOrderedNames(pinnedLabelNames)
    }

    private func deleteLabels(at offsets: IndexSet) {
        pinnedLabelNames.remove(atOffsets: offsets)
        CarPlayPinnedLabelStore.setOrderedNames(pinnedLabelNames)
    }

    private func addPlace(_ entry: LocationEntry) {
        guard pinnedItemIDs.count < CarPlayPinnedStore.maxCount else { return }
        pinnedItemIDs.append(entry.item.id.uuidString)
        CarPlayPinnedStore.setOrderedIDs(pinnedItemIDs)
    }

    private func addLabel(_ name: String) {
        guard pinnedLabelNames.count < CarPlayPinnedLabelStore.maxCount else { return }
        pinnedLabelNames.append(name)
        CarPlayPinnedLabelStore.setOrderedNames(pinnedLabelNames)
    }

    private func loadEntries() async {
        let provider = UnifiedListProvider.shared
        var all: [LocationEntry] = []
        for list in provider.allLists {
            let items = await provider.fetchItemsForDisplay(for: list)
            let labels = await provider.fetchLabelsForDisplay(for: list)
            all.append(contentsOf: WelcomeViewModel.locationEntries(from: items, labels: labels, list: list))
        }
        allEntries = all
    }
}

private struct PlacePickerSheet: View {
    let candidates: [LocationEntry]
    let onPick: (LocationEntry) -> Void

    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [LocationEntry] {
        guard !search.isEmpty else { return candidates }
        return candidates.filter { $0.item.note.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "Nothing to add",
                        systemImage: "mappin.slash",
                        description: Text("All items with locations are already pinned, or no items in your lists have a pinned location yet.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(filtered) { entry in
                        Button {
                            onPick(entry)
                        } label: {
                            HStack(spacing: 12) {
                                if let symbol = entry.labelSymbol, !symbol.isEmpty {
                                    Image(systemName: symbol)
                                        .frame(width: 24)
                                        .foregroundStyle(entry.labelColor.flatMap { Color(hex: $0) } ?? .secondary)
                                } else {
                                    Image(systemName: "mappin.circle.fill")
                                        .frame(width: 24)
                                        .foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.item.note)
                                        .foregroundStyle(.primary)
                                    Text(entry.list.summary.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search items")
            .navigationTitle("Add Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct LabelPickerSheet: View {
    let candidates: [String]
    let exemplar: (String) -> LocationEntry?
    let onPick: (String) -> Void

    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [String] {
        guard !search.isEmpty else { return candidates }
        return candidates.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "Nothing to add",
                        systemImage: "tag.slash",
                        description: Text("All labels are already pinned, or no items with locations carry a label yet.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(filtered, id: \.self) { name in
                        Button {
                            onPick(name)
                        } label: {
                            HStack(spacing: 12) {
                                let ex = exemplar(name)
                                if let symbol = ex?.labelSymbol, !symbol.isEmpty {
                                    Image(systemName: symbol)
                                        .frame(width: 24)
                                        .foregroundStyle(ex?.labelColor.flatMap { Color(hex: $0) } ?? .secondary)
                                } else {
                                    Image(systemName: "tag.fill")
                                        .frame(width: 24)
                                        .foregroundStyle(.secondary)
                                }
                                Text(name)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search labels")
            .navigationTitle("Add Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
