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
    @ObservedObject var settings: AppSettings

    var body: some View {
        Button {
            settings.toggleSection(labelName)
        } label: {
            HStack {
                // Colored chip with label text
                Text(labelName.removingLabelNumberPrefix())
                    .font(.subheadline)
                    .textCase(nil)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(color ?? Color.gray.opacity(0.3))
                    )
                    .foregroundColor(.white)

                Spacer()

                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees((settings.expandedSections[labelName] ?? false) ? 90 : 0))
                    .foregroundColor(.gray)
                    .font(.caption)
            }
            .contentShape(Rectangle())
                        .padding(8)
                        .background(
                            Group {
                                if isExpanded {
                                    // Rounded only top corners
                                    RoundedCorner(radius: 12, corners: [.topLeft, .topRight])
                                        .fill(Color(.secondarySystemBackground))
                                } else {
                                    // Fully rounded corners
                                    RoundedCorner(radius: 12, corners: [.allCorners])
                                        .fill(Color(.secondarySystemBackground))
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
    let showTopDivider: Bool
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showTopDivider {
                Divider()
                    .padding(.leading, 0)
            }

            HStack {
                Text(item.note)
                    .strikethrough(item.checked, color: .gray)
                    .foregroundColor(item.checked ? .gray : .primary)
                Spacer()
                if item.checked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                } else {
                    Image(systemName: "circle.fill")
                        .foregroundColor(Color.primary)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                Group {
                    if isLast {
                        RoundedCorner(radius: 12, corners: [.bottomLeft, .bottomRight])
                            .fill(Color(.secondarySystemBackground))
                    } else {
                        Color(.secondarySystemBackground)
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
    @StateObject private var viewModel: ShoppingListViewModel
    @State private var showingAddView = false
    @StateObject private var settings = AppSettings.shared

    init(shoppingListId: String) {
        _viewModel = StateObject(wrappedValue: ShoppingListViewModel(shoppingListId: shoppingListId))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12, pinnedViews: []) { // pinnedViews empty since no sticky headers
                ForEach(viewModel.sortedLabelKeys, id: \.self) { labelName in
                    let color = viewModel.colorForLabel(name: labelName)
                    let isExpanded = settings.expandedSections[labelName] == true
                    
                    VStack(spacing: 0) {

                        SectionHeaderView(labelName: labelName, color: color, isExpanded: isExpanded, settings: settings)
                            .padding(.horizontal, 10)
  

                        if settings.expandedSections[labelName] == true {
                            let items = viewModel.itemsGroupedByLabel[labelName] ?? []
                            VStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    ItemRowView(
                                        item: item,
                                        showTopDivider: true, // Always show
                                        isLast: index == items.count - 1
                                    ) {
                                        Task {
                                            await viewModel.toggleChecked(for: item)
                                        }
                                    }
                                }
                                .padding(.horizontal, 10)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .padding(.vertical, 10)
        }
        .scrollIndicators(.visible) // Show scrollbar like List
        .refreshable {
            await viewModel.loadItems()
            settings.initializeExpandedSections(for: viewModel.sortedLabelKeys)
        }
        .task {
            await viewModel.loadItems()
            settings.initializeExpandedSections(for: viewModel.sortedLabelKeys)
        }
        .navigationTitle("Shopping List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAddView = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddView) {
            AddItemView(viewModel: viewModel)
        }
    }
}
