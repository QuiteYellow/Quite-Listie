//
//  SyncResilienceTests.swift
//  QuiteListieTests
//
//  Contracts for the sync-resilience work (Layers 1-5). Each test exercises a
//  specific guarantee that, if broken, would re-introduce the "lists disconnect
//  after deep sleep" class of bugs. Integration-level tests (URLSession invalidation,
//  ScenePhase, network) are deferred to manual verification on device because the
//  simulator doesn't faithfully reproduce iOS suspension behaviour.
//

import XCTest
@testable import QuiteListie

// MARK: - Layer 3: Severity classification

final class UnavailabilityReasonSeverityTests: XCTestCase {
    func testFileNotFoundIsPermanent() {
        XCTAssertEqual(UnavailableBookmark.UnavailabilityReason.fileNotFound.severity, .permanent)
    }

    func testInTrashIsPermanent() {
        XCTAssertEqual(UnavailableBookmark.UnavailabilityReason.inTrash.severity, .permanent)
    }

    func testBookmarkInvalidIsTransient() {
        let err = NSError(domain: "test", code: 1)
        XCTAssertEqual(UnavailableBookmark.UnavailabilityReason.bookmarkInvalid(err).severity, .transient)
    }

    func testICloudNotDownloadedIsTransient() {
        XCTAssertEqual(UnavailableBookmark.UnavailabilityReason.iCloudNotDownloaded.severity, .transient)
    }
}

// MARK: - Layer 3: UnifiedList state predicates

final class UnifiedListStateTests: XCTestCase {
    private func makeList(reason: UnavailableBookmark.UnavailabilityReason?) -> UnifiedList {
        var list = UnifiedList(
            id: "test-id",
            source: .privateICloud("test-id"),
            summary: ListSummary(id: "test-id", name: "Test"),
            originalFileId: nil,
            isReadOnly: false
        )
        if let reason {
            list.unavailableBookmark = UnavailableBookmark(
                id: "test-id", originalPath: "/tmp/test",
                reason: reason, fileName: "Test", folderName: "Folder"
            )
        }
        return list
    }

    func testNoBookmarkIsNeitherTransientNorPermanent() {
        let list = makeList(reason: nil)
        XCTAssertFalse(list.isUnavailable)
        XCTAssertFalse(list.isPermanentlyUnavailable)
        XCTAssertFalse(list.hasTransientSyncError)
    }

    func testFileNotFoundIsPermanentOnly() {
        let list = makeList(reason: .fileNotFound)
        XCTAssertTrue(list.isUnavailable)
        XCTAssertTrue(list.isPermanentlyUnavailable)
        XCTAssertFalse(list.hasTransientSyncError)
    }

    func testICloudNotDownloadedIsTransientOnly() {
        let list = makeList(reason: .iCloudNotDownloaded)
        XCTAssertTrue(list.isUnavailable)
        XCTAssertFalse(list.isPermanentlyUnavailable)
        XCTAssertTrue(list.hasTransientSyncError)
    }

    func testBookmarkInvalidIsTransientOnly() {
        let err = NSError(domain: "test", code: 1)
        let list = makeList(reason: .bookmarkInvalid(err))
        XCTAssertTrue(list.isUnavailable)
        XCTAssertFalse(list.isPermanentlyUnavailable)
        XCTAssertTrue(list.hasTransientSyncError)
    }
}

// MARK: - Layer 4: Mutation log

final class MutationLogTests: XCTestCase {

    override func setUp() async throws {
        await MutationLog.shared.clear()
        // Default flag off — restore at teardown
        UserDefaults.standard.removeObject(forKey: MutationLog.featureFlagKey)
    }

    override func tearDown() async throws {
        await MutationLog.shared.clear()
        UserDefaults.standard.removeObject(forKey: MutationLog.featureFlagKey)
    }

    func testEnqueueIncreasesDepth() async {
        let entry = MutationEntry(
            listId: "test-list",
            listSource: .privateICloud(listId: "test-list"),
            op: .persistDocument(payload: Data())
        )
        await MutationLog.shared.enqueue(entry)
        let depth = await MutationLog.shared.depth()
        XCTAssertEqual(depth, 1)
    }

