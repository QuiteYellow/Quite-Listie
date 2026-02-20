//
//  EventKitManager.swift
//  Listie.md
//
//  Manages writing reminder items as native EKEvents into a dedicated "Listie Schedule" calendar.
//  The user can then share that calendar from Calendar.app to get a real webcal:// URL
//  hosted by Apple's iCloud infrastructure — works on iOS, Mac, Google Calendar, etc.
//
//  Events are identified via a local [ShoppingItem.UUID → EKEvent.eventIdentifier] mapping
//  persisted in UserDefaults. This avoids polluting the notes field and correctly handles
//  recurring events (store.event(withIdentifier:) returns the root, not an occurrence).
//

import EventKit
import SwiftUI

@MainActor
class EventKitManager: ObservableObject {

    // MARK: - Singleton

    static let shared = EventKitManager()

    // MARK: - State

    @Published var isEnabled: Bool = false
    @Published var authStatus: EKAuthorizationStatus = .notDetermined
    @Published var calendarExists: Bool = false
    /// Accounts available for calendar creation, sorted best-first.
    @Published var availableSources: [EKSource] = []
    /// The source identifier the user has chosen (or the auto-selected default).
    @Published var selectedSourceId: String? = nil

    /// True when the app has been granted sufficient calendar access.
    var isCalendarAccessGranted: Bool { Self.isAuthorized(authStatus) }

    /// True when calendar access has been explicitly denied or restricted.
    var isCalendarAccessDenied: Bool { authStatus == .denied || authStatus == .restricted }

    // MARK: - Private

    private let store = EKEventStore()
    private let calendarName = "Listie Schedule"
    private let enabledKey = "com.listie.eventkit-enabled"
    private let calendarIdKey = "com.listie.eventkit-calendar-id"
    private let sourceIdKey = "com.listie.eventkit-source-id"
    private let eventMappingKey = "com.listie.eventkit-event-mapping"
    private let bootstrapDoneKey = "com.listie.eventkit-bootstrap-done"

    /// Debounce task for coalescing rapid sync calls.
    private var syncTask: Task<Void, Never>?

    private init() {}

    // MARK: - Event Mapping (UserDefaults-persisted)

