//
//  AppLoggerEvents.swift
//  Listie.md
//
//  Structured event names for the sync-resilience pipeline (Layer 5).
//
//  os_log's "message" field is a freeform string by default, which makes Console.app
//  filtering ineffective ("did the session reactivate?" requires substring matching
//  every random log line). These constants give the events stable, greppable names
//  — `subsystem:Nextcloud category:Nextcloud message:event=session.reactivated` filters
//  cleanly. The matching logger calls use them as a `event=` prefix in the message.
//

import Foundation

enum SyncEvent {
    // Session lifecycle (Layer 1)
    static let sessionReactivated     = "session.reactivated"
    static let sessionRefreshDeferred = "session.refresh_deferred"
    static let keychainRetry          = "session.keychain_retry"
    static let iCloudAvailabilityReset = "icloud.availability_reset"

    // Availability classification (Layer 3)
    static let listMarkedTransient = "list.marked_transient"
    static let listMarkedPermanent = "list.marked_permanent"
    static let notFoundDisambiguated = "list.404_disambiguated"

    // Mutation log (Layer 4)
    static let mutationEnqueued        = "mutation.enqueued"
    static let mutationReplayed        = "mutation.replayed"
    static let mutationReplayFailed    = "mutation.replay_failed"
    static let mutationConflictMerged  = "mutation.conflict_merged"

    // iCloud (Layer 1+3)
    static let iCloudDownloadStarted   = "icloud.download_started"
    static let iCloudDownloadCompleted = "icloud.download_completed"
    static let iCloudDownloadTimeout   = "icloud.download_timeout"

    // Health checks (Layer 5)
    static let healthCheckRan          = "health.check_ran"
    static let healthCheckListCount    = "health.list_count"
}
