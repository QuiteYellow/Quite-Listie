//
//  ReminderManager.swift
//  Listie-md
//
//  Manages local notification scheduling, cancellation, and reconciliation for item reminders
//

import Foundation
import UserNotifications

enum ReminderManager {

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

    /// Reconciles pending notifications against current item states.
    /// Cancels notifications for items that are checked, deleted, or no longer have a reminder.
    /// Re-schedules notifications for items that have a future reminder but no pending notification.
    static func reconcile(items: [ShoppingItem], listName: String, listId: String) async {
        let center = UNUserNotificationCenter.current()
        let pendingRequests = await center.pendingNotificationRequests()

        // Build a set of notification IDs we currently have scheduled
        let pendingIds = Set(pendingRequests.map(\.identifier))

        var idsToCancel: [String] = []

        for item in items {
            let nId = notificationId(for: item)
            let hasPending = pendingIds.contains(nId)

            if item.checked || item.isDeleted || item.reminderDate == nil {
                // Item no longer needs a reminder — cancel if scheduled
                if hasPending {
                    idsToCancel.append(nId)
                }
            } else if let date = item.reminderDate, date > Date() {
                // Item has a future reminder — schedule if not already pending
                if !hasPending {
                    scheduleReminder(for: item, listName: listName, listId: listId)
                }
            }
        }

        if !idsToCancel.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: idsToCancel)
            print("🔄 Reconciliation: cancelled \(idsToCancel.count) stale reminder(s)")
        }
    }

    // MARK: - Repeating Reminders

    /// Calculates the next reminder date based on the repeat interval and mode.
    /// - `fixed` mode: advances from the original reminder date by one interval
    /// - `afterComplete` mode: advances from now by one interval
    static func nextReminderDate(
        from currentDate: Date?,
        interval: ReminderRepeatInterval,
        mode: ReminderRepeatMode
    ) -> Date? {
        guard interval != .none else { return nil }

        let baseDate: Date
        switch mode {
        case .fixed:
            // Advance from the original reminder date (or now if nil)
            baseDate = currentDate ?? Date()
        case .afterComplete:
            // Always advance from now
            baseDate = Date()
        }

        let calendar = Calendar.current
        switch interval {
        case .none:
            return nil
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: baseDate)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: baseDate)
        case .biweekly:
            return calendar.date(byAdding: .weekOfYear, value: 2, to: baseDate)
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: baseDate)
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: baseDate)
        }
    }

    // MARK: - Helpers

    /// Consistent notification identifier for an item.
    private static func notificationId(for item: ShoppingItem) -> String {
        "reminder-\(item.id.uuidString)"
    }
}