    /// Maps ShoppingItem.id.uuidString → EKEvent.eventIdentifier.
    /// Persisted in UserDefaults so we can look up events by ID without enumerating.
    private var eventMapping: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: eventMappingKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: eventMappingKey) }
    }

    // MARK: - Auth Helpers

    /// Returns true if the app currently has sufficient calendar access to read/write events.
    private static func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        if #available(iOS 17.0, macCatalyst 17.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    // MARK: - Lifecycle

    /// Restores persisted enabled state and checks current auth status. Call on app launch.
    func restoreState() async {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        selectedSourceId = UserDefaults.standard.string(forKey: sourceIdKey)
        authStatus = EKEventStore.authorizationStatus(for: .event)
        if Self.isAuthorized(authStatus) {
            loadAvailableSources()
            if isEnabled { calendarExists = findCalendar() != nil }
        }
    }

    /// Populates `availableSources` with usable EKSource accounts, sorted best-first.
    /// Selects a default if `selectedSourceId` is unset or the stored source is gone.
    func loadAvailableSources() {
        let usable = store.sources.filter {
            $0.sourceType == .calDAV || $0.sourceType == .local || $0.sourceType == .exchange
        }.sorted { a, b in
            sourceRank(a) < sourceRank(b)
        }
        availableSources = usable

        if let currentId = selectedSourceId,
           usable.contains(where: { $0.sourceIdentifier == currentId }) {
            // Already valid
        } else {
            selectedSourceId = usable.first?.sourceIdentifier
            if let id = selectedSourceId {
                UserDefaults.standard.set(id, forKey: sourceIdKey)
            }
        }
    }

    /// Ranks a source for display ordering (lower = better).
    private func sourceRank(_ source: EKSource) -> Int {
        if source.sourceType == .calDAV && source.sourceIdentifier.lowercased().contains("icloud") { return 0 }
        if source.sourceType == .calDAV { return 1 }
        if source.sourceType == .exchange { return 2 }
        return 3
    }

    // MARK: - Enable / Disable

    /// Requests calendar permission and enables sync. Call when the user turns on the toggle.
    func requestAccessAndEnable() async {
        do {
            let granted: Bool
            if #available(iOS 17.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await withCheckedThrowingContinuation { continuation in
                    store.requestAccess(to: .event) { ok, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: ok)
                        }
                    }
                }
            }
            authStatus = EKEventStore.authorizationStatus(for: .event)
            if granted {
                loadAvailableSources()
                isEnabled = true
                UserDefaults.standard.set(true, forKey: enabledKey)
                calendarExists = findOrCreateCalendar() != nil
            } else {
                isEnabled = true
                UserDefaults.standard.set(true, forKey: enabledKey)
            }
        } catch {
            authStatus = EKEventStore.authorizationStatus(for: .event)
        }
    }

    /// Disables EventKit sync, removes all managed events, and deletes the calendar.
    func disable() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: enabledKey)

        // Remove all managed events
        let mapping = eventMapping
        for (_, eventId) in mapping {
            if let event = store.event(withIdentifier: eventId) {
                try? store.remove(event, span: .futureEvents)
            }
        }

        // Remove the calendar itself so it doesn't linger as an empty ghost
        if let calendar = findCalendar() {
            try? store.removeCalendar(calendar, commit: false)
        }

        try? store.commit()

        eventMapping = [:]
        UserDefaults.standard.removeObject(forKey: calendarIdKey)
        UserDefaults.standard.set(false, forKey: bootstrapDoneKey)
        calendarExists = false
    }

    // MARK: - Sync (debounced)

    /// Public entry point — debounces rapid calls (e.g. multiple saves in succession).
    func syncIfEnabled(provider: UnifiedListProvider) async {
        syncTask?.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.performSync(provider: provider)
        }
        syncTask = task
        await task.value
    }

    /// The actual sync logic — runs after debounce delay.
    private func performSync(provider: UnifiedListProvider) async {
        guard isEnabled else { return }
        let status = EKEventStore.authorizationStatus(for: .event)
        guard Self.isAuthorized(status) else {
            authStatus = status
            return
        }

        guard let calendar = findOrCreateCalendar() else { return }
        calendarExists = true

        // Collect all active items with reminders across all lists
        var activeItems: [(item: ShoppingItem, listName: String)] = []
        for list in provider.allLists where !list.isUnavailable && !list.isReadOnly {
            if let items = try? await provider.fetchItems(for: list) {
                for item in items where !item.isDeleted && !item.checked && item.reminderDate != nil {
                    activeItems.append((item, list.summary.name))
                }
            }
        }

        let activeIds = Set(activeItems.map { $0.item.id })
        var mapping = eventMapping

        // Bootstrap: one-time enumeration to rebuild mapping on a new device
        // that connects to an existing calendar with events from another device.
        if mapping.isEmpty && !activeItems.isEmpty
            && !UserDefaults.standard.bool(forKey: bootstrapDoneKey) {
            bootstrapMapping(from: calendar, activeItems: activeItems, mapping: &mapping)
            UserDefaults.standard.set(true, forKey: bootstrapDoneKey)
        }

        // Upsert active items — O(1) lookup per item via eventIdentifier
        for entry in activeItems {
            let existing = mapping[entry.item.id.uuidString].flatMap { store.event(withIdentifier: $0) }
            let event = upsertEvent(for: entry.item, listName: entry.listName,
                                     calendar: calendar, existing: existing)
            if let event {
                mapping[entry.item.id.uuidString] = event.eventIdentifier
            } else {
                // Save failed — remove stale mapping so a fresh event is created next time
                mapping.removeValue(forKey: entry.item.id.uuidString)
            }
        }

        // Remove orphans — collect keys first, then remove in a second pass
        let orphanKeys = mapping.keys.filter { uuidStr in
            guard let uuid = UUID(uuidString: uuidStr) else { return true }
            return !activeIds.contains(uuid)
        }
        for key in orphanKeys {
            if let eventId = mapping[key],
               let event = store.event(withIdentifier: eventId) {
                try? store.remove(event, span: .futureEvents)
            }
            mapping.removeValue(forKey: key)
        }

        eventMapping = mapping
        try? store.commit()
    }

    // MARK: - Calendar Management

    /// Returns the existing "Listie Schedule" EKCalendar if it exists, else nil.
    private func findCalendar() -> EKCalendar? {
        if let savedId = UserDefaults.standard.string(forKey: calendarIdKey),
           let calendar = store.calendar(withIdentifier: savedId) {
            return calendar
        }
        return store.calendars(for: .event).first { $0.title == calendarName }
    }

    /// Returns the existing "Listie Schedule" calendar, or creates one on the user-selected source.
    private func findOrCreateCalendar() -> EKCalendar? {
        if let existing = findCalendar() {
            return existing
        }

        let source: EKSource?
        if let chosenId = selectedSourceId {
            source = store.sources.first { $0.sourceIdentifier == chosenId }
        } else {
            source = nil
        }
        let resolvedSource = source
            ?? store.sources.first(where: { $0.sourceType == .calDAV && $0.sourceIdentifier.lowercased().contains("icloud") })
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local })

        guard let resolvedSource else { return nil }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = calendarName
        calendar.source = resolvedSource
        calendar.cgColor = UIColor.systemBlue.cgColor

        do {
            try store.saveCalendar(calendar, commit: true)
            UserDefaults.standard.set(calendar.calendarIdentifier, forKey: calendarIdKey)
            selectedSourceId = resolvedSource.sourceIdentifier
            UserDefaults.standard.set(resolvedSource.sourceIdentifier, forKey: sourceIdKey)
            return calendar
        } catch {
            return nil
        }
    }

    /// Changes the account the "Listie Schedule" calendar lives in.
    func changeSource(to sourceId: String) {
        guard sourceId != selectedSourceId else { return }

        if let old = findCalendar() {
            try? store.removeCalendar(old, commit: true)
        }

        UserDefaults.standard.removeObject(forKey: calendarIdKey)
        UserDefaults.standard.set(false, forKey: bootstrapDoneKey)
        eventMapping = [:]
        calendarExists = false

        selectedSourceId = sourceId
        UserDefaults.standard.set(sourceId, forKey: sourceIdKey)
    }

    // MARK: - Event Management

    /// Creates or updates an EKEvent for the given ShoppingItem. Returns the event on success.
    /// Includes a dirty check — skips the save if no fields have changed.
    @discardableResult
    private func upsertEvent(for item: ShoppingItem, listName: String,
                              calendar: EKCalendar, existing: EKEvent?) -> EKEvent? {
        guard let reminderDate = item.reminderDate else { return nil }

        let event = existing ?? EKEvent(eventStore: store)
        event.calendar = calendar

        // Build expected title
        let title: String
        if item.quantity > 1 {
            let qtyStr = item.quantity.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(item.quantity))
                : String(format: "%.1f", item.quantity)
            title = "\(qtyStr)× \(item.note)"
        } else {
            title = item.note
        }

        // Build expected recurrence
        let isRecurring: Bool
        let expectedRule: EKRecurrenceRule?
        if let rule = item.reminderRepeatRule,
           item.reminderRepeatMode == .fixed,
           let ekRule = ekRecurrenceRule(from: rule) {
            expectedRule = ekRule
            isRecurring = true
        } else {
            expectedRule = nil
            isRecurring = false
        }

        let deeplink = URL(string: "listie://item?id=\(item.id.uuidString)")

        // Dirty check — skip save if existing event already matches all fields.
        // Note: url is intentionally excluded — existing events without a url get it added
        // as a silent one-time migration without causing duplicate event writes.
        if existing != nil {
            let titleMatches = event.title == title
            let startMatches = event.startDate == reminderDate
            let notesMatch = event.notes == item.markdownNotes
            let locationMatches = event.location == listName
            let urlAlreadySet = event.url == deeplink

            // Compare recurrence: both nil, or both have same frequency+interval
            let recurrenceMatches: Bool
            if let existingRule = event.recurrenceRules?.first, let newRule = expectedRule {
                recurrenceMatches = existingRule.frequency == newRule.frequency
                    && existingRule.interval == newRule.interval
            } else {
                recurrenceMatches = event.recurrenceRules?.first == nil && expectedRule == nil
            }

            if titleMatches && startMatches && notesMatch && locationMatches && urlAlreadySet && recurrenceMatches {
                return event // Nothing changed — skip save
            }
        }

        // Apply fields
        event.title = title
        event.startDate = reminderDate
        event.endDate = reminderDate.addingTimeInterval(1200)
        event.isAllDay = false
        event.notes = item.markdownNotes
        event.location = listName
        event.url = deeplink
        event.alarms = [EKAlarm(relativeOffset: 0)]

        if let rule = expectedRule {
            event.recurrenceRules = [rule]
        } else {
            event.recurrenceRules = nil
        }

        do {
            try store.save(event, span: isRecurring ? .futureEvents : .thisEvent)
            return event
        } catch {
            return nil
        }
    }

    // MARK: - Bootstrap (cross-device fallback)

    /// One-time enumeration to rebuild the mapping when it's empty but the calendar has events.
    /// Matches events to items by (title, startDate) pair for disambiguation.
    private func bootstrapMapping(from calendar: EKCalendar,
                                   activeItems: [(item: ShoppingItem, listName: String)],
                                   mapping: inout [String: String]) {
        let start = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date()
        let end   = Calendar.current.date(byAdding: .year, value: 5,  to: Date()) ?? Date()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])

        // Build (title, startDate) → eventIdentifier. First match wins per key.
        struct EventKey: Hashable { let title: String; let startDate: Date }
        var keyToEventId: [EventKey: String] = [:]
        // Also keep a title-only fallback for cases where dates drifted
        var titleToEventId: [String: String] = [:]

        store.enumerateEvents(matching: predicate) { event, _ in
            let key = EventKey(title: event.title, startDate: event.startDate)
            if keyToEventId[key] == nil {
                keyToEventId[key] = event.eventIdentifier
            }
            if titleToEventId[event.title] == nil {
                titleToEventId[event.title] = event.eventIdentifier
            }
        }

        // Track which eventIdentifiers have been claimed to prevent double-mapping
        var claimedEventIds: Set<String> = []

        for entry in activeItems {
            guard let reminderDate = entry.item.reminderDate else { continue }

            let expectedTitle: String
            if entry.item.quantity > 1 {
                let qtyStr = entry.item.quantity.truncatingRemainder(dividingBy: 1) == 0
                    ? String(Int(entry.item.quantity))
                    : String(format: "%.1f", entry.item.quantity)
                expectedTitle = "\(qtyStr)× \(entry.item.note)"
            } else {
                expectedTitle = entry.item.note
            }

            // Prefer (title, date) match, fall back to title-only
            let key = EventKey(title: expectedTitle, startDate: reminderDate)
            let eventId = keyToEventId[key] ?? titleToEventId[expectedTitle]

            if let eventId, !claimedEventIds.contains(eventId) {
                mapping[entry.item.id.uuidString] = eventId
                claimedEventIds.insert(eventId)
            }
        }
    }

    // MARK: - Helpers

    /// Maps a ReminderRepeatRule to an EKRecurrenceRule.
    private func ekRecurrenceRule(from rule: ReminderRepeatRule) -> EKRecurrenceRule? {
        switch rule.unit {
        case .day:
            return EKRecurrenceRule(
                recurrenceWith: .daily,
                interval: rule.interval,
                end: nil
            )
        case .week:
            return EKRecurrenceRule(
                recurrenceWith: .weekly,
                interval: rule.interval,
                end: nil
            )
        case .month:
            return EKRecurrenceRule(
                recurrenceWith: .monthly,
                interval: rule.interval,
                end: nil
            )
        case .year:
            return EKRecurrenceRule(
                recurrenceWith: .yearly,
                interval: rule.interval,
                end: nil
            )
        case .weekdays:
            return EKRecurrenceRule(
                recurrenceWith: .weekly,
                interval: 1,
                daysOfTheWeek: [
                    EKRecurrenceDayOfWeek(.monday),
                    EKRecurrenceDayOfWeek(.tuesday),
                    EKRecurrenceDayOfWeek(.wednesday),
                    EKRecurrenceDayOfWeek(.thursday),
                    EKRecurrenceDayOfWeek(.friday)
                ],
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: nil
            )
        }
    }
}
