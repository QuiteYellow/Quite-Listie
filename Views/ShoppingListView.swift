//
//  ShoppingListView.swift (UNIFIED VERSION)
//  ListsForMealie
//
//  Updated to work seamlessly with both local and external lists
//

import SwiftUI

// MARK: - Section Header View
struct SectionHeaderView: View {
    let labelName: String
    let color: Color?
    let isExpanded: Bool
    let uncheckedCount: Int
    let checkedCount: Int
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack {
                Image(systemName: "tag.fill")
                    .foregroundColor((color ?? .secondary).adjusted(forBackground: Color(.systemBackground)))
                
                Text(labelName.removingLabelNumberPrefix())
                    .foregroundColor(.primary)
                
                Spacer()
                HStack {
                    Text(labelName == "Completed" ? "\(checkedCount)" : "\(uncheckedCount)")
                        .foregroundColor(.primary)
                    
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(.easeInOut, value: isExpanded)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 0)
            }
            .background(Color(.systemGroupedBackground))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Item Row View
struct ItemRowView: View {
    let item: ShoppingItem
    let isLast: Bool
    let onTap: () -> Void
    let onTextTap: () -> Void
    let onIncrement: (() -> Void)?
    let onDecrement: (() -> Void)?
    let isReadOnly: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            if item.quantity ?? 0 > 1 {
                Text((item.quantity ?? 0).formatted(.number.precision(.fractionLength(0))))
                    .font(.subheadline)
                    .strikethrough(item.checked && (item.quantity ?? 0) >= 2,
                                   color: (item.checked ? .gray : .primary))
                    .foregroundColor(
                        (item.quantity ?? 0) < 2 ? Color.clear :
                            (item.checked ? .gray : .primary)
                    )
                    .frame(minWidth: 12, alignment: .leading)
            }
            
            // tap gesture for note text
            Text(item.note)
                .font(.subheadline)
                .strikethrough(item.checked, color: .gray)
                .foregroundColor(item.checked ? .gray : .primary)
                .onTapGesture {
                    onTextTap()
                }
            
            Spacer()
            
            // Checkbox tap area
            if !isReadOnly {
                Button(action: {
                    onTap()
                }) {
                    Image(systemName: item.checked ? "inset.filled.circle" : "circle")
                        .foregroundColor(item.checked ? .gray : .accentColor)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 0)
        .padding(.horizontal, 0)
        .background(.clear)
    }
}

struct MarkdownExport: Identifiable {
    let id = UUID()
    let listName: String
    let items: [ShoppingItem]
    let labels: [ShoppingLabel]
    let activeOnly: Bool
}

struct ShoppingListView: View {
    let list: ShoppingListSummary
    let unifiedList: UnifiedList
    let unifiedProvider: UnifiedListProvider
    @ObservedObject var welcomeViewModel: WelcomeViewModel
    var onExportJSON: (() -> Void)?
    
    @StateObject private var viewModel: ShoppingListViewModel
    @State private var showingAddView = false
    @State private var editingItem: ShoppingItem? = nil
    @State private var showingEditView = false
    @State private var itemToDelete: ShoppingItem? = nil
    
    @State private var showingMarkdownImport = false
    @State private var markdownToExport: MarkdownExport? = nil
    @State private var exportMarkdownText = ""
    
    // Export triggers for menu commands
    @State private var triggerMarkdownExport = false
    @State private var triggerJSONExport = false
    
    @State private var showContent = false
    
    // Store per-list preference in UserDefaults
    @AppStorage("showCompletedAtBottom") private var showCompletedAtBottomData: Data = Data()

    // Computed property to get/set for this specific list
    private var showCompletedAtBottom: Bool {
        get {
            let dict = (try? JSONDecoder().decode([String: Bool].self, from: showCompletedAtBottomData)) ?? [:]
            return dict[unifiedList.id] ?? false
        }
        nonmutating set {
            var dict = (try? JSONDecoder().decode([String: Bool].self, from: showCompletedAtBottomData)) ?? [:]
            dict[unifiedList.id] = newValue
            if let data = try? JSONEncoder().encode(dict) {
                showCompletedAtBottomData = data
            }
        }
    }
    
    @AppStorage("expandedSections") private var expandedSectionsData: Data = Data()

