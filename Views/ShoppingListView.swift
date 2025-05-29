//
//  ListView.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 25/05/2025.
//

import SwiftUI

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
                Text(labelName.removingLabelNumberPrefix())
                    .font(.headline)
                    .foregroundColor((color ?? .primary).adjusted(forBackground: Color(.systemBackground)))
                    .padding(.horizontal, 0)
                    .padding(.vertical, 4)
                
                Spacer()
                
                HStack(spacing: 4) {
                    Text(labelName == "Completed" ? "\(checkedCount)" : "\(uncheckedCount)") // Show checked count instead of unchecked for Completed!
                        .foregroundColor((color ?? .primary).adjusted(forBackground: Color(.systemBackground)))
                        .font(.headline)
                        .padding(.horizontal, 4)

                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundColor((color ?? .primary).adjusted(forBackground: Color(.systemBackground)))
                        .font(.headline)
                        .padding(.horizontal, 2)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 0)
                .background(
                        Capsule()
                            .fill(.clear)
                    )
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 0)
        }
        //.buttonStyle(.plain)
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
            Button(action: {
                onTap()
            }) {
                Image(systemName: item.checked ? "inset.filled.circle" : "circle")
                    .foregroundColor(item.checked ? .gray : .accentColor)
                    .imageScale(.large)
                
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 0)
        .padding(.horizontal, 0)
        .background(.clear)
    }
}

struct ShoppingListView: View {
    let listName: String
    let shoppingListId: String

    @StateObject private var viewModel: ShoppingListViewModel
    @State private var showingAddView = false
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var networkMonitor: NetworkMonitor

    @State private var editingItem: ShoppingItem? = nil
    @State private var showingEditView = false
    @State private var itemToDelete: ShoppingItem? = nil

    init(shoppingListId: String, listName: String) {
        self.shoppingListId = shoppingListId
        self.listName = listName
        _viewModel = StateObject(wrappedValue: ShoppingListViewModel(shoppingListId: shoppingListId))
    }
    
    @ViewBuilder
    private func renderSection(labelName: String, items: [ShoppingItem], color: Color?) -> some View {
        let isExpanded = settings.expandedSections[labelName] ?? true
        let uncheckedItems = items.filter { !$0.checked }
        let checkedItems = items.filter { $0.checked }

        let itemsToShow = settings.showCompletedAtBottom && labelName != "Completed"
            ? uncheckedItems
            : uncheckedItems + checkedItems

        if !itemsToShow.isEmpty {
            Section(header:
                SectionHeaderView(
                    labelName: labelName,
                    color: color,
                    isExpanded: isExpanded,
                    uncheckedCount: uncheckedItems.count,
                    checkedCount: checkedItems.count,
                    settings: settings
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)) // custom insets for header
            ) {
                if isExpanded {
                    ForEach(itemsToShow) { item in
                        ItemRowView(
                            item: item,
                            isLast: false,
                            onTap: {
                                Task { await viewModel.toggleChecked(for: item) }
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
                            }
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
                            Button(role: .destructive) {
                                itemToDelete = item
                            } label: {
                                Label("Delete Item...", systemImage: "trash")
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
        .navigationTitle(listName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !networkMonitor.isConnected {
                    Image(systemName: "wifi.slash")
                        .foregroundColor(.red)
                }
                Button { showingAddView = true } label: {
                    Image(systemName: "plus")
                }
                Button {
                    settings.showCompletedAtBottom.toggle()
                } label: {
                    Image(systemName: settings.showCompletedAtBottom ? "circle.badge.checkmark.fill" : "circle.badge.xmark")
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
            AddItemView(viewModel: viewModel)
        }
        .fullScreenCover(item: $editingItem) { item in
            EditItemView(viewModel: viewModel, item: item)
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
