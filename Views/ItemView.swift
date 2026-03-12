//
//  ItemView.swift (V2 - UPDATED)
//  Listie.md
//
//  Updated EditItemView to use V2 format with direct markdownNotes field
//

import os
import SwiftUI
import MapKit
import MarkdownView

// MARK: - Shared Item Form View
struct ItemFormView: View {
    @Binding var itemName: String
    @Binding var quantity: Int
    @Binding var selectedLabel: ShoppingLabel?
    @Binding var checked: Bool
    @Binding var mdNotes: String
    @Binding var showMarkdownEditor: Bool
    @Binding var reminderEnabled: Bool
    @Binding var reminderDate: Date
    @Binding var repeatRule: ReminderRepeatRule?
    @Binding var repeatMode: ReminderRepeatMode

    let availableLabels: [ShoppingLabel]
    let isLoading: Bool

    /// Optional list context shown at the top of the form (icon, name, folder)
    var listIcon: String? = nil
    var listName: String? = nil
    var folderName: String? = nil
    /// When set, a "Copy Item Link" button appears next to "Edit Notes".
    var itemID: UUID? = nil
    /// Whether map/location features are enabled for this list.
    var enableMapData: Bool = false
    /// The item's current pinned coordinate (read/write).
    @Binding var location: Coordinate?

    @State private var linkCopied = false
    @State private var pasteLocationFeedback: PasteLocationFeedback = .idle
    @State private var showRemoveLocationConfirm = false
    @State private var showLocationPicker = false

    @AppStorage("navShowAppleMaps") private var navShowAppleMaps: Bool = true
    @AppStorage("navShowGoogleMaps") private var navShowGoogleMaps: Bool = true
    @AppStorage("navShowTomTomGo") private var navShowTomTomGo: Bool = true

    private enum PasteLocationFeedback: Equatable {
        case idle, loading, success, failed
    }
    
    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > 700

