//
//  ListView.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 25/05/2025.
//

import SwiftUI

struct SectionHeaderView: View {
    let labelName: String
    let color: Color?
    let isExpanded: Bool
    let uncheckedCount: Int
    let checkedCount: Int
    
    @ObservedObject var settings: AppSettings
    
    var body: some View {
        Button(action: {
            withAnimation(.easeInOut) {
                settings.toggleSection(labelName)
            }
        }) {
            
            
            HStack {
                Image(systemName: "tag.fill")
                    .foregroundColor((color ?? .secondary).adjusted(forBackground: Color(.systemBackground)))
                
                Text(labelName.removingLabelNumberPrefix())
                // .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                HStack {
                    Text(labelName == "Completed" ? "\(checkedCount)" : "\(uncheckedCount)")
                    //.font(.subheadline)
                        .foregroundColor(.primary)
                    
                    
                    // Chevron
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(.easeInOut, value: isExpanded)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 0)
            }
            
            .background(Color(.systemGroupedBackground))
            //.background(Capsule().fill(.red))
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

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

struct ShoppingListView: View {
    @ObservedObject var welcomeViewModel: WelcomeViewModel
    
    let list: ShoppingListSummary
    var onListChanged: (() async -> Void)? = nil
    
    @StateObject private var viewModel: ShoppingListViewModel
    @State private var showingAddView = false
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var networkMonitor: NetworkMonitor
    
    @State private var editingItem: ShoppingItem? = nil
    @State private var showingEditView = false
    @State private var itemToDelete: ShoppingItem? = nil
    
    
    init(list: ShoppingListSummary, welcomeViewModel: WelcomeViewModel) {
        self.list = list
        self._viewModel = StateObject(wrappedValue: ShoppingListViewModel(list: list))
        self.welcomeViewModel = welcomeViewModel
    }
    
    private func updateUncheckedCount(for listID: String, with count: Int) async {
        await MainActor.run {
            welcomeViewModel.uncheckedCounts[listID] = count
        }
    }
    
    @ViewBuilder
    private func renderSection(labelName: String, items: [ShoppingItem], color: Color?) -> some View {
        let isExpanded = settings.expandedSections[labelName] ?? true
        let uncheckedItems = items.filter { !$0.checked }
        let checkedItems = items.filter { $0.checked }
        
        let itemsToShow = settings.showCompletedAtBottom && labelName != "Completed"
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
                                    if list.isLocal {
                                        await onListChanged?()
                                    }
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
                                _ = await viewModel.updateItem(item, note: item.note, label: item.label, quantity: newQty)
                                if list.isLocal {
                                    await onListChanged?()
                                }
                            }
                        },
                        onDecrement: {
                            if (item.quantity ?? 1) <= 1 {
                                itemToDelete = item
                            } else {
                                Task {
                                    let newQty = max((item.quantity ?? 1) - 1, 1)
                                    _ = await viewModel.updateItem(item, note: item.note, label: item.label, quantity: newQty)
                                    if list.isLocal {
                                        await onListChanged?()
                                    }
                                }
                            }
                        },
                        isReadOnly: list.isReadOnlyExample
                    )
                    .swipeActions(edge: .trailing) {
                        Button(role: .none) {
                            if (item.quantity ?? 1) < 2 {
                                itemToDelete = item
                            } else {
                                Task {
                                    let newQty = max((item.quantity ?? 1) - 1, 1)
                                    _ = await viewModel.updateItem(item, note: item.note, label: item.label, quantity: newQty)
                                }
                            }
                        } label: {
                            Label((item.quantity ?? 1) < 2 ? "Delete" : "–", systemImage: (item.quantity ?? 1) < 2 ? "trash" : "minus")
                        }
                        .tint((item.quantity ?? 1) < 2 ? .red : .orange)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task {
                                let newQty = (item.quantity ?? 1) + 1
                                _ = await viewModel.updateItem(item, note: item.note, label: item.label, quantity: newQty)
                            }
                        } label: {
                            Label("+", systemImage: "plus")
                        }
                        .tint(.green)
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
                settings: settings
            )
        }
    }
    
    var body: some View {
        
        List {
            if settings.showCompletedAtBottom {
                // Only unchecked items per label
                ForEach(
                    viewModel.sortedLabelKeys.filter { labelName in
                        guard labelName != "Completed" else { return false }
                        let items = viewModel.itemsGroupedByLabel[labelName] ?? []
                        if settings.showCompletedAtBottom {
                            return items.contains(where: { !$0.checked }) // show only if there are unchecked items
                        } else {
                            return !items.isEmpty // show if there are any items
                        }
                    },
                    id: \.self
                ) { labelName in
                    let items = viewModel.itemsGroupedByLabel[labelName] ?? []
                    let color = viewModel.colorForLabel(name: labelName)
                    renderSection(labelName: labelName, items: items, color: color)
                }
                
                // Checked items go in "Completed" section
                let completedItems = viewModel.items.filter { $0.checked }
                if !completedItems.isEmpty {
                    renderSection(labelName: "Completed", items: completedItems, color: .primary)
                }
                
            } else {
                // All items per label — skip "Completed" label key
                ForEach(viewModel.sortedLabelKeys.filter { $0 != "Completed" }, id: \.self) { labelName in
                    let items = viewModel.itemsGroupedByLabel[labelName] ?? []
                    if !items.isEmpty {
                        let color = viewModel.colorForLabel(name: labelName)
                        renderSection(labelName: labelName, items: items, color: color)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.large)
        
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                
                // Network status indicator
                if !networkMonitor.isConnected {
                    Image(systemName: "wifi.slash")
                        .foregroundColor(.red)
                }
                
                // Add item button
                Button {
                    showingAddView = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(list.isReadOnlyExample)
                
                // Menu with list actions
                Menu {
                    // Submenu for bulk marking
                    Menu("Mark All Items As…") {
                        Button {
                            Task {
                                await viewModel.setAllItems(for: list.id, toCompleted: true) { count in
                                    await updateUncheckedCount(for: list.id, with: count)
                                    if list.isLocal {
                                        await onListChanged?()
                                    }
                                }
                            }
                        } label: {
                            Label("Completed", systemImage: "inset.filled.circle")
                        }
                        .disabled(list.isReadOnlyExample)

                        Button {
                            Task {
                                await viewModel.setAllItems(for: list.id, toCompleted: false) { count in
                                    await updateUncheckedCount(for: list.id, with: count)
                                    if list.isLocal {
                                        await onListChanged?()
                                    }
                                }
                            }
                        } label: {
                            Label("Active", systemImage: "circle")
                        }
                        .disabled(list.isReadOnlyExample)
                    }

                    // Show/Hide Completed
                    Button {
                        withAnimation(.easeInOut) {
                            settings.showCompletedAtBottom.toggle()
                        }
                    } label: {
                        Label(
                            settings.showCompletedAtBottom ? "Show Completed Inline" : "Show Completed as Label",
                            systemImage: settings.showCompletedAtBottom ? "circle.badge.xmark" : "circle.badge.checkmark.fill"
                        )
                    }
                    .disabled(list.isReadOnlyExample)

                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        
        .refreshable {
            await viewModel.loadItems()
            settings.initializeExpandedSections(for: viewModel.sortedLabelKeys)
        }
        .task {
            await viewModel.loadItems()
            settings.initializeExpandedSections(for: viewModel.sortedLabelKeys)
        }
        .fullScreenCover(isPresented: $showingAddView) {
            AddItemView(list: list, viewModel: viewModel)
                .onDisappear {
                    if list.isLocal {
                        Task {
                            await onListChanged?()
                        }
                    }
                }
        }
        .fullScreenCover(item: $editingItem) { item in
            EditItemView(viewModel: viewModel, item: item, list: list)
                .onDisappear {
                    if list.isLocal {
                        Task {
                            await onListChanged?()
                        }
                    }
                }
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
                        if list.isLocal {
                            await onListChanged?()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { itemToDelete = nil }
        } message: {
            Text("Are you sure you want to delete this item?")
        }
    }
}