    func testMarkCompletedRemovesEntry() async {
        let entry = MutationEntry(
            listId: "test-list",
            listSource: .privateICloud(listId: "test-list"),
            op: .persistDocument(payload: Data())
        )
        await MutationLog.shared.enqueue(entry)
        await MutationLog.shared.markCompleted(entry.id)
        let depth = await MutationLog.shared.depth()
        XCTAssertEqual(depth, 0)
    }

    func testRecordAttemptIncrementsCount() async {
        let entry = MutationEntry(
            listId: "test-list",
            listSource: .privateICloud(listId: "test-list"),
            op: .persistDocument(payload: Data())
        )
        await MutationLog.shared.enqueue(entry)
        let err = NSError(domain: "test", code: 42)
        await MutationLog.shared.recordAttempt(for: entry.id, error: err)

        let snapshot = await MutationLog.shared.snapshot()
        XCTAssertEqual(snapshot.first?.attemptCount, 1)
        XCTAssertEqual(snapshot.first?.lastError, err.localizedDescription)
        XCTAssertNotNil(snapshot.first?.lastAttemptedAt)
    }

    func testFeatureFlagDefaultOff() {
        UserDefaults.standard.removeObject(forKey: MutationLog.featureFlagKey)
        XCTAssertFalse(MutationLog.isEnabled)
    }

    func testFeatureFlagToggle() {
        UserDefaults.standard.set(true, forKey: MutationLog.featureFlagKey)
        XCTAssertTrue(MutationLog.isEnabled)
        UserDefaults.standard.set(false, forKey: MutationLog.featureFlagKey)
        XCTAssertFalse(MutationLog.isEnabled)
    }

    func testEntryCodableRoundTrip() throws {
        let payload = "hello".data(using: .utf8)!
        let original = MutationEntry(
            listId: "abc",
            listSource: .nextcloud(accountId: "u@host", remotePath: "/lists/x.listie"),
            op: .persistDocument(payload: payload)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MutationEntry.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.listId, original.listId)
        if case .nextcloud(let acc, let path) = decoded.listSource {
            XCTAssertEqual(acc, "u@host")
            XCTAssertEqual(path, "/lists/x.listie")
        } else {
            XCTFail("Expected nextcloud source")
        }
    }
}

// MARK: - SaveStatus + error classification

final class SaveStatusClassificationTests: XCTestCase {
    func testFailedAliasMapsToSyncFailed() {
        let aliased: UnifiedListProvider.SaveStatus = .failed("oops")
        XCTAssertEqual(aliased, .syncFailed("oops"))
    }

    func testNetworkErrorClassifiesAsPendingSync() {
        let err = NCError.networkError("connection lost")
        let status = UnifiedListProvider.classifySaveError(err)
        XCTAssertEqual(status, .pendingSync)
    }

    func testNotConnectedClassifiesAsPendingSync() {
        let err = NCError.notConnected
        let status = UnifiedListProvider.classifySaveError(err)
        XCTAssertEqual(status, .pendingSync)
    }

    func testNotFoundClassifiesAsSyncFailed() {
        let err = NCError.notFound("/lists/missing.listie")
        let status = UnifiedListProvider.classifySaveError(err)
        if case .syncFailed = status { /* ok */ } else {
            XCTFail("Expected .syncFailed, got \(status)")
        }
    }

    func testURLErrorClassifiesAsPendingSync() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let status = UnifiedListProvider.classifySaveError(err)
        XCTAssertEqual(status, .pendingSync)
    }

    func testGenericErrorClassifiesAsSyncFailed() {
        let err = NSError(domain: "Unknown", code: 42, userInfo: [NSLocalizedDescriptionKey: "bad"])
        let status = UnifiedListProvider.classifySaveError(err)
        XCTAssertEqual(status, .syncFailed("bad"))
    }
}

// MARK: - Layer 1: Keychain retry

final class NextcloudCredentialsRetryTests: XCTestCase {
    /// Verifies the retry helper at least returns when keychain is empty (default state
    /// in unit-test bundles, which don't have provisioned credentials). The bounded
    /// timing behaviour is exercised indirectly: this completes well within the
    /// 50+100+200ms budget without hanging.
    func testLoadWithRetryReturnsNilWhenAbsentWithinBudget() async {
        let start = Date()
        let result = await NextcloudCredentials.loadWithRetry(attempts: 3, baseDelayMs: 10)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 1.0, "Retry budget should be well under 1s")
    }
}
