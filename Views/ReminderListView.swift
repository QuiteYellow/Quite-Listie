//
//  ReminderListView.swift
//  Listie-md
//
//  Shows reminder items across all lists, filtered by Today or Scheduled
//  Items grouped by due date with full interaction (swipe, context, check-off)
//

import SwiftUI
import UserNotifications

enum ReminderFilter {
    case today      // Overdue + due today
    case scheduled  // Future (not today)
}

struct ReminderListView: View {
    let filter: ReminderFilter
    @ObservedObject var welcomeViewModel: WelcomeViewModel
    @ObservedObject var unifiedProvider: UnifiedListProvider
    @Binding var selectedListID: String?
    @Binding var searchText: String

    @State private var editingItem: ReminderEntry? = nil
    @State private var itemToDelete: ReminderEntry? = nil
    @State private var notificationsDenied = false

    // Cache of ViewModels per list ID for operations
    @State private var viewModelCache: [String: ShoppingListViewModel] = [:]
    @State private var listWidth: CGFloat = 0

    private var title: String {
        filter == .today ? "Today" : "Scheduled"
    }

    private var filteredEntries: [ReminderEntry] {
        let calendar = Calendar.current
        let now = Date()
        let query = searchText.trimmingCharacters(in: .whitespaces)

        return welcomeViewModel.reminderEntries
            .filter { entry in
                guard let date = entry.item.reminderDate else { return false }
                switch filter {
                case .today:
                    return date < now || calendar.isDateInToday(date)
                case .scheduled:
                    // Show all reminders: overdue, today, and future (like Apple Reminders)
                    return true
                }
            }
            .filter { entry in
                guard !query.isEmpty else { return true }
                // Search item text, list name, and label name
                if entry.item.note.localizedCaseInsensitiveContains(query) { return true }
                if entry.list.summary.name.localizedCaseInsensitiveContains(query) { return true }
                if let labelName = entry.labelName,
                   labelName.localizedCaseInsensitiveContains(query) { return true }
                return false
            }
            .sorted { a, b in
                (a.item.reminderDate ?? .distantFuture) < (b.item.reminderDate ?? .distantFuture)
            }
    }

    // MARK: - Date Grouping

    private enum DateGroup: Hashable, Comparable {
        case overdue
        case today
        case tomorrow
        case date(Date)  // Start of day for future dates

        var sortOrder: Int {
            switch self {
            case .overdue: return 0
            case .today: return 1
            case .tomorrow: return 2
            case .date: return 3
            }
        }

        var title: String {
            switch self {
            case .overdue: return "Overdue"
            case .today: return "Today"
            case .tomorrow: return "Tomorrow"
            case .date(let d):
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                return formatter.string(from: d)
            }
        }

        var icon: String {
            switch self {
            case .overdue: return "bell.slash"
            case .today: return "calendar"
            case .tomorrow: return "calendar.badge.clock"
            case .date: return "calendar"
            }
        }

        var color: Color {
            switch self {
            case .overdue: return .red
            case .today: return .orange
            case .tomorrow: return .blue
            case .date: return .secondary
            }
        }

        static func < (lhs: DateGroup, rhs: DateGroup) -> Bool {
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            // Both are .date — compare the actual dates
            if case .date(let ld) = lhs, case .date(let rd) = rhs {
                return ld < rd
            }
            return false
        }
    }

    private func dateGroup(for date: Date) -> DateGroup {
        let calendar = Calendar.current
        let now = Date()

        if date < now && !calendar.isDateInToday(date) {
            return .overdue
        } else if calendar.isDateInToday(date) {
            return .today
        } else if calendar.isDateInTomorrow(date) {
            return .tomorrow
        } else {
            return .date(calendar.startOfDay(for: date))
        }
    }

    private var groupedByDate: [(group: DateGroup, entries: [ReminderEntry])] {
        let grouped = Dictionary(grouping: filteredEntries) { entry in
            dateGroup(for: entry.item.reminderDate ?? .distantFuture)
        }
        return grouped
            .map { (group, entries) in (group: group, entries: entries) }
            .sorted { $0.group < $1.group }
    }

