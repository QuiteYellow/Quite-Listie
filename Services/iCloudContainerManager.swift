//
//  iCloudContainerManager.swift
//  Listie.md
//
//  Manages access to the app's iCloud ubiquity container for private list storage.
//

import Foundation

actor iCloudContainerManager {
    static let shared = iCloudContainerManager()

    // MARK: - Properties

    private var containerURL: URL?
    private var localFallbackURL: URL?
    private var isICloudAvailable: Bool = false
    private var hasCheckedAvailability: Bool = false

    /// UserDefaults key for iCloud sync setting
    private let iCloudSyncEnabledKey = "iCloudSyncEnabled"

    /// Directory name for private lists
    private let listsDirectoryName = "Lists"

    // MARK: - Initialization

    init() {
        // Set up local fallback directory
        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            localFallbackURL = documentsURL.appendingPathComponent("LocalLists", isDirectory: true)
        }
    }

    // MARK: - Public Methods

    /// Checks if iCloud is available and caches the result
    func checkICloudAvailability() async -> Bool {
        // First, always check for iCloud container availability
        let containerAvailable: Bool
        if let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            containerURL = ubiquityURL.appendingPathComponent("Documents", isDirectory: true)
                                      .appendingPathComponent(listsDirectoryName, isDirectory: true)
            containerAvailable = true

            // Ensure the directory exists
            try? FileManager.default.createDirectory(at: containerURL!, withIntermediateDirectories: true)

            print("☁️ [iCloud] Container available at: \(containerURL!.path)")
        } else {
            containerAvailable = false
            print("⚠️ [iCloud] Container not available")
        }

        // Check if user has disabled iCloud sync in settings
        let syncEnabled = UserDefaults.standard.bool(forKey: iCloudSyncEnabledKey)
        let userExplicitlyDisabled = !syncEnabled && UserDefaults.standard.object(forKey: iCloudSyncEnabledKey) != nil

        if userExplicitlyDisabled {
            // User explicitly disabled sync - use local even if iCloud is available
            isICloudAvailable = false
            hasCheckedAvailability = true
            print("☁️ [iCloud] Sync disabled by user, using local fallback")
            return false
        }

        // Use iCloud if container is available and sync is enabled
        isICloudAvailable = containerAvailable
        hasCheckedAvailability = true

        if !containerAvailable {
            print("⚠️ [iCloud] Using local fallback (container unavailable)")
        }

        return containerAvailable
    }

    /// Returns the directory URL for storing private lists
    /// Uses iCloud container if available, otherwise falls back to local Documents directory
    func getPrivateListsDirectory() async -> URL {
        if !hasCheckedAvailability {
            _ = await checkICloudAvailability()
        }

        if isICloudAvailable, let containerURL = containerURL {
            return containerURL
        }

        // Fallback to local directory
        guard let localURL = localFallbackURL else {
            // Last resort fallback
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            return documentsURL.appendingPathComponent("LocalLists", isDirectory: true)
        }

        // Ensure local directory exists
        try? FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        return localURL
    }

    /// Returns the file URL for a specific list by ID
    func fileURL(for listId: String) async -> URL {
        let directory = await getPrivateListsDirectory()
        return directory.appendingPathComponent("\(listId).listie")
    }

    /// Discovers all list files in the private container
    func discoverListFiles() async throws -> [URL] {
        let directory = await getPrivateListsDirectory()

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        // Filter for .listie files
        let listFiles = contents.filter { $0.pathExtension == "listie" }

        print("📂 [iCloud] Discovered \(listFiles.count) private list(s)")
        return listFiles
    }

    /// Returns whether iCloud sync is currently enabled
    func isICloudSyncEnabled() -> Bool {
        // Default to true if not set
        if UserDefaults.standard.object(forKey: iCloudSyncEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: iCloudSyncEnabledKey)
    }

    /// Sets whether iCloud sync is enabled and migrates files between storage locations
    func setICloudSyncEnabled(_ enabled: Bool) async {
        // Get the current directories BEFORE changing the setting
        let wasUsingICloud = isICloudAvailable

        // Check if iCloud container is actually available
        let iCloudContainerAvailable = FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil

        // Determine source and destination directories
        let sourceDir: URL?
        let destDir: URL?

        if enabled && iCloudContainerAvailable {
            // Moving from local to iCloud
            sourceDir = localFallbackURL
            if let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
                destDir = ubiquityURL.appendingPathComponent("Documents", isDirectory: true)
                                     .appendingPathComponent(listsDirectoryName, isDirectory: true)
            } else {
                destDir = nil
            }
        } else if !enabled && wasUsingICloud {
            // Moving from iCloud to local
            sourceDir = containerURL
            destDir = localFallbackURL
        } else {
            sourceDir = nil
            destDir = nil
        }

        // Migrate files if we have valid source and destination
        if let source = sourceDir, let dest = destDir {
            await migrateFiles(from: source, to: dest)
            // Clear FileStore cache to ensure fresh data is loaded from new location
            await FileStore.shared.clearPrivateListsCache()
        }

        // Now update the setting
        UserDefaults.standard.set(enabled, forKey: iCloudSyncEnabledKey)

        // Re-check availability (this will update based on new setting)
        hasCheckedAvailability = false
        _ = await checkICloudAvailability()

        print("☁️ [iCloud] Sync \(enabled ? "enabled" : "disabled")")
    }

    /// Migrates all .listie files from source to destination directory
    private func migrateFiles(from source: URL, to destination: URL) async {
        let fileManager = FileManager.default

        // Ensure destination exists
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        // Check if source exists and has files
        guard fileManager.fileExists(atPath: source.path) else {
            print("☁️ [Migration] Source directory doesn't exist: \(source.path)")
            return
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            let listFiles = contents.filter { $0.pathExtension == "listie" }

            if listFiles.isEmpty {
                print("☁️ [Migration] No files to migrate")
                return
            }

            print("☁️ [Migration] Migrating \(listFiles.count) file(s) from \(source.lastPathComponent) to \(destination.lastPathComponent)")

            for file in listFiles {
                let destFile = destination.appendingPathComponent(file.lastPathComponent)

                // Skip if file already exists at destination
                if fileManager.fileExists(atPath: destFile.path) {
                    print("☁️ [Migration] Skipping \(file.lastPathComponent) - already exists at destination")
                    continue
                }

                do {
                    // Copy file to destination
                    try fileManager.copyItem(at: file, to: destFile)
                    print("☁️ [Migration] Copied \(file.lastPathComponent)")

                    // Remove from source after successful copy
                    try fileManager.removeItem(at: file)
                    print("☁️ [Migration] Removed original \(file.lastPathComponent)")
                } catch {
                    print("❌ [Migration] Failed to migrate \(file.lastPathComponent): \(error)")
                }
            }

            print("☁️ [Migration] Migration complete")
        } catch {
            print("❌ [Migration] Failed to read source directory: \(error)")
        }
    }

    /// Marks a file as excluded from iCloud backup (local-only)
    func setFileExcludedFromBackup(_ url: URL, excluded: Bool) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = excluded

        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }

    /// Returns the current storage location type for display purposes
    func getStorageLocationDescription() async -> String {
        if !hasCheckedAvailability {
            _ = await checkICloudAvailability()
        }

        if isICloudAvailable {
            return "iCloud"
        } else {
            return "On This Device"
        }
    }

    /// Checks if a URL is in the iCloud container (vs local fallback)
    func isInICloudContainer(_ url: URL) -> Bool {
        guard let containerURL = containerURL else { return false }
        return url.path.hasPrefix(containerURL.path)
    }

    // MARK: - Migration Support

    /// Returns the old Documents directory where V1 lists were stored
    /// This is nonisolated since FileManager is thread-safe
    nonisolated func getOldLocalListsDirectory() -> URL? {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Checks if there are old-format lists that need migration
    /// This is nonisolated since FileManager is thread-safe
    nonisolated func hasOldListsToMigrate() -> Bool {
        guard let oldDirectory = getOldLocalListsDirectory() else { return false }

        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: oldDirectory.path) else {
            return false
        }

        // Look for list_*.json files (old format)
        return contents.contains { $0.hasPrefix("list_") && $0.hasSuffix(".json") }
    }
}
