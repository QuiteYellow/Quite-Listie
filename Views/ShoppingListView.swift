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
    
    @ObservedObject var settings: AppSettings
    
    var body: some View {
        Button {
            settings.toggleSection(labelName)
        } label: {
            HStack {
                Text(labelName.removingLabelNumberPrefix())
                    .font(.headline)
                    .textCase(nil)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    //.background(Capsule().fill(color ?? Color.gray.opacity(0.3))) // Chip background
                    //.foregroundColor((color ?? Color.gray.opacity(0.3)).appropriateForegroundColor())
                    .foregroundColor((color ?? .primary).lightened(forBackground: Color(.systemBackground))) //need to add darkened for light mode.

                Spacer()
                
                HStack {
                    Text("\(uncheckedCount)")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 4)
                    
                    
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees((settings.expandedSections[labelName] ?? false) ? 90 : 0))
                        .foregroundColor(.gray)
                        .font(.body)
                }
                .padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
                        .background(
                            Group {
                                if isExpanded {
                                    // Rounded only top corners
                                    RoundedCorner(radius: 10, corners: [.topLeft, .topRight])
                                        .fill(Color(.systemBackground))
                                        .overlay(
                                            RoundedCorner(radius: 10, corners: [.topLeft, .topRight])
                                                .stroke(Color(.systemGray3), lineWidth: 1)
                                        )
                                } else {
                                    // Fully rounded corners
                                    RoundedCorner(radius: 10, corners: [.allCorners])
                                        .fill(Color(.systemBackground))
                                        .overlay(
                                            RoundedCorner(radius: 10, corners: [.allCorners])
                                                .stroke(Color(.systemGray3), lineWidth: 1)
                                        )
                                }
                                    
                            }
                        )
                    }
                    .animation(.easeInOut, value: isExpanded)
                }
            }

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

struct ItemRowView: View {
    let item: ShoppingItem
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {

            HStack {
                // Quantity chip on the left
                Text((item.quantity ?? 0).formatted(.number.precision(.fractionLength(0))))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(item.checked ? Color(.systemBackground) : .primary)) // quantity chip colour
                    .foregroundColor(item.checked ? .gray : Color(.systemGray5))

                // Item note text
                Text(item.note)
                    .strikethrough(item.checked, color: .gray)
                    .foregroundColor(item.checked ? .gray : .primary)
                    .font(.subheadline)

                Spacer()

                if item.checked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .imageScale(.large)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.accentColor)
                        .imageScale(.large)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                Group {
                    if isLast {
                        RoundedCorner(radius: 10, corners: [.bottomLeft, .bottomRight])
                            .fill(Color(.systemGray5))
                            .overlay(
                                RoundedCorner(radius: 10, corners: [.bottomLeft, .bottomRight])
                                    .stroke(Color(.systemGray3), lineWidth: 1)
                            )
                    } else {
                        // Fully rounded corners
                        RoundedCorner(radius: 0, corners: [.bottomLeft, .bottomRight])
                            .fill(Color(.systemGray5))
                            .overlay(
                                RoundedCorner(radius: 0, corners: [.bottomLeft, .bottomRight])
                                    .stroke(Color(.systemGray3), lineWidth: 1)
                                )
                    }
                }
            )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
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

    var body: some View {
        ScrollView {
            let labelKeys = viewModel.sortedLabelKeys
            let mainPadding = CGFloat(6)

            ForEach(labelKeys, id: \.self) { labelName in
                let color = viewModel.colorForLabel(name: labelName)
                let isExpanded = settings.expandedSections[labelName] == true

                let items = viewModel.itemsGroupedByLabel[labelName] ?? []

                let uncheckedItems = items.filter { !$0.checked }
                let checkedItems = items.filter { $0.checked }

                let itemsToShow = settings.showCompletedAtBottom ? uncheckedItems : uncheckedItems + checkedItems

                if !itemsToShow.isEmpty {
                    VStack(spacing: 0) {
                        
                        SectionHeaderView(labelName: labelName,
                                          color: color,
                                          isExpanded: isExpanded,
                                          uncheckedCount: uncheckedItems.count,
                                          settings: settings)
                            .padding(.horizontal, mainPadding)
                            .background(Color(.systemBackground))
                            .zIndex(1)

                        if isExpanded {
                            VStack(spacing: 0) {
                                ForEach(Array(itemsToShow.enumerated()), id: \.element.id) { index, item in
                                    ItemRowView(
                                        item: item,
                                        isLast: index == itemsToShow.count - 1
                                    ) {
                                        Task {
                                            await viewModel.toggleChecked(for: item)
                                        }
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
                                .padding(.horizontal, mainPadding)
                            }
                            .zIndex(0)
                            //.transition(.move(edge: .top))
                            .animation(.easeInOut, value: isExpanded)
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, mainPadding)
                }
            }

            if settings.showCompletedAtBottom {
                let allCheckedItems = viewModel.items.filter { $0.checked }

                if !allCheckedItems.isEmpty {
                    VStack(spacing: 0) {
                        SectionHeaderView(labelName: "Completed",
                                          color: .primary,
                                          isExpanded: settings.expandedSections["Completed"] == true,
                                          uncheckedCount: allCheckedItems.count,
                                          settings: settings)
                            .padding(.horizontal, mainPadding)
                            .background(Color(.systemBackground))
                            .zIndex(1)

                        if settings.expandedSections["Completed"] == true {
                            VStack(spacing: 0) {
                                ForEach(Array(allCheckedItems.enumerated()), id: \.element.id) { index, item in
                                    ItemRowView(
                                        item: item,
                                        isLast: index == allCheckedItems.count - 1
                                    ) {
                                        Task {
                                            await viewModel.toggleChecked(for: item)
                                        }
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
                                .padding(.horizontal, mainPadding)
                            }
                            .zIndex(0)
                            //.transition(.opacity.combined(with: .move(edge: .top)))
                            .animation(.easeInOut, value: settings.expandedSections["Completed"])
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, mainPadding)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .alert("Delete Item?", isPresented: Binding(
                get: { itemToDelete != nil },
                set: { newValue in if !newValue { itemToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    guard let item = itemToDelete else { return }
                    Task {
                        await viewModel.deleteItem(item)
                        await MainActor.run {
                            itemToDelete = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    itemToDelete = nil
                }
            } message: {
                Text("Are you sure you want to delete this item?")
            }
        .fullScreenCover(item: $editingItem) { item in
            EditItemView(viewModel: viewModel, item: item)
        }
        .scrollIndicators(.visible)
        .refreshable {
            await viewModel.loadItems()
            settings.initializeExpandedSections(for: viewModel.sortedLabelKeys)
        }
        .task {
            await viewModel.loadItems()
            settings.initializeExpandedSections(for: viewModel.sortedLabelKeys)
        }
        .navigationTitle(listName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !networkMonitor.isConnected {
                    Image(systemName: "wifi.slash")
                        .foregroundColor(.red)
                        .help("No internet connection")
                }
                Button {
                    showingAddView = true
                } label: {
                    Image(systemName: "plus")
                }
                
                Button {
                    settings.showCompletedAtBottom.toggle()
                } label: {
                    Image(systemName: settings.showCompletedAtBottom ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help("Toggle completed items section")
            }
        }
        .fullScreenCover(isPresented: $showingAddView) {
            AddItemView(viewModel: viewModel)
        }
    }
}
