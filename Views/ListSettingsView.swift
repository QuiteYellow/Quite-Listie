//
//  ListSettingsView.swift (V2 - SIMPLIFIED)
//  Listie.md
//
//  Updated to use V2 format with direct fields instead of extras
//

import os
import SwiftUI
import SymbolPicker

struct ListSettingsView: View {
    @State private var allLabels: [ShoppingLabel] = []
    @State private var hiddenLabelIDs: Set<String> = []
    let list: ShoppingListSummary
    let unifiedList: UnifiedList
    let unifiedProvider: UnifiedListProvider
    let onSave: (String, String?, [String]?, [String]?) -> Void  // (name, icon, hiddenLabels, labelOrder)

    
    @Environment(\.dismiss) var dismiss
    @State private var name: String = ""
    @State private var icon: String = "pencil"
    @State private var iconPickerPresented = false
    @State private var isFavourited: Bool = false
    
    // Label management states
    @State private var showingLabelEditor = false
    @State private var editingLabel: ShoppingLabel? = nil
    @State private var showingDeleteConfirmation = false
    @State private var labelToDelete: ShoppingLabel? = nil
    
    @State private var showCompletedAtBottom: Bool = false
    @State private var listBackground: ListBackground? = nil

    // Favorites stored in UserDefaults
    @AppStorage("favouriteListIDs") private var favouriteListIDsData: Data = Data()
    @AppStorage("showCompletedAtBottom") private var showCompletedAtBottomData: Data = Data()
    @AppStorage("listBackgrounds") private var listBackgroundsData: Data = Data()
    
