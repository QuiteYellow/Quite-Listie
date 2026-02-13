//
//  WelcomeView.swift (FULLY UNIFIED VERSION)
//  Listie.md
//
//  All lists (local and external) shown together with unified UI
//

import SwiftUI

struct WelcomeView: View {
    @StateObject private var welcomeViewModel = WelcomeViewModel()
    @StateObject private var unifiedProvider = UnifiedListProvider()
    @StateObject private var deeplinkCoordinator = DeeplinkCoordinator()
    
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
    
    @State private var detailSearchText = ""
    
    @AppStorage("hideWelcomeList") private var hideWelcomeList = false
    @AppStorage("hideQuickAdd") private var hideQuickAdd = false
    @AppStorage("hideEmptyLabels") private var hideEmptyLabels = true
    
    
    private var searchPrompt: String {selectedListID != nil ? "Search items" : "Select a list to search"}
    
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
                await refreshLists()
            }
            .toolbar {
                ToolbarItem(id: "menu", placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            isPresentingNewList = true
                        } label: {
                            Label("New Private List...", systemImage: "doc.badge.plus")
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
                            Label("Open File...", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                
                ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
                
                ToolbarItem(id: "setings", placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings...", systemImage: "gear")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        } detail: {
            detailPane
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                hideWelcomeList: $hideWelcomeList,
                hideQuickAdd: $hideQuickAdd,
                hideEmptyLabels: $hideEmptyLabels
            )
        }
        .sheet(item: $editingUnifiedList, onDismiss: {
            NotificationCenter.default.post(name: .listSettingsChanged, object: nil)
        }) { unifiedList in
            makeListSettingsSheet(unifiedList)
        }
        .sheet(isPresented: $isPresentingNewList) {
            NewShoppingListView {
                Task {
                    await refreshLists()
                }
            }
        }
        .sheet(item: $deeplinkCoordinator.markdownImport) { request in
            makeMarkdownImportSheet(request)
        }
        .sheet(item: $deeplinkCoordinator.pendingImport) { pending in
            ImportListPickerSheet(
                pending: pending,
                lists: unifiedProvider.allLists,
                onSelect: { listId in
                    deeplinkCoordinator.completePendingImport(with: listId)
                }
            )
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.listie, .json],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
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
            contentType: .listie,
            defaultFilename: exportingDocument?.document.list.name ?? "new-list"
        ) { result in
            handleFileExport(result)
        }
        .alert("ID Conflict", isPresented: $showIDConflictAlert) {
            Button("Generate New ID") {
                handleIDConflict()
            }
            Button("Cancel", role: .cancel) {
                cancelIDConflict()
            }
        } message: {
            Text("This file's ID matches an existing local list. Generate a new ID to open it, or cancel.")
        }
        .alert("Import Failed", isPresented: $deeplinkCoordinator.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deeplinkCoordinator.errorMessage ?? "Unknown error")
        }
        .task {
            // Run migrations first (one-time migration from old local storage to iCloud)
            do {
                try await MigrationManager.shared.runMigrationsIfNeeded()
            } catch {
                print("❌ Migration failed: \(error)")
            }

            await unifiedProvider.loadAllLists()
            await welcomeViewModel.loadLists()
            await welcomeViewModel.loadUnifiedCounts(for: unifiedProvider.allLists, provider: unifiedProvider)

            // Reconcile reminders on cold launch (catches changes made on other devices while app was killed)
            await syncAndReconcileReminders()
        }
        .focusedSceneValue(\.newListSheet, $isPresentingNewList)
        .focusedSceneValue(\.fileImporter, $showFileImporter)
        .focusedSceneValue(\.newConnectedExporter, $showNewConnectedExporter)
        .focusedSceneValue(\.settingsSheet, $showSettings)
        .modifier(WelcomeNotificationObservers(
            selectedListID: $selectedListID,
            syncAndReconcile: syncAndReconcileReminders,
            refreshCounts: {
                await welcomeViewModel.loadUnifiedCounts(for: unifiedProvider.allLists, provider: unifiedProvider)
            },
            refreshAll: {
                await unifiedProvider.loadAllLists()
                await welcomeViewModel.loadUnifiedCounts(for: unifiedProvider.allLists, provider: unifiedProvider)
            }
        ))
        .overlay {
            if unifiedProvider.isDownloadingFile {
                ZStack {
                    Color.black.opacity(0)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 80, height: 80)
                            
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 36))
                                .symbolEffect(.pulse)
                        }
                        
                        VStack(spacing: 8) {
                            Text("Downloading from iCloud")
                                .font(.headline)
                            
                            Text("This may take a moment...")
                                .font(.subheadline)
                        }
                        
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.2)
                    }
                    .padding(40)
                    .background {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            }
                    }
                    .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: unifiedProvider.isDownloadingFile)
            }
        }
        .onChange(of: selectedListID) { _, _ in
            detailSearchText = ""
        }
        .onOpenURL { url in
            Task {
                await deeplinkCoordinator.handle(url, provider: unifiedProvider)
            }
        }
        .onChange(of: deeplinkCoordinator.fileToOpen) { _, url in
            handleFileToOpen(url)
        }
        .onChange(of: deeplinkCoordinator.markdownImport) { _, request in
            handleMarkdownImportRequest(request)
        }
    }
    
    // MARK: - Detail Pane (Extracted to Fix Type-Checker)

    @ViewBuilder
    private var detailPane: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            if selectedListID == "__reminders_today" {
                ReminderListView(
                    filter: .today,
                    welcomeViewModel: welcomeViewModel,
                    unifiedProvider: unifiedProvider,
                    selectedListID: $selectedListID,
                    searchText: $detailSearchText
                )
            } else if selectedListID == "__reminders_scheduled" {
                ReminderListView(
                    filter: .scheduled,
                    welcomeViewModel: welcomeViewModel,
                    unifiedProvider: unifiedProvider,
                    selectedListID: $selectedListID,
                    searchText: $detailSearchText
                )
            } else if let listID = selectedListID,
               let unifiedList = unifiedProvider.allLists.first(where: { $0.id == listID }) {
                ShoppingListView(
                    list: unifiedList.summary,
                    unifiedList: unifiedList,
                    unifiedProvider: unifiedProvider,
                    welcomeViewModel: welcomeViewModel,
                    searchText: $detailSearchText,
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
        .searchable(
            text: $detailSearchText,
            prompt: searchPrompt
        )
        .searchToolbarBehavior(.minimize)
        .toolbar {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
        }
    }

    // MARK: - Sheet Builders (Extracted to Fix Type-Checker)
    
    @ViewBuilder
    private func makeListSettingsSheet(_ unifiedList: UnifiedList) -> some View {
        ListSettingsView(
            list: unifiedList.summary,
            unifiedList: unifiedList,
            unifiedProvider: unifiedProvider
        ) { updatedName, icon, hiddenLabels in  // Updated signature
            Task {
                let _ = try? await unifiedProvider.fetchItems(for: unifiedList)
                try? await unifiedProvider.updateList(
                    unifiedList,
                    name: updatedName,
                    icon: icon,
                    hiddenLabels: hiddenLabels
                )
                await unifiedProvider.loadAllLists()
            }
        }
    }
    
    @ViewBuilder
    private func makeMarkdownImportSheet(_ request: DeeplinkCoordinator.MarkdownImportRequest) -> some View {
        Group {
            if let listID = selectedListID,
               let unifiedList = unifiedProvider.allLists.first(where: { $0.id == listID }) {
                MarkdownListImportView(
                    list: unifiedList,
                    provider: unifiedProvider,
                    existingItems: [],
                    existingLabels: [],
                    initialMarkdown: request.markdown,
                    autoPreview: request.shouldPreview
                )
            }
        }
    }
    
    // MARK: - Actions
    
    private func refreshLists() async {
        await unifiedProvider.loadAllLists()
        await welcomeViewModel.loadLists()
        await welcomeViewModel.loadUnifiedCounts(for: unifiedProvider.allLists, provider: unifiedProvider)
    }

    private func syncAndReconcileReminders() async {
        print("🔄 [Sync] Starting foreground reminder sync")
        await unifiedProvider.syncAllExternalLists()

        // Fetch pending notifications once (not per-list)
        let pendingRequests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let pendingIds = Set(pendingRequests.map(\.identifier))

        // Collect all items and cancel stale notifications per-list
        var allReminderItems: [(item: ShoppingItem, listName: String, listId: String)] = []

        for list in unifiedProvider.allLists where !list.isReadOnly {
            do {
                let items = try await unifiedProvider.fetchItems(for: list)

                // Cancel notifications for checked/deleted items in this list
                ReminderManager.reconcileCancellations(items: items, listId: list.id, pendingIds: pendingIds)

                // Collect active items with reminders for the budget pass
                for item in items where !item.checked && !item.isDeleted && item.reminderDate != nil {
                    allReminderItems.append((item: item, listName: list.summary.name, listId: list.id))
                }
            } catch {
                print("❌ [Sync] Failed to fetch items for \(list.summary.name): \(error)")
            }
        }

        // Budget-aware pass: schedule the top 60 soonest reminders
        await ReminderManager.reconcileWithBudget(allItems: allReminderItems, trigger: "foreground")

        // Schedule next background refresh
        BackgroundRefreshManager.scheduleNextRefresh()
        print("🔄 [Sync] Foreground reminder sync complete")
    }
    
    @MainActor
    private func exportList(_ list: ShoppingListSummary) async {
        guard let unifiedList = unifiedProvider.allLists.first(where: { $0.summary.id == list.id }) else {
            return
        }
        
        do {
            let document = try await unifiedProvider.prepareExport(for: unifiedList)
            exportingDocument = ListDocumentFile(document: document)
            pendingExportType = .exportExisting
            showFileExporter = true
        } catch {
            print("Failed to prepare export: \(error)")
        }
    }
    
    // MARK: - File Handlers
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
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
    
    private func handleFileExport(_ result: Result<URL, Error>) {
        let exportType = pendingExportType
        
        switch result {
        case .success(let url):
            print("Exported to: \(url)")
            
            if exportType == .newConnectedList {
                Task {
                    await createNewConnectedList(at: url)
                }
            }
            
        case .failure(let error):
            print("Export error: \(error)")
        }
        
        exportingDocument = nil
        showFileExporter = false
        showNewConnectedExporter = false
        pendingExportType = nil
    }
    
    private func createNewConnectedList(at url: URL) async {
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
    
    // MARK: - Alert Handlers
    
    private func handleIDConflict() {
        Task {
            guard let url = conflictingFileURL, var document = conflictingDocument else { return }
            
            document.list.id = UUID().uuidString
            
            try? await ExternalFileStore.shared.saveFile(document, to: url)
            
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
    
    private func cancelIDConflict() {
        conflictingFileURL = nil
        conflictingDocument = nil
    }
    
    // MARK: - Deeplink Handlers
    
    private func handleFileToOpen(_ url: URL?) {
        guard let url = url else { return }
        
        Task {
            do {
                if let listId = try await unifiedProvider.openExternalFile(at: url) {
                    selectedListID = listId
                }
            } catch {
                print("Failed to open file from deeplink: \(error)")
            }
        }
    }
    
    private func handleMarkdownImportRequest(_ request: DeeplinkCoordinator.MarkdownImportRequest?) {
        guard let request = request else { return }

        // Find list by runtime ID or original file ID and select it
        let targetList = unifiedProvider.allLists.first { list in
            list.id == request.listId || list.originalFileId == request.listId
        }

        if let targetList = targetList {
            selectedListID = targetList.id
        }
    }
}

// MARK: - Notification Observers (Extracted to Fix Type-Checker)

private struct WelcomeNotificationObservers: ViewModifier {
    @Binding var selectedListID: String?
    let syncAndReconcile: () async -> Void
    let refreshCounts: () async -> Void
    let refreshAll: () async -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await syncAndReconcile() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                BackgroundRefreshManager.scheduleNextRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reminderTapped)) { notification in
                if let listId = notification.userInfo?["listId"] as? String {
                    selectedListID = listId
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reminderCompleted)) { _ in
                Task { await refreshCounts() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .storageLocationChanged)) { _ in
                Task { await refreshAll() }
            }
    }
}
