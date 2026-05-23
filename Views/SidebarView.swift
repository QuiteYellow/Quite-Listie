//
//  SidebarView.swift
//  Listie-md
//
//  Created by Jack Nagy on 02/01/2026.
//


//
//  SidebarView.swift
//  Listie.md
//
//  Sidebar view for managing and displaying all shopping lists
//

import os
import SwiftUI

struct SidebarView: View {
    var welcomeViewModel: WelcomeViewModel
    var unifiedProvider: UnifiedListProvider
    @Binding var selectedListID: String?
    @Binding var editingUnifiedList: UnifiedList?
    
    var onImportFile: () -> Void
    
    @Binding var hideWelcomeList: Bool
    
    @State private var listToDelete: UnifiedList? = nil
    @State private var showingDeleteConfirmation = false
    @State private var showFavouritesWarning: Bool = !UserDefaults.standard.bool(forKey: "hideFavouritesWarning")
    @State private var iCloudSyncEnabled: Bool = true
    var onOpenNextcloud: () -> Void

    // Per-card visibility — opt-out, default on. Toggled from Settings or each card's context menu.
    @AppStorage("hideTodayCard") private var hideTodayCard: Bool = false
    @AppStorage("hideScheduledCard") private var hideScheduledCard: Bool = false
    @AppStorage("hideLocationsCard") private var hideLocationsCard: Bool = false

    // Favorites stored in UserDefaults
    @AppStorage("favouriteListIDs") private var favouriteListIDsData: Data = Data()
    
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
    
    private func toggleFavourite(for listID: String) {
        var ids = favouriteListIDs
        if ids.contains(listID) {
            ids.remove(listID)
        } else {
            ids.insert(listID)
        }
        setFavouriteListIDs(ids)
    }
    
    private func folderName(for list: UnifiedList) -> String {
        switch list.source {
        case .external(let url):
            return url.deletingLastPathComponent().lastPathComponent
        case .nextcloud(let accountId, _):
            // Use the server hostname as section header
            if let host = URL(string: accountId.components(separatedBy: "@").last ?? "")?.host {
                return host
            }
            return accountId.components(separatedBy: "@").last ?? "Nextcloud"
        default:
            return ""
        }
    }

    /// For Nextcloud lists: returns the name of the remote parent folder, or "Nextcloud" for root.
    private func nextcloudFolderName(for list: UnifiedList) -> String {
        guard case .nextcloud(_, let remotePath) = list.source else { return "Nextcloud" }
        let components = remotePath.split(separator: "/").dropLast()
        return components.last.map(String.init) ?? "Nextcloud"
    }

    /// Returns the SF Symbol name representing where an external file is stored.
    private func externalIcon(for list: UnifiedList) -> String {
        guard case .external(let url) = list.source else { return "internaldrive.fill" }
        return url.path.contains("Mobile Documents") ? "icloud.fill" : "internaldrive.fill"
    }

    private struct FolderSection: Identifiable {
        let id: String           // unique key, e.g. "ext_Documents", "nc_lists", "__private"
        let displayName: String
        let systemImage: String
        var lists: [UnifiedList]
    }

    /// All non-favourite, non-special lists grouped by folder and sorted alphabetically by display name.
    private var folderSections: [FolderSection] {
        // Transient sync errors don't disqualify a list from the active sidebar —
        // those lists keep showing their cached content with a small sync chip.
        let regularLists = unifiedProvider.allLists.filter {
            !favouriteListIDs.contains($0.summary.id) &&
            !$0.isReadOnly &&
            !$0.isPermanentlyUnavailable &&
            $0.id != "example-welcome-list"
        }

        var dict: [String: FolderSection] = [:]
        for list in regularLists {
            let key: String; let name: String; let icon: String
            if list.isPrivate {
                key = "__private"
                name = "Private"
                icon = iCloudSyncEnabled ? "lock.icloud.fill" : "iphone"
            } else if list.isExternal {
                let folder = folderName(for: list)
                key = "ext_\(folder)"
                name = folder.isEmpty ? "Documents" : folder
                icon = externalIcon(for: list)
            } else if list.isNextcloud {
                let folder = nextcloudFolderName(for: list)
                key = "nc_\(folder)"
                name = folder
                icon = "externaldrive.fill.badge.icloud"
            } else {
                continue
            }
            if dict[key] == nil {
                dict[key] = FolderSection(id: key, displayName: name, systemImage: icon, lists: [])
            }
            dict[key]!.lists.append(list)
        }

        return dict.values.sorted {
            let cmp = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.id < $1.id  // stable tiebreaker when names are equal
        }
    }
    
