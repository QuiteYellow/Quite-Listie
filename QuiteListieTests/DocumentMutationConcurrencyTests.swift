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
}