    // Computed property to get/set for this specific list
    private var expandedSections: [String: Bool] {
        get {
            let allData = (try? JSONDecoder().decode([String: [String: Bool]].self, from: expandedSectionsData)) ?? [:]
            return allData[unifiedList.id] ?? [:]
        }
        nonmutating set {
            var allData = (try? JSONDecoder().decode([String: [String: Bool]].self, from: expandedSectionsData)) ?? [:]
            allData[unifiedList.id] = newValue
            if let data = try? JSONEncoder().encode(allData) {
                expandedSectionsData = data
            }
        }
    }
    
    @State private var showingRecycleBin = false
    
    init(list: ShoppingListSummary, unifiedList: UnifiedList, unifiedProvider: UnifiedListProvider, welcomeViewModel: WelcomeViewModel, onExportJSON exportJSON: (() -> Void)? = nil) {
        self.list = list
        self.unifiedList = unifiedList
        self.unifiedProvider = unifiedProvider
        self.welcomeViewModel = welcomeViewModel
        self.onExportJSON = exportJSON
        self._viewModel = StateObject(wrappedValue: ShoppingListViewModel(list: unifiedList, provider: unifiedProvider))
    }
    
    private var saveStatus: UnifiedListProvider.SaveStatus {
        unifiedProvider.saveStatus[unifiedList.id] ?? .saved
    }
    
    private func updateUncheckedCount(for listID: String, with count: Int) async {
        await MainActor.run {
            welcomeViewModel.uncheckedCounts[listID] = count
        }
    }
    
    private func toggleSection(_ labelName: String) {
        withAnimation(.easeInOut) {
            var sections = expandedSections
            sections[labelName] = !(sections[labelName] ?? true)
            expandedSections = sections
        }
    }

    private func initializeExpandedSections(for labels: [String]) {
        var sections = expandedSections
        for label in labels {
            if sections[label] == nil {
                sections[label] = true
            }
        }
        expandedSections = sections
    }
    
