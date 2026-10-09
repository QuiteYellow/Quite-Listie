//
//  DocumentMutationConcurrencyTests.swift
//  QuiteListieTests
//
//  Regression cover for the lost-update race behind "tick four items off quickly and
//  one or two pop back checked".
//
//  Every document edit used to be a read-modify-write spread across two suspension
//  points: read the whole `ListDocument` out of a backend actor's cache, mutate one
//  field, write the whole thing back. `@MainActor` isolation does not make an `async`
//  function atomic — it is reentrant at every `await` — so two edits arriving close
//  together both read the same pre-edit document. `ListDocument` is a struct, so each
//  mutated a private copy and the later write discarded the earlier one.
//
//  `FileStore.mutate(source:)` and `NextcloudManager.mutate(remotePath:)` close the
//  window by running read → transform → write-back with no `await` in between, so the
//  actor cannot interleave. These tests drive the real `FileStore` actor over a temp
//  file: the Nextcloud path is the same construction but needs live credentials.
//

import XCTest
@testable import QuiteListie

final class DocumentMutationConcurrencyTests: XCTestCase {

    private var fileURL: URL!

    /// Number of items ticked concurrently. Comfortably above the 4-ish taps that
    /// triggered the bug in practice, to keep the race reproducible on fast hardware.
    private let itemCount = 12

    override func setUpWithError() throws {
        try super.setUpWithError()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutation-race-\(UUID().uuidString)")
            .appendingPathExtension("listie")
        try writeDocument(makeDocument(itemCount: itemCount))
    }

    override func tearDownWithError() throws {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeDocument(itemCount: Int) -> ListDocument {
        let items = (0..<itemCount).map {
            ListItem(note: "Item \($0)", checked: false)
        }
        return ListDocument(
            list: ListSummary(id: UUID().uuidString, name: "Race Test"),
            items: items
        )
    }

    private func writeDocument(_ doc: ListDocument) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(doc).write(to: fileURL, options: .atomic)
    }

    private var source: FileSource { .externalFile(fileURL) }

    private func cachedDocument() async -> ListDocument? {
        await FileStore.shared.getLastKnownDocument(at: fileURL)
    }

    // MARK: - Tests

