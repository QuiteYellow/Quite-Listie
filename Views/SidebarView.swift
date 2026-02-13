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

import SwiftUI

struct SidebarView: View {
    @ObservedObject var welcomeViewModel: WelcomeViewModel
    @ObservedObject var unifiedProvider: UnifiedListProvider
    @Binding var selectedListID: String?
    @Binding var editingUnifiedList: UnifiedList?
    
    var onImportFile: () -> Void
    
    @Binding var hideWelcomeList: Bool
    
    @State private var listToDelete: UnifiedList? = nil
    @State private var showingDeleteConfirmation = false
    @State private var showFavouritesWarning: Bool = !UserDefaults.standard.bool(forKey: "hideFavouritesWarning")
    @State private var iCloudSyncEnabled: Bool = true
    
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
        if case .external(let url) = list.source {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return ""
    }
    
    var body: some View {
        List(selection: $selectedListID) {

            // MARK: - Reminder Smart Boxes
            let todayCount = welcomeViewModel.todayReminderCount
            let scheduledCount = welcomeViewModel.scheduledReminderCount

            if todayCount > 0 || scheduledCount > 0 {
                Section {
                    HStack(spacing: 12) {
                        // Today box
                        ReminderSmartBox(
                            title: "Today",
                            count: todayCount,
                            icon: "calendar.circle.fill",
                            color: .orange,
                            isSelected: selectedListID == "__reminders_today"
                        ) {
                            selectedListID = "__reminders_today"
                        }

                        // Scheduled box
                        ReminderSmartBox(
                            title: "Scheduled",
                            count: scheduledCount,
                            icon: "calendar.badge.clock",
                            color: .blue,
                            isSelected: selectedListID == "__reminders_scheduled"
                        ) {
                            selectedListID = "__reminders_scheduled"
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
                

            // MARK: - Welcome Section (at the top)
            if !hideWelcomeList {
                let welcomeList = unifiedProvider.allLists.first(where: { $0.id == "example-welcome-list" })
                if let welcome = welcomeList {
                    Section(header: Text("Getting Started").foregroundColor(.purple)) {
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
                Section(header: Label("Favourites", systemImage: "star.fill").foregroundColor(.yellow)) {
                    ForEach(favourites.sorted(by: { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }), id: \.id) { list in
                        listRow(for: list)
                    }
                }
            }
            
            // MARK: - Private Lists (in iCloud container)
            let privateLists = unifiedProvider.allLists.filter { !favouriteListIDs.contains($0.summary.id) && $0.isPrivate && !$0.isReadOnly }
            if !privateLists.isEmpty {
                Section(header: Label("Private", systemImage: iCloudSyncEnabled ? "lock.icloud.fill" : "icloud.slash.fill")) {
                    ForEach(privateLists.sorted(by: { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }), id: \.id) { list in
                        listRow(for: list)
                    }
                }
            }
            
            // MARK: - External / Linked Lists (Grouped by Folder)
            let externalLists = unifiedProvider.allLists.filter { !favouriteListIDs.contains($0.summary.id) && $0.isExternal && !$0.isReadOnly && !$0.isUnavailable }
            if !externalLists.isEmpty {
                // Group by folder
                let grouped = Dictionary(grouping: externalLists) { list in
                    folderName(for: list)
                }
                
                let sortedFolders = grouped.keys.sorted()
                
                ForEach(sortedFolders, id: \.self) { folder in
                    Section(header: Text(folder.isEmpty ? "Connected" : folder)) {
                        ForEach(grouped[folder]!.sorted(by: { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }), id: \.id) { list in
                            listRow(for: list)
                        }
                    }
                }
            }
            
            // MARK: - Temporary Read-Only Lists
            let readOnlyLists = unifiedProvider.allLists.filter { !favouriteListIDs.contains($0.summary.id) && $0.isReadOnly && !$0.isUnavailable && $0.id != "example-welcome-list" }
            if !readOnlyLists.isEmpty {
                Section(header: Text("Temporary (Read Only)")) {
                    ForEach(readOnlyLists.sorted(by: { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }), id: \.id) { list in
                        listRow(for: list)
                    }
                }
            }

            // MARK: - Unavailable Lists
            let unavailableLists = unifiedProvider.allLists.filter { $0.isUnavailable }
            if !unavailableLists.isEmpty {
                Section(header: Label("Unavailable", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)) {
                    ForEach(unavailableLists.sorted(by: { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }), id: \.id) { list in
                        unavailableListRow(for: list)
                    }
                }
            }
        }
        .navigationTitle("Listie.md")
        .navigationBarTitleDisplayMode(.large)
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
                            .foregroundColor(.secondary)
                    } else {
                        Text("Loading \(loadingFile)...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: unifiedProvider.isInitialLoad)

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
                        print("❌ Failed to delete list: \(error)")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { list in
            if list.isExternal {
                Text("This will remove the file from Listie. The actual file will not be deleted.")
            } else {
                Text("Are you sure you want to delete the list \"\(list.summary.name)\"?")
            }
        }
        .task {
            // Load initial iCloud sync state
            iCloudSyncEnabled = await iCloudContainerManager.shared.isICloudSyncEnabled()
            // Also check if iCloud is actually available
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
        let saveStatus = unifiedProvider.saveStatus[list.id] ?? .saved
        
        HStack {
            // Icon
            Image(systemName: list.summary.icon ?? "list.bullet")
                .frame(minWidth: 30)
                .symbolRenderingMode(.hierarchical)
                //.foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(list.summary.name)
                
                // Show folder name as caption for favorited external lists
                if isFavourited && list.isExternal {
                    Text(folderName(for: list))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Save status indicator (like writie.md)
            
            // Show link icon for favorited external lists
            if isFavourited && list.isExternal {
                Image(systemName: "link")
                    .foregroundColor(.secondary)
                    .imageScale(.small)
            }

            // Show sync status icons
            if list.isExternal {
                saveStatusView(for: saveStatus)
            }
            // Unchecked count
            Text("\(welcomeViewModel.uncheckedCounts[list.summary.id] ?? 0)")
                .foregroundColor(.secondary)
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
                
                if list.isExternal {
                    Button("Close File") {
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
                Text("Read-only list").foregroundColor(.gray)
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
                    Label(list.isExternal ? "Close" : "Delete", systemImage: list.isExternal ? "xmark.circle" : "trash")
                }
                .tint(.red)
            }
        }
    }
    
    @ViewBuilder
    private func saveStatusView(for status: UnifiedListProvider.SaveStatus) -> some View {
        switch status {
        case .saved:
            EmptyView()
        case .saving:
            EmptyView()
        case .unsaved:
            Image(systemName: "circle.fill")
                .foregroundColor(.orange)
                .imageScale(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .imageScale(.small)
        }
    }

    @ViewBuilder
    private func unavailableListRow(for list: UnifiedList) -> some View {
        if let bookmark = list.unavailableBookmark {
            HStack {
                // Warning icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .frame(minWidth: 30)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(list.summary.name)
                        .foregroundColor(.secondary)

                    // Show folder and error reason
                    Text("\(bookmark.folderName) • \(bookmark.reason.localizedDescription)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Show the specific issue icon
                Image(systemName: bookmark.reason.icon)
                    .foregroundColor(.secondary)
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
                        await ExternalFileStore.shared.refreshBookmarkAvailability()
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
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(color)
                    Spacer()
                    Text("\(count)")
                        .font(.title2.bold())
                        .foregroundColor(.primary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.25), value: count)
                }

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(isSelected ? color.opacity(0.15) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? color.opacity(0.4) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
