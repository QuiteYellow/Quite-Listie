//
//  KanbanBoardView.swift
//  Listie.md
//
//  Board/Kanban view for shopping lists — labels displayed as side-by-side columns
//

import SwiftUI

struct KanbanBoardView: View {
    let list: ShoppingListSummary
    let unifiedList: UnifiedList
    @ObservedObject var viewModel: ShoppingListViewModel

    @Binding var editingItem: ShoppingItem?
    @Binding var showingEditView: Bool
    @Binding var itemToDelete: ShoppingItem?

    @AppStorage("hideQuickAdd") private var hideQuickAdd = false
    @AppStorage("hideEmptyLabels") private var hideEmptyLabels = true

    @State private var activeInlineAdd: String? = nil
    @State private var inlineAddText: String = ""
    @FocusState private var inlineAddFocused: Bool

    let updateUncheckedCount: (String, Int) async -> Void

    // MARK: - Labels to show

    private var labelsToShow: [String] {
        let hiddenLabelIDs = Set(list.hiddenLabels ?? [])

        if viewModel.showCompletedAtBottom {
            if hideEmptyLabels {
                return viewModel.filteredSortedLabelKeys.filter { labelName in
                    if labelName == "Completed" { return false }
                    let items = viewModel.filteredItemsGroupedByLabel[labelName] ?? []
                    return items.contains(where: { !$0.checked })
                }
            } else {
                var allLabels = viewModel.labels
                    .filter { !hiddenLabelIDs.contains($0.id) }
                    .map { $0.name }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

                if let noLabelItems = viewModel.filteredItemsGroupedByLabel["No Label"],
                   !noLabelItems.isEmpty {
                    allLabels.append("No Label")
                }
                return allLabels
            }
        } else {
            if hideEmptyLabels {
                return viewModel.filteredSortedLabelKeys.filter { $0 != "Completed" }
            } else {
                var allLabels = viewModel.labels
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
    }

    // MARK: - Body

    /// Column width: 400 on wide screens (>600), 300 on narrow (phones).
    private func columnWidth(for availableWidth: CGFloat) -> CGFloat {
        availableWidth > 600 ? 400 : 300
    }

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > 600
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 12) {
                    let columns = labelsToShow
                    let colWidth = columnWidth(for: geometry.size.width)
                    ForEach(columns, id: \.self) { labelName in
                        let items = viewModel.filteredItemsGroupedByLabel[labelName] ?? []
                        let color = viewModel.colorForLabel(name: labelName)
                        kanbanColumn(labelName: labelName, items: items, color: color, columnHeight: geometry.size.height, columnWidth: colWidth)
                    }

                    // Completed column (when showing completed at bottom)
                    if viewModel.showCompletedAtBottom && !viewModel.filteredCompletedItems.isEmpty {
                        kanbanColumn(
                            labelName: "Completed",
                            items: viewModel.filteredCompletedItems,
                            color: .primary,
                            columnHeight: geometry.size.height,
                            columnWidth: colWidth
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: geometry.size.height + (isWide ? geometry.safeAreaInsets.bottom : 0))
            .ignoresSafeArea(edges: isWide ? .bottom : [])
        }
        .environment(\.chipsInline, false)
    }

    // MARK: - Column

    @ViewBuilder
    private func kanbanColumn(labelName: String, items: [ShoppingItem], color: Color?, columnHeight: CGFloat, columnWidth: CGFloat) -> some View {
        let uncheckedItems = items.filter { !$0.checked }
        let checkedItems = items.filter { $0.checked }

        VStack(spacing: 0) {
            columnHeader(labelName: labelName, color: color, uncheckedCount: uncheckedItems.count, checkedCount: checkedItems.count)

            List {
                let itemsToShow = labelName == "Completed" ? checkedItems : uncheckedItems

                ForEach(itemsToShow) { item in
                    itemRow(item: item)
                }

                // Quick add row
                if !hideQuickAdd && labelName != "Completed" && !unifiedList.isReadOnly {
                    inlineAddRow(for: labelName, color: color)
                }

                // Inline completed items (when not showing at bottom)
                if !viewModel.showCompletedAtBottom && labelName != "Completed" && !checkedItems.isEmpty {
                    Section {
                        if viewModel.isKanbanCompletedVisible(labelName) {
                            ForEach(checkedItems) { item in
                                itemRow(item: item)
                            }
                        }
                    } header: {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                viewModel.toggleKanbanCompleted(labelName)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle")
                                    .foregroundColor(.secondary)
                                Text("Completed (\(checkedItems.count))")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .rotationEffect(.degrees(viewModel.isKanbanCompletedVisible(labelName) ? 0 : -90))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
        }
        .frame(width: columnWidth, alignment: .top)
        .padding(.bottom, 12)
    }

    // MARK: - Column Header

    private func columnHeader(labelName: String, color: Color?, uncheckedCount: Int, checkedCount: Int) -> some View {
        let displayCount = labelName == "Completed" ? checkedCount : uncheckedCount

        return HStack {
            Image(systemName: "tag.fill")
                .foregroundColor((color ?? .secondary).adjusted(forBackground: Color(.systemBackground)))

            Text(labelName.removingLabelNumberPrefix())
                .font(.headline)
                .foregroundColor(.primary)

            Spacer()

            Text("\(displayCount)")
                .foregroundColor(.primary)
                .foregroundColor(.secondary)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.25), value: displayCount)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 10)
    }

    // MARK: - Item Row (with context menu)

    @ViewBuilder
    private func itemRow(item: ShoppingItem) -> some View {
        ItemRowView(
            item: item,
            isLast: false,
            onTap: {
                Task {
                    await viewModel.toggleChecked(for: item, didUpdate: { count in
                        await updateUncheckedCount(list.id, count)
                    })
                }
            },
            onTextTap: {
                editingItem = item
                showingEditView = true
            },
            onIncrement: {
                Task {
                    await viewModel.incrementQuantity(for: item)
                }
            },
            onDecrement: {
                Task {
                    let shouldKeep = await viewModel.decrementQuantity(for: item)
                    if !shouldKeep {
                        itemToDelete = item
                    }
                }
            },
            isReadOnly: unifiedList.isReadOnly
        )
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

    // MARK: - Inline Add Row

    @ViewBuilder
    private func inlineAddRow(for labelName: String, color: Color?) -> some View {
        if activeInlineAdd == labelName {
            HStack(spacing: 12) {
                TextField("Item name", text: $inlineAddText)
                    .font(.subheadline)
                    .focused($inlineAddFocused)
                    .onSubmit {
                        addInlineItem(to: labelName)
                    }

                Button {
                    activeInlineAdd = nil
                    inlineAddText = ""
                    inlineAddFocused = false
                } label: {
                    Image(systemName: "xmark")
                        .foregroundColor(.red.opacity(0.75))
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)

                Button {
                    addInlineItem(to: labelName)
                } label: {
                    Image(systemName: "checkmark")
                        .foregroundColor(
                            inlineAddText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? .secondary
                            : .accentColor
                        )
                }
                .buttonStyle(.glass)
                .disabled(inlineAddText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
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
            }
        }
    }

    // MARK: - Add Inline Item

    private func addInlineItem(to labelName: String) {
        let trimmedText = inlineAddText.trimmingCharacters(in: .whitespaces)

        if trimmedText.isEmpty {
            activeInlineAdd = nil
            inlineAddText = ""
            inlineAddFocused = false
            return
        }

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
                    inlineAddFocused = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        inlineAddFocused = true
                    }
                }
            }
        }
    }
}
