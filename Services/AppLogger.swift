//
//  AppLogger.swift
//  Listie.md
//
//  Centralised os.Logger instances for structured, filterable logging.
//  Logs appear in Console.app but have zero cost when not observed in production.
//

import Foundation
import os

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.quiteyellow.listiemd"

    // Storage & file I/O
    static let iCloud    = Logger(subsystem: subsystem, category: "iCloud")
    static let fileStore = Logger(subsystem: subsystem, category: "FileStore")
    static let cache     = Logger(subsystem: subsystem, category: "Cache")

    // Synchronisation & data
    static let sync      = Logger(subsystem: subsystem, category: "Sync")
    static let merge     = Logger(subsystem: subsystem, category: "Merge")
    static let labels    = Logger(subsystem: subsystem, category: "Labels")
    static let items     = Logger(subsystem: subsystem, category: "Items")

    // Features
    static let reminders = Logger(subsystem: subsystem, category: "Reminders")
    static let markdown  = Logger(subsystem: subsystem, category: "Markdown")
    static let migration = Logger(subsystem: subsystem, category: "Migration")
    static let deeplinks = Logger(subsystem: subsystem, category: "DeepLinks")
    static let background = Logger(subsystem: subsystem, category: "Background")

    // Nextcloud
    static let nextcloud = Logger(subsystem: subsystem, category: "Nextcloud")

    // UI / general
    static let ui        = Logger(subsystem: subsystem, category: "UI")
    static let general   = Logger(subsystem: subsystem, category: "General")
}
