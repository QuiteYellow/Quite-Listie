//
//  WelcomeView.swift (FULLY UNIFIED VERSION)
//  ListsForMealie
//
//  All lists (local and external) shown together with unified UI
//

import SwiftUI

struct WelcomeView: View {
    @StateObject private var welcomeViewModel = WelcomeViewModel()
    @StateObject private var unifiedProvider = UnifiedListProvider()
    
    @State private var selectedListID: String? = nil
    @State private var isPresentingNewList = false
    @State private var showFileImporter = false
    @State private var showFileExporter = false
    @State private var exportingDocument: ListDocumentFile? = nil
    @State private var editingUnifiedList: UnifiedList? = nil
    
    @State private var conflictingFileURL: URL? = nil
    @State private var conflictingDocument: ListDocument? = nil
    @State private var showIDConflictAlert = false
    
    @State private var showNewConnectedExporter = false
    
    @State private var pendingExportType: ExportType? = nil
    
    @State private var showSettings = false
    @AppStorage("hideWelcomeList") private var hideWelcomeList = false
    
    enum ExportType {
        case newConnectedList
        case exportExisting
    }
    
    var body: some View {
        NavigationSplitView {
            SidebarView(
                welcomeViewModel: welcomeViewModel,
                unifiedProvider: unifiedProvider,
                selectedListID: $selectedListID,
                editingUnifiedList: $editingUnifiedList,
                onImportFile: { showFileImporter = true },
                hideWelcomeList: $hideWelcomeList
            )
            .refreshable {
                await unifiedProvider.loadAllLists()
                //await welcomeViewModel.loadLists()
                await welcomeViewModel.loadUnifiedCounts(for: unifiedProvider.allLists, provider: unifiedProvider)
                
                //await Task.yield()
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            isPresentingNewList = true
                        } label: {
                            Label("New List (Private)", systemImage: "doc.badge.plus")
                        }
                        
                        Button {
                            pendingExportType = .newConnectedList
                            showNewConnectedExporter = true
                        } label: {
                            Label("New List As File...", systemImage: "doc.badge.plus")
                        }
                        
                        Divider()
                        
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Open JSON File", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    
                    Menu {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings...", systemImage: "gear")
                        }
                    } label: {  // Move this out here
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        } detail: {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                if let listID = selectedListID,
                   let unifiedList = unifiedProvider.allLists.first(where: { $0.id == listID }) {
                    ShoppingListView(
                        list: unifiedList.summary,
                        unifiedList: unifiedList,
                        unifiedProvider: unifiedProvider,
                        welcomeViewModel: welcomeViewModel,
                        onExportJSON: {
                            Task {
                                await exportList(unifiedList.summary)
                            }
                        }
                    )
                    .id(unifiedList.id)
                } else {
                    ContentUnavailableView("Select a list", systemImage: "list.bullet")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(hideWelcomeList: $hideWelcomeList)
        }
        .sheet(item: $editingUnifiedList, onDismiss: {
            NotificationCenter.default.post(name: .listSettingsChanged, object: nil)
        }) { unifiedList in
            ListSettingsView(
                list: unifiedList.summary,
                unifiedList: unifiedList,
                unifiedProvider: unifiedProvider
            ) { updatedName, extras in
                Task {
                    let items = try? await unifiedProvider.fetchItems(for: unifiedList)
                    try? await unifiedProvider.updateList(
                        unifiedList,
                        name: updatedName,
                        extras: extras,
                        items: items ?? []
                    )
                    await unifiedProvider.loadAllLists()
                    await welcomeViewModel.loadLists()
                }
            }
        }
        .sheet(isPresented: $isPresentingNewList) {
            NewShoppingListView {
                Task {
                    await unifiedProvider.loadAllLists()
                    await welcomeViewModel.loadLists()
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        do {
                            if let listId = try await unifiedProvider.openExternalFile(at: url) {
                                selectedListID = listId
                            }
                        } catch {
                            let nsError = error as NSError
                            if nsError.domain == "UnifiedListProvider" && nsError.code == 1 {
                                // ID conflict - show alert
                                conflictingFileURL = nsError.userInfo["url"] as? URL
                                conflictingDocument = nsError.userInfo["document"] as? ListDocument
                                showIDConflictAlert = true
                            } else {
                                print("Failed to open file: \(error)")
                            }
                        }
                    }
                }
            case .failure(let error):
                print("File import error: \(error)")
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { showFileExporter || showNewConnectedExporter },
                set: { isPresented in
                    if !isPresented {
                        showFileExporter = false
                        showNewConnectedExporter = false
                    }
                }
            ),
            document: exportingDocument ?? ListDocumentFile.empty(name: "New List"),
            contentType: .json,
            defaultFilename: exportingDocument?.document.list.name ?? "new-list"
        ) { result in
            let exportType = pendingExportType  // Capture before reset
            
            switch result {
            case .success(let url):
                print("Exported to: \(url)")
                
                // Handle new connected list creation
                if exportType == .newConnectedList {
                    Task {
                        do {
                            let filename = url.deletingPathExtension().lastPathComponent
                            let newList = ModelHelpers.createNewList(name: filename, icon: "checklist")
                            let document = ListDocument(list: newList, items: [], labels: [])
                            
                            try await ExternalFileStore.shared.saveFile(document, to: url)
                            await unifiedProvider.loadAllLists()
                            
                            if let newList = unifiedProvider.allLists.first(where: {
                                if case .external(let listURL) = $0.source {
                                    return listURL.standardizedFileURL.path == url.standardizedFileURL.path
                                }
                                return false
                            }) {
                                selectedListID = newList.id
                                print("✅ Selected new list: \(newList.summary.name)")
                            } else {
                                print("⚠️ Could not find newly created list at: \(url.path)")
                            }
                        } catch {
                            print("❌ Failed to create new connected list: \(error)")
                        }
                    }
                }
                
            case .failure(let error):
                print("Export error: \(error)")
            }
            
            // Reset state
            exportingDocument = nil
            showFileExporter = false
            showNewConnectedExporter = false
            pendingExportType = nil  // Reset the type
        }
        .alert("ID Conflict", isPresented: $showIDConflictAlert) {
            Button("Generate New ID") {
                Task {
                    guard let url = conflictingFileURL, var document = conflictingDocument else { return }
                    
                    // Generate new ID
                    document.list.id = UUID().uuidString
                    
                    // Save with new ID
                    try? await ExternalFileStore.shared.saveFile(document, to: url)
                    
                    // Now open it
                    await unifiedProvider.loadAllLists()
                    
                    if let newList = unifiedProvider.allLists.first(where: {
                        if case .external(let listURL) = $0.source {
                            return listURL == url
                        }
                        return false
                    }) {
                        selectedListID = newList.id
                    }
                    
                    conflictingFileURL = nil
                    conflictingDocument = nil
                }
            }
            Button("Cancel", role: .cancel) {
                conflictingFileURL = nil
                conflictingDocument = nil
            }
        } message: {
            Text("This file's ID matches an existing local list. Generate a new ID to open it, or cancel.")
        }
        .task {
            await unifiedProvider.loadAllLists()
            await welcomeViewModel.loadLists()
            await welcomeViewModel.loadUnifiedCounts(for: unifiedProvider.allLists, provider: unifiedProvider)
            
        }
        .focusedSceneValue(\.newListSheet, $isPresentingNewList)
        .focusedSceneValue(\.fileImporter, $showFileImporter)
        .focusedSceneValue(\.newConnectedExporter, $showNewConnectedExporter)
        .onChange(of: selectedListID) { oldValue, newValue in
            guard let listID = newValue else { return }
            
            // Find the selected list
            if let list = unifiedProvider.allLists.first(where: { $0.id == listID }) {
                Task {
                    // NEW: Sync before displaying
                    try? await unifiedProvider.syncIfNeeded(for: list)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                await unifiedProvider.syncAllExternalLists()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenExternalFile"))) { notification in
            guard let url = notification.object as? URL else { return }
            
            Task {
                do {
                    if let listId = try await unifiedProvider.openExternalFile(at: url) {
                        selectedListID = listId
                    }
                } catch {
                    print("Failed to open file from URL: \(error)")
                }
            }
        }
    }
    
    @MainActor
    private func exportList(_ list: ShoppingListSummary) async {
        // Find the unified list
        guard let unifiedList = unifiedProvider.allLists.first(where: { $0.summary.id == list.id }) else {
            return
        }
        
        // Fetch all data
        let items = try? await unifiedProvider.fetchItems(for: unifiedList)
        let labels = try? await unifiedProvider.fetchLabels(for: unifiedList)
        
        // Use original ID if available (for external lists)
        var exportList = list
        if let originalId = unifiedList.originalFileId {
            exportList.id = originalId
        }
        
        // Prepare the document
        let document = ListDocument(
            list: exportList,
            items: items ?? [],
            labels: labels ?? []
        )
        
        // Set the document and show exporter
        exportingDocument = ListDocumentFile(document: document)
        
        pendingExportType = .exportExisting
        
        showFileExporter = true
    }
}

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
    
    var body: some View {
        let favourites = unifiedProvider.allLists.filter { list in
            favouriteListIDs.contains(list.summary.id)
        }
        
        let nonFavourites = unifiedProvider.allLists.filter { list in
            !favouriteListIDs.contains(list.summary.id)
        }
        
        List(selection: $selectedListID) {
            
            // MARK: - Welcome Section (at the top)
            if !hideWelcomeList {
                let welcomeList = unifiedProvider.allLists.first(where: { $0.id == "example-welcome-list" })
                if let welcome = welcomeList {
                    Section(header: Text("Getting Started")) {
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
            
            // MARK: - Internal / Private Lists
            let internalLists = unifiedProvider.allLists.filter { !favouriteListIDs.contains($0.summary.id) && !($0.isExternal) && !$0.isReadOnly }
            if !internalLists.isEmpty {
                Section(header: Text("Private")) {
                    ForEach(internalLists.sorted(by: { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }), id: \.id) { list in
                        listRow(for: list)
                    }
                }
            }
            
            // MARK: - External / Linked Lists
            let externalLists = unifiedProvider.allLists.filter { !favouriteListIDs.contains($0.summary.id) && $0.isExternal && !$0.isReadOnly }
            if !externalLists.isEmpty {
                Section(header: Text("Connected")) {
                    ForEach(externalLists.sorted(by: { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }), id: \.id) { list in
                        listRow(for: list)
                    }
                }
            }
            
            // MARK: - Temporary Read-Only Lists
            let readOnlyLists = unifiedProvider.allLists.filter { !favouriteListIDs.contains($0.summary.id) && $0.isReadOnly && $0.id != "example-welcome-list" }
            if !readOnlyLists.isEmpty {
                Section(header: Text("Temporary (Read Only)")) {
                    ForEach(readOnlyLists.sorted(by: { $0.summary.name.localizedCaseInsensitiveCompare($1.summary.name) == .orderedAscending }), id: \.id) { list in
                        listRow(for: list)
                    }
                }
            }
        }
        .navigationTitle("All Lists")
        .navigationBarTitleDisplayMode(.large)
        .animation(.none, value: welcomeViewModel.uncheckedCounts) // Disable animation for count changes
        .animation(.none, value: unifiedProvider.allLists) // Disable animation for list changes
        
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
                        print("âŒ Failed to delete list: \(error)")
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
    }
    
    @ViewBuilder
    private func listRow(for list: UnifiedList) -> some View {
        let isFavourited = favouriteListIDs.contains(list.summary.id)
        let saveStatus = unifiedProvider.saveStatus[list.id] ?? .saved
        
        HStack {
            // Icon
            Image(systemName: list.summary.icon ?? list.summary.extras?["listsForMealieListIcon"] ?? "list.bullet")
                .frame(minWidth: 30)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(list.summary.name)
                
            }
            
            Spacer()
            
            // Save status indicator (like writie.md)
            
            // Only show external icon if this list is a favourite
            if isFavourited && list.isExternal {
                Image(systemName: "link")
                    .foregroundColor(.secondary)
                    .imageScale(.small)
            }
            if list.isExternal {
                saveStatusView(for: saveStatus)
            } else {
                Image(systemName: "icloud.slash.fill")
                    .foregroundColor(.secondary)
                    .imageScale(.small)
            }
            
            // Unchecked count
            if let count = welcomeViewModel.uncheckedCounts[list.summary.id], count >= 0 {
                Text("\(count)")
                    .foregroundColor(.secondary)
            } else {
                Text("0")
                    .foregroundColor(.secondary)
            }
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
            //Image(systemName: "checkmark.icloud.fill")
            //.foregroundColor(.green)
            //.imageScale(.small)
            EmptyView()
        case .saving:
            ProgressView()
                .scaleEffect(0.6)
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
}