    private var favouriteListIDs: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: favouriteListIDsData)) ?? []
        }
    }
    
    private func setFavouriteListIDs(_ ids: Set<String>) {
        if let data = try? JSONEncoder().encode(ids) {
            favouriteListIDsData = data
        }
    }
    
    private func loadLabels() async {
        do {
            let fetched = try await unifiedProvider.fetchLabels(for: unifiedList)
            if allLabels.isEmpty {
                // First load — sort by persisted label order
                allLabels = sortedLabels(fetched, by: unifiedList.summary.labelOrder)
            } else {
                // Subsequent loads (after create/edit/delete) — re-sort by the latest
                // persisted labelOrder so a sync from another device is reflected.
                let currentIDs = Set(allLabels.map { $0.id })
                let fetchedMap = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })

                // Update existing labels in place (name/color may have changed)
                var merged = allLabels.compactMap { fetchedMap[$0.id] }

                // Append any newly created labels not yet in our order
                let newLabels = fetched.filter { !currentIDs.contains($0.id) }
                merged.append(contentsOf: newLabels)

                // Re-apply persisted order (handles sync from another device)
                allLabels = sortedLabels(merged, by: unifiedList.summary.labelOrder)
            }
        } catch {
            AppLogger.labels.error("Failed to load labels: \(error, privacy: .public)")
        }
    }

    private func createLabel(name: String, color: String) async {
        // Use ModelHelpers to create a label with a simple, unique ID
        let newLabel = ModelHelpers.createNewLabel(
            name: name,
            color: color,
            existingLabels: allLabels
        )
        
        do {
            try await unifiedProvider.createLabel(newLabel, for: unifiedList)
            await loadLabels()
        } catch {
            AppLogger.labels.error("Failed to create label: \(error, privacy: .public)")
        }
    }
    
    private func updateLabel(_ label: ShoppingLabel) async {
        do {
            try await unifiedProvider.updateLabel(label, for: unifiedList)
            await loadLabels()
        } catch {
            AppLogger.labels.error("Failed to update label: \(error, privacy: .public)")
        }
    }
    
    private func deleteLabel(_ label: ShoppingLabel) async {
        do {
            try await unifiedProvider.deleteLabel(label, from: unifiedList)
            await loadLabels()
            NotificationCenter.default.post(name: .listSettingsChanged, object: nil)
        } catch {
            AppLogger.labels.error("Could not delete label: \(error, privacy: .public)")
        }
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Details")) {
                    HStack {
                        Label("Title", systemImage: "textformat")
                        Spacer()
                        TextField("Enter title", text: $name)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 400)
                    }
                    
                    HStack {
                        Label("Icon", systemImage: "square.grid.2x2")
                        Spacer()
                        Button {
                            iconPickerPresented = true
                        } label: {
                            Image(systemName: icon)
                                .imageScale(.large)
                        }
                    }
                    .sheet(isPresented: $iconPickerPresented) {
                        SymbolPicker(symbol: $icon)
                    }
                    
                    // Favourite toggle
                    Toggle(isOn: $isFavourited) {
                        Label("Mark as Favourite", systemImage: "star.fill")
                    }
                    .toggleStyle(.switch)
                    
                    Label {
                        switch unifiedList.source {
                        case .privateICloud:
                            Text("Private List")
                        case .external(let url):
                            Text("\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)")
                        }
                    } icon: {
                        switch unifiedList.source {
                        case .privateICloud:
                            Image(systemName: "icloud.fill")
                        case .external:
                            Image(systemName: "link")
                        }
                    }
                }
                
                Section(header: Text("Display Options")) {
                    Toggle(isOn: $showCompletedAtBottom) {
                        Label("Show Completed as Separate Label", systemImage: "checkmark.circle.badge.questionmark")
                    }
                    .toggleStyle(.switch)
                }

                Section(header: Text("Background")) {
                    DisclosureGroup {
                        // None option
                        Button {
                            listBackground = nil
                        } label: {
                            HStack {
                                Image(systemName: "circle.slash")
                                    .foregroundColor(.secondary)
                                Text("None")
                                    .foregroundColor(.primary)
                                Spacer()
                                if listBackground == nil {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)

                        // Gradient grid
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                            ForEach(BackgroundGradient.all) { gradient in
                                let isSelected: Bool = {
                                    if case .gradient(let id) = listBackground { return id == gradient.id }
                                    return false
                                }()
                                Button {
                                    listBackground = .gradient(gradient.id)
                                } label: {
                                    VStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(
                                                LinearGradient(
                                                    colors: [gradient.fromColor, gradient.toColor],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(height: 52)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                                            )
                                        Text(gradient.name)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(gradient.name)
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Label("Choose Background", systemImage: "paintbrush")
                            Spacer()
                            if let gradient = listBackground?.resolved() {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        LinearGradient(
                                            colors: [gradient.fromColor, gradient.toColor],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 40, height: 24)
                            }
                        }
                    }
                }

                // Label Management Section
                Section(header:
                    HStack {
                        Text("Labels")
                        Spacer()
                        Button {
                            editingLabel = nil
                            showingLabelEditor = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .imageScale(.medium)
                        }
                    }
                ) {
                    if allLabels.isEmpty {
                        Text("No labels yet. Tap + to add one.")
                            .foregroundColor(.secondary)
                            .font(.callout)
                    } else {
                        ForEach($allLabels, id: \.id) { $label in
                            HStack {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(.secondary)
                                    .font(.footnote)

                                Image(systemName: "tag.fill")
                                    .foregroundColor(Color(hex: label.color).adjusted(forBackground: Color(.systemBackground)))

                                Text(label.name)

                                Spacer()

                                // Show/hide toggle
                                let isShown = !hiddenLabelIDs.contains(label.id)
                                Toggle("", isOn: Binding(
                                    get: { isShown },
                                    set: { newValue in
                                        if newValue {
                                            hiddenLabelIDs.remove(label.id)
                                        } else {
                                            hiddenLabelIDs.insert(label.id)
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }
                            .opacity(hiddenLabelIDs.contains(label.id) ? 0.5 : 1.0)
                            .swipeActions(edge: .trailing) {
                                Button() {
                                    labelToDelete = label
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    editingLabel = label
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.accentColor)
                            }
                            .contextMenu {
                                Button {
                                    editingLabel = label
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }

                                Button(role: .destructive) {
                                    labelToDelete = label
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .onMove { from, to in
                            allLabels.move(fromOffsets: from, toOffset: to)
                        }
                    }
                }
                .headerProminence(.increased)
            }
            .navigationTitle("List Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        /// Save favorite state to UserDefaults
                        var ids = favouriteListIDs
                        if isFavourited {
                            ids.insert(list.id)
                        } else {
                            ids.remove(list.id)
                        }
                        setFavouriteListIDs(ids)
                        
                        // Save show completed setting
                        var dict = (try? JSONDecoder().decode([String: Bool].self, from: showCompletedAtBottomData)) ?? [:]
                        dict[list.id] = showCompletedAtBottom
                        if let data = try? JSONEncoder().encode(dict) {
                            showCompletedAtBottomData = data
                        }

                        // Save background preference
                        var bgDict = (try? JSONDecoder().decode([String: ListBackground].self, from: listBackgroundsData)) ?? [:]
                        if let listBackground {
                            bgDict[list.id] = listBackground
                        } else {
                            bgDict.removeValue(forKey: list.id)
                        }
                        if let bgData = try? JSONEncoder().encode(bgDict) {
                            listBackgroundsData = bgData
                        }

                        // Call with direct values (convert Set to Array)
                        let hiddenArray = hiddenLabelIDs.isEmpty ? nil : Array(hiddenLabelIDs)
                        let labelOrderArray = allLabels.map { $0.id }
                        onSave(name, icon, hiddenArray, labelOrderArray)
                        
                        NotificationCenter.default.post(name: .listSettingsChanged, object: nil)

                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .help("Cancel")
                }
            }
            .sheet(item: $editingLabel) { label in
                // Edit existing label
                LabelEditorView(
                    viewModel: LabelEditorViewModel(from: label),
                    onSave: { name, colorHex in
                        var updated = label
                        updated.name = name
                        updated.color = colorHex
                        Task {
                            await updateLabel(updated)
                        }
                    },
                    onCancel: {
                        editingLabel = nil
                    }
                )
            }
            .sheet(isPresented: $showingLabelEditor) {
                // Create new label
                LabelEditorView(
                    viewModel: LabelEditorViewModel(),
                    onSave: { name, colorHex in
                        Task {
                            await createLabel(name: name, color: colorHex)
                        }
                    },
                    onCancel: {
                        showingLabelEditor = false
                    }
                )
            }
            .alert("Delete Label?", isPresented: $showingDeleteConfirmation, presenting: labelToDelete) { label in
                Button("Delete", role: .destructive) {
                    Task {
                        await deleteLabel(label)
                        labelToDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    labelToDelete = nil
                }
            } message: { label in
                Text("Are you sure you want to delete \"\(label.name)\"? Items using this label will not be deleted.")
            }
        }
        .onAppear {
            Task {
                // Force reload from storage to get latest data
                await unifiedProvider.reloadList(unifiedList)
                
                // Now read fresh data
                let currentList = unifiedList.summary
                
                name = currentList.name
                icon = currentList.icon ?? "checklist"
                hiddenLabelIDs = Set(currentList.hiddenLabels ?? [])
                
                AppLogger.labels.debug("Loaded hiddenLabelIDs: \(hiddenLabelIDs, privacy: .public)")
                
                isFavourited = favouriteListIDs.contains(currentList.id)
                await loadLabels()
                
                let dict = (try? JSONDecoder().decode([String: Bool].self, from: showCompletedAtBottomData)) ?? [:]
                showCompletedAtBottom = dict[currentList.id] ?? false

                // Load background preference
                let bgDict = (try? JSONDecoder().decode([String: ListBackground].self, from: listBackgroundsData)) ?? [:]
                listBackground = bgDict[currentList.id]
            }
        }
    }
}
