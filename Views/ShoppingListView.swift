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
                    let displayCount = labelName == "Completed" ? checkedCount : uncheckedCount

                    Text("\(displayCount)")
                        .foregroundColor(.primary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.25), value: displayCount)
                    
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(.easeInOut, value: isExpanded)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 0)
            }
            .background(.clear)
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
    var showReminderChip: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            ChipAlignedRow {
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

                    Text(item.note)
                        .font(.subheadline)
                        .strikethrough(item.checked, color: .gray)
                        .foregroundColor(item.checked ? .gray : .primary)
                        .onTapGesture {
                            onTextTap()
                        }
                }
            } chips: {
                if showReminderChip, let reminderDate = item.reminderDate, !item.checked {
                    ReminderChipView(
                        reminderDate: reminderDate,
                        isRepeating: item.reminderRepeatRule != nil
                    )
                }
            }

            Spacer()

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

    // MARK: - Shared Context Menu

    @ViewBuilder
    static func itemContextMenu(
        item: ShoppingItem,
        isReadOnly: Bool,
        onEdit: @escaping () -> Void,
        onIncrement: @escaping () -> Void,
        onDecrement: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        Button { onEdit() } label: {
            Label("Edit Item...", systemImage: "pencil")
        }

        if !isReadOnly {
            Divider()

            Button { onIncrement() } label: {
                Label("Increase Quantity", systemImage: "plus")
            }

            if item.quantity < 2 { Divider() }

            Button {
                onDecrement()
            } label: {
                Label(
                    item.quantity < 2 ? "Delete Item..." : "Decrease Quantity",
                    systemImage: item.quantity < 2 ? "trash" : "minus"
                )
            }

            if item.quantity >= 2 {
                Divider()

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Item...", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Reminder Chip

struct ReminderChipView: View {
    let reminderDate: Date
    var isRepeating: Bool = false

    private var reminderStatus: ReminderStatus {
        let now = Date()
        let calendar = Calendar.current

        if reminderDate < now {
            return .overdue
        } else if calendar.isDateInToday(reminderDate) {
            return .today(reminderDate)
        } else if calendar.isDateInTomorrow(reminderDate) {
            return .tomorrow(reminderDate)
        } else {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: reminderDate)).day ?? 0
            return .upcoming(days)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: reminderStatus.icon)
                .font(.caption2)
            Text(reminderStatus.label)
                .font(.caption2)
                .lineLimit(1)
            if isRepeating {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(reminderStatus.color.opacity(0.15))
        .foregroundColor(reminderStatus.color)
        .clipShape(Capsule())
    }
}

private enum ReminderStatus {
    case overdue
    case today(Date)
    case tomorrow(Date)
    case upcoming(Int)

    var label: String {
        switch self {
        case .overdue:
            return "Overdue"
        case .today(let date):
            return "Today \(date.formatted(date: .omitted, time: .shortened))"
        case .tomorrow(let date):
            return "Tomorrow \(date.formatted(date: .omitted, time: .shortened))"
        case .upcoming(let days):
            return "In \(days) day\(days == 1 ? "" : "s")"
        }
    }

    var icon: String {
        switch self {
        case .overdue: return "bell.slash"
        case .today: return "bell.badge"
        case .tomorrow, .upcoming: return "bell"
        }
    }

    var color: Color {
        switch self {
        case .overdue: return .red
        case .today: return .orange
        case .tomorrow: return .blue
        case .upcoming: return .gray
        }
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
    @State private var shareLinkExport: MarkdownExport? = nil
    @State private var exportMarkdownText = ""
    
    // Export triggers for menu commands
    @State private var triggerMarkdownExport = false
    @State private var triggerJSONExport = false
    @State private var triggerShareLink = false
    
    @State private var showContent = false
    @State private var isPerformingBulkAction = false
    @State private var showingRecycleBin = false
    @State private var showingListSettings = false
    @State private var beatenToItMessage: String? = nil
    
    @AppStorage("hideQuickAdd") private var hideQuickAdd = false
    @AppStorage("hideEmptyLabels") private var hideEmptyLabels = true
    
    @State private var activeInlineAdd: String? = nil  // Track which section is active
    @State private var inlineAddText: String = ""
    @FocusState private var inlineAddFocused: Bool
    @State private var listWidth: CGFloat = 0
    @State private var kanbanRefreshState: KanbanRefreshState = .idle

    private enum KanbanRefreshState {
        case idle, refreshing, done
    }

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

    /// Labels the list body should display (extracted to avoid complex inline closures that slow the type checker).
    private var labelsForListBody: [String] {
        let hiddenLabelIDs = Set(list.hiddenLabels ?? [])

        if hideEmptyLabels {
            var keys = viewModel.filteredSortedLabelKeys
            if viewModel.showCompletedAtBottom {
                keys = keys.filter { labelName in
                    if labelName == "Completed" { return false }
                    let items = viewModel.filteredItemsGroupedByLabel[labelName] ?? []
                    return items.contains(where: { !$0.checked })
                }
            } else {
                keys = keys.filter { $0 != "Completed" }
            }
            return keys
        } else {
            var allLabels: [String] = viewModel.labels
                .filter { !hiddenLabelIDs.contains($0.id) }
                .map { $0.name }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            if let noLabelItems = viewModel.filteredItemsGroupedByLabel["No Label"],
               !noLabelItems.isEmpty {
                allLabels.append("No Label")
            }
            return allLabels
        }
    }
    
    private func updateUncheckedCount(for listID: String, with count: Int) async {
        await MainActor.run {
            welcomeViewModel.uncheckedCounts[listID] = count
        }
    }
    
    
    @ViewBuilder
    private func itemWithActions(_ item: ShoppingItem) -> some View {
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
                Task { await viewModel.incrementQuantity(for: item) }
            },
            onDecrement: {
                Task {
                    let shouldKeep = await viewModel.decrementQuantity(for: item)
                    if !shouldKeep { itemToDelete = item }
                }
            },
            isReadOnly: unifiedList.isReadOnly
        )
        .swipeActions(edge: .trailing) {
            if !unifiedList.isReadOnly {
                Button(role: .none) {
                    Task {
                        let shouldKeep = await viewModel.decrementQuantity(for: item)
                        if !shouldKeep { itemToDelete = item }
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
                    Task { await viewModel.incrementQuantity(for: item) }
                } label: {
                    Label("Increase", systemImage: "plus")
                }
                .tint(.green)
            }
        }
        .contextMenu {
            ItemRowView.itemContextMenu(
                item: item,
                isReadOnly: unifiedList.isReadOnly,
                onEdit: {
                    editingItem = item
                    showingEditView = true
                },
                onIncrement: {
                    Task { await viewModel.incrementQuantity(for: item) }
                },
                onDecrement: {
                    Task {
                        let shouldKeep = await viewModel.decrementQuantity(for: item)
                        if !shouldKeep { itemToDelete = item }
                    }
                },
                onDelete: {
                    itemToDelete = item
                }
            )
        }
    }

    @ViewBuilder
    private func renderSection(labelName: String, items: [ShoppingItem], color: Color?) -> some View {
        let isExpanded = viewModel.expandedSections[labelName] ?? true
        let uncheckedItems = items.filter { !$0.checked }
        let checkedItems = items.filter { $0.checked }
        Section {
            if isExpanded {
                let itemsToShow = labelName == "Completed" ? checkedItems : uncheckedItems

                ForEach(itemsToShow) { item in
                    itemWithActions(item)
                }

                if !hideQuickAdd && labelName != "Completed" && !unifiedList.isReadOnly {
                    inlineAddRow(for: labelName, color: color)
                }

                if !viewModel.showCompletedAtBottom {
                    ForEach(checkedItems) { item in
                        itemWithActions(item)
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
    
    @ViewBuilder
    private func inlineAddRow(for labelName: String, color: Color?) -> some View {
        if activeInlineAdd == labelName {
            // Active state - show text field
            HStack(spacing: 12) {
                TextField("Item name", text: $inlineAddText)
                    .font(.subheadline)
                    .focused($inlineAddFocused)
                    .onSubmit {
                        addInlineItem(to: labelName)
                    }
                
                // Cancel button
                Button {
                    activeInlineAdd = nil
                    inlineAddText = ""
                    inlineAddFocused = false
                } label: {
                    Image(systemName: "xmark")
                        .foregroundColor(.red.opacity(0.75))
                    
                    //.imageScale(.medium)
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                
                // Add button
                Button {
                    addInlineItem(to: labelName)
                } label: {
                    Image(systemName: "checkmark")
                        .foregroundColor(
                            inlineAddText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? .secondary
                            : .accentColor
                        )
                    //.imageScale(.medium)
                }
                .buttonStyle(.glass)
                .disabled(inlineAddText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.vertical, 1.5)
        } else {
            // Inactive state - show "+ Add Item" button
            HStack {
                Button {
                    activeInlineAdd = labelName
                    inlineAddFocused = true
                } label: {
                    
                    Text("Add Item")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
                .buttonStyle(.glass)
                
                Spacer()
                
                Button {
                    activeInlineAdd = labelName
                    inlineAddFocused = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.glass)
                //.padding(.vertical, 4)
            }
        }
    }
    
    var body: some View {
        Group {
            if viewModel.viewMode == .kanban {
                KanbanBoardView(
                    list: list,
                    unifiedList: unifiedList,
                    viewModel: viewModel,
                    editingItem: $editingItem,
                    showingEditView: $showingEditView,
                    itemToDelete: $itemToDelete,
                    updateUncheckedCount: { listID, count in
                        await updateUncheckedCount(for: listID, with: count)
                    }
                )
            } else {
                List {
                    ForEach(labelsForListBody, id: \.self) { labelName in
                        let items = viewModel.filteredItemsGroupedByLabel[labelName] ?? []
                        let color = viewModel.colorForLabel(name: labelName)
                        renderSection(labelName: labelName, items: items, color: color)
                    }

                    if viewModel.showCompletedAtBottom && !viewModel.filteredCompletedItems.isEmpty {
                        renderSection(labelName: "Completed", items: viewModel.filteredCompletedItems, color: .primary)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable {
                    try? await unifiedProvider.syncIfNeeded(for: unifiedList)
                    await viewModel.loadLabels()
                    await viewModel.loadItems()
                    viewModel.initializeExpandedSections(for: viewModel.filteredSortedLabelKeys)
                }
                .environment(\.chipsInline, shouldShowChipsInline(
                    itemTitles: viewModel.items.map(\.note),
                    availableWidth: listWidth
                ))
            }
        }
        .background(
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                if let gradient = viewModel.listBackground?.resolved() {
                    LinearGradient(
                        colors: [gradient.fromColor, gradient.toColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ).ignoresSafeArea()
                }

                GeometryReader { geo in
                    Color.clear.preference(key: ListWidthPreferenceKey.self, value: geo.size.width)
                }
            }
        )
        .onPreferenceChange(ListWidthPreferenceKey.self) { listWidth = $0 }
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(viewModel.viewMode == .kanban ? .inline : .large)
        .toolbar(id: "LIST_ACTIONS") {
            // Add button - always present, just hidden/disabled
            ToolbarItem(id: "icon", placement: .largeTitle) {
                VStack {
                    HStack {
                        Image(systemName: list.icon ?? "list.bullet")
                            .font(.system(.title2, design: .default, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                        Text(list.name)
                            .font(.system(.title2, design: .default, weight: .bold))
                        
                        Spacer()
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal)
                }

            }
            
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
            
            // Refresh button - only in kanban mode (no pull-to-refresh)
            ToolbarItem(id: "refresh", placement: .navigationBarTrailing) {
                if viewModel.viewMode == .kanban {
                    Button {
                        guard kanbanRefreshState == .idle else { return }
                        kanbanRefreshState = .refreshing
                        Task {
                            let start = Date()
                            try? await unifiedProvider.syncIfNeeded(for: unifiedList)
                            await viewModel.loadLabels()
                            await viewModel.loadItems()
                            // Ensure spinner shows for at least 0.6s
                            let elapsed = Date().timeIntervalSince(start)
                            if elapsed < 0.6 {
                                try? await Task.sleep(nanoseconds: UInt64((0.6 - elapsed) * 1_000_000_000))
                            }
                            await MainActor.run {
                                withAnimation {
                                    kanbanRefreshState = .done
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    withAnimation {
                                        kanbanRefreshState = .idle
                                    }
                                }
                            }
                        }
                    } label: {
                        Group {
                            switch kanbanRefreshState {
                            case .idle:
                                Image(systemName: "arrow.clockwise")
                            case .refreshing:
                                ProgressView()
                                    .controlSize(.small)
                            case .done:
                                Image(systemName: "checkmark")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .disabled(kanbanRefreshState != .idle)
                }
            }

            // Add button - in bottom bar next to search
            ToolbarItem(id: "add", placement: .bottomBar) {
                Button {
                    showingAddView = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(unifiedList.isReadOnly)
            }

            // Menu - always present, just hidden/disabled
            ToolbarItem(id: "menu", placement: .navigationBarTrailing) {
                Menu {
                    overflowMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                }
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
        
        .modifier(ShoppingListSheetsModifier(
            list: list,
            unifiedList: unifiedList,
            unifiedProvider: unifiedProvider,
            viewModel: viewModel,
            welcomeViewModel: welcomeViewModel,
            showingAddView: $showingAddView,
            editingItem: $editingItem,
            showingRecycleBin: $showingRecycleBin,
            showingMarkdownImport: $showingMarkdownImport,
            markdownToExport: $markdownToExport,
            shareLinkExport: $shareLinkExport,
            showingListSettings: $showingListSettings,
            itemToDelete: $itemToDelete,
            beatenToItMessage: $beatenToItMessage,
            triggerMarkdownExport: $triggerMarkdownExport,
            triggerJSONExport: $triggerJSONExport,
            triggerShareLink: $triggerShareLink,
            searchText: $searchText,
            onExportJSON: onExportJSON
        ))
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
    
    @ViewBuilder
    private var overflowMenuContent: some View {
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
                    await MainActor.run { isPerformingBulkAction = false }
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
                    await MainActor.run { isPerformingBulkAction = false }
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
                systemImage: viewModel.showCompletedAtBottom ? "circle.badge.xmark" : "circle.badge.checkmark.fill"
            )
        }
        .disabled(unifiedList.isReadOnly)

        Button {
            withAnimation(.easeInOut) {
                viewModel.setViewMode(viewModel.viewMode == .list ? .kanban : .list)
            }
        } label: {
            Label(
                viewModel.viewMode == .list ? "Kanban View" : "List View",
                systemImage: viewModel.viewMode == .list ? "rectangle.split.3x1" : "list.bullet"
            )
        }

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

            Button {
                shareLinkExport = MarkdownExport(
                    listName: list.name,
                    listId: unifiedList.originalFileId ?? unifiedList.id,
                    items: viewModel.items,
                    labels: viewModel.labels,
                    activeOnly: true
                )
            } label: {
                Label("Share Link", systemImage: "link")
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
            showingListSettings = true
        } label: {
            Label("List Settings", systemImage: "gearshape")
        }

        Button {
            showingRecycleBin = true
        } label: {
            Label("Recycle Bin", systemImage: "trash")
        }
        .disabled(unifiedList.isReadOnly)
    }

    private func addInlineItem(to labelName: String) {
        let trimmedText = inlineAddText.trimmingCharacters(in: .whitespaces)

        // If empty, treat as cancel
        if trimmedText.isEmpty {
            activeInlineAdd = nil
            inlineAddText = ""
            inlineAddFocused = false
            return
        }

        // Find the label
        let label = viewModel.labels.first { $0.name == labelName }

        Task {
            let success = await viewModel.addItem(
                note: trimmedText,
                label: label,
                quantity: 1,
                markdownNotes: nil
            )

            if success {
                await MainActor.run {
                    inlineAddText = ""
                    // Briefly defocus and refocus to trigger scroll recalculation
                    inlineAddFocused = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        inlineAddFocused = true
                    }
                }
            }
        }
    }
}

// MARK: - Sheets, Alerts & Notification Handlers (extracted to reduce body complexity)

private struct ShoppingListSheetsModifier: ViewModifier {
    let list: ShoppingListSummary
    let unifiedList: UnifiedList
    let unifiedProvider: UnifiedListProvider
    @ObservedObject var viewModel: ShoppingListViewModel
    @ObservedObject var welcomeViewModel: WelcomeViewModel

    @Binding var showingAddView: Bool
    @Binding var editingItem: ShoppingItem?
    @Binding var showingRecycleBin: Bool
    @Binding var showingMarkdownImport: Bool
    @Binding var markdownToExport: MarkdownExport?
    @Binding var shareLinkExport: MarkdownExport?
    @Binding var showingListSettings: Bool
    @Binding var itemToDelete: ShoppingItem?
    @Binding var beatenToItMessage: String?
    @Binding var triggerMarkdownExport: Bool
    @Binding var triggerJSONExport: Bool
    @Binding var triggerShareLink: Bool
    @Binding var searchText: String
    var onExportJSON: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $showingAddView, onDismiss: {
                Task { await refreshReminderCounts() }
            }) {
                AddItemView(list: list, viewModel: viewModel)
            }
            .fullScreenCover(item: $editingItem, onDismiss: {
                Task { await refreshReminderCounts() }
            }) { item in
                EditItemView(viewModel: viewModel, item: item, list: list, unifiedList: unifiedList)
            }
            .sheet(isPresented: $showingRecycleBin) {
                RecycleBinView(list: unifiedList, provider: unifiedProvider) {
                    Task { await viewModel.loadItems() }
                }
            }
            .sheet(isPresented: $showingMarkdownImport) {
                Task {
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
            .sheet(item: $shareLinkExport) { export in
                ShareLinkSheet(
                    listName: export.listName,
                    listId: export.listId,
                    items: export.items,
                    labels: export.labels
                )
            }
            .sheet(isPresented: $showingListSettings, onDismiss: {
                NotificationCenter.default.post(name: .listSettingsChanged, object: nil)
            }) {
                ListSettingsView(
                    list: list,
                    unifiedList: unifiedList,
                    unifiedProvider: unifiedProvider
                ) { updatedName, icon, hiddenLabels in
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
            .modifier(ShoppingListAlertsModifier(
                viewModel: viewModel,
                unifiedList: unifiedList,
                itemToDelete: $itemToDelete,
                beatenToItMessage: $beatenToItMessage,
                editingItem: $editingItem
            ))
            .modifier(ShoppingListObserversModifier(
                list: list,
                unifiedList: unifiedList,
                unifiedProvider: unifiedProvider,
                viewModel: viewModel,
                markdownToExport: $markdownToExport,
                shareLinkExport: $shareLinkExport,
                triggerMarkdownExport: $triggerMarkdownExport,
                triggerJSONExport: $triggerJSONExport,
                triggerShareLink: $triggerShareLink,
                searchText: $searchText,
                editingItem: $editingItem,
                beatenToItMessage: $beatenToItMessage,
                onExportJSON: onExportJSON
            ))
    }

    private func refreshReminderCounts() async {
        await welcomeViewModel.loadUnifiedCounts(
            for: unifiedProvider.allLists,
            provider: unifiedProvider
        )
    }
}

// MARK: - Alerts (extracted from sheets modifier)

private struct ShoppingListAlertsModifier: ViewModifier {
    @ObservedObject var viewModel: ShoppingListViewModel
    let unifiedList: UnifiedList
    @Binding var itemToDelete: ShoppingItem?
    @Binding var beatenToItMessage: String?
    @Binding var editingItem: ShoppingItem?

    func body(content: Content) -> some View {
        content
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
            .alert("You've been beaten to it!", isPresented: Binding(
                get: { beatenToItMessage != nil },
                set: { if !$0 { beatenToItMessage = nil } }
            )) {
                Button("OK", role: .cancel) { beatenToItMessage = nil }
            } message: {
                Text(beatenToItMessage ?? "")
            }
    }
}

// MARK: - Notification & onChange Observers (extracted from body)

private struct ShoppingListObserversModifier: ViewModifier {
    let list: ShoppingListSummary
    let unifiedList: UnifiedList
    let unifiedProvider: UnifiedListProvider
    @ObservedObject var viewModel: ShoppingListViewModel
    @Binding var markdownToExport: MarkdownExport?
    @Binding var shareLinkExport: MarkdownExport?
    @Binding var triggerMarkdownExport: Bool
    @Binding var triggerJSONExport: Bool
    @Binding var triggerShareLink: Bool
    @Binding var searchText: String
    @Binding var editingItem: ShoppingItem?
    @Binding var beatenToItMessage: String?
    var onExportJSON: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .listSettingsChanged)) { _ in
                Task {
                    await viewModel.loadLabels()
                    await viewModel.loadItems()
                    viewModel.reloadBackground()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .externalListChanged)) { notification in
                if let changedListId = notification.object as? String,
                   changedListId == unifiedList.id {
                    Task {
                        await viewModel.loadLabels()
                        await viewModel.loadItems()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reminderCompleted)) { notification in
                if let listId = notification.userInfo?["listId"] as? String,
                   listId == unifiedList.id {
                    Task { await viewModel.loadItems() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reminderTapped)) { notification in
                guard let listId = notification.userInfo?["listId"] as? String,
                      listId == unifiedList.id,
                      let itemIdString = notification.userInfo?["itemId"] as? String,
                      let itemId = UUID(uuidString: itemIdString) else { return }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let item = viewModel.items.first(where: { $0.id == itemId }) {
                        if item.checked {
                            let time = item.modifiedAt.formatted(date: .omitted, time: .shortened)
                            let day = Calendar.current.isDateInToday(item.modifiedAt) ? "today" : item.modifiedAt.formatted(date: .abbreviated, time: .omitted)
                            beatenToItMessage = "Completed \(day) at \(time)"
                        } else {
                            editingItem = item
                        }
                    }
                }
            }
            .focusedSceneValue(\.exportMarkdown, $triggerMarkdownExport)
            .focusedSceneValue(\.exportJSON, $triggerJSONExport)
            .focusedSceneValue(\.shareLink, $triggerShareLink)
            .focusedSceneValue(\.isReadOnly, unifiedList.isReadOnly)
            .onChange(of: triggerMarkdownExport) { _, newValue in
                if newValue {
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
            .onChange(of: triggerJSONExport) { _, newValue in
                if newValue {
                    onExportJSON?()
                    triggerJSONExport = false
                }
            }
            .onChange(of: triggerShareLink) { _, newValue in
                if newValue {
                    shareLinkExport = MarkdownExport(
                        listName: list.name,
                        listId: unifiedList.originalFileId ?? unifiedList.id,
                        items: viewModel.items,
                        labels: viewModel.labels,
                        activeOnly: true
                    )
                    triggerShareLink = false
                }
            }
            .onChange(of: searchText) { _, newValue in
                viewModel.searchText = newValue
            }
    }
}