    /// Today + Scheduled cards, shared between the HStack and VStack fallback
    /// inside `ViewThatFits` so we declare the children exactly once.
    @ViewBuilder
    private var todayScheduledCards: some View {
        let todayCount = welcomeViewModel.todayReminderCount
        let scheduledCount = welcomeViewModel.scheduledReminderCount
        let isLoadingCounts = !welcomeViewModel.hasLoadedCounts

        if !hideTodayCard {
            ReminderSmartBox(
                title: "Today",
                count: todayCount,
                icon: "calendar.circle.fill",
                color: .orange,
                isSelected: selectedListID == "__reminders_today",
                isLoading: isLoadingCounts,
                onTap: { selectedListID = "__reminders_today" },
                onHide: { hideTodayCard = true }
            )
        }
        if !hideScheduledCard {
            ReminderSmartBox(
                title: "Scheduled",
                count: scheduledCount,
                icon: "calendar.badge.clock",
                color: .blue,
                isSelected: selectedListID == "__reminders_scheduled",
                isLoading: isLoadingCounts,
                onTap: { selectedListID = "__reminders_scheduled" },
                onHide: { hideScheduledCard = true }
            )
        }
    }

    var body: some View {
        List(selection: $selectedListID) {

            // MARK: - Smart Boxes (Reminders + Locations)
            // Always rendered (unless explicitly hidden in Settings) so the user has
            // a stable entry point regardless of whether anything is currently due.
            // The cards self-style for zero/loading states.
            let todayCount = welcomeViewModel.todayReminderCount
            let scheduledCount = welcomeViewModel.scheduledReminderCount
            let locationCount = welcomeViewModel.activeLocationCount
            let isLoadingCounts = !welcomeViewModel.hasLoadedCounts
            let showTodayOrScheduled = !hideTodayCard || !hideScheduledCard
            let showAnyCard = showTodayOrScheduled || !hideLocationsCard

            if showAnyCard {
                Section {
                    if showTodayOrScheduled {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                todayScheduledCards
                            }
                            VStack(spacing: 12) {
                                todayScheduledCards
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    if !hideLocationsCard {
                        ReminderSmartBox(
                            title: "Locations",
                            count: locationCount,
                            icon: "mappin.circle.fill",
                            color: .green,
                            isSelected: selectedListID == "__map",
                            isLoading: isLoadingCounts,
                            onTap: { selectedListID = "__map" },
                            onHide: { hideLocationsCard = true }
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }



            // MARK: - Welcome Section (at the top)
            if !hideWelcomeList {
                let welcomeList = unifiedProvider.allLists.first(where: { $0.id == "example-welcome-list" })
                if let welcome = welcomeList {
                    Section(header: Text("Getting Started").foregroundStyle(.purple)) {
                        listRow(for: welcome)
                            .swipeActions(edge: .trailing) {
                                Button {
                                    hideWelcomeList = true
                                } label: {
                                    Label("Hide", systemImage: "eye.slash")
                                }
                                .tint(.orange)
                            }
                    }
                }
            }
            
            // MARK: - Favourites Section
            let favourites = unifiedProvider.allLists.filter {
                favouriteListIDs.contains($0.summary.id) && $0.id != "example-welcome-list"
            }
            if !favourites.isEmpty {
                Section(header: Label("Favourites", systemImage: "star.fill").foregroundStyle(.yellow)) {
                    ForEach(favourites.sorted(by: { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }), id: \.id) { list in
                        listRow(for: list)
                    }
                }
            }
            
            // MARK: - All Lists (alphabetical by folder, all sources mixed)
            ForEach(folderSections) { section in
                Section {
                    ForEach(section.lists.sorted { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }, id: \.id) { list in
                        listRow(for: list)
                    }
                } header: {
                    Label(section.displayName, systemImage: section.systemImage)
                }
            }

            // MARK: - Temporary Read-Only Lists
            let readOnlyLists = unifiedProvider.allLists.filter { !favouriteListIDs.contains($0.summary.id) && $0.isReadOnly && !$0.isPermanentlyUnavailable && $0.id != "example-welcome-list" }
            if !readOnlyLists.isEmpty {
                Section(header: Text("Temporary (Read Only)")) {
                    ForEach(readOnlyLists.sorted(by: { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }), id: \.id) { list in
                        listRow(for: list)
                    }
                }
            }

            // MARK: - Unavailable Lists
            // Only confirmed-permanent failures appear here (file deleted, in trash). Transient
            // sync errors live alongside their normal sidebar row with a small chip — they're
            // still usable from cache. The legacy `isRecoveringSession` banner suppression is
            // no longer needed because Layer 3 routes those errors as transient.
            let unavailableLists = unifiedProvider.allLists.filter { $0.isPermanentlyUnavailable }
            if !unavailableLists.isEmpty {
                Section(header: Label("Unavailable", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)) {
                    ForEach(unavailableLists.sorted(by: { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }), id: \.id) { list in
                        unavailableListRow(for: list)
                    }
                }
            }
        }
        .navigationTitle("Quite Listie")
        #if !targetEnvironment(macCatalyst)
        .navigationBarTitleDisplayMode(.large)
        #endif
        //.animation(.none, value: welcomeViewModel.uncheckedCounts)
        //.animation(.none, value: unifiedProvider.allLists)
        .safeAreaInset(edge: .bottom) {
            if unifiedProvider.isInitialLoad, let loadingFile = unifiedProvider.currentlyLoadingFile {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)

                    if unifiedProvider.loadingProgress.total > 0 {
                        Text("Loading \(loadingFile)... \(unifiedProvider.loadingProgress.current)/\(unifiedProvider.loadingProgress.total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Loading \(loadingFile)...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if unifiedProvider.isRecoveringSession {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Reconnecting to Nextcloud...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: unifiedProvider.isInitialLoad)
        .animation(.easeInOut(duration: 0.25), value: unifiedProvider.isRecoveringSession)

        .alert("Delete List?", isPresented: $showingDeleteConfirmation, presenting: listToDelete) { list in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await unifiedProvider.deleteList(list)
                        if selectedListID == list.id {
                            selectedListID = nil
                        }
                        await welcomeViewModel.loadLists()
                    } catch {
                        AppLogger.fileStore.error("Failed to delete list: \(error, privacy: .public)")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { list in
            if list.isNextcloud {
                Text("This will remove the list from Listie. The file will remain on your Nextcloud server.")
            } else if list.isExternal {
                Text("This will remove the file from Listie. The actual file will not be deleted.")
            } else {
                Text("Are you sure you want to delete the list \"\(list.summary.name)\"?")
            }
        }
        .task {
            // Load initial iCloud sync state
            iCloudSyncEnabled = await iCloudContainerManager.shared.isICloudSyncEnabled()
            let available = await iCloudContainerManager.shared.checkICloudAvailability()
            iCloudSyncEnabled = available
        }
        .onReceive(NotificationCenter.default.publisher(for: .storageLocationChanged)) { _ in
            Task {
                let available = await iCloudContainerManager.shared.checkICloudAvailability()
                iCloudSyncEnabled = available
            }
        }
    }
    
    @ViewBuilder
    private func listRow(for list: UnifiedList) -> some View {
        let isFavourited = favouriteListIDs.contains(list.summary.id)
        // Suppress transient error icons for NC lists while session is recovering.
        // Both syncFailed and saveFailed are masked so the user sees the "recovering"
        // banner rather than a red triangle that will probably clear on its own.
        let rawStatus = unifiedProvider.saveStatus[list.id] ?? .saved
        let saveStatus: UnifiedListProvider.SaveStatus = {
            if unifiedProvider.isRecoveringSession, list.isNextcloud {
                switch rawStatus {
                case .syncFailed, .saveFailed: return .saving
                default: return rawStatus
                }
            }
            return rawStatus
        }()
        
        HStack {
            // Icon
            Image(systemName: list.summary.icon ?? "list.bullet")
                .frame(minWidth: 30)
                .symbolRenderingMode(.hierarchical)
                //.foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(list.summary.name)
                
                // Show folder name as caption for favorited external/Nextcloud lists
                if isFavourited && (list.isExternal || list.isNextcloud) {
                    Text(list.isNextcloud ? nextcloudFolderName(for: list) : folderName(for: list))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Save status indicator (like writie.md)
            
            // Show link icon for favorited external/Nextcloud lists
            if isFavourited && (list.isExternal || list.isNextcloud) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }

            // Show sync-pending indicator for lists serving cached data
            if unifiedProvider.syncPendingListIDs.contains(list.id) {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }

            // Show sync status icons
            if list.isExternal || list.isNextcloud {
                saveStatusView(for: saveStatus)
            }
            // Unchecked count
            Text("\(welcomeViewModel.uncheckedCounts[list.summary.id] ?? 0)")
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.25), value: welcomeViewModel.uncheckedCounts[list.summary.id])
        }
        .tag(list.id)
        .contextMenu {
            if !list.isReadOnly {
                Button(isFavourited ? "Unfavourite" : "Favourite") {
                    toggleFavourite(for: list.summary.id)
                }
                
                Button("List Settings") {
                    editingUnifiedList = list
                }
                Divider()
                
                if list.isExternal || list.isNextcloud {
                    Button(list.isNextcloud ? "Remove from Sidebar" : "Close File") {
                        listToDelete = list
                        showingDeleteConfirmation = true
                    }
                } else {
                    Divider()

                    Button("Delete List", role: .destructive) {
                        listToDelete = list
                        showingDeleteConfirmation = true
                    }
                }
            } else {
                Text("Read-only list").foregroundStyle(.gray)
            }
        }
        .swipeActions(edge: .leading) {
            if !list.isReadOnly {
                Button {
                    editingUnifiedList = list
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.accentColor)
            }
        }
        .swipeActions(edge: .trailing) {
            if !list.isReadOnly {
                Button(role: .none) {
                    listToDelete = list
                    showingDeleteConfirmation = true
                } label: {
                    let isLinked = list.isExternal || list.isNextcloud
                    Label(isLinked ? "Close" : "Delete", systemImage: isLinked ? "xmark.circle" : "trash")
                }
                .tint(.red)
            }
        }
    }
    
    @ViewBuilder
    private func saveStatusView(for status: UnifiedListProvider.SaveStatus) -> some View {
        switch status {
        case .saved, .saving:
            EmptyView()
        case .unsaved:
            Image(systemName: "circle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
                .help("Saving…")
        case .pendingSync:
            // Saved locally; upload queued. Grey cloud-slash so the user knows their
            // data is safe but hasn't reached the server yet.
            Image(systemName: "icloud.slash")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .help("Saved locally — will sync when connection returns")
        case .syncFailed(let msg):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .imageScale(.small)
                .help(msg)
        case .saveFailed(let msg):
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .imageScale(.small)
                .help(msg)
        }
    }

    @ViewBuilder
    private func unavailableListRow(for list: UnifiedList) -> some View {
        if let bookmark = list.unavailableBookmark {
            HStack {
                // Warning icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .frame(minWidth: 30)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(list.summary.name)
                        .foregroundStyle(.secondary)

                    // Show folder and error reason
                    Text("\(bookmark.folderName) • \(bookmark.reason.localizedDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Show the specific issue icon
                Image(systemName: bookmark.reason.icon)
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
            .tag(list.id)
            .contextMenu {
                Button("Remove from Sidebar") {
                    Task {
                        await unifiedProvider.removeUnavailableList(list)
                    }
                }

                Button("Retry") {
                    Task {
                        // loadAllLists() handles bookmark refresh internally (single-pass)
                        await unifiedProvider.loadAllLists()
                    }
                }
            }
        }
    }
}

// MARK: - Reminder Smart Box

struct ReminderSmartBox: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color
    let isSelected: Bool
    var isLoading: Bool = false
    let onTap: () -> Void
    var onHide: (() -> Void)? = nil

    private var isEmpty: Bool { count == 0 && !isLoading }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(isEmpty ? color.opacity(0.55) : color)
                    Spacer()
                    countView
                }

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(isSelected ? color.opacity(0.15) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? color.opacity(0.4) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(SmartBoxPressStyle())
        .sensoryFeedback(.selection, trigger: isSelected) { old, new in !old && new }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValueText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if let onHide {
                Button {
                    onHide()
                } label: {
                    Label("Hide from Sidebar", systemImage: "eye.slash")
                }
            }
        }
    }

    @ViewBuilder
    private var countView: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 24, alignment: .trailing)
        } else {
            Text("\(count)")
                .font(.title2.weight(isEmpty ? .regular : .bold))
                .foregroundStyle(isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.25), value: count)
        }
    }

    private var accessibilityValueText: String {
        if isLoading { return "Loading" }
        if count == 0 { return "Nothing scheduled" }
        return "\(count) " + (count == 1 ? "item" : "items")
    }
}

/// Subtle press feedback for smart boxes — the default `.plain` style strips
/// all visual response, which makes the cards feel inert on tap.
private struct SmartBoxPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