    // MARK: - ViewModel Access

    private func viewModel(for entry: ReminderEntry) -> ShoppingListViewModel {
        if let cached = viewModelCache[entry.list.id] {
            return cached
        }
        let vm = ShoppingListViewModel(list: entry.list, provider: unifiedProvider)
        DispatchQueue.main.async {
            viewModelCache[entry.list.id] = vm
        }
        return vm
    }

    // MARK: - Body

    var body: some View {
        List {
            if notificationsDenied {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.slash.fill")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notifications Disabled")
                                .font(.subheadline.weight(.medium))
                            Text("Reminders won't alert you. Enable in Settings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .listRowBackground(Color.orange.opacity(0.08))
                }
                .listSectionSeparator(.hidden)
            }

            if filteredEntries.isEmpty {
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView(
                        filter == .today ? "No Reminders Today" : "No Scheduled Reminders",
                        systemImage: filter == .today ? "calendar" : "calendar.badge.clock",
                        description: Text("Items with reminders will appear here")
                    )
                }
            } else {
                ForEach(groupedByDate, id: \.group) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            ReminderEntryRow(
                                entry: entry,
                                isReadOnly: entry.list.isReadOnly,
                                onToggle: {
                                    Task { await toggleItem(entry) }
                                },
                                onEdit: {
                                    editingItem = entry
                                },
                                onIncrement: {
                                    Task { await incrementItem(entry) }
                                },
                                onDecrement: {
                                    Task { await decrementItem(entry) }
                                },
                                onDelete: {
                                    itemToDelete = entry
                                },
                                onNavigateToList: {
                                    selectedListID = entry.list.id
                                }
                            )
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: section.group.icon)
                                .foregroundColor(section.group.color)
                            Text(section.group.title)
                                .foregroundColor(section.group.color)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(GeometryReader { geo in
            Color.clear.preference(key: ListWidthPreferenceKey.self, value: geo.size.width)
        })
        .onPreferenceChange(ListWidthPreferenceKey.self) { listWidth = $0 }
        .environment(\.chipsInline, shouldShowChipsInline(
            itemTitles: filteredEntries.map(\.item.note),
            availableWidth: listWidth,
            chipWidth: 220
        ))
        .refreshable {
            await refreshReminders()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(item: $editingItem, onDismiss: {
            Task { await refreshReminders() }
        }) { entry in
            let vm = viewModel(for: entry)
            EditItemView(viewModel: vm, item: entry.item, list: entry.list.summary, unifiedList: entry.list)
        }
        .alert("Delete Item?", isPresented: Binding(
            get: { itemToDelete != nil },
            set: { if !$0 { itemToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let entry = itemToDelete {
                    Task {
                        let vm = viewModel(for: entry)
                        await vm.loadItems()
                        _ = await vm.deleteItem(entry.item)
                        await refreshReminders()
                        itemToDelete = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { itemToDelete = nil }
        } message: {
            Text("Item will be moved to the Recycle Bin and automatically deleted after 30 days.")
        }
        .task {
            await checkNotificationPermission()
            // Pre-load ViewModels for visible lists
            for entry in filteredEntries {
                let vm = viewModel(for: entry)
                await vm.loadItems()
                await vm.loadLabels()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await checkNotificationPermission() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reminderCompleted)) { _ in
            Task { await refreshReminders() }
        }
    }

    // MARK: - Permission Check

    private func checkNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let denied = settings.authorizationStatus == .denied
        await MainActor.run { notificationsDenied = denied }
    }

    // MARK: - Actions

    private func toggleItem(_ entry: ReminderEntry) async {
        let vm = viewModel(for: entry)
        await vm.loadItems()
        await vm.toggleChecked(for: entry.item) { count in
            await MainActor.run {
                welcomeViewModel.uncheckedCounts[entry.list.id] = count
            }
        }
        await refreshReminders()
    }

    private func incrementItem(_ entry: ReminderEntry) async {
        let vm = viewModel(for: entry)
        await vm.loadItems()
        await vm.incrementQuantity(for: entry.item)
        await refreshReminders()
    }

    private func decrementItem(_ entry: ReminderEntry) async {
        let vm = viewModel(for: entry)
        await vm.loadItems()
        let shouldKeep = await vm.decrementQuantity(for: entry.item)
        if !shouldKeep {
            itemToDelete = entry
        } else {
            await refreshReminders()
        }
    }

    private func refreshReminders() async {
        await unifiedProvider.syncAllExternalLists()
        await welcomeViewModel.loadUnifiedCounts(
            for: unifiedProvider.allLists,
            provider: unifiedProvider
        )
    }
}

// MARK: - Reminder Entry Row

private struct ReminderEntryRow: View {
    let entry: ReminderEntry
    let isReadOnly: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    let onDelete: () -> Void
    let onNavigateToList: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ChipAlignedRow {
                HStack(spacing: 12) {
                    if entry.item.quantity > 1 {
                        Text(entry.item.quantity.formatted(.number.precision(.fractionLength(0))))
                            .font(.subheadline)
                            .strikethrough(entry.item.checked && entry.item.quantity >= 2,
                                           color: (entry.item.checked ? .gray : .primary))
                            .foregroundColor(
                                entry.item.quantity < 2 ? Color.clear :
                                    (entry.item.checked ? .gray : .primary)
                            )
                            .frame(minWidth: 12, alignment: .leading)
                    }

                    Text(entry.item.note)
                        .font(.subheadline)
                        .strikethrough(entry.item.checked, color: .gray)
                        .foregroundColor(entry.item.checked ? .gray : .primary)
                        .onTapGesture {
                            onEdit()
                        }
                }
            } chips: {
                HStack(spacing: 6) {
                    if let reminderDate = entry.item.reminderDate, !entry.item.checked {
                        ReminderChipView(
                            reminderDate: reminderDate,
                            isRepeating: entry.item.reminderRepeatRule != nil
                        )
                    }

                    MetadataChip(
                        icon: entry.list.summary.icon ?? "list.bullet",
                        text: entry.list.summary.name,
                        color: .accentColor
                    )

                    if let labelName = entry.labelName {
                        let chipColor = (entry.labelColor.map { Color(hex: $0) } ?? .secondary)
                            .adjusted(forBackground: Color(.systemBackground))
                        MetadataChip(
                            icon: "tag",
                            text: labelName.removingLabelNumberPrefix(),
                            color: chipColor
                        )
                    }
                }
            }

            Spacer()

            if !isReadOnly {
                Button(action: {
                    onToggle()
                }) {
                    Image(systemName: entry.item.checked ? "inset.filled.circle" : "circle")
                        .foregroundColor(entry.item.checked ? .gray : .accentColor)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing) {
            if !isReadOnly {
                Button(role: .none) {
                    onDecrement()
                } label: {
                    Label(entry.item.quantity < 2 ? "Delete" : "Decrease",
                          systemImage: entry.item.quantity < 2 ? "trash" : "minus")
                }
                .tint(entry.item.quantity < 2 ? .red : .orange)
            }
        }
        .swipeActions(edge: .leading) {
            if !isReadOnly {
                Button {
                    onIncrement()
                } label: {
                    Label("Increase", systemImage: "plus")
                }
                .tint(.green)
            }
        }
        .contextMenu {
            Button("Edit Item...") {
                onEdit()
            }

            Button {
                onNavigateToList()
            } label: {
                Label("Go to List", systemImage: "arrow.right.circle")
            }

            Divider()

            Button(role: .none) {
                onDelete()
            } label: {
                Label("Delete Item...", systemImage: "trash")
            }
            .tint(.red)
        }
    }
}

// MARK: - Metadata Chip

private struct MetadataChip: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .foregroundColor(color)
        .clipShape(Capsule())
    }
}

// MARK: - ReminderEntry conformances for sheet binding

extension ReminderEntry: Equatable {
    static func == (lhs: ReminderEntry, rhs: ReminderEntry) -> Bool {
        lhs.item.id == rhs.item.id
    }
}

extension ReminderEntry: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(item.id)
    }
}
