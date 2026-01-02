//
//  ShoppingListView.swift (UNIFIED VERSION)
//  Listie.md
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
            if item.quantity > 1 {
                Text(item.quantity.formatted(.number.precision(.fractionLength(0))))
                    .font(.subheadline)
                    .strikethrough(item.checked && item.quantity >= 2,
                                   color: (item.checked ? .gray : .primary))
                    .foregroundColor(
                        item.quantity < 2 ? Color.clear :
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
    let listId: String?
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
    @State private var isPerformingBulkAction = false
    @State private var showingRecycleBin = false
    
    @Binding var searchText: String
    
    init(list: ShoppingListSummary, unifiedList: UnifiedList, unifiedProvider: UnifiedListProvider, welcomeViewModel: WelcomeViewModel, searchText: Binding<String>, onExportJSON exportJSON: (() -> Void)? = nil) {
        self.list = list
        self.unifiedList = unifiedList
        self.unifiedProvider = unifiedProvider
        self.welcomeViewModel = welcomeViewModel
        self._searchText = searchText  // Binding
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

    
    @ViewBuilder
    private func renderSection(labelName: String, items: [ShoppingItem], color: Color?) -> some View {
        let isExpanded = viewModel.expandedSections[labelName] ?? true
        let uncheckedItems = items.filter { !$0.checked }
        let checkedItems = items.filter { $0.checked }
        
        let itemsToShow =  viewModel.showCompletedAtBottom && labelName != "Completed"
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
                                await viewModel.incrementQuantity(for: item)  // ← Centralized!
                            }
                        },
                        onDecrement: {
                            Task {
                                let shouldKeep = await viewModel.decrementQuantity(for: item)  // ← Centralized!
                                if !shouldKeep {
                                    itemToDelete = item
                                }
                            }
                        },
                        isReadOnly: unifiedList.isReadOnly
                    )
                    .swipeActions(edge: .trailing) {
                        if !unifiedList.isReadOnly {
                            Button(role: .none) {
                                Task {
                                    let shouldKeep = await viewModel.decrementQuantity(for: item)  // ← Centralized!
                                    if !shouldKeep {
                                        itemToDelete = item
                                    }
                                }
                            } label: {
                                Label(item.quantity < 2 ? "Delete" : "Decrease",
                                      systemImage: item.quantity < 2 ? "trash" : "minus")
                            }
                            .tint(item.quantity < 2 ? .red : .orange)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if !unifiedList.isReadOnly {
                            Button {
                                Task {
                                    await viewModel.incrementQuantity(for: item)  // ← Centralized!
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
                onToggle: { viewModel.toggleSection(labelName) }
            )
        }
    }
    
    var body: some View {
        List {
            if  viewModel.showCompletedAtBottom {
                // Use viewModel properties instead:
                let keysToShow = viewModel.filteredSortedLabelKeys.filter { labelName in
                    if labelName == "Completed" {
                        return false
                    }
                    let items = viewModel.filteredItemsGroupedByLabel[labelName] ?? []
                    return items.contains(where: { !$0.checked })
                }
                
                ForEach(keysToShow, id: \.self) { labelName in
                    let items = viewModel.filteredItemsGroupedByLabel[labelName] ?? []
                    let color = viewModel.colorForLabel(name: labelName)
                    renderSection(labelName: labelName, items: items, color: color)
                }
                
                let completedItems = viewModel.filteredItems.filter { $0.checked }
                if !completedItems.isEmpty {
                    renderSection(labelName: "Completed", items: completedItems, color: .primary)
                }
                
            } else {
                let keysToShow = viewModel.filteredSortedLabelKeys.filter { $0 != "Completed" }
                
                ForEach(keysToShow, id: \.self) { labelName in
                    let items = viewModel.filteredItemsGroupedByLabel[labelName] ?? []
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
        .toolbar(id: "LIST_ACTIONS") {
            
            // Save status indicator - always present, just hidden
            ToolbarItem(id: "save-status", placement: .navigationBarTrailing) {
                Group {
                    switch saveStatus {
                    case .saved:
                        EmptyView()
                    case .saving:
                        EmptyView()
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
            
            // Add button - always present, just hidden/disabled
            ToolbarItem(id: "add", placement: .navigationBarTrailing) {
                Button {
                    showingAddView = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(unifiedList.isReadOnly)
            }
            
            ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
            
            // Menu - always present, just hidden/disabled
            ToolbarItem(id: "menu", placement: .navigationBarTrailing) {
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
                                isPerformingBulkAction = true
                                
                                await viewModel.setAllItems(for: list.id, toCompleted: true) { count in
                                    await updateUncheckedCount(for: list.id, with: count)
                                }
                                
                                await MainActor.run {
                                    isPerformingBulkAction = false
                                }
                            }
                        } label: {
                            Label("Completed", systemImage: "checkmark.circle.fill")
                        }
                        .disabled(unifiedList.isReadOnly)
                        
                        Button {
                            Task {
                                isPerformingBulkAction = true
                                
                                await viewModel.setAllItems(for: list.id, toCompleted: false) { count in
                                    await updateUncheckedCount(for: list.id, with: count)
                                }
                                
                                await MainActor.run {
                                    isPerformingBulkAction = false
                                }
                            }
                        } label: {
                            Label("Active", systemImage: "circle")
                        }
                        .disabled(unifiedList.isReadOnly)
                    }
                    
                    Button {
                        withAnimation(.easeInOut) {
                            viewModel.setShowCompletedAtBottom(!viewModel.showCompletedAtBottom)
                        }
                    } label: {
                        Label(
                            viewModel.showCompletedAtBottom ? "Show Completed Inline" : "Show Completed as Label",
                            systemImage:  viewModel.showCompletedAtBottom ? "circle.badge.xmark" : "circle.badge.checkmark.fill"
                        )
                    }
                    .disabled(unifiedList.isReadOnly)
                    
                    Divider()
                    
                    Menu("Export As…") {
                        Button {
                            markdownToExport = MarkdownExport(
                                listName: list.name,
                                listId: unifiedList.originalFileId ?? unifiedList.id,
                                items: viewModel.items,
                                labels: viewModel.labels,
                                activeOnly: true
                            )
                        } label: {
                            Label("Markdown", systemImage: "doc.text")
                        }
                        .disabled(unifiedList.isReadOnly)
                        
                        Divider()
                        
                        Button {
                            onExportJSON?()
                        } label: {
                            Label("Listie File...", systemImage: "doc.badge.gearshape")
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
                    Image(systemName: "ellipsis")
                }
                //.disabled(isPerformingBulkAction)
            }
            
        }
        .animation(nil, value: isPerformingBulkAction)
        
        .task {
            showContent = false
            try? await unifiedProvider.syncIfNeeded(for: unifiedList)
            await unifiedProvider.cleanupOldDeletedItems(for: unifiedList)
            
            await viewModel.loadLabels()
            await viewModel.loadItems()
            viewModel.initializeExpandedSections(for: viewModel.filteredSortedLabelKeys)  // ← Use viewModel
            
            showContent = true
        }
        .refreshable {
            try? await unifiedProvider.syncIfNeeded(for: unifiedList)
            
            await viewModel.loadLabels()
            await viewModel.loadItems()
            viewModel.initializeExpandedSections(for: viewModel.filteredSortedLabelKeys)  // ← Use viewModel
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
                listId: export.listId,
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
                        _ = await viewModel.deleteItem(item)
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
                    listId: unifiedList.originalFileId ?? unifiedList.id,
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
        .onChange(of: searchText) { _, newValue in
            viewModel.searchText = newValue  // ← Sync search text to ViewModel
        }
    }
    
    @ViewBuilder
    private var saveStatusView: some View {
        Group {
            switch saveStatus {
            case .saved:
                EmptyView()
            case .saving:
                //ProgressView()
                //    .scaleEffect(0.7) //As saves are so quick, only showing on error instead...
                
                EmptyView()
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
