//
//  ReminderManager.swift
//  Listie-md
//
//  Manages local notification scheduling, cancellation, and reconciliation for item reminders
//

import Foundation
import UserNotifications

enum ReminderManager {

    // MARK: - Notification Category

    static let categoryIdentifier = "REMINDER"
    static let completeActionIdentifier = "COMPLETE_REMINDER"

    /// Registers the actionable notification category. Call once at app launch.
    static func registerCategory() {
        let completeAction = UNNotificationAction(
            identifier: completeActionIdentifier,
            title: "Complete",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [completeAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
        print("🔔 Registered notification category with Complete action")
    }

    // MARK: - Permission

    /// Requests notification permission. Returns true if granted.
    static func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            print(granted ? "🔔 Notification permission granted" : "🔕 Notification permission denied")
            return granted
        } catch {
            print("❌ Notification permission error: \(error)")
            return false
        }
    }

    /// Checks if notifications are currently authorized.
    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    /// Ensures notification permission is available.
    /// Only prompts the user if status is `.notDetermined` (first time).
    /// Returns true if authorized, false if denied/restricted.
    static func ensurePermission() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return await requestPermission()
        default:
            return false
        }
    }

    // MARK: - Scheduling

    /// Schedules a local notification for an item's reminder date.
    /// Replaces any existing notification for the same item.
    static func scheduleReminder(for item: ShoppingItem, listName: String, listId: String) {
        guard let reminderDate = item.reminderDate, reminderDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = listName
        content.body = item.quantity > 1
            ? "\(Int(item.quantity)) \(item.note)"
            : item.note
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = [
            "itemId": item.id.uuidString,
            "listId": listId
        ]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: reminderDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: notificationId(for: item),
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to schedule reminder for '\(item.note)': \(error)")
            } else {
                print("🔔 Scheduled reminder for '\(item.note)' at \(reminderDate)")
            }
        }
    }

    // MARK: - Cancellation

    /// Cancels the pending notification for a specific item.
    static func cancelReminder(for item: ShoppingItem) {
        let id = notificationId(for: item)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        print("🔕 Cancelled reminder for '\(item.note)'")
    }

    /// Cancels notifications for multiple items.
    static func cancelReminders(for items: [ShoppingItem]) {
        let ids = items.map { notificationId(for: $0) }
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        print("🔕 Cancelled \(ids.count) reminder(s)")
    }

    // MARK: - Reconciliation

    /// Single-list reconciliation: only cancels stale notifications for checked/deleted/removed items.
    /// Does NOT schedule new ones — that's handled by `reconcileWithBudget` to respect the 64-notification limit.
    static func reconcileCancellations(items: [ShoppingItem], listId: String, pendingIds: Set<String>) {
        var idsToCancel: [String] = []

        for item in items {
            let nId = notificationId(for: item)
            let hasPending = pendingIds.contains(nId)

            if hasPending && (item.checked || item.isDeleted || item.reminderDate == nil) {
                idsToCancel.append(nId)
            }
        }

        if !idsToCancel.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: idsToCancel)
            print("🔄 [Reconcile] Cancelled \(idsToCancel.count) stale notification(s) for list \(listId)")
        }
    }

    /// Legacy per-list reconciliation — kept for backward compatibility with `UnifiedListProvider.syncIfNeeded`.
    static func reconcile(items: [ShoppingItem], listName: String, listId: String) async {
        let pendingRequests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let pendingIds = Set(pendingRequests.map(\.identifier))
        reconcileCancellations(items: items, listId: listId, pendingIds: pendingIds)
    }

    // MARK: - Budget-Aware Reconciliation

    /// Maximum number of notification slots to use (iOS limit is 64, reserve 4 for headroom)
    private static let notificationBudget = 60

    /// Full reconciliation across all lists with budget enforcement.
    /// 1. Cancels notifications for checked/deleted/removed items
    /// 2. Sorts all valid reminder items by date (soonest first)
    /// 3. Schedules the top 60, cancels any beyond that
    /// 4. Logs a complete summary
    static func reconcileWithBudget(
        allItems: [(item: ShoppingItem, listName: String, listId: String)],
        trigger: String
    ) async {
        print("🔔 [Reconcile] Starting budget reconciliation (trigger: \(trigger))")

        // Ensure notification permission before scheduling anything
        let hasPermission = await ensurePermission()
        if !hasPermission {
            print("🔕 [Reconcile] Notification permission not granted — skipping scheduling")
            return
        }

        let center = UNUserNotificationCenter.current()
        let pendingRequests = await center.pendingNotificationRequests()
        let now = Date()

        // Build lookup of currently scheduled reminder notification IDs
        let pendingReminderIds = Set(
            pendingRequests
                .filter { $0.identifier.hasPrefix("reminder-") }
                .map(\.identifier)
        )
        let pendingById = Dictionary(
            pendingRequests.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // All valid reminder items sorted by date (soonest first)
        let validItems = allItems
            .filter { !$0.item.checked && !$0.item.isDeleted && $0.item.reminderDate != nil }
            .sorted { ($0.item.reminderDate ?? .distantFuture) < ($1.item.reminderDate ?? .distantFuture) }

        // Take the top N items that fit within the budget
        let itemsToSchedule = Array(validItems.prefix(notificationBudget))
        let idsToSchedule = Set(itemsToSchedule.map { notificationId(for: $0.item) })

        // 1. Cancel any reminder notifications NOT in the budget window
        let idsToCancel = pendingReminderIds.subtracting(idsToSchedule)
        if !idsToCancel.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(idsToCancel))
        }

        // 2. Schedule items that are in the budget but not yet pending (and in the future)
        var scheduledCount = 0
        for entry in itemsToSchedule {
            let nId = notificationId(for: entry.item)
            if pendingById[nId] == nil, let date = entry.item.reminderDate, date > now {
                scheduleReminder(for: entry.item, listName: entry.listName, listId: entry.listId)
                scheduledCount += 1
            }
        }

        // 3. Summary log
        let overflow = validItems.count - itemsToSchedule.count
        let alreadyScheduled = itemsToSchedule.count - scheduledCount
        let finalPending = alreadyScheduled + scheduledCount

        print("🔔 [Reconcile] Summary (trigger: \(trigger)):")
        print("   📋 Total reminder items found: \(validItems.count)")
        print("   ✅ Already scheduled: \(alreadyScheduled)")
        print("   🆕 Newly scheduled: \(scheduledCount)")
        print("   🗑️ Cancelled (stale/over budget): \(idsToCancel.count)")
        print("   📊 Active notifications: \(finalPending)/\(notificationBudget)")
        if overflow > 0 {
            print("   ⚠️ Deferred (over budget): \(overflow)")
        }
    }

    // MARK: - Repeating Reminders

    /// Calculates the next reminder date based on the repeat rule and mode.
    /// - `fixed` mode: advances from the original reminder date by the rule's interval
    /// - `afterComplete` mode: advances from now by the rule's interval
    /// For fixed mode, keeps advancing until the result is in the future.
    static func nextReminderDate(
        from currentDate: Date?,
        rule: ReminderRepeatRule,
        mode: ReminderRepeatMode
    ) -> Date? {
        let calendar = Calendar.current
        let now = Date()

        let baseDate: Date
        switch mode {
        case .fixed:
            baseDate = currentDate ?? now
        case .afterComplete:
            baseDate = now
        }

        /// Advances a date by the rule once
        func advance(_ date: Date) -> Date? {
            switch rule.unit {
            case .day:
                return calendar.date(byAdding: .day, value: rule.interval, to: date)
            case .week:
                return calendar.date(byAdding: .weekOfYear, value: rule.interval, to: date)
            case .month:
                return calendar.date(byAdding: .month, value: rule.interval, to: date)
            case .year:
                return calendar.date(byAdding: .year, value: rule.interval, to: date)
            case .weekdays:
                return nextWeekday(after: date)
            }
        }

        // For fixed mode, keep advancing until we land in the future
        // This handles the case where the user completes early
        var candidate = advance(baseDate)
        if mode == .fixed {
            while let c = candidate, c <= now {
                candidate = advance(c)
            }
        }

        return candidate
    }

    /// Finds the next weekday (Mon–Fri) after the given date, preserving the time.
    private static func nextWeekday(after date: Date) -> Date? {
        let calendar = Calendar.current
        var candidate = calendar.date(byAdding: .day, value: 1, to: date)!

        // Advance past weekends (Saturday = 7, Sunday = 1)
        while true {
            let weekday = calendar.component(.weekday, from: candidate)
            if weekday >= 2 && weekday <= 6 { break }  // Mon(2)–Fri(6)
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
        }
        return candidate
    }

    // MARK: - Notification Actions

    /// Completes an item directly from a notification action.
    /// Handles repeating reminders (advance to next date) and one-off reminders (check off + clear).
    @MainActor
    static func completeItemFromNotification(itemId: String, listId: String) async {
        print("✅ [Notification] Complete action for item \(itemId) in list \(listId)")

        let provider = UnifiedListProvider()
        await provider.loadAllLists()

        guard let unifiedList = provider.allLists.first(where: { $0.id == listId }) else {
            print("❌ [Notification] List not found: \(listId)")
            return
        }

        do {
            let items = try await provider.fetchItems(for: unifiedList)
            guard let itemUUID = UUID(uuidString: itemId),
                  var item = items.first(where: { $0.id == itemUUID }) else {
                print("❌ [Notification] Item not found: \(itemId)")
                return
            }

            item.modifiedAt = Date()

            if let rule = item.reminderRepeatRule,
               let nextDate = nextReminderDate(
                   from: item.reminderDate,
                   rule: rule,
                   mode: item.reminderRepeatMode ?? .fixed
               ) {
                // Repeating: keep unchecked, advance to next date, reschedule
                item.checked = false
                item.reminderDate = nextDate
                cancelReminder(for: item)
                scheduleReminder(for: item, listName: unifiedList.summary.name, listId: listId)
                print("🔁 [Notification] Repeating reminder advanced to \(nextDate)")
            } else {
                // One-off: check off and clear reminder
                item.checked = true
                item.reminderDate = nil
                cancelReminder(for: item)
                print("✅ [Notification] Item checked off")
            }

            try await provider.updateItem(item, in: unifiedList)
        } catch {
            print("❌ [Notification] Failed to complete item: \(error)")
        }
    }

    // MARK: - Helpers

    /// Consistent notification identifier for an item.
    private static func notificationId(for item: ShoppingItem) -> String {
        "reminder-\(item.id.uuidString)"
    }
}
