//
//  EventKitManager.swift
//  Listie.md
//
//  Manages writing reminder items as native EKEvents into a dedicated "Listie Schedule" calendar.
//  The user can then share that calendar from Calendar.app to get a real webcal:// URL
//  hosted by Apple's iCloud infrastructure — works on iOS, Mac, Google Calendar, etc.
//
//  Events are identified via the event's URL field (quitelistie://item?id=<UUID>), which syncs
//  via iCloud and is readable on every device. A local [UUID → eventIdentifier] cache in
//  UserDefaults is rebuilt from this URL each sync, preventing cross-device duplication.
//

import EventKit
import SwiftUI

@Observable
@MainActor
class EventKitManager {

    // MARK: - Singleton

    static let shared = EventKitManager()

    // MARK: - State

    var isEnabled: Bool = false
    var authStatus: EKAuthorizationStatus = .notDetermined
    var calendarExists: Bool = false
    /// Accounts available for calendar creation, sorted best-first.
    var availableSources: [EKSource] = []
    /// The source identifier the user has chosen (or the auto-selected default).
    var selectedSourceId: String? = nil

    /// True when the app has been granted sufficient calendar access.
    var isCalendarAccessGranted: Bool { Self.isAuthorized(authStatus) }

    /// True when calendar access has been explicitly denied or restricted.
    var isCalendarAccessDenied: Bool { authStatus == .denied || authStatus == .restricted }

    // MARK: - Private

    private let store = EKEventStore()
    private let calendarName = "Quite Listie Schedule"
    private let enabledKey = "com.listie.eventkit-enabled"
    private let calendarIdKey = "com.listie.eventkit-calendar-id"
    private let sourceIdKey = "com.listie.eventkit-source-id"
    private let eventMappingKey = "com.listie.eventkit-event-mapping"
    private let calendarMigratedKey = "com.listie.eventkit-calendar-renamed-v1"

    /// Debounce task for coalescing rapid sync calls.
    private var syncTask: Task<Void, Never>?

    private init() {
        // EKEventStoreChanged fires for our own commits too. Do NOT clear eventMapping here —
        // doing so races with the mapping we just saved in performSync and causes the next
        // sync to create duplicate events. rebuildMappingFromCalendar already handles stale
        // entries by validating each externalId against findEvent(externalId:).
    }

    // MARK: - Event Mapping (UserDefaults-persisted)

