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
                        //.foregroundColor(.primary)
                        
                        Spacer()
                        HStack {
                            Text(labelName == "Completed" ? "\(checkedCount)" : "\(uncheckedCount)")
                            //.font(.subheadline)
                            //.foregroundColor(.accentColor)
                                
                            
                            // Chevron
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                                .animation(.easeInOut, value: isExpanded)
                                .foregroundColor(.secondary)
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
        let isExpandedBinding = Binding<Bool>(
            get: { settings.expandedSections[labelName] ?? true },
            set: { newValue in
                settings.expandedSections[labelName] = newValue
            }
        )
        
        let uncheckedItems = items.filter { !$0.checked }
        let checkedItems = items.filter { $0.checked }

        let itemsToShow = settings.showCompletedAtBottom && labelName != "Completed"
            ? uncheckedItems
            : uncheckedItems + checkedItems

        if !itemsToShow.isEmpty {
            Section(
                header:
                    SectionHeaderView(
                        labelName: labelName,
                        color: color,
                        isExpanded: isExpandedBinding.wrappedValue,
                        uncheckedCount: uncheckedItems.count,
                        checkedCount: checkedItems.count,
                        settings: settings
                    )
            ) {
                if isExpandedBinding.wrappedValue {
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
                                    _ = await viewModel.updateItem(item, note: item.note, label: item.label, quantity: newQty)
                                }
                            },
                            onDecrement: {
                                if (item.quantity ?? 1) <= 1 {
                                    itemToDelete = item
                                } else {
                                    Task {
                                        let newQty = max((item.quantity ?? 1) - 1, 1)
                                        _ = await viewModel.updateItem(item, note: item.note, label: item.label, quantity: newQty)
                                    }
                                }
                            },
                            isReadOnly: list.isReadOnlyExample
                        )
                        .swipeActions(edge: .trailing) {
                            if !list.isReadOnlyExample {
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
                        }
                        .swipeActions(edge: .leading) {
                            if !list.isReadOnlyExample {
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
                        }
                        .contextMenu {
                            if !list.isReadOnlyExample {
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
                            } else {
                                Text("Read-only example list").foregroundColor(.gray)
                            }
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        
        List {
            ForEach(viewModel.sortedLabelKeys, id: \.self) { labelName in
                let items = viewModel.itemsGroupedByLabel[labelName] ?? []
                let color = viewModel.colorForLabel(name: labelName)
                renderSection(labelName: labelName, items: items, color: color)
            }
            
            if settings.showCompletedAtBottom {
                let completedItems = viewModel.items.filter { $0.checked }
                renderSection(labelName: "Completed", items: completedItems, color: .primary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.large)

        .toolbar {

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                
                if !networkMonitor.isConnected {
                    Image(systemName: "wifi.slash")
                        .foregroundColor(.red)
                }
                Button { showingAddView = true } label: {
                    Image(systemName: "plus")
                }.disabled(list.isReadOnlyExample)
                Button {
                    withAnimation(.easeInOut) {
                        settings.showCompletedAtBottom.toggle()
                    }
                } label: {
                    Image(systemName: settings.showCompletedAtBottom ? "circle.badge.checkmark.fill" : "circle.badge.xmark")
                }.disabled(list.isReadOnlyExample)
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
        }
        .fullScreenCover(item: $editingItem) { item in
            EditItemView(viewModel: viewModel, item: item, list: list)
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
            Text("Are you sure you want to delete this item?")
        }
    }
}