            if isWide {
                HStack(spacing: 0) {
                    formLeft
                        .frame(width: geometry.size.width * 0.4)

                    Divider()

                    VStack(alignment: .leading, spacing: 0) {

                        formRight
                    }
                    .frame(width: geometry.size.width * 0.6)
                }
            } else {
                Form {
                    formLeftContent

                    VStack(alignment: .leading, spacing: 0) {
                        Text("Markdown Notes")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)

                        Divider()
                            .padding(.top, 8)
                            .padding(.bottom, 8)

                        formRightContent
                    }
                    .frame(minHeight: 200)
                    .listRowBackground(Color.clear)
                    .padding(.bottom, 80)
                }
                .overlay(alignment: .bottomTrailing) {
                    notesButtonRow
                        .padding(20)
                }
            }
        }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerSheet(location: $location)
        }
    }
    
    @ViewBuilder
    private var notesButtonRow: some View {
        HStack(spacing: 10) {
            if let itemID {
                Button {
                    UIPasteboard.general.string = "quitelistie://item?id=\(itemID.uuidString)"
                    withAnimation(.easeInOut(duration: 0.15)) { linkCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeInOut(duration: 0.3)) { linkCopied = false }
                    }
                } label: {
                    Label(
                        linkCopied ? "Copied!" : "Copy",
                        systemImage: linkCopied ? "checkmark" : "link"
                    )
                }
                .controlSize(.large)
                .buttonStyle(.glass)
                .tint(linkCopied ? .green : .primary)
                .animation(.easeInOut(duration: 0.2), value: linkCopied)
            }

            Button {
                showMarkdownEditor = true
            } label: {
                Label("Edit Notes", systemImage: "square.and.pencil")
            }
            .controlSize(.large)
            .buttonStyle(.glass)
        }
    }

    private var formLeft: some View {
        Form {
            formLeftContent
        }
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .frame(maxWidth: .infinity)
    }
    
    private var formRight: some View {
        ZStack(alignment: .bottomTrailing) {
            formRightContent
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .frame(maxWidth: .infinity)

            notesButtonRow
                .padding(20)
        }
    }
    
    private var formLeftContent: some View {
        Section() {
            HStack {
                Label("Name", systemImage: "textformat")
                Spacer()
                if checked {
                    Text(itemName.isEmpty ? "Item name" : itemName)
                        .multilineTextAlignment(.trailing)
                        .strikethrough(true, color: .secondary)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 200, alignment: .trailing)
                } else {
                    TextField("Item name", text: $itemName)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 200)
                }
            }

            HStack {
                Label("Quantity:", systemImage: "number")
                Spacer()
                Stepper(value: $quantity, in: 1...100) {
                    Text("\(quantity)")
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.25), value: quantity)
                }
            }

            HStack {
                Label("Label", systemImage: "tag")
                Spacer()
                if isLoading {
                    ProgressView()
                } else {
                    Picker("", selection: $selectedLabel) {
                        Text("No Label").tag(Optional<ShoppingLabel>(nil))

                        ForEach(availableLabels, id: \.id) { label in
                            Text(label.name)
                                .tag(Optional(label))
                        }
                    }
                    .labelsHidden()
                }
            }

            HStack {
                Label("Completed", systemImage: "checkmark.circle")
                Spacer()
                Toggle("", isOn: $checked)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            HStack {
                Label("Reminder", systemImage: "bell")
                Spacer()
                Toggle("", isOn: $reminderEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if reminderEnabled {
                DatePicker(
                    "Date & Time",
                    selection: $reminderDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )

                RepeatRulePicker(rule: $repeatRule)

                if repeatRule != nil {
                    Picker("Mode", selection: $repeatMode) {
                        ForEach(ReminderRepeatMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            }

            // Location — shown just below Reminder when map data is enabled
            if enableMapData {
                if let coord = location {
                    HStack {
                        Button {
                            showLocationPicker = true
                        } label: {
                            Label("View Location", systemImage: "mappin.and.ellipse")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text(String(format: "%.4f°, %.4f°", coord.latitude, coord.longitude))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            showRemoveLocationConfirm = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .confirmationDialog("Remove Location?", isPresented: $showRemoveLocationConfirm, titleVisibility: .visible) {
                        Button("Remove", role: .destructive) { location = nil }
                        Button("Cancel", role: .cancel) {}
                    }

                    if navShowAppleMaps {
                        Button { openInAppleMaps(coord) } label: {
                            Label("Navigate with Apple Maps", systemImage: "map")
                        }
                    }
                    if navShowGoogleMaps {
                        Button { openInGoogleMaps(coord) } label: {
                            Label("Navigate with Google Maps", systemImage: "globe")
                        }
                    }
                    #if !targetEnvironment(macCatalyst)
                    if navShowTomTomGo {
                        Button { navigateInTomTomGo(coord) } label: {
                            Label("Navigate with TomTom Go", systemImage: "car.fill")
                        }
                    }
                    #endif
                } else {
                    HStack {
                        Button {
                            showLocationPicker = true
                        } label: {
                            Label("Choose Location", systemImage: "mappin.and.ellipse")
                        }
                        .foregroundStyle(Color.accentColor)
                        Spacer()
                        Button {
                            Task { await pasteLocation() }
                        } label: {
                            switch pasteLocationFeedback {
                            case .idle:
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundStyle(.secondary)
                            case .loading:
                                ProgressView().controlSize(.small)
                            case .success:
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                            case .failed:
                                Image(systemName: "xmark")
                                    .foregroundStyle(.red)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(pasteLocationFeedback == .loading)
                    }
                    Text("Search by address or tap \(Image(systemName: "doc.on.clipboard")) to paste an Apple or Google Maps link.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let name = listName {
                HStack(spacing: 6) {

                    Spacer()
                    ItemFormChip(
                        icon: listIcon ?? "list.bullet",
                        text: name,
                        color: .accentColor
                    )
                    if let folder = folderName {
                        ItemFormChip(
                            icon: "folder",
                            text: folder,
                            color: .secondary
                        )
                    }
                }
            }
        }
    }

    private func pasteLocation() async {
        guard let text = UIPasteboard.general.string else {
            pasteLocationFeedback = .failed
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            pasteLocationFeedback = .idle
            return
        }
        pasteLocationFeedback = .loading
        AppLogger.location.debug("pasteLocation clipboard: \(text, privacy: .public)")
        if let coord = await LocationParser.parseCoordinate(from: text) {
            AppLogger.location.debug("pasteLocation parsed: \(coord.latitude, privacy: .public), \(coord.longitude, privacy: .public)")
            location = coord
            // Append the source link to markdown notes
            let trimmedURL = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let link = "\n[Location](\(trimmedURL))"
            if !mdNotes.contains(link) {
                mdNotes += link
            }
            pasteLocationFeedback = .success
        } else {
            AppLogger.location.warning("pasteLocation failed to parse: \(text, privacy: .public)")
            pasteLocationFeedback = .failed
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        pasteLocationFeedback = .idle
    }

    private func openInAppleMaps(_ coord: Coordinate) {
        var components = URLComponents(string: "maps://")!
        components.queryItems = [
            URLQueryItem(name: "daddr", value: "\(coord.latitude),\(coord.longitude)")
        ]
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }

    private func openInGoogleMaps(_ coord: Coordinate) {
        let destination = "\(coord.latitude),\(coord.longitude)"
        // Try the native app first, fall back to the web URL
        if let appURL = URL(string: "comgooglemaps://?daddr=\(destination)&directionsmode=driving"),
           UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else if let webURL = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(destination)") {
            UIApplication.shared.open(webURL)
        }
    }

    private func navigateInTomTomGo(_ coord: Coordinate) {
        let destination = "\(coord.latitude),\(coord.longitude)"
        if let url = URL(string: "tomtomgo://x-callback-url/navigate?destination=\(destination)") {
            UIApplication.shared.open(url)
        }
    }

    private var formRightContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if mdNotes.isEmpty {
                    Text("Click \"Edit Notes\" to add a note, use Markdown for Sublists, links, images and more. Sublists can be directly toggled here!")
                        .foregroundStyle(.placeholder)
                } else {
                    CheckableMarkdownView(text: $mdNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Repeat Rule Picker

struct RepeatRulePicker: View {
    @Binding var rule: ReminderRepeatRule?

    // Internal state for custom mode
    @State private var selectedPresetIndex: Int = 0  // 0 = Never
    @State private var customUnit: ReminderRepeatUnit = .day
    @State private var customInterval: Int = 2
    @State private var isCustom: Bool = false
    @State private var didInitialize: Bool = false

    /// The picker options: Never, then presets, then Custom
    private static let presetLabels = ["Never"] + ReminderRepeatRule.presets.map(\.displayName) + ["Custom…"]

    var body: some View {
        Picker("Repeat", selection: $selectedPresetIndex) {
            ForEach(0..<Self.presetLabels.count, id: \.self) { index in
                Text(Self.presetLabels[index]).tag(index)
            }
        }
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            let idx = presetIndex(for: rule)
            selectedPresetIndex = idx
            if idx == Self.presetLabels.count - 1, let r = rule {
                isCustom = true
                customUnit = r.unit
                customInterval = r.interval
            }
        }
        .onChange(of: selectedPresetIndex) { _, newValue in
            applySelection(newValue)
        }

        if isCustom {
            HStack {
                Label("Every", systemImage: "arrow.trianglehead.2.clockwise")
                Spacer()
                Stepper(value: $customInterval, in: 1...365) {
                    Text("\(customInterval)")
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.25), value: customInterval)
                }
                .frame(maxWidth: 140)
            }
            .onChange(of: customInterval) { _, _ in
                updateCustomRule()
            }

            Picker("Unit", selection: $customUnit) {
                ForEach(ReminderRepeatUnit.allCases, id: \.self) { unit in
                    Text(customInterval == 1 ? unit.displayName : unit.pluralName).tag(unit)
                }
            }
            .onChange(of: customUnit) { _, _ in
                updateCustomRule()
            }
        }
    }

    private func applySelection(_ index: Int) {
        if index == 0 {
            rule = nil
            isCustom = false
        } else if index <= ReminderRepeatRule.presets.count {
            rule = ReminderRepeatRule.presets[index - 1]
            isCustom = false
        } else {
            isCustom = true
            updateCustomRule()
        }
    }

    private func updateCustomRule() {
        if customUnit == .weekdays {
            rule = ReminderRepeatRule(unit: .weekdays, interval: 1)
        } else {
            rule = ReminderRepeatRule(unit: customUnit, interval: customInterval)
        }
    }

    private func presetIndex(for rule: ReminderRepeatRule?) -> Int {
        guard let rule = rule else { return 0 }
        if let idx = ReminderRepeatRule.presets.firstIndex(of: rule) {
            return idx + 1
        }
        return Self.presetLabels.count - 1  // Custom
    }
}

struct AddItemView: View {
    let list: ShoppingListSummary

    @Environment(\.dismiss) var dismiss
    var viewModel: ShoppingListViewModel

    @State private var itemName = ""
    @State private var selectedLabel: ShoppingLabel? = nil
    @State private var availableLabels: [ShoppingLabel] = []
    @State private var checked: Bool = false
    @State private var isLoading = true
    @State private var quantity: Int = 1
    @State private var showError = false
    @State private var mdNotes = ""
    @State private var showMarkdownEditor = false
    @State private var reminderEnabled = false
    @State private var reminderDate = Date().addingTimeInterval(3600) // Default: 1 hour from now
    @State private var repeatRule: ReminderRepeatRule? = nil
    @State private var repeatMode: ReminderRepeatMode = .fixed
    @State private var location: Coordinate?

    init(list: ShoppingListSummary, viewModel: ShoppingListViewModel, initialLocation: Coordinate? = nil) {
        self.list = list
        self.viewModel = viewModel
        self._location = State(initialValue: initialLocation)
    }

    var body: some View {
        NavigationStack {
            ItemFormView(
                itemName: $itemName,
                quantity: $quantity,
                selectedLabel: $selectedLabel,
                checked: $checked,
                mdNotes: $mdNotes,
                showMarkdownEditor: $showMarkdownEditor,
                reminderEnabled: $reminderEnabled,
                reminderDate: $reminderDate,
                repeatRule: $repeatRule,
                repeatMode: $repeatMode,
                availableLabels: availableLabels,
                isLoading: isLoading,
                enableMapData: list.enableMapData == true,
                location: $location
            )
            .navigationTitle("Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            let success = await viewModel.addItem(
                                note: itemName,
                                label: selectedLabel,
                                quantity: Double(quantity),
                                checked: checked,
                                markdownNotes: mdNotes.isEmpty ? nil : mdNotes,
                                reminderDate: reminderEnabled ? reminderDate : nil,
                                reminderRepeatRule: reminderEnabled ? repeatRule : nil,
                                reminderRepeatMode: reminderEnabled && repeatRule != nil ? repeatMode : nil,
                                location: location
                            )
                            if success {
                                dismiss()
                            } else {
                                showError = true
                            }
                        }
                    }
                    .disabled(itemName.trimmingCharacters(in: .whitespaces).isEmpty)
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
            .alert("Failed to Add Item", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please check your internet connection or try again.")
            }
            .sheet(isPresented: $showMarkdownEditor) {
                MarkdownEditorView(text: $mdNotes)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
            .task {
                do {
                    let labels = try await viewModel.provider.fetchLabels(for: viewModel.list)
                    let hiddenLabelIDs = Set(list.hiddenLabels ?? [])
                    availableLabels = labels.filter { !hiddenLabelIDs.contains($0.id) }
                    availableLabels.sort {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                } catch {
                    AppLogger.labels.warning("Failed to fetch labels: \(error, privacy: .public)")
                }
                isLoading = false
            }
        }
    }
}

// MARK: - Edit Item View

struct EditItemView: View {
    @Environment(\.dismiss) var dismiss
    var viewModel: ShoppingListViewModel

    let item: ShoppingItem
    let list: ShoppingListSummary
    let unifiedList: UnifiedList

    private var editFolderName: String? {
        if case .external(let url) = unifiedList.source {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return nil
    }

    @State private var itemName: String = ""
    @State private var selectedLabel: ShoppingLabel? = nil
    @State private var quantity: Int = 1
    @State private var mdNotes: String = ""
    @State private var availableLabels: [ShoppingLabel] = []
    @State private var checked: Bool = false
    @State private var isLoading = true
    @State private var showDeleteConfirmation = false
    @State private var showError = false
    @State private var showMarkdownEditor = false
    @State private var reminderEnabled = false
    @State private var reminderDate = Date().addingTimeInterval(3600)
    @State private var repeatRule: ReminderRepeatRule? = nil
    @State private var repeatMode: ReminderRepeatMode = .fixed
    @State private var location: Coordinate? = nil

    var body: some View {
        NavigationStack {
            ItemFormView(
                itemName: $itemName,
                quantity: $quantity,
                selectedLabel: $selectedLabel,
                checked: $checked,
                mdNotes: $mdNotes,
                showMarkdownEditor: $showMarkdownEditor,
                reminderEnabled: $reminderEnabled,
                reminderDate: $reminderDate,
                repeatRule: $repeatRule,
                repeatMode: $repeatMode,
                availableLabels: availableLabels,
                isLoading: isLoading,
                listIcon: list.icon,
                listName: list.name,
                folderName: editFolderName,
                itemID: item.id,
                enableMapData: list.enableMapData == true,
                location: $location
            )
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    if !unifiedList.isReadOnly {
                        Button(role : .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                        .tint(.red)

                        Button(role : .close) {
                            Task {
                                let success = await viewModel.updateItem(
                                    item,
                                    note: itemName,
                                    labelId: selectedLabel?.id,
                                    quantity: Double(quantity),
                                    checked: checked,
                                    markdownNotes: mdNotes.isEmpty ? nil : mdNotes,
                                    reminderDate: reminderEnabled ? reminderDate : nil,
                                    reminderRepeatRule: reminderEnabled ? repeatRule : nil,
                                    reminderRepeatMode: reminderEnabled && repeatRule != nil ? repeatMode : nil,
                                    location: location
                                )
                                if success {
                                    dismiss()
                                } else {
                                    showError = true
                                }
                            }
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        .tint(.accentColor)
                        .disabled(itemName.trimmingCharacters(in: .whitespaces).isEmpty)
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
            .alert("Delete Item?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    Task {
                        let success = await viewModel.deleteItem(item)
                        if success {
                            dismiss()
                        } else {
                            showError = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Failed to Save Changes", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            }
            .sheet(isPresented: $showMarkdownEditor) {
                MarkdownEditorView(text: $mdNotes)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
            .task {
                do {
                    let labels = try await viewModel.provider.fetchLabels(for: viewModel.list)
                    let hiddenLabelIDs = Set(list.hiddenLabels ?? [])
                    availableLabels = labels.filter { !hiddenLabelIDs.contains($0.id) }
                    availableLabels.sort {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    if let labelId = item.labelId {
                        selectedLabel = availableLabels.first(where: { $0.id == labelId })
                    } else {
                        selectedLabel = nil
                    }
                } catch {
                    AppLogger.labels.warning("Failed to fetch labels: \(error, privacy: .public)")
                }
                isLoading = false
            }
        }
        .onAppear {
            itemName = item.note
            quantity = Int(item.quantity)
            mdNotes = item.markdownNotes ?? ""
            checked = item.checked
            if let date = item.reminderDate {
                reminderEnabled = true
                reminderDate = date
            }
            repeatRule = item.reminderRepeatRule
            repeatMode = item.reminderRepeatMode ?? .fixed
            location = item.location
        }
    }
}

// MARK: - Checkable Markdown View (interactive checkboxes in markdown preview)

/// Renders markdown with interactive checkboxes, mirroring writie's task-list preview.
/// Pass a `Binding<String>` so checkbox toggles mutate the source text.
struct CheckableMarkdownView: View {
    @Binding var text: String

    private enum CheckState { case none, checked, unchecked }

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let state = checkState(of: line)
                if state != .none {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button {
                            text = toggleCheckbox(at: index, in: text)
                        } label: {
                            Image(systemName: state == .checked ? "inset.filled.circle" : "circle")
                                .imageScale(.large)
                                .foregroundStyle(state == .checked ? .gray : .accentColor)
                        }
                        .buttonStyle(.borderless)

                        MarkdownView(labelText(from: line))
                            .foregroundStyle(state == .checked ? .gray : .primary)
                            .strikethrough(state == .checked, color: .gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    MarkdownView(line)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("") // empty line spacer
                }
            }
        }
    }

    private func checkState(of line: String) -> CheckState {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") { return .checked }
        if trimmed.hasPrefix("- [ ] ") { return .unchecked }
        return .none
    }

    private func labelText(from line: String) -> String {
        guard let range = line.range(of: #"- \[[ xX]\] "#, options: .regularExpression) else {
            return line
        }
        return String(line[range.upperBound...])
    }

    private func toggleCheckbox(at index: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard index >= 0, index < lines.count else { return text }
        let line = lines[index]
        if let range = line.range(of: "- [x] ", options: .caseInsensitive) {
            lines[index] = line.replacingCharacters(in: range, with: "- [ ] ")
        } else if let range = line.range(of: "- [ ] ") {
            lines[index] = line.replacingCharacters(in: range, with: "- [x] ")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Item Preview View (Read-only markdown preview)

struct ItemPreviewView: View {
    @Environment(\.dismiss) var dismiss
    let item: ShoppingItem
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if notes.isEmpty {
                        Text("No notes")
                            .foregroundStyle(.secondary)
                    } else {
                        CheckableMarkdownView(text: $notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(item.note)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
        }
        .onAppear {
            notes = item.markdownNotes ?? ""
        }
    }
}

// MARK: - Markdown Editor View (Extracted for reuse)

struct MarkdownEditorView: View {
    @Binding var text: String
    @Environment(\.dismiss) var dismiss
    @FocusState private var editorFocused: Bool

    // AttributedString + selection state — gives us real cursor position.
    @State private var attributedText = AttributedString("")
    @State private var selection = AttributedTextSelection()

    // MARK: Snippet insertion — uses actual cursor position from AttributedTextSelection
    private func applySnippet(_ snippet: MarkdownSnippet) {
        let str = String(attributedText.characters)
        let nsStr = str as NSString

        // 1. Convert AttributedTextSelection → NSRange (UTF-16 units, as NSRange expects).
        //    AttributedString.Index bridges to String.Index via the characters view.
        func attrIdxToUTF16(_ idx: AttributedString.Index) -> Int {
            // AttributedString.Index can be used directly as a String.Index into .characters
            let strIdx = String.Index(idx, within: str) ?? str.endIndex
            return str.utf16.distance(from: str.utf16.startIndex, to: strIdx.samePosition(in: str.utf16) ?? str.utf16.endIndex)
        }

        let nsRange: NSRange
        switch selection.indices(in: attributedText) {
        case .insertionPoint(let idx):
            let loc = attrIdxToUTF16(idx)
            nsRange = NSRange(location: loc, length: 0)
        case .ranges(let rangeSet):
            if let first = rangeSet.ranges.first {
                let loc = attrIdxToUTF16(first.lowerBound)
                let end = attrIdxToUTF16(first.upperBound)
                nsRange = NSRange(location: loc, length: end - loc)
            } else {
                nsRange = NSRange(location: nsStr.length, length: 0)
            }
        }

        // 2. Apply the snippet to get the new plain string and desired new selection range.
        let (newText, newNSRange) = snippet.apply(to: str, selectedRange: nsRange)

        // 3. Replace attributedText with the new plain text, keeping selection valid.
        attributedText.transform(updating: &selection) { attrStr in
            attrStr = AttributedString(newText)
        }

        // 4. Position cursor at newNSRange (UTF-16) — after inline wrapping this selects
        //    the placeholder; after line-prefix it's an insertion point.
        let newStr = newText
        if newNSRange.length > 0 {
            // Convert UTF-16 range → AttributedString range
            if let startIdx = newStr.utf16.index(newStr.utf16.startIndex,
                                                  offsetBy: newNSRange.location,
                                                  limitedBy: newStr.utf16.endIndex),
               let endIdx = newStr.utf16.index(startIdx,
                                               offsetBy: newNSRange.length,
                                               limitedBy: newStr.utf16.endIndex),
               let strStart = startIdx.samePosition(in: newStr),
               let strEnd = endIdx.samePosition(in: newStr) {
                let attrStart = AttributedString.Index(strStart, within: attributedText)
                let attrEnd   = AttributedString.Index(strEnd,   within: attributedText)
                if let s = attrStart, let e = attrEnd {
                    selection = AttributedTextSelection(range: s..<e)
                }
            }
        } else {
            // Insertion point only
            if let startIdx = newStr.utf16.index(newStr.utf16.startIndex,
                                                  offsetBy: newNSRange.location,
                                                  limitedBy: newStr.utf16.endIndex),
               let strStart = startIdx.samePosition(in: newStr) {
                if let attrStart = AttributedString.Index(strStart, within: attributedText) {
                    selection = AttributedTextSelection(insertionPoint: attrStart)
                }
            }
        }

        text = newText
    }

    // MARK: body

    var body: some View {
        NavigationStack {
#if targetEnvironment(macCatalyst)
            // TextEditor fills the full space; glass snippet bar floats over it at the top.
            TextEditor(text: $attributedText, selection: $selection)
                .font(.system(.body, design: .monospaced))
                .focused($editorFocused)
                .onChange(of: attributedText) { _, newVal in
                    let str = String(newVal.characters)
                    if str != text { text = str }
                }
                .navigationTitle("Notes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    macSnippetBar
                }
#else
            TextEditor(text: $attributedText, selection: $selection)
                .font(.system(.body, design: .monospaced))
                .padding(0)
                .focused($editorFocused)
                .onChange(of: attributedText) { _, newVal in
                    let str = String(newVal.characters)
                    if str != text { text = str }
                }
                .navigationTitle("Notes")
                .navigationBarTitleDisplayMode(.inline)
                // .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                // .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Button { applySnippet(.taskItem) } label: { Label("Task", systemImage: MarkdownSnippet.taskItem.systemImage) }
                        Button { applySnippet(.unorderedList) } label: { Label("List", systemImage: MarkdownSnippet.unorderedList.systemImage) }
                        Menu {
                            Button("H1 — Heading 1") { applySnippet(.heading(1)) }
                            Button("H2 — Heading 2") { applySnippet(.heading(2)) }
                            Button("H3 — Heading 3") { applySnippet(.heading(3)) }
                        } label: { Label("Heading", systemImage: MarkdownSnippet.heading(1).systemImage) }
                        Button { applySnippet(.link) } label: { Label("Link", systemImage: MarkdownSnippet.link.systemImage) }
                        Spacer()
                        Menu {
                            Button { applySnippet(.bold) } label: { Label(MarkdownSnippet.bold.label, systemImage: MarkdownSnippet.bold.systemImage) }
                            Button { applySnippet(.italic) } label: { Label(MarkdownSnippet.italic.label, systemImage: MarkdownSnippet.italic.systemImage) }
                            Button { applySnippet(.code) } label: { Label(MarkdownSnippet.code.label, systemImage: MarkdownSnippet.code.systemImage) }
                            Button { applySnippet(.codeBlock) } label: { Label(MarkdownSnippet.codeBlock.label, systemImage: MarkdownSnippet.codeBlock.systemImage) }
                            Button { applySnippet(.blockquote) } label: { Label(MarkdownSnippet.blockquote.label, systemImage: MarkdownSnippet.blockquote.systemImage) }
                            Button { applySnippet(.image) } label: { Label(MarkdownSnippet.image.label, systemImage: MarkdownSnippet.image.systemImage) }
                            Button { applySnippet(.orderedList) } label: { Label(MarkdownSnippet.orderedList.label, systemImage: MarkdownSnippet.orderedList.systemImage) }
                        } label: { Label("More", systemImage: "ellipsis") }
                    }
                }
#endif
        }
        .onAppear {
            attributedText = AttributedString(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                editorFocused = true
            }
        }
        .onChange(of: text) { _, newVal in
            let current = String(attributedText.characters)
            if current != newVal { attributedText = AttributedString(newVal) }
        }
    }

    // MARK: Mac Catalyst inline snippet bar (no keyboard on Mac)

#if targetEnvironment(macCatalyst)
    private var macSnippetBar: some View {
        HStack(spacing: 12) {
            Spacer()
            // Primary group — single capsule glass surface behind all 4 buttons
            HStack(spacing: 0) {
                Button { applySnippet(.taskItem) } label: {
                    Image(systemName: MarkdownSnippet.taskItem.systemImage)
                        .imageScale(.medium)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .help("Task")

                Button { applySnippet(.unorderedList) } label: {
                    Image(systemName: MarkdownSnippet.unorderedList.systemImage)
                        .imageScale(.medium)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .help("List")

                Menu {
                    Button("H1") { applySnippet(.heading(1)) }
                    Button("H2") { applySnippet(.heading(2)) }
                    Button("H3") { applySnippet(.heading(3)) }
                } label: {
                    Image(systemName: MarkdownSnippet.heading(1).systemImage)
                        .imageScale(.medium)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .help("Heading")

                Button { applySnippet(.link) } label: {
                    Image(systemName: MarkdownSnippet.link.systemImage)
                        .imageScale(.medium)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .help("Link")
            }
            .glassEffect(.regular.interactive(), in: .capsule)

            // Overflow — separate floating circle
            Menu {
                Button { applySnippet(.bold) } label: { Label(MarkdownSnippet.bold.label, systemImage: MarkdownSnippet.bold.systemImage) }
                Button { applySnippet(.italic) } label: { Label(MarkdownSnippet.italic.label, systemImage: MarkdownSnippet.italic.systemImage) }
                Button { applySnippet(.code) } label: { Label(MarkdownSnippet.code.label, systemImage: MarkdownSnippet.code.systemImage) }
                Button { applySnippet(.codeBlock) } label: { Label(MarkdownSnippet.codeBlock.label, systemImage: MarkdownSnippet.codeBlock.systemImage) }
                Button { applySnippet(.blockquote) } label: { Label(MarkdownSnippet.blockquote.label, systemImage: MarkdownSnippet.blockquote.systemImage) }
                Button { applySnippet(.image) } label: { Label(MarkdownSnippet.image.label, systemImage: MarkdownSnippet.image.systemImage) }
                Button { applySnippet(.orderedList) } label: { Label(MarkdownSnippet.orderedList.label, systemImage: MarkdownSnippet.orderedList.systemImage) }
            } label: {
                Image(systemName: "ellipsis")
                    .imageScale(.medium)
                    .frame(width: 40, height: 40)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .help("More")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
#endif
}

// MARK: - Item Form Chip

private struct ItemFormChip: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }
}

// MARK: - Location Picker Sheet

struct LocationPickerSheet: View {
    @Environment(\.dismiss) var dismiss
    @Binding var location: Coordinate?

    @State private var position: MapCameraPosition
    @State private var centerCoord: CLLocationCoordinate2D
    @State private var isEditing: Bool
    @State private var addressQuery = ""
    @State private var geocodeState: GeocodeState = .idle
    @FocusState private var searchFocused: Bool

    private enum GeocodeState { case idle, loading, failed }

    init(location: Binding<Coordinate?>) {
        self._location = location
        if let existing = location.wrappedValue {
            let cl = CLLocationCoordinate2D(latitude: existing.latitude, longitude: existing.longitude)
            self._centerCoord = State(initialValue: cl)
            self._position = State(initialValue: .region(MKCoordinateRegion(
                center: cl,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            )))
            self._isEditing = State(initialValue: false)
        } else {
            self._centerCoord = State(initialValue: CLLocationCoordinate2D(latitude: 0, longitude: 0))
            self._position = State(initialValue: .automatic)
            self._isEditing = State(initialValue: true)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if isEditing {
                    Map(position: $position)
                        .onMapCameraChange(frequency: .continuous) { context in
                            centerCoord = context.camera.centerCoordinate
                        }
                        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: true))
                        .mapControls {
                            MapUserLocationButton()
                            MapCompass()
                        }
                        .ignoresSafeArea(edges: .bottom)
                        .onTapGesture { searchFocused = false }
                        .onAppear { LocationPermissionManager.shared.requestIfNeeded() }

                    // Fixed centre crosshair
                    Image(systemName: "dot.crosshair")
                        .font(.system(size: 36))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.accentColor.opacity(0.3), Color.accentColor)
                        .allowsHitTesting(false)
                } else {
                    Map(position: $position) {
                        Marker("", coordinate: CLLocationCoordinate2D(
                            latitude: centerCoord.latitude,
                            longitude: centerCoord.longitude
                        ))
                        .tint(Color.accentColor)
                    }
                    .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: true))
                    .mapControls {
                        MapCompass()
                    }
                    .ignoresSafeArea(edges: .bottom)
                }

                // Coordinate readout (both modes)
                VStack {
                    Spacer()
                    Text(String(format: "%.4f°, %.4f°", centerCoord.latitude, centerCoord.longitude))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
                .allowsHitTesting(false)
            }
            .navigationTitle(isEditing ? "Update Location" : "View Location")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if isEditing {
                    addressSearchBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isEditing {
                        Button {
                            location = Coordinate(latitude: centerCoord.latitude, longitude: centerCoord.longitude)
                            dismiss()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Button("Edit") {
                            position = .region(MKCoordinateRegion(
                                center: centerCoord,
                                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                            ))
                            withAnimation { isEditing = true }
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if location != nil { isEditing = false }
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").symbolRenderingMode(.hierarchical)
                    }
                }
            }
        }
    }

    private var addressSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField("Search address", text: $addressQuery)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { Task { await geocodeAddress() } }
                .autocorrectionDisabled()
            if geocodeState == .loading {
                ProgressView().controlSize(.small)
            } else if geocodeState == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .transition(.scale.combined(with: .opacity))
            } else if !addressQuery.isEmpty {
            
                Button {
                    Task { await geocodeAddress() }
                } label: {
                    Text("Search")
                        .font(.subheadline)
                        .frame(height: 20)
                }
                .buttonStyle(.glassProminent)
                .transition(.scale.combined(with: .opacity))

                Button { addressQuery = "" } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .transition(.scale.combined(with: .opacity))

            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .animation(.easeInOut(duration: 0.15), value: geocodeState)
        .animation(.easeInOut(duration: 0.15), value: addressQuery.isEmpty)
    }

    private func geocodeAddress() async {
        let query = addressQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchFocused = false
        geocodeState = .loading
        guard let request = MKGeocodingRequest(addressString: query),
              let item = try? await request.mapItems.first else {
            geocodeState = .failed
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            geocodeState = .idle
            return
        }
        let coord = item.location.coordinate
        position = .region(MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        ))
        centerCoord = coord
        geocodeState = .idle
    }
}

// MARK: - Markdown Snippet

enum MarkdownSnippet {
    case bold, italic, code, codeBlock, blockquote, link, image, taskItem, unorderedList, orderedList, heading(Int)

    var label: String {
        switch self {
        case .bold:          return "Bold"
        case .italic:        return "Italic"
        case .code:          return "Inline Code"
        case .codeBlock:     return "Code Block"
        case .blockquote:    return "Blockquote"
        case .link:          return "Link"
        case .image:         return "Image"
        case .taskItem:      return "Task"
        case .unorderedList: return "Unordered List"
        case .orderedList:   return "Ordered List"
        case .heading(let n): return "H\(n)"
        }
    }

    var systemImage: String {
        switch self {
        case .bold:          return "bold"
        case .italic:        return "italic"
        case .code:          return "chevron.left.forwardslash.chevron.right"
        case .codeBlock:     return "doc.plaintext"
        case .blockquote:    return "text.quote"
        case .link:          return "link"
        case .image:         return "photo"
        case .taskItem:      return "checklist"
        case .unorderedList: return "list.bullet"
        case .orderedList:   return "list.number"
        case .heading:       return "textformat.size"
        }
    }

    /// Apply snippet to `fullText` at `selectedRange` (UTF-16 units).
    /// Returns the modified string and new selection range (UTF-16 units).
    func apply(to fullText: String, selectedRange: NSRange) -> (String, NSRange) {
        guard let swiftRange = Range(selectedRange, in: fullText) else {
            return (fullText, selectedRange)
        }
        let selected = String(fullText[swiftRange])
        let hasSelection = !selected.isEmpty

        switch self {
        case .bold:
            return wrapInline(fullText, swiftRange, prefix: "**", suffix: "**", placeholder: "bold", selected: selected, hasSelection: hasSelection)
        case .italic:
            return wrapInline(fullText, swiftRange, prefix: "*", suffix: "*", placeholder: "italic", selected: selected, hasSelection: hasSelection)
        case .code:
            return wrapInline(fullText, swiftRange, prefix: "`", suffix: "`", placeholder: "code", selected: selected, hasSelection: hasSelection)
        case .codeBlock:
            let inner = hasSelection ? selected : "code"
            let snippet = "```\n\(inner)\n```"
            let result = fullText.replacingCharacters(in: swiftRange, with: snippet)
            let base = utf16Offset(of: swiftRange.lowerBound, in: fullText)
            return (result, NSRange(location: base + 4, length: inner.utf16.count))
        case .link:
            if hasSelection {
                let snippet = "[\(selected)](URL)"
                let result = fullText.replacingCharacters(in: swiftRange, with: snippet)
                let base = utf16Offset(of: swiftRange.lowerBound, in: fullText)
                // Select "URL"
                return (result, NSRange(location: base + 1 + selected.utf16.count + 2, length: 3))
            } else {
                let snippet = "[text](URL)"
                let result = fullText.replacingCharacters(in: swiftRange, with: snippet)
                let base = utf16Offset(of: swiftRange.lowerBound, in: fullText)
                return (result, NSRange(location: base + 1, length: 4)) // select "text"
            }
        case .image:
            if hasSelection {
                let snippet = "![\(selected)](URL)"
                let result = fullText.replacingCharacters(in: swiftRange, with: snippet)
                let base = utf16Offset(of: swiftRange.lowerBound, in: fullText)
                return (result, NSRange(location: base + 2 + selected.utf16.count + 2, length: 3))
            } else {
                let snippet = "![alt](URL)"
                let result = fullText.replacingCharacters(in: swiftRange, with: snippet)
                let base = utf16Offset(of: swiftRange.lowerBound, in: fullText)
                return (result, NSRange(location: base + 2, length: 3)) // select "alt"
            }
        case .taskItem:
            return insertLinePrefix("- [ ] ", fullText: fullText, swiftRange: swiftRange, selectedRange: selectedRange)
        case .unorderedList:
            return insertLinePrefix("- ", fullText: fullText, swiftRange: swiftRange, selectedRange: selectedRange)
        case .orderedList:
            return insertLinePrefix("1. ", fullText: fullText, swiftRange: swiftRange, selectedRange: selectedRange)
        case .blockquote:
            return insertLinePrefix("> ", fullText: fullText, swiftRange: swiftRange, selectedRange: selectedRange)
        case .heading(let level):
            return insertLinePrefix(String(repeating: "#", count: level) + " ", fullText: fullText, swiftRange: swiftRange, selectedRange: selectedRange)
        }
    }

    private func wrapInline(_ fullText: String, _ swiftRange: Range<String.Index>,
                             prefix: String, suffix: String, placeholder: String,
                             selected: String, hasSelection: Bool) -> (String, NSRange) {
        let inner = hasSelection ? selected : placeholder
        let snippet = "\(prefix)\(inner)\(suffix)"
        let result = fullText.replacingCharacters(in: swiftRange, with: snippet)
        let base = utf16Offset(of: swiftRange.lowerBound, in: fullText)
        return (result, NSRange(location: base + prefix.utf16.count, length: inner.utf16.count))
    }

    private func insertLinePrefix(_ prefix: String, fullText: String,
                                  swiftRange: Range<String.Index>,
                                  selectedRange: NSRange) -> (String, NSRange) {
        var lineStart = swiftRange.lowerBound
        while lineStart > fullText.startIndex {
            let prev = fullText.index(before: lineStart)
            if fullText[prev] == "\n" { break }
            lineStart = prev
        }
        let result = fullText.replacingCharacters(in: lineStart..<lineStart, with: prefix)
        let newLocation = selectedRange.location + prefix.utf16.count
        return (result, NSRange(location: newLocation, length: selectedRange.length))
    }

    private func utf16Offset(of index: String.Index, in str: String) -> Int {
        return str.utf16.distance(from: str.utf16.startIndex, to: index.samePosition(in: str.utf16) ?? str.utf16.startIndex)
    }
}

// (CustomTextEditor, MarkdownTextView, and MarkdownSnippetToolbar removed —
//  the editor now uses SwiftUI TextEditor with ToolbarItemGroup(placement: .keyboard))