    /// Maps ShoppingItem.id.uuidString → EKEvent.calendarItemExternalIdentifier.
    /// calendarItemExternalIdentifier is identical on every device for the same iCloud event,
    /// unlike eventIdentifier which is device-local. Storing the external ID means Device B
    /// can look up an event created by Device A without a second reconciliation pass.
    private var eventMapping: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: eventMappingKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: eventMappingKey) }
    }

    /// Looks up a Listie event by its calendarItemExternalIdentifier, preferring the series root.
    private func findEvent(externalId: String) -> EKEvent? {
        let matches = store.calendarItems(withExternalIdentifier: externalId).compactMap { $0 as? EKEvent }
        return matches.first(where: { !$0.isDetached }) ?? matches.first
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
            migrateCalendarNameIfNeeded()
            if isEnabled { calendarExists = findCalendar() != nil }
        }
    }

    /// One-time migration: renames a legacy "Listie Schedule" calendar to "Quite Listie Schedule".
    private func migrateCalendarNameIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: calendarMigratedKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: calendarMigratedKey) }

        let oldName = "Listie Schedule"
        guard let calendar = store.calendars(for: .event).first(where: { $0.title == oldName }),
              calendar.allowsContentModifications else { return }

        calendar.title = calendarName
        try? store.saveCalendar(calendar, commit: true)

        // Re-persist the identifier in case it changed after save
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: calendarIdKey)
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
        for (_, externalId) in mapping {
            if let event = findEvent(externalId: externalId) {
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

        // Scan the calendar to: (a) recover mappings from synced event URLs on devices that
        // don't have them locally yet, (b) delete duplicates for the same UUID keeping newest,
        // (c) validate existing mapping entries are still pointing at the right event.
        rebuildMappingFromCalendar(calendar, mapping: &mapping)

        // Upsert active items — O(1) lookup per item via cross-device external identifier
        for entry in activeItems {
            let existing = mapping[entry.item.id.uuidString].flatMap { findEvent(externalId: $0) }
            let event = upsertEvent(for: entry.item, listName: entry.listName,
                                     calendar: calendar, existing: existing)
            if let event, let externalId = event.calendarItemExternalIdentifier {
                mapping[entry.item.id.uuidString] = externalId
            } else {
                // Save failed or no external ID yet — remove so a fresh event is created next time
                mapping.removeValue(forKey: entry.item.id.uuidString)
            }
        }

        // Remove orphans — collect keys first, then remove in a second pass
        let orphanKeys = mapping.keys.filter { uuidStr in
            guard let uuid = UUID(uuidString: uuidStr) else { return true }
            return !activeIds.contains(uuid)
        }
        for key in orphanKeys {
            if let externalId = mapping[key],
               let event = findEvent(externalId: externalId) {
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
        calendar.cgColor = UIColor(white: 0.55, alpha: 1).cgColor

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

        // Build expected recurrence — only .fixed repeat mode maps to a calendar recurrence rule.
        // "after completed" items advance their date on check-off in Listie itself, so they are
        // stored as plain (non-recurring) events in the calendar.
        let expectedRule: EKRecurrenceRule?
        if let rule = item.reminderRepeatRule,
           item.reminderRepeatMode == .fixed,
           let ekRule = ekRecurrenceRule(from: rule) {
            expectedRule = ekRule
        } else {
            expectedRule = nil
        }

        // For a recurring series, always operate on the root event rather than an occurrence.
        // Saving an occurrence with .futureEvents splits the series, producing a new
        // eventIdentifier each time — which is the root cause of cross-device duplication.
        let resolvedEvent: EKEvent
        if let existing {
            if existing.isDetached || (existing.recurrenceRules?.isEmpty == false),
               let rootId = existing.calendarItemExternalIdentifier,
               let root = findEvent(externalId: rootId) {
                // Use the series root so we never mutate a detached occurrence.
                resolvedEvent = root
            } else {
                resolvedEvent = existing
            }
        } else {
            resolvedEvent = event  // newly created EKEvent
        }

        let deeplink = URL(string: "quitelistie://item?id=\(item.id.uuidString)")

        // Dirty check — skip save if the resolved event already matches all fields.
        // url is intentionally excluded so existing events without one get it added silently.
        if existing != nil {
            let titleMatches = resolvedEvent.title == title
            let startMatches = resolvedEvent.startDate == reminderDate
            let notesMatch = resolvedEvent.notes == item.markdownNotes
            let locationMatches = resolvedEvent.location == listName
            let urlAlreadySet = resolvedEvent.url == deeplink

            let recurrenceMatches: Bool
            if let existingRule = resolvedEvent.recurrenceRules?.first, let newRule = expectedRule {
                recurrenceMatches = existingRule.frequency == newRule.frequency
                    && existingRule.interval == newRule.interval
            } else {
                recurrenceMatches = resolvedEvent.recurrenceRules?.first == nil && expectedRule == nil
            }

            if titleMatches && startMatches && notesMatch && locationMatches && urlAlreadySet && recurrenceMatches {
                return resolvedEvent // Nothing changed — skip save
            }
        }

        // Apply fields to the resolved (root) event
        resolvedEvent.title = title
        resolvedEvent.startDate = reminderDate
        resolvedEvent.endDate = reminderDate.addingTimeInterval(1200)
        resolvedEvent.isAllDay = false
        resolvedEvent.notes = item.markdownNotes
        resolvedEvent.location = listName
        resolvedEvent.url = deeplink
        resolvedEvent.alarms = []  // No alerts — Listie's own notification handles that

        if let rule = expectedRule {
            resolvedEvent.recurrenceRules = [rule]
        } else {
            resolvedEvent.recurrenceRules = nil
        }

        // Always save with .thisEvent — we are already on the root event, so this updates
        // the whole series without splitting it or minting a new eventIdentifier.
        do {
            try store.save(resolvedEvent, span: .thisEvent)
            return resolvedEvent
        } catch {
            return nil
        }
    }

    // MARK: - Mapping Recovery & Deduplication

    /// Scans the calendar for all Listie events, deduplicates any that share the same item UUID
    /// (keeping the most recently modified), then rebuilds missing mapping entries.
    ///
    /// This is the source-of-truth pass that runs every sync. Because event.url syncs via iCloud
    /// it is readable on every device, making this approach robust across the whole device fleet.
    private func rebuildMappingFromCalendar(_ calendar: EKCalendar, mapping: inout [String: String]) {
        let start = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date()
        let end   = Calendar.current.date(byAdding: .year, value: 5,  to: Date()) ?? Date()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])

        // Collect ALL events per UUID — keyed by calendarItemExternalIdentifier (cross-device stable).
        // enumerateEvents uses an escaping closure so we build locally and apply afterwards.
        // Value: array of (externalIdentifier, eventIdentifier, lastModifiedDate)
        struct EventCandidate { let externalId: String; let eventId: String; let modified: Date }
        var candidates: [String: [EventCandidate]] = [:]
        store.enumerateEvents(matching: predicate) { event, _ in
            guard let url = event.url,
                  url.scheme == "listie",
                  url.host == "item",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let uuidStr = components.queryItems?.first(where: { $0.name == "id" })?.value,
                  let externalId = event.calendarItemExternalIdentifier
            else { return }
            let modified = event.lastModifiedDate ?? event.creationDate ?? Date.distantPast
            candidates[uuidStr, default: []].append(
                EventCandidate(externalId: externalId, eventId: event.eventIdentifier, modified: modified)
            )
        }

        // For each UUID, keep the newest event and delete all older duplicates.
        var needsCommit = false
        for (uuidStr, events) in candidates {
            guard events.count > 1 else {
                // No duplicates — fill in a missing mapping entry with the external identifier.
                if mapping[uuidStr] == nil {
                    mapping[uuidStr] = events[0].externalId
                }
                continue
            }

            // Sort newest-first, keep index 0, delete the rest.
            let sorted = events.sorted { $0.modified > $1.modified }
            mapping[uuidStr] = sorted[0].externalId

            for duplicate in sorted.dropFirst() {
                if let event = store.event(withIdentifier: duplicate.eventId) {
                    try? store.remove(event, span: .futureEvents, commit: false)
                    needsCommit = true
                }
            }
        }

        if needsCommit {
            try? store.commit()
        }

        // Validate existing mapping entries — confirm each external ID still resolves to
        // an event whose URL encodes the expected UUID. Clear stale entries so upsert
        // creates a fresh event rather than failing silently.
        for (uuidStr, externalId) in mapping {
            guard let event = findEvent(externalId: externalId) else {
                mapping.removeValue(forKey: uuidStr)
                continue
            }
            if let url = event.url,
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let storedUUID = components.queryItems?.first(where: { $0.name == "id" })?.value,
               storedUUID == uuidStr {
                // Valid — leave as-is.
            } else {
                mapping.removeValue(forKey: uuidStr)
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