    /// The headline case: tick every item off at once. Before the fix, concurrent
    /// read-modify-writes clobbered each other and some items stayed unchecked —
    /// which is exactly what the user saw as items "popping back".
    func testConcurrentTicksAreNotLost() async throws {
        let seeded = try await FileStore.shared.mutate(source: source) { _ in true }
        let seed = try XCTUnwrap(seeded)
        let ids = seed.items.map(\.id)
        XCTAssertEqual(ids.count, itemCount)

        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    _ = try? await FileStore.shared.mutate(source: self.source) { doc in
                        guard let index = doc.items.firstIndex(where: { $0.id == id }) else {
                            return false
                        }
                        doc.items[index].checked = true
                        doc.items[index].modifiedAt = Date()
                        doc.items[index].lastChangeField = "checked"
                        return true
                    }
                }
            }
        }

        let cached = await cachedDocument()
        let final = try XCTUnwrap(cached)
        let unchecked = final.items.filter { !$0.checked }
        XCTAssertTrue(
            unchecked.isEmpty,
            "Lost \(unchecked.count) of \(itemCount) ticks: \(unchecked.map(\.note).sorted())"
        )
    }

    /// Interleaved edits to *different* fields of the same document must all survive.
    /// A whole-document write discards concurrent edits regardless of which field they
    /// touched, so this catches a regression that only ever loses non-`checked` fields.
    func testConcurrentEditsToDifferentFieldsAllSurvive() async throws {
        let seeded = try await FileStore.shared.mutate(source: source) { _ in true }
        let seed = try XCTUnwrap(seeded)
        let ids = seed.items.map(\.id)

        await withTaskGroup(of: Void.self) { group in
            // Tick the even items…
            for id in ids.enumerated().filter({ $0.offset.isMultiple(of: 2) }).map(\.element) {
                group.addTask {
                    _ = try? await FileStore.shared.mutate(source: self.source) { doc in
                        guard let i = doc.items.firstIndex(where: { $0.id == id }) else { return false }
                        doc.items[i].checked = true
                        return true
                    }
                }
            }
            // …rename the odd ones at the same time.
            for id in ids.enumerated().filter({ !$0.offset.isMultiple(of: 2) }).map(\.element) {
                group.addTask {
                    _ = try? await FileStore.shared.mutate(source: self.source) { doc in
                        guard let i = doc.items.firstIndex(where: { $0.id == id }) else { return false }
                        doc.items[i].note = "renamed"
                        return true
                    }
                }
            }
            // …and append a label, so a whole-document field races the item array too.
            group.addTask {
                _ = try? await FileStore.shared.mutate(source: self.source) { doc in
                    doc.labels.append(ListLabel(id: "concurrent", name: "Concurrent", color: "#FF0000"))
                    return true
                }
            }
        }

        let cached = await cachedDocument()
        let final = try XCTUnwrap(cached)
        let checked = final.items.filter(\.checked).count
        let renamed = final.items.filter { $0.note == "renamed" }.count
        XCTAssertEqual(checked, (itemCount + 1) / 2, "Lost tick edits")
        XCTAssertEqual(renamed, itemCount / 2, "Lost rename edits")
        XCTAssertTrue(final.labels.contains { $0.id == "concurrent" }, "Lost the label edit")
    }

    /// Item order is array position — there is no per-item sort field — so a mutation
    /// must never reorder the document. Guards against "fixing" a future conflict by
    /// routing writes through a dictionary-based merge, which would scramble the list.
    func testMutationPreservesItemOrder() async throws {
        let seeded = try await FileStore.shared.mutate(source: source) { _ in true }
        let seed = try XCTUnwrap(seeded)
        let originalOrder = seed.items.map(\.id)

        await withTaskGroup(of: Void.self) { group in
            for id in originalOrder {
                group.addTask {
                    _ = try? await FileStore.shared.mutate(source: self.source) { doc in
                        guard let i = doc.items.firstIndex(where: { $0.id == id }) else { return false }
                        doc.items[i].checked = true
                        return true
                    }
                }
            }
        }

        let cached = await cachedDocument()
        let final = try XCTUnwrap(cached)
        XCTAssertEqual(final.items.map(\.id), originalOrder, "Mutation reordered the items")
    }

    /// A transform reporting "nothing changed" must not write, so a no-op edit can't
    /// schedule a pointless upload.
    func testNoOpTransformSkipsTheWrite() async throws {
        _ = try await FileStore.shared.mutate(source: source) { _ in true }
        let beforeCached = await cachedDocument()
        let before = try XCTUnwrap(beforeCached)

        let result = try await FileStore.shared.mutate(source: source) { doc in
            doc.items.removeAll()   // discarded — the transform reports no change
            return false
        }

        XCTAssertNil(result, "mutate should return nil when the transform reports no change")
        let afterCached = await cachedDocument()
        let after = try XCTUnwrap(afterCached)
        XCTAssertEqual(after.items.count, before.items.count, "No-op transform still wrote")
    }

    // MARK: - Merge, as used by the download-path reconciliation
    //
    // `mutate` closes the *edit* side of the race. The *refresh* side stayed open:
    // `NextcloudManager.downloadFile` took the server body wholesale, and its network
    // `await` is a suspension point, so a `mutate` completing in between was discarded
    // from memCache and disk — then read straight back by the `.externalListChanged`
    // reload, which is the item popping back. It now reconciles via
    // `ListDocument.merge` when the cache generation moved while the download was in
    // flight. These cover the merge properties that reconciliation depends on.

    private func fixedItem(_ note: String, checked: Bool = false, offset: TimeInterval = 0) -> ListItem {
        ListItem(note: note, checked: checked, modifiedAt: Date(timeIntervalSince1970: 1_000_000 + offset))
    }

    private func document(_ items: [ListItem]) -> ListDocument {
        ListDocument(list: ListSummary(id: "list-1", name: "Merge Test",
                                       modifiedAt: Date(timeIntervalSince1970: 1_000_000)),
                     items: items)
    }

    /// The reconciliation case itself: a tick lands while the download is in flight, so
    /// the live cache carries it and the server body predates it. The tick must survive.
    func testMergeKeepsAnEditThatLandedDuringADownload() {
        let apple = fixedItem("apple")
        let bread = fixedItem("bread")
        var ticked = apple
        ticked.checked = true
        ticked.modifiedAt = apple.modifiedAt.addingTimeInterval(60)

        let merged = ListDocument.merge(local: document([ticked, bread]),
                                        remote: document([apple, bread]))

        XCTAssertEqual(merged.items.first(where: { $0.note == "apple" })?.checked, true,
                       "The tick was discarded — this is the pop-back")
    }

    /// Item order is user-visible position, so merge must not rebuild the array from its
    /// dictionary. `Array(itemsById.values)` has unspecified order; it reshuffled the
    /// list on every merge, and was the reason this reconciliation was left unfixed.
    func testMergePreservesLocalItemOrderAndAppendsRemoteOnlyItems() {
        let a = fixedItem("apple"), b = fixedItem("bread"), c = fixedItem("cheese")
        let d = fixedItem("dates")

        let merged = ListDocument.merge(local: document([a, b, c]),
                                        remote: document([c, a, b, d]))

        XCTAssertEqual(merged.items.map(\.note), ["apple", "bread", "cheese", "dates"],
                       "Merge reordered items")
    }

    /// Merge is a union keyed on id with no item tombstone, so it can never express a
    /// removal. This is why an authoritative download must still replace the cache
    /// wholesale when nothing changed locally: `cleanupOldDeletedItems` hard-removes
    /// 30-day-old tombstones, and if every download merged, the other device's cache
    /// would resurrect the purged item and re-upload it on every pass.
    func testMergeCannotExpressARemovalSoDownloadsMustStillReplaceWholesale() {
        let a = fixedItem("apple"), b = fixedItem("bread"), purged = fixedItem("cheese")

        let merged = ListDocument.merge(local: document([a, b, purged]),
                                        remote: document([a, b]))

        XCTAssertEqual(merged.items.count, 3,
                       "If merge ever learns item tombstones, revisit downloadFile's wholesale branch")
    }

    /// Merge used to build its result through the memberwise init, which doesn't carry
    /// `_preserved` — so every merge stripped top-level keys written by a newer app
    /// version. Routing the download path through merge would have widened that.
    func testMergeCarriesTopLevelPreservedKeys() {
        var local = document([fixedItem("apple")])
        local._preserved = ["shared": .string("local"), "onlyLocal": .number(1)]
        var remote = document([fixedItem("apple")])
        remote._preserved = ["shared": .string("remote"), "onlyRemote": .bool(true)]

        let merged = ListDocument.merge(local: local, remote: remote)

        XCTAssertEqual(merged._preserved["shared"], .string("local"), "Local should win")
        XCTAssertEqual(merged._preserved["onlyLocal"], .number(1), "Local-only key dropped")
        XCTAssertEqual(merged._preserved["onlyRemote"], .bool(true), "Remote-only key dropped")
    }

    /// Label tombstones must keep working now that labels are also order-preserved.
    func testMergeDropsTombstonedLabelsAndPreservesLabelOrder() {
        let aisle = ListLabel(id: "a", name: "Aisle", color: "red")
        let bakery = ListLabel(id: "b", name: "Bakery", color: "blue")
        let chilled = ListLabel(id: "c", name: "Chilled", color: "green")

        var local = document([])
        local.labels = [aisle, bakery]
        var remote = document([])
        remote.labels = [chilled, aisle, bakery]
        remote.deletedLabelIDs = ["b"]

        let merged = ListDocument.merge(local: local, remote: remote)

        XCTAssertEqual(merged.labels.map(\.id), ["a", "c"],
                       "Tombstoned label resurrected, or label order rebuilt from the dictionary")
    }
}