    @ViewBuilder
    private func renderSection(labelName: String, items: [ShoppingItem], color: Color?) -> some View {
        let isExpanded = expandedSections[labelName] ?? true
        let uncheckedItems = items.filter { !$0.checked }
        let checkedItems = items.filter { $0.checked }
        
        let itemsToShow = showCompletedAtBottom && labelName != "Completed"
        ? uncheckedItems
        : uncheckedItems + checkedItems
        
        Section {
            if isExpanded {
                ForEach(itemsToShow) { item in
                    ItemRowView(
                        item: item,
                        isLast: false,
                        onTap: {
                            Task {
                                await viewModel.toggleChecked(for: item, didUpdate: { count in
                                    await updateUncheckedCount(for: list.id, with: count)
                                })
                            }
                        },
                        onTextTap: {
                            editingItem = item
                            showingEditView = true
                        },
                        onIncrement: {
                            Task {
                                let newQty = (item.quantity ?? 1) + 1
                                _ = await viewModel.updateItem(item, note: item.note, label: viewModel.labelForItem(item), quantity: newQty)
                            }
                        },
                        onDecrement: {
                            if (item.quantity ?? 1) <= 1 {
                                itemToDelete = item
                            } else {
                                Task {
                                    let newQty = max((item.quantity ?? 1) - 1, 1)
                                    _ = await viewModel.updateItem(item, note: item.note, label: viewModel.labelForItem(item), quantity: newQty)
                                }
                            }
                        },
                        isReadOnly: unifiedList.isReadOnly
                    )
                    .swipeActions(edge: .trailing) {
                        if !unifiedList.isReadOnly {
                            Button(role: .none) {
                                if (item.quantity ?? 1) < 2 {
                                    itemToDelete = item
                                } else {
                                    Task {
                                        let newQty = max((item.quantity ?? 1) - 1, 1)
                                        _ = await viewModel.updateItem(item, note: item.note, label: viewModel.labelForItem(item), quantity: newQty)
                                        
                                    }
                                }
                            } label: {
                                Label((item.quantity ?? 1) < 2 ? "Delete" : "Decrease", systemImage: (item.quantity ?? 1) < 2 ? "trash" : "minus")
                            }
                            .tint((item.quantity ?? 1) < 2 ? .red : .orange)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if !unifiedList.isReadOnly {
                            Button {
                                Task {
                                    let newQty = (item.quantity ?? 1) + 1
                                    _ = await viewModel.updateItem(item, note: item.note, label: viewModel.labelForItem(item), quantity: newQty)
                                }
                            } label: {
                                Label("Increase", systemImage: "plus")
                            }
                            .tint(.green)
                        }
                    }
                    .contextMenu {
                        Button("Edit Item...") {
                            editingItem = item
                            showingEditView = true
                        }
                        Button(role: .none) {
                            itemToDelete = item
                        } label: {
                            Label("Delete Item...", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        } header: {
            SectionHeaderView(
                labelName: labelName,
                color: color,
                isExpanded: isExpanded,
                uncheckedCount: uncheckedItems.count,
                checkedCount: checkedItems.count,
                onToggle: { toggleSection(labelName) }
            )
        }
    }
    
    var body: some View {
        List {
            if showCompletedAtBottom {
                // Filter keys to show only sections with unchecked items
                let keysToShow = viewModel.sortedLabelKeys.filter { labelName in
                    if labelName == "Completed" {
                        return false
                    }
                    let items = viewModel.itemsGroupedByLabel[labelName] ?? []
                    return items.contains(where: { !$0.checked })
                }
                
                ForEach(keysToShow, id: \.self) { labelName in
                    let items = viewModel.itemsGroupedByLabel[labelName] ?? []
                    let color = viewModel.colorForLabel(name: labelName)
                    renderSection(labelName: labelName, items: items, color: color)
                }
                
                let completedItems = viewModel.items.filter { $0.checked }
                if !completedItems.isEmpty {
                    renderSection(labelName: "Completed", items: completedItems, color: .primary)
                }
                
            } else {
                let keysToShow = viewModel.sortedLabelKeys.filter { $0 != "Completed" }
                
                ForEach(keysToShow, id: \.self) { labelName in
                    let items = viewModel.itemsGroupedByLabel[labelName] ?? []
                    if !items.isEmpty {
                        let color = viewModel.colorForLabel(name: labelName)
                        renderSection(labelName: labelName, items: items, color: color)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Save status indicator (like writie.md)
                saveStatusView
                
                // Add item button
                Button {
                    showingAddView = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(unifiedList.isReadOnly)
                
                // Menu with list actions
                Menu {
                    Button {
                            showingMarkdownImport = true
                        } label: {
                            Label("Import from Markdown", systemImage: "square.and.arrow.down")
                        }
                        .disabled(unifiedList.isReadOnly)
                        
                        
                    
                    Divider()
                    
                    Menu("Mark All Items As…") {
                        Button {
                            Task {
                                await viewModel.setAllItems(for: list.id, toCompleted: true) { count in
                                    await updateUncheckedCount(for: list.id, with: count)
                                }
                            }
                        } label: {
                            Label("Completed", systemImage: "checkmark.circle.fill")
                        }
                        .disabled(unifiedList.isReadOnly)

                        Button {
                            Task {
                                await viewModel.setAllItems(for: list.id, toCompleted: false) { count in
                                    await updateUncheckedCount(for: list.id, with: count)
                                }
                            }
                        } label: {
                            Label("Active", systemImage: "circle")
                        }
                        .disabled(unifiedList.isReadOnly)
                    }

                    Button {
                        withAnimation(.easeInOut) {
                            showCompletedAtBottom.toggle()
                        }
                    } label: {
                        Label(
                            showCompletedAtBottom ? "Show Completed Inline" : "Show Completed as Label",
                            systemImage: showCompletedAtBottom ? "circle.badge.xmark" : "circle.badge.checkmark.fill"
                        )
                    }
                    .disabled(unifiedList.isReadOnly)
                    
                    Divider()
                
                    Menu("Export As…") {
                        Button {
                            markdownToExport = MarkdownExport(
                                listName: list.name,
                                items: viewModel.items,
                                labels: viewModel.labels,
                                activeOnly: true  // Defaults to active, user can toggle in the view
                            )
                        } label: {
                            Label("Markdown", systemImage: "doc.text")
                        }
                        .disabled(unifiedList.isReadOnly)
                        
                        Divider()
                        
                        Button {
                            onExportJSON?()
                        } label: {
                            Label("JSON (Backup)", systemImage: "doc.badge.gearshape")
                        }
                        .disabled(unifiedList.isReadOnly)
                    }
                                        
                                        Divider()
                                        
                                        Button {
                                            showingRecycleBin = true
                                        } label: {
                                            Label("Recycle Bin", systemImage: "trash")
                                        }
                                        .disabled(unifiedList.isReadOnly)
                                        
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                }
                            }
        .refreshable {
            // NEW: Sync external files before refreshing
            try? await unifiedProvider.syncIfNeeded(for: unifiedList)
            
            await viewModel.loadLabels()
            await viewModel.loadItems()
            initializeExpandedSections(for: viewModel.sortedLabelKeys)
        }
        .task {
            showContent = false  // Reset on appear
            // Sync on open
            try? await unifiedProvider.syncIfNeeded(for: unifiedList)

            // NEW: Cleanup old deleted items
            await unifiedProvider.cleanupOldDeletedItems(for: unifiedList)
            
            await viewModel.loadLabels()
            await viewModel.loadItems()
            initializeExpandedSections(for: viewModel.sortedLabelKeys)
            
            // Fade in after loading
                    withAnimation {
                        showContent = true
                    }
        }
        
        .fullScreenCover(isPresented: $showingAddView) {
            AddItemView(list: list, viewModel: viewModel)
        }
        .fullScreenCover(item: $editingItem) { item in
            EditItemView(viewModel: viewModel, item: item, list: list, unifiedList: unifiedList) 
        }
        .sheet(isPresented: $showingRecycleBin) {
            RecycleBinView(list: unifiedList, provider: unifiedProvider) {
                Task {
                    await viewModel.loadItems()
                }
            }
            
            
        }
        .sheet(isPresented: $showingMarkdownImport) {
            Task {
                // Reload items and labels after import
                await viewModel.loadItems()
                await viewModel.loadLabels()
            }
        } content: {
            MarkdownListImportView(
                list: unifiedList,
                provider: unifiedProvider,
                existingItems: viewModel.items,
                existingLabels: viewModel.labels
            )
        }
        .sheet(item: $markdownToExport) { export in
            MarkdownExportView(
                listName: export.listName,
                items: export.items,
                labels: export.labels,
                activeOnly: export.activeOnly
            )
        }
        .alert("Delete Item?", isPresented: Binding(
            get: { itemToDelete != nil },
            set: { if !$0 { itemToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let item = itemToDelete {
                    Task {
                        await viewModel.deleteItem(item)
                        await MainActor.run { itemToDelete = nil }
                    }
                }
            }
            Button("Cancel", role: .cancel) { itemToDelete = nil }
        } message: {
            Text("Item will be moved to the Recycle Bin and automatically deleted after 30 days.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .listSettingsChanged)) { _ in
            Task {
                await viewModel.loadLabels()
                await viewModel.loadItems()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .externalListChanged)) { notification in
            // Reload if this list changed
            if let changedListId = notification.object as? String,
               changedListId == unifiedList.id {
                Task {
                    await viewModel.loadLabels()
                    await viewModel.loadItems()
                }
            }
        }
        .focusedSceneValue(\.exportMarkdown, $triggerMarkdownExport)
        .focusedSceneValue(\.exportJSON, $triggerJSONExport)
        .focusedSceneValue(\.isReadOnly, unifiedList.isReadOnly) 
        .onChange(of: triggerMarkdownExport) { oldValue, newValue in
            if newValue {
                // Trigger markdown export
                markdownToExport = MarkdownExport(
                    listName: list.name,
                    items: viewModel.items,
                    labels: viewModel.labels,
                    activeOnly: true
                )
                triggerMarkdownExport = false
            }
        }
        .onChange(of: triggerJSONExport) { oldValue, newValue in
            if newValue {
                // Trigger JSON export
                onExportJSON?()
                triggerJSONExport = false
            }
        }
    }
    
    @ViewBuilder
    private var saveStatusView: some View {
        Group {
            switch saveStatus {
            case .saved:
                EmptyView()
            case .saving:
                ProgressView()
                    .scaleEffect(0.7)
            case .unsaved:
                Image(systemName: "circle.fill")
                    .foregroundColor(.orange)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .help(message)
            }
        }
        .padding(.horizontal, 4)
    }
}
