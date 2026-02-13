//
//  BackgroundRefreshManager.swift
//  Listie-md
//
//  Manages BGAppRefreshTask for syncing reminder notifications
//  when the app is in the background or terminated.
//
//  List selection strategy:
//  - Priority pool (up to 10): lists that already have pending notifications
//  - Recency pool (up to 20): most recently modified lists
//  - Deduplicates across both pools
//

import BackgroundTasks
import UserNotifications

enum BackgroundRefreshManager {

    static let taskIdentifier = "com.quiteyellow.listiemd.reminderRefresh"

    // MARK: - Registration

    /// Registers the background refresh task handler. Call once at app launch (in AppDelegate).
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            handleBackgroundRefresh(task: refreshTask)
        }
        print("🔄 [BGRefresh] Registered background task: \(taskIdentifier)")
    }

    // MARK: - Scheduling

    /// Minimum interval to avoid iOS throttling (30 minutes)
    private static let minimumInterval: TimeInterval = 30 * 60
    /// Safety buffer before an upcoming reminder (1 hour)
    private static let reminderLeadTime: TimeInterval = 60 * 60
    /// Idle interval when no reminders exist (4 hours)
    private static let idleInterval: TimeInterval = 4 * 60 * 60

    /// Schedules the next background refresh with an adaptive interval.
    /// - When a reminder is approaching: wakes ~1 hour before it to reconcile
    /// - When no reminders are near: long idle interval (4 hours)
    /// - Hard floor of 30 minutes to avoid iOS throttling
    static func scheduleNextRefresh() {
        Task {
            let interval = await calculateNextInterval()
            let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: interval)

            do {
                try BGTaskScheduler.shared.submit(request)
                let minutes = Int(interval / 60)
                print("🔄 [BGRefresh] Scheduled next refresh in ~\(minutes) minutes")
            } catch {
                print("❌ [BGRefresh] Failed to schedule: \(error)")
            }
        }
    }

    /// Calculates the optimal interval until the next background refresh.
    private static func calculateNextInterval() async -> TimeInterval {
        let now = Date()

        // Find the earliest upcoming reminder from pending notifications
        let pendingRequests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let nextReminderDate = pendingRequests
            .filter { $0.identifier.hasPrefix("reminder-") }
            .compactMap { request -> Date? in
                guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { return nil }
                return trigger.nextTriggerDate()
            }
            .filter { $0 > now }
            .min()

        let interval: TimeInterval
        if let nextDate = nextReminderDate {
            // Wake up [leadTime] before the next reminder, but not below the floor
            // and capped at idleInterval so we still catch new reminders from other devices
            let timeUntilReminder = nextDate.timeIntervalSince(now)
            interval = min(idleInterval, max(minimumInterval, timeUntilReminder - reminderLeadTime))
        } else {
            // No upcoming reminders — idle polling
            interval = idleInterval
        }

        return interval
    }

    // MARK: - Handler

    private static func handleBackgroundRefresh(task: BGAppRefreshTask) {
        let workTask = Task {
            await performReminderReconciliation()
            // Schedule next refresh AFTER reconciliation so the interval
            // accounts for any newly discovered/scheduled reminders
            scheduleNextRefresh()
        }

        // If iOS cuts us short, still schedule the next one
        task.expirationHandler = {
            workTask.cancel()
            scheduleNextRefresh()
            print("⚠️ [BGRefresh] Task expired before completion")
        }

        // Wait for completion
        Task {
            _ = await workTask.value
            task.setTaskCompleted(success: true)
            print("✅ [BGRefresh] Task completed successfully")
        }
    }

    // MARK: - Reconciliation Logic

    /// The main background work: load lists, scan for reminders, reconcile notifications.
    @MainActor
    private static func performReminderReconciliation() async {
        print("🔄 [BGRefresh] Starting background reconciliation")

        let provider = UnifiedListProvider()
        await provider.loadAllLists()

        let allLists = provider.allLists
        guard !allLists.isEmpty else {
            print("🔄 [BGRefresh] No lists found, skipping")
            return
        }

        // Select which lists to scan (budget-aware)
        let listsToScan = await selectListsToScan(from: allLists)
        print("🔄 [BGRefresh] Scanning \(listsToScan.count) of \(allLists.count) lists")

        // Collect all reminder items across selected lists
        var allReminderItems: [(item: ShoppingItem, listName: String, listId: String)] = []
        var listsScanned = 0
        var listsFailed = 0

        for list in listsToScan {
            do {
                let items = try await provider.fetchItems(for: list)
                let activeWithReminders = items.filter { !$0.checked && !$0.isDeleted && $0.reminderDate != nil }
                for item in activeWithReminders {
                    allReminderItems.append((item: item, listName: list.summary.name, listId: list.id))
                }
                listsScanned += 1
            } catch {
                listsFailed += 1
                print("⚠️ [BGRefresh] Failed to fetch items for \(list.summary.name): \(error)")
            }
        }

        print("🔄 [BGRefresh] Scanned \(listsScanned) lists (\(listsFailed) failed), found \(allReminderItems.count) reminder items")

        // Reconcile with notification budget
        await ReminderManager.reconcileWithBudget(allItems: allReminderItems, trigger: "background")
    }

    // MARK: - List Selection

    /// Selects up to ~30 lists to scan using the priority + recency strategy.
    private static func selectListsToScan(from allLists: [UnifiedList]) async -> [UnifiedList] {
        // If total lists fit within budget, scan all
        if allLists.count <= 30 {
            return allLists
        }

        // 1. Priority pool: lists that already have pending notifications (up to 10)
        let pendingRequests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let listIdsWithNotifications = Set(
            pendingRequests.compactMap { $0.content.userInfo["listId"] as? String }
        )
        let priorityLists = allLists
            .filter { listIdsWithNotifications.contains($0.id) }
            .prefix(10)
        let priorityIds = Set(priorityLists.map(\.id))

        // 2. Recency pool: 20 most recently modified, excluding priority pool
        let recencyLists = allLists
            .filter { !priorityIds.contains($0.id) }
            .sorted { $0.summary.modifiedAt > $1.summary.modifiedAt }
            .prefix(20)

        return Array(priorityLists) + Array(recencyLists)
    }
}
