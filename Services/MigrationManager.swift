//
//  MigrationManager.swift
//  Listie.md
//
//  Handles data migration from old storage formats to the new unified iCloud-based storage.
//

import Foundation

actor MigrationManager {
    static let shared = MigrationManager()

    // MARK: - Migration Version Tracking

    private let migrationVersionKey = "com.listie.migrationVersion"
    private let currentMigrationVersion = 2  // Version 2 = unified iCloud storage

    /// Tracks which specific lists have been migrated (for resumable migration)
    private let migratedListsKey = "com.listie.migratedLists"

    // MARK: - Public Methods

    /// Runs any pending migrations. Call this on app launch.
    func runMigrationsIfNeeded() async throws {
        let lastMigrationVersion = UserDefaults.standard.integer(forKey: migrationVersionKey)

        if lastMigrationVersion < currentMigrationVersion {
            print("🔄 [Migration] Running migrations from version \(lastMigrationVersion) to \(currentMigrationVersion)")

            // Run migrations in order
            if lastMigrationVersion < 2 {
                try await migrateLocalListsToICloud()
            }

            // Update migration version
            UserDefaults.standard.set(currentMigrationVersion, forKey: migrationVersionKey)
            print("✅ [Migration] Completed all migrations")
        }
    }

    /// Forces re-running migration (for testing or recovery)
    func forceMigration() async throws {
        UserDefaults.standard.removeObject(forKey: migrationVersionKey)
        UserDefaults.standard.removeObject(forKey: migratedListsKey)
        try await runMigrationsIfNeeded()
    }

    // MARK: - Migration v2: Local Lists to iCloud

    /// Migrates old local lists (list_*.json in Documents) to the new iCloud container
    private func migrateLocalListsToICloud() async throws {
        print("🔄 [Migration] Starting local lists migration to iCloud...")

        guard let oldDirectory = iCloudContainerManager.shared.getOldLocalListsDirectory() else {
            print("⚠️ [Migration] Could not find old Documents directory")
            return
        }

        let newDirectory = await iCloudContainerManager.shared.getPrivateListsDirectory()

        // Get already migrated lists
        var migratedLists = getMigratedLists()

        // Find old list files
        let fileManager = FileManager.default
        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: oldDirectory.path)
        } catch {
            print("⚠️ [Migration] Could not read old directory: \(error)")
            return
        }

        let oldListFiles = contents.filter { $0.hasPrefix("list_") && $0.hasSuffix(".json") }

        if oldListFiles.isEmpty {
            print("✅ [Migration] No old lists to migrate")
            return
        }

        print("📦 [Migration] Found \(oldListFiles.count) list(s) to migrate")

        var successCount = 0
        var failCount = 0

        for fileName in oldListFiles {
            // Extract list ID from filename (list_<uuid>.json -> <uuid>)
            let listId = String(fileName.dropFirst(5).dropLast(5))

            // Skip if already migrated
            if migratedLists.contains(listId) {
                print("⏭️ [Migration] Skipping already migrated: \(listId)")
                continue
            }

            let oldURL = oldDirectory.appendingPathComponent(fileName)
            let newURL = newDirectory.appendingPathComponent("\(listId).listie")

            do {
                // Read old file
                let data = try Data(contentsOf: oldURL)

                // Validate it's a valid ListDocument
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let document = try decoder.decode(ListDocument.self, from: data)

                // Write to new location using NSFileCoordinator for safety
                let coordinator = NSFileCoordinator()
                var coordinatorError: NSError?

                coordinator.coordinate(writingItemAt: newURL, options: .forReplacing, error: &coordinatorError) { writeURL in
                    do {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        let newData = try encoder.encode(document)
                        try newData.write(to: writeURL, options: .atomic)
                    } catch {
                        print("❌ [Migration] Failed to write \(listId): \(error)")
                    }
                }

                if let error = coordinatorError {
                    throw error
                }

                // Verify the new file exists and is valid
                let verifyData = try Data(contentsOf: newURL)
                _ = try decoder.decode(ListDocument.self, from: verifyData)

                // Mark as migrated BEFORE deleting old file
                migratedLists.insert(listId)
                saveMigratedLists(migratedLists)

                // Delete old file
                try fileManager.removeItem(at: oldURL)

                print("✅ [Migration] Migrated: \(document.list.name)")
                successCount += 1

            } catch {
                print("❌ [Migration] Failed to migrate \(listId): \(error)")
                failCount += 1
                // Continue with other lists - don't fail the whole migration
            }
        }

        print("📊 [Migration] Complete: \(successCount) succeeded, \(failCount) failed")

        if failCount > 0 {
            print("⚠️ [Migration] Some lists failed to migrate. They remain in the old location.")
        }
    }

    // MARK: - Migration State Tracking

    private func getMigratedLists() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: migratedListsKey),
              let lists = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return lists
    }

    private func saveMigratedLists(_ lists: Set<String>) {
        if let data = try? JSONEncoder().encode(lists) {
            UserDefaults.standard.set(data, forKey: migratedListsKey)
        }
    }

    // MARK: - Rollback Support

    /// Attempts to rollback migration (for recovery scenarios)
    /// This copies files back from iCloud to local, but doesn't delete from iCloud
    func rollbackMigration() async throws {
        print("⏪ [Migration] Starting rollback...")

        guard let oldDirectory = iCloudContainerManager.shared.getOldLocalListsDirectory() else {
            throw MigrationError.rollbackFailed("Could not find Documents directory")
        }

        let newDirectory = await iCloudContainerManager.shared.getPrivateListsDirectory()
        let migratedLists = getMigratedLists()

        let fileManager = FileManager.default

        for listId in migratedLists {
            let newURL = newDirectory.appendingPathComponent("\(listId).listie")
            let oldURL = oldDirectory.appendingPathComponent("list_\(listId).json")

            // Only rollback if new file exists and old doesn't
            if fileManager.fileExists(atPath: newURL.path) && !fileManager.fileExists(atPath: oldURL.path) {
                do {
                    try fileManager.copyItem(at: newURL, to: oldURL)
                    print("✅ [Rollback] Restored: \(listId)")
                } catch {
                    print("❌ [Rollback] Failed to restore \(listId): \(error)")
                }
            }
        }

        // Clear migration state so it will run again
        UserDefaults.standard.removeObject(forKey: migrationVersionKey)
        UserDefaults.standard.removeObject(forKey: migratedListsKey)

        print("✅ [Migration] Rollback complete")
    }

    // MARK: - Error Types

    enum MigrationError: LocalizedError {
        case rollbackFailed(String)

        var errorDescription: String? {
            switch self {
            case .rollbackFailed(let reason):
                return "Migration rollback failed: \(reason)"
            }
        }
    }
}
