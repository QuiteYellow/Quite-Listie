//
//  ListieTests.swift
//  Listie-mdTests
//
//  Unit tests for pure-logic components: parser, generator, model helpers, reminder logic, and label sorting.
//

import XCTest
@testable import QuiteListie

final class MarkdownListParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParseSimpleUncheckedItem() {
        let md = "- [ ] Apples"
        let result = MarkdownListParser.parse(md)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].note, "Apples")
        XCTAssertFalse(result.items[0].checked)
        XCTAssertEqual(result.items[0].quantity, 1.0)
    }

    func testParseCheckedItem() {
        let md = "- [x] Milk"
        let result = MarkdownListParser.parse(md)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].note, "Milk")
        XCTAssertTrue(result.items[0].checked)
    }

    func testParseCheckedItemUppercase() {
        let md = "- [X] Butter"
        let result = MarkdownListParser.parse(md)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(result.items[0].checked)
    }

    func testParseBulletItemWithoutCheckbox() {
        let md = "- Bread"
        let result = MarkdownListParser.parse(md)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].note, "Bread")
        XCTAssertFalse(result.items[0].checked)
    }

    func testParseAsteriskBullet() {
        let md = "* Eggs"
        let result = MarkdownListParser.parse(md)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].note, "Eggs")
    }

    func testParsePlusBullet() {
        let md = "+ Cheese"
        let result = MarkdownListParser.parse(md)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].note, "Cheese")
    }

    func testParseNumberedList() {
        let md = "1. Flour\n2. Sugar"
        let result = MarkdownListParser.parse(md)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items[0].note, "Flour")
        XCTAssertEqual(result.items[1].note, "Sugar")
    }

    // MARK: - Quantity Parsing

    func testParseQuantityPrefix() {
        let md = "- [ ] 3 Apples"
        let result = MarkdownListParser.parse(md)
        XCTAssertEqual(result.items[0].quantity, 3.0)
        XCTAssertEqual(result.items[0].note, "Apples")
    }

    func testParseDecimalQuantity() {
        let md = "- [ ] 2.5 lbs flour"
        let result = MarkdownListParser.parse(md)
        XCTAssertEqual(result.items[0].quantity, 2.5)
        XCTAssertEqual(result.items[0].note, "lbs flour")
    }

    func testNoQuantityDefaultsToOne() {
        let md = "- [ ] Tomatoes"
        let result = MarkdownListParser.parse(md)
        XCTAssertEqual(result.items[0].quantity, 1.0)
    }

    // MARK: - Label (Heading) Parsing

    func testHeadingBecomesLabel() {
        let md = "## Produce\n- [ ] Apples\n- [ ] Bananas"
        let result = MarkdownListParser.parse(md, listTitle: nil)
        // The first heading with no listTitle and i >= 5 would not be skipped,
        // but since i < 5 and !skippedFirstHeading, it's skipped as title.
        // With a listTitle that doesn't match, it becomes a label.
        let result2 = MarkdownListParser.parse(md, listTitle: "Groceries")
        XCTAssertEqual(result2.items.count, 2)
        XCTAssertEqual(result2.items[0].labelName, "Produce")
        XCTAssertEqual(result2.items[1].labelName, "Produce")
        XCTAssertTrue(result2.labelNames.contains("Produce"))
    }

    func testListTitleHeadingIsSkipped() {
        let md = "# My Grocery List\n## Produce\n- [ ] Apples"
        let result = MarkdownListParser.parse(md, listTitle: "My Grocery List")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].labelName, "Produce")
        XCTAssertFalse(result.labelNames.contains("My Grocery List"))
    }

    func testItemsWithNoLabelHaveNilLabelName() {
        let md = "- [ ] Milk"
        let result = MarkdownListParser.parse(md, listTitle: "List")
        XCTAssertNil(result.items[0].labelName)
    }

    func testMultipleLabels() {
        let md = "# Title\n## Dairy\n- [ ] Milk\n## Produce\n- [ ] Apples"
        let result = MarkdownListParser.parse(md, listTitle: "Title")
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items[0].labelName, "Dairy")
        XCTAssertEqual(result.items[1].labelName, "Produce")
        XCTAssertEqual(result.labelNames.count, 2)
    }

    // MARK: - Sub-items (Markdown Notes)

    func testSubItemsBecomesMarkdownNotes() {
        let md = "- [ ] Shopping\n  - Apples\n  - Bananas"
        let result = MarkdownListParser.parse(md, listTitle: "List")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertNotNil(result.items[0].markdownNotes)
        XCTAssertTrue(result.items[0].markdownNotes!.contains("Apples"))
        XCTAssertTrue(result.items[0].markdownNotes!.contains("Bananas"))
    }

    func testNoSubItemsMeansNilMarkdownNotes() {
        let md = "- [ ] Milk"
        let result = MarkdownListParser.parse(md, listTitle: "List")
        XCTAssertNil(result.items[0].markdownNotes)
    }

    func testEmptyMarkdownReturnsNoItems() {
        let result = MarkdownListParser.parse("")
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.labelNames.isEmpty)
    }

    func testMarkdownWithOnlyHeadingReturnsNoItems() {
        let result = MarkdownListParser.parse("## Section", listTitle: "Other")
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.labelNames.contains("Section"))
    }
}

// MARK: -

final class MarkdownListGeneratorTests: XCTestCase {

    private func makeItem(note: String, quantity: Double = 1, checked: Bool = false, labelId: String? = nil, markdownNotes: String? = nil) -> ListItem {
        ListItem(id: UUID(), note: note, quantity: quantity, checked: checked, labelId: labelId, markdownNotes: markdownNotes)
    }

    private func makeLabel(id: String, name: String, color: String = "#FF0000") -> ListLabel {
        ListLabel(id: id, name: name, color: color)
    }

    // MARK: - Basic Generation

    func testGeneratesListTitle() {
        let result = MarkdownListGenerator.generate(listName: "Groceries", items: [], labels: [])
        XCTAssertTrue(result.markdown.hasPrefix("# Groceries\n"))
    }

    func testEmptyListActiveOnly() {
        let item = makeItem(note: "Milk", checked: true)
        let result = MarkdownListGenerator.generate(listName: "List", items: [item], labels: [], activeOnly: true)
        XCTAssertTrue(result.markdown.contains("All items are checked!"))
    }

    func testEmptyListNotActiveOnly() {
        let result = MarkdownListGenerator.generate(listName: "List", items: [], labels: [], activeOnly: false)
        XCTAssertTrue(result.markdown.contains("This list is empty."))
    }

    func testCheckedItemHasXCheckbox() {
        let item = makeItem(note: "Milk", checked: true)
        let result = MarkdownListGenerator.generate(listName: "List", items: [item], labels: [])
        XCTAssertTrue(result.markdown.contains("- [x] Milk"))
    }

    func testUncheckedItemHasEmptyCheckbox() {
        let item = makeItem(note: "Bread")
        let result = MarkdownListGenerator.generate(listName: "List", items: [item], labels: [])
        XCTAssertTrue(result.markdown.contains("- [ ] Bread"))
    }

    func testQuantityPrefixWhenGreaterThanOne() {
        let item = makeItem(note: "Apples", quantity: 3)
        let result = MarkdownListGenerator.generate(listName: "List", items: [item], labels: [])
        XCTAssertTrue(result.markdown.contains("- [ ] 3 Apples"))
    }

    func testNoQuantityPrefixWhenOne() {
        let item = makeItem(note: "Milk", quantity: 1)
        let result = MarkdownListGenerator.generate(listName: "List", items: [item], labels: [])
        XCTAssertTrue(result.markdown.contains("- [ ] Milk"))
        XCTAssertFalse(result.markdown.contains("- [ ] 1 Milk"))
    }

    func testActiveOnlyFiltersCheckedItems() {
        let unchecked = makeItem(note: "Bread")
        let checked = makeItem(note: "Milk", checked: true)
        let result = MarkdownListGenerator.generate(listName: "List", items: [unchecked, checked], labels: [], activeOnly: true)
        XCTAssertTrue(result.markdown.contains("Bread"))
        XCTAssertFalse(result.markdown.contains("Milk"))
    }

    func testItemsGroupedByLabel() {
        let labelId = "dairy-id"
        let label = makeLabel(id: labelId, name: "Dairy")
        let milkItem = makeItem(note: "Milk", labelId: labelId)
        let breadItem = makeItem(note: "Bread")
        let result = MarkdownListGenerator.generate(listName: "List", items: [milkItem, breadItem], labels: [label])
        XCTAssertTrue(result.markdown.contains("## Dairy"))
        XCTAssertTrue(result.markdown.contains("## No Label"))
    }

    func testNoWarningsForCleanItems() {
        let item = makeItem(note: "Apples")
        let result = MarkdownListGenerator.generate(listName: "List", items: [item], labels: [])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: - isExportableLine

    func testBlockquoteNotExportable() {
        XCTAssertFalse(MarkdownListGenerator.isExportableLine("> quote"))
    }

    func testCodeFenceNotExportable() {
        XCTAssertFalse(MarkdownListGenerator.isExportableLine("```swift"))
    }

    func testHorizontalRuleNotExportable() {
        XCTAssertFalse(MarkdownListGenerator.isExportableLine("---"))
        XCTAssertFalse(MarkdownListGenerator.isExportableLine("***"))
        XCTAssertFalse(MarkdownListGenerator.isExportableLine("___"))
    }

    func testTableNotExportable() {
        XCTAssertFalse(MarkdownListGenerator.isExportableLine("| col1 | col2 |"))
    }

    func testEmptyLineNotExportable() {
        XCTAssertFalse(MarkdownListGenerator.isExportableLine(""))
        XCTAssertFalse(MarkdownListGenerator.isExportableLine("   "))
    }

    func testRegularTextIsExportable() {
        XCTAssertTrue(MarkdownListGenerator.isExportableLine("Some text"))
        XCTAssertTrue(MarkdownListGenerator.isExportableLine("- list item"))
        XCTAssertTrue(MarkdownListGenerator.isExportableLine("## Heading"))
    }

    // MARK: - imageToLink

    func testImageToLinkConversion() {
        let result = MarkdownListGenerator.imageToLink("![alt text](https://example.com/img.png)")
        XCTAssertEqual(result, "[alt text](https://example.com/img.png)")
    }

    func testImageToLinkEmptyAlt() {
        let result = MarkdownListGenerator.imageToLink("![](https://example.com/img.png)")
        XCTAssertEqual(result, "[Image link](https://example.com/img.png)")
    }

    func testImageToLinkReturnNilForNonImage() {
        XCTAssertNil(MarkdownListGenerator.imageToLink("Regular text"))
        XCTAssertNil(MarkdownListGenerator.imageToLink("[link](url)"))
    }

    // MARK: - headingLevel

    func testHeadingLevelDetection() {
        XCTAssertEqual(MarkdownListGenerator.headingLevel("# H1"), 1)
        XCTAssertEqual(MarkdownListGenerator.headingLevel("## H2"), 2)
        XCTAssertEqual(MarkdownListGenerator.headingLevel("###### H6"), 6)
    }

    func testHeadingLevelRequiresSpace() {
        XCTAssertNil(MarkdownListGenerator.headingLevel("#NoSpace"))
    }

    func testNonHeadingReturnsNil() {
        XCTAssertNil(MarkdownListGenerator.headingLevel("Regular text"))
        XCTAssertNil(MarkdownListGenerator.headingLevel("- list"))
    }

    // MARK: - headingText

    func testHeadingTextExtraction() {
        XCTAssertEqual(MarkdownListGenerator.headingText("# Hello World"), "Hello World")
        XCTAssertEqual(MarkdownListGenerator.headingText("## Section Name"), "Section Name")
    }
}

// MARK: -

final class SortedLabelNamesTests: XCTestCase {

    private func makeLabel(id: String, name: String) -> ListLabel {
        ListLabel(id: id, name: name, color: "#000000")
    }

    func testAlphabeticalSortWithNoOrder() {
        let labels = [makeLabel(id: "b", name: "Bakery"), makeLabel(id: "a", name: "Apples")]
        let names = labels.map { $0.name }
        let result = sortedLabelNames(names, labels: labels, labelOrder: nil)
        XCTAssertEqual(result, ["Apples", "Bakery"])
    }

    func testNoLabelIsAlwaysLast() {
        let labels = [makeLabel(id: "a", name: "Apples")]
        let names = ["No Label", "Apples"]
        let result = sortedLabelNames(names, labels: labels, labelOrder: nil)
        XCTAssertEqual(result.last, "No Label")
    }

    func testCustomOrderIsRespected() {
        let labelA = makeLabel(id: "id-a", name: "AAA")
        let labelB = makeLabel(id: "id-b", name: "BBB")
        let labels = [labelA, labelB]
        let names = ["AAA", "BBB"]
        // Custom order: BBB first, then AAA
        let result = sortedLabelNames(names, labels: labels, labelOrder: ["id-b", "id-a"])
        XCTAssertEqual(result, ["BBB", "AAA"])
    }

    func testLabelsNotInOrderAreAppendedAlphabetically() {
        let labelA = makeLabel(id: "id-a", name: "AAA")
        let labelB = makeLabel(id: "id-b", name: "BBB")
        let labelC = makeLabel(id: "id-c", name: "CCC")
        let labels = [labelA, labelB, labelC]
        let names = ["AAA", "BBB", "CCC"]
        // Order only specifies B; A and C are appended alphabetically after
        let result = sortedLabelNames(names, labels: labels, labelOrder: ["id-b"])
        XCTAssertEqual(result[0], "BBB")
        XCTAssertEqual(result[1], "AAA")
        XCTAssertEqual(result[2], "CCC")
    }

    func testEmptyOrderFallsBackToAlphabetical() {
        let labels = [makeLabel(id: "x", name: "Zebra"), makeLabel(id: "y", name: "Apple")]
        let names = labels.map { $0.name }
        let result = sortedLabelNames(names, labels: labels, labelOrder: [])
        XCTAssertEqual(result[0], "Apple")
        XCTAssertEqual(result[1], "Zebra")
    }

    func testSortedLabelsFunction() {
        let labelA = ListLabel(id: "id-a", name: "AAA", color: "#000")
        let labelB = ListLabel(id: "id-b", name: "BBB", color: "#000")
        let labels = [labelB, labelA]
        let result = sortedLabels(labels, by: ["id-a", "id-b"])
        XCTAssertEqual(result[0].id, "id-a")
        XCTAssertEqual(result[1].id, "id-b")
    }
}

// MARK: -

final class ReminderManagerTests: XCTestCase {

    // MARK: - nextReminderDate fixed mode

    func testNextDateFixedDaily() {
        let base = Date()
        let rule = ReminderRepeatRule.daily
        let next = ReminderManager.nextReminderDate(from: base, rule: rule, mode: .fixed)
        XCTAssertNotNil(next)
        // Should be ~24 hours in the future
        let diff = next!.timeIntervalSince(base)
        XCTAssertGreaterThan(diff, 0)
        XCTAssertGreaterThan(next!, Date())
    }

    func testNextDateFixedWeekly() {
        let base = Date()
        let rule = ReminderRepeatRule.weekly
        let next = ReminderManager.nextReminderDate(from: base, rule: rule, mode: .fixed)
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, Date())
    }

    func testNextDateFixedMonthly() {
        let base = Date()
        let rule = ReminderRepeatRule.monthly
        let next = ReminderManager.nextReminderDate(from: base, rule: rule, mode: .fixed)
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, Date())
    }

    func testNextDateFixedYearly() {
        let base = Date()
        let rule = ReminderRepeatRule.yearly
        let next = ReminderManager.nextReminderDate(from: base, rule: rule, mode: .fixed)
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, Date())
    }

    func testNextDateFixedAdvancesPastNow() {
        // Give a date far in the past — fixed mode should keep advancing until future
        let pastDate = Date(timeIntervalSinceNow: -86400 * 365 * 2) // 2 years ago
        let rule = ReminderRepeatRule.daily
        let next = ReminderManager.nextReminderDate(from: pastDate, rule: rule, mode: .fixed)
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, Date())
    }

    func testNextDateAfterCompletePreservesOriginalTime() {
        let calendar = Calendar.current
        // Original reminder was set for 9:30:00 on some past date
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.year = (components.year ?? 2026) - 1
        components.hour = 9
        components.minute = 30
        components.second = 0
        let pastDate = calendar.date(from: components)!

        let rule = ReminderRepeatRule.daily
        let next = ReminderManager.nextReminderDate(from: pastDate, rule: rule, mode: .afterComplete)
        XCTAssertNotNil(next)

        // Date should be tomorrow (today + 1 day)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertTrue(calendar.isDate(next!, inSameDayAs: tomorrow))

        // Time-of-day should match the original (9:30)
        let nextTime = calendar.dateComponents([.hour, .minute, .second], from: next!)
        XCTAssertEqual(nextTime.hour, 9)
        XCTAssertEqual(nextTime.minute, 30)
        XCTAssertEqual(nextTime.second, 0)
    }

    func testNextDateWeekdaysSkipsWeekend() {
        let calendar = Calendar.current
        // Find a Friday
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear, .weekday, .hour, .minute], from: Date())
        components.weekday = 6  // Friday
        let friday = calendar.date(from: components)!
        let rule = ReminderRepeatRule.weekdays
        let next = ReminderManager.nextReminderDate(from: friday, rule: rule, mode: .fixed)
        XCTAssertNotNil(next)
        let weekday = calendar.component(.weekday, from: next!)
        // Must be Mon(2)–Fri(6)
        XCTAssertGreaterThanOrEqual(weekday, 2)
        XCTAssertLessThanOrEqual(weekday, 6)
    }

    func testNextDateBiweekly() {
        let base = Date()
        let rule = ReminderRepeatRule.biweekly
        let next = ReminderManager.nextReminderDate(from: base, rule: rule, mode: .fixed)
        XCTAssertNotNil(next)
        // Should be ~14 days away
        let diff = next!.timeIntervalSince(base)
        XCTAssertGreaterThan(diff, 86400 * 13)
    }

    func testNilBaseDateUsesNowForFixed() {
        let rule = ReminderRepeatRule.daily
        let next = ReminderManager.nextReminderDate(from: nil, rule: rule, mode: .fixed)
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, Date())
    }
}

// MARK: -

final class ModelHelpersTests: XCTestCase {

    func testCreateNewItemHasUniqueIds() {
        let item1 = ModelHelpers.createNewItem(note: "A")
        let item2 = ModelHelpers.createNewItem(note: "B")
        XCTAssertNotEqual(item1.id, item2.id)
    }

    func testCreateNewItemDefaults() {
        let item = ModelHelpers.createNewItem(note: "Milk")
        XCTAssertEqual(item.note, "Milk")
        XCTAssertEqual(item.quantity, 1.0)
        XCTAssertFalse(item.checked)
        XCTAssertFalse(item.isDeleted)
        XCTAssertNil(item.labelId)
        XCTAssertNil(item.markdownNotes)
        XCTAssertNil(item.reminderDate)
    }

    func testCreateNewItemWithLabel() {
        let item = ModelHelpers.createNewItem(note: "Eggs", labelId: "dairy-123")
        XCTAssertEqual(item.labelId, "dairy-123")
    }

    func testCreateNewListHasUniqueIds() {
        let list1 = ModelHelpers.createNewList(name: "List A")
        let list2 = ModelHelpers.createNewList(name: "List B")
        XCTAssertNotEqual(list1.id, list2.id)
    }

    func testCreateNewListDefaultIcon() {
        let list = ModelHelpers.createNewList(name: "My List")
        XCTAssertEqual(list.icon, "checklist")
    }

    func testCreateNewListHasNoLocalPrefix() {
        let list = ModelHelpers.createNewList(name: "Test")
        XCTAssertFalse(list.id.hasPrefix("local-"))
    }

    func testCreateNewLabelHasUniqueIds() {
        let label1 = ModelHelpers.createNewLabel(name: "A", color: "#FF0000")
        let label2 = ModelHelpers.createNewLabel(name: "B", color: "#00FF00")
        XCTAssertNotEqual(label1.id, label2.id)
    }

    func testTouchItemUpdatesTimestamp() {
        let item = ModelHelpers.createNewItem(note: "Apples")
        let before = Date()
        let touched = ModelHelpers.touchItem(item)
        let after = Date()
        XCTAssertGreaterThanOrEqual(touched.modifiedAt, before)
        XCTAssertLessThanOrEqual(touched.modifiedAt, after)
    }
}

// MARK: -

final class ListModelTests: XCTestCase {

    // MARK: - ListSummary cleanId

    func testCleanIdStripsLocalPrefix() {
        let summary = ListSummary(id: "local-abc-123", name: "Test")
        XCTAssertEqual(summary.cleanId, "abc-123")
    }

    func testCleanIdNoPrefix() {
        let id = UUID().uuidString
        let summary = ListSummary(id: id, name: "Test")
        XCTAssertEqual(summary.cleanId, id)
    }

    func testIsLocalListId() {
        XCTAssertTrue("local-abc".isLocalListId)
        XCTAssertFalse("abc".isLocalListId)
    }

    // MARK: - ListLabel cleanId & isLocal

    func testLabelCleanId() {
        let label = ListLabel(id: "local-xyz", name: "Test", color: "#000")
        XCTAssertEqual(label.cleanId, "xyz")
    }

    func testLabelIsLocal() {
        let local = ListLabel(id: "local-xyz", name: "Test", color: "#000")
        let remote = ListLabel(id: "xyz", name: "Test", color: "#000")
        XCTAssertTrue(local.isLocal)
        XCTAssertFalse(remote.isLocal)
    }

    // MARK: - ReminderRepeatRule displayName

    func testDailyDisplayName() {
        XCTAssertEqual(ReminderRepeatRule.daily.displayName, "Daily")
    }

    func testWeeklyDisplayName() {
        XCTAssertEqual(ReminderRepeatRule.weekly.displayName, "Weekly")
    }

    func testBiweeklyDisplayName() {
        XCTAssertEqual(ReminderRepeatRule.biweekly.displayName, "Every 2 Weeks")
    }

    func testMonthlyDisplayName() {
        XCTAssertEqual(ReminderRepeatRule.monthly.displayName, "Monthly")
    }

    func testYearlyDisplayName() {
        XCTAssertEqual(ReminderRepeatRule.yearly.displayName, "Yearly")
    }

    func testWeekdaysDisplayName() {
        XCTAssertEqual(ReminderRepeatRule.weekdays.displayName, "Weekdays")
    }

    func testCustomIntervalDisplayName() {
        let rule = ReminderRepeatRule(unit: .day, interval: 3)
        XCTAssertEqual(rule.displayName, "Every 3 Days")
    }

    // MARK: - ListItem Codable round-trip

    func testListItemCodableRoundTrip() throws {
        let original = ListItem(
            id: UUID(),
            note: "Apples",
            quantity: 3,
            checked: false,
            labelId: "fruit-id",
            markdownNotes: "- Granny Smith",
            modifiedAt: Date(),
            isDeleted: false,
            reminderDate: Date(timeIntervalSinceNow: 3600),
            reminderRepeatRule: .weekly,
            reminderRepeatMode: .fixed
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ListItem.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.note, original.note)
        XCTAssertEqual(decoded.quantity, original.quantity)
        XCTAssertEqual(decoded.labelId, original.labelId)
        XCTAssertEqual(decoded.markdownNotes, original.markdownNotes)
        XCTAssertEqual(decoded.isDeleted, original.isDeleted)
        XCTAssertEqual(decoded.reminderRepeatRule, original.reminderRepeatRule)
        XCTAssertEqual(decoded.reminderRepeatMode, original.reminderRepeatMode)
    }
}

// MARK: - Markdown Import Logic

/// Tests for the pure-Swift logic extracted from MarkdownListImportView.
/// Covers merge stats and per-row diff lines for both fresh-import and preset-reload
/// scenarios. Snapshot/view-level testing is not in the project's test toolchain.
final class MarkdownImportLogicTests: XCTestCase {

    private func parsed(_ note: String, qty: Double = 1, label: String? = nil) -> ParsedListItem {
        ParsedListItem(note: note, quantity: qty, checked: false, labelName: label, markdownNotes: nil)
    }

    private func existing(_ note: String, qty: Double = 1, checked: Bool = false,
                          labelId: String? = nil, id: UUID = UUID()) -> ListItem {
        ListItem(id: id, note: note, quantity: qty, checked: checked, labelId: labelId, modifiedAt: Date(), isDeleted: false)
    }

    private func label(_ id: String, _ name: String) -> ListLabel {
        ListLabel(id: id, name: name, color: "#FF0000")
    }

    // MARK: - matchExisting

    func testMatchByNameWhenNoExpected() {
        let parsedItem = parsed("Apples")
        let result = MarkdownImportLogic.matchExisting(
            parsed: parsedItem,
            in: [existing("apples"), existing("Bananas")],
            expectedItems: []
        )
        XCTAssertEqual(result?.note.lowercased(), "apples")
    }

    func testMatchByUUIDSurvivesRename() {
        // Preset captured "Apples", item has since been renamed to "Granny Smiths".
        let stableId = UUID()
        let parsedItem = parsed("Apples")  // markdown still says Apples (preset-generated)
        let expectedSnapshot = [existing("Apples", id: stableId)]  // preset-time snapshot
        let liveItems = [existing("Granny Smiths", id: stableId)]  // current name
        let result = MarkdownImportLogic.matchExisting(
            parsed: parsedItem,
            in: liveItems,
            expectedItems: expectedSnapshot
        )
        XCTAssertEqual(result?.id, stableId)
        XCTAssertEqual(result?.note, "Granny Smiths")
    }

    // MARK: - mergeStats

    func testCheckedItemMatchedCountsAsUpdatedNotNew() {
        let stats = MarkdownImportLogic.mergeStats(
            for: [parsed("Apples")],
            existingItems: [existing("Apples", checked: true)],
            existingLabels: [],
            expectedItems: [],
            createUnmatchedLabels: true
        )
        XCTAssertEqual(stats.updatedItems, 1)
        XCTAssertEqual(stats.newItems, 0)
    }

    func testCreateUnmatchedLabelsOffGivesZeroNewLabels() {
        let stats = MarkdownImportLogic.mergeStats(
            for: [parsed("Apples", label: "Fruit"), parsed("Bread", label: "Bakery")],
            existingItems: [],
            existingLabels: [label("fruit", "Fruit")],  // only Fruit exists, Bakery is unmatched
            expectedItems: [],
            createUnmatchedLabels: false
        )
        XCTAssertEqual(stats.matchedLabels, 1)
        XCTAssertEqual(stats.unmatchedLabels, 1)
        XCTAssertEqual(stats.newLabels, 0)
    }

    func testCreateUnmatchedLabelsOnGivesNewLabels() {
        let stats = MarkdownImportLogic.mergeStats(
            for: [parsed("Apples", label: "Fruit"), parsed("Bread", label: "Bakery")],
            existingItems: [],
            existingLabels: [label("fruit", "Fruit")],
            expectedItems: [],
            createUnmatchedLabels: true
        )
        XCTAssertEqual(stats.newLabels, 1)
    }

    // MARK: - diffLines

    func testReactivationDiffShownEvenWhenQuantityUnchanged() {
        // Critical signal for preset reload: matched item is currently checked.
        // Even if the quantity doesn't change, the user needs to know "this is
        // being brought back to life."
        let item = existing("Apples", qty: 3, checked: true)
        let lines = MarkdownImportLogic.diffLines(
            existing: item,
            parsed: parsed("Apples", qty: 3),
            existingLabels: [],
            replaceQuantities: true
        )
        XCTAssertTrue(lines.contains { $0.kind == .reactivate })
    }

    func testQuantityNoOpHidden() {
        // replaceQuantities=true; parsed qty equals existing qty → no diff line.
        let item = existing("Apples", qty: 3)
        let lines = MarkdownImportLogic.diffLines(
            existing: item,
            parsed: parsed("Apples", qty: 3),
            existingLabels: [],
            replaceQuantities: true
        )
        XCTAssertFalse(lines.contains { $0.kind == .quantity })
    }

    func testQuantityAddMode() {
        // replaceQuantities=false, item not checked → quantity adds.
        let item = existing("Apples", qty: 3)
        let lines = MarkdownImportLogic.diffLines(
            existing: item,
            parsed: parsed("Apples", qty: 2),
            existingLabels: [],
            replaceQuantities: false
        )
        let qtyLine = lines.first { $0.kind == .quantity }
        XCTAssertNotNil(qtyLine)
        XCTAssertTrue(qtyLine?.text.contains("3") == true)
        XCTAssertTrue(qtyLine?.text.contains("5") == true)
    }

    func testLabelChangeRendered() {
        let lines = MarkdownImportLogic.diffLines(
            existing: existing("Apples", labelId: "fruit"),
            parsed: parsed("Apples", label: "Snacks"),
            existingLabels: [label("fruit", "Fruit")],
            replaceQuantities: true
        )
        let labelLine = lines.first { $0.kind == .label }
        XCTAssertNotNil(labelLine)
        XCTAssertTrue(labelLine?.text.contains("Fruit") == true)
        XCTAssertTrue(labelLine?.text.contains("Snacks") == true)
    }

    func testNoLabelChangeWhenLabelsMatchCaseInsensitively() {
        let lines = MarkdownImportLogic.diffLines(
            existing: existing("Apples", labelId: "fruit"),
            parsed: parsed("Apples", label: "fruit"),  // same name, different case
            existingLabels: [label("fruit", "Fruit")],
            replaceQuantities: true
        )
        XCTAssertFalse(lines.contains { $0.kind == .label })
    }

    func testFullyUnchangedItemHasNoDiffLines() {
        // Active item with matching name, label, and quantity (in replace mode).
        let lines = MarkdownImportLogic.diffLines(
            existing: existing("Apples", qty: 3, labelId: "fruit"),
            parsed: parsed("Apples", qty: 3, label: "Fruit"),
            existingLabels: [label("fruit", "Fruit")],
            replaceQuantities: true
        )
        XCTAssertTrue(lines.isEmpty)
    }
}

// MARK: - Resilient Decoding: preservation + lossy array

/// Tests that opening a `.listie` file written by a hypothetical newer version
/// of the app and saving it back doesn't lose JSON values this version doesn't
/// understand. Also exercises the lossy-array layer that protects the document
/// from a single structurally-broken element.
final class ResilientDecodingTests: XCTestCase {

    // MARK: - helpers

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> [String: Any] {
        let data = try makeEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodeDoc(_ json: String) throws -> ListDocument {
        try makeDecoder().decode(ListDocument.self, from: Data(json.utf8))
    }

    private func decodeItem(_ json: String) throws -> ListItem {
        try makeDecoder().decode(ListItem.self, from: Data(json.utf8))
    }

    private func validItemJSON(id: String = "11111111-1111-1111-1111-111111111111") -> String {
        """
        {
          "id": "\(id)",
          "note": "Apples",
          "quantity": 1,
          "checked": false,
          "modifiedAt": "2026-01-01T00:00:00Z",
          "isDeleted": false
        }
        """
    }

    private func validDocumentJSON(extraTopLevel: String = "", items: String = "[]") -> String {
        """
        {
          "version": 2,
          "list": { "id": "list-1", "name": "Test", "modifiedAt": "2026-01-01T00:00:00Z" },
          "items": \(items),
          "labels": [],
          "deletedLabelIDs": []\(extraTopLevel.isEmpty ? "" : ",\n  \(extraTopLevel)")
        }
        """
    }

    // MARK: - Unknown keys

    func testUnknownTopLevelKeyRoundTrips() throws {
        let json = validDocumentJSON(extraTopLevel: "\"experimentalFeature\": {\"foo\": 42, \"bar\": [1,2,3]}")
        let doc = try decodeDoc(json)
        let dict = try roundTrip(doc)
        let extra = try XCTUnwrap(dict["experimentalFeature"] as? [String: Any])
        XCTAssertEqual(extra["foo"] as? Double, 42)
        XCTAssertEqual(extra["bar"] as? [Double], [1, 2, 3])
    }

    func testUnknownItemKeyRoundTrips() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "note": "Apples",
          "quantity": 1,
          "checked": false,
          "modifiedAt": "2026-01-01T00:00:00Z",
          "isDeleted": false,
          "futureField": "hello-from-the-future"
        }
        """
        let item = try decodeItem(json)
        let dict = try roundTrip(item)
        XCTAssertEqual(dict["futureField"] as? String, "hello-from-the-future")
    }

    func testCoordinateAltitudeRoundTrips() throws {
        let json = """
        {"latitude": 51.5, "longitude": -0.12, "altitude": 100.0}
        """
        let coord = try makeDecoder().decode(Coordinate.self, from: Data(json.utf8))
        let dict = try roundTrip(coord)
        XCTAssertEqual(dict["altitude"] as? Double, 100.0)
    }

    // MARK: - Unknown values of known keys

    func testUnknownEnumValueRoundTrips() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "note": "Apples",
          "quantity": 1,
          "checked": false,
          "modifiedAt": "2026-01-01T00:00:00Z",
          "isDeleted": false,
          "reminderRepeatMode": "afterDelay"
        }
        """
        let item = try decodeItem(json)
        XCTAssertNil(item.reminderRepeatMode, "Unknown enum value should leave the typed property nil")
        let dict = try roundTrip(item)
        XCTAssertEqual(dict["reminderRepeatMode"] as? String, "afterDelay",
                       "Raw value should round-trip even though the typed enum couldn't represent it")
    }

    func testUnknownNestedFieldInRuleRoundTrips() throws {
        // A v3-style rule with a known unit but a future "endDate" field.
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "note": "Apples",
          "quantity": 1,
          "checked": false,
          "modifiedAt": "2026-01-01T00:00:00Z",
          "isDeleted": false,
          "reminderRepeatRule": { "unit": "week", "interval": 2, "endDate": "2027-01-01T00:00:00Z" }
        }
        """
        let item = try decodeItem(json)
        XCTAssertEqual(item.reminderRepeatRule?.unit, .week)
        XCTAssertEqual(item.reminderRepeatRule?.interval, 2)
        let dict = try roundTrip(item)
        let rule = try XCTUnwrap(dict["reminderRepeatRule"] as? [String: Any])
        XCTAssertEqual(rule["endDate"] as? String, "2027-01-01T00:00:00Z")
    }

    func testUnknownUnitInRuleStashesEntireRule() throws {
        // Unknown unit makes the rule unparseable. Whole rule object survives
        // in _preserved on the item so we don't strip the user's data.
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "note": "Apples",
          "quantity": 1,
          "checked": false,
          "modifiedAt": "2026-01-01T00:00:00Z",
          "isDeleted": false,
          "reminderRepeatRule": { "unit": "fortnight", "interval": 2 }
        }
        """
        let item = try decodeItem(json)
        XCTAssertNil(item.reminderRepeatRule)
        let dict = try roundTrip(item)
        let rule = try XCTUnwrap(dict["reminderRepeatRule"] as? [String: Any])
        XCTAssertEqual(rule["unit"] as? String, "fortnight")
        XCTAssertEqual(rule["interval"] as? Double, 2)
    }

    // MARK: - Typed value overrides preserved raw

    func testTypedFieldOverwritesPreservedRaw() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "note": "Apples",
          "quantity": 1,
          "checked": false,
          "modifiedAt": "2026-01-01T00:00:00Z",
          "isDeleted": false,
          "reminderRepeatMode": "afterDelay"
        }
        """
        var item = try decodeItem(json)
        // User picks a known mode, overriding the unknown stashed value.
        item.reminderRepeatMode = .fixed
        let dict = try roundTrip(item)
        XCTAssertEqual(dict["reminderRepeatMode"] as? String, "fixed")
    }

    func testClearingTypedFieldRemovesKey() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "note": "Apples",
          "quantity": 1,
          "checked": false,
          "modifiedAt": "2026-01-01T00:00:00Z",
          "isDeleted": false,
          "reminderRepeatMode": "fixed"
        }
        """
        var item = try decodeItem(json)
        XCTAssertEqual(item.reminderRepeatMode, .fixed)
        // Successfully-decoded value lands in the typed property, NOT in _preserved.
        item.reminderRepeatMode = nil
        let dict = try roundTrip(item)
        XCTAssertNil(dict["reminderRepeatMode"], "Clearing a previously-set typed field should omit the key entirely")
    }

    func testExplicitNullInOptionalEnumStaysAbsent() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "note": "Apples",
          "quantity": 1,
          "checked": false,
          "modifiedAt": "2026-01-01T00:00:00Z",
          "isDeleted": false,
          "reminderRepeatMode": null
        }
        """
        let item = try decodeItem(json)
        XCTAssertNil(item.reminderRepeatMode)
        let dict = try roundTrip(item)
        XCTAssertNil(dict["reminderRepeatMode"], "Explicit null should not be re-emitted (matches absent semantics)")
    }

    // MARK: - Lossy arrays

    func testBadItemSkippedDocumentDecodes() throws {
        // Middle item is missing required `note` — should be dropped, others kept.
        let json = """
        {
          "version": 2,
          "list": { "id": "L", "name": "T", "modifiedAt": "2026-01-01T00:00:00Z" },
          "items": [
            { "id": "11111111-1111-1111-1111-111111111111", "note": "A", "quantity": 1, "checked": false, "modifiedAt": "2026-01-01T00:00:00Z", "isDeleted": false },
            { "id": "22222222-2222-2222-2222-222222222222", "quantity": 1, "checked": false, "modifiedAt": "2026-01-01T00:00:00Z", "isDeleted": false },
            { "id": "33333333-3333-3333-3333-333333333333", "note": "C", "quantity": 1, "checked": false, "modifiedAt": "2026-01-01T00:00:00Z", "isDeleted": false }
          ],
          "labels": [],
          "deletedLabelIDs": []
        }
        """
        let doc = try decodeDoc(json)
        XCTAssertEqual(doc.items.count, 2)
        XCTAssertEqual(doc.items.map(\.note), ["A", "C"])
    }

    func testLossyArrayDoesNotInfiniteLoopOnBadElement() throws {
        // The unkeyed container's index must advance even when an element
        // fails to decode; otherwise the decoder spins forever. This is the
        // single most common bug in hand-rolled lossy-array implementations.
        let json = """
        [
          { "latitude": 1.0, "longitude": 2.0 },
          "not-an-object",
          { "latitude": 3.0, "longitude": 4.0 }
        ]
        """
        let exp = expectation(description: "lossy array decode terminates")
        DispatchQueue.global().async {
            do {
                let lossy = try self.makeDecoder().decode(LossyArray<Coordinate>.self, from: Data(json.utf8))
                XCTAssertEqual(lossy.values.count, 2)
                XCTAssertEqual(lossy.values[0].latitude, 1.0)
                XCTAssertEqual(lossy.values[1].latitude, 3.0)
                exp.fulfill()
            } catch {
                XCTFail("Decode threw: \(error)")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - Equality ignores _preserved

    func testSharePresetsWithDifferentExtrasAreEqual() throws {
        let baseJSON: (String) -> String = { extra in """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "P",
          "itemIds": [],
          "compress": true,
          "includeComments": false,
          "createdAt": "2026-01-01T00:00:00Z",
          "modifiedAt": "2026-01-01T00:00:00Z",
          "isDeleted": false\(extra)
        }
        """
        }
        let dec = makeDecoder()
        let a = try dec.decode(SharePreset.self, from: Data(baseJSON("").utf8))
        let b = try dec.decode(SharePreset.self, from: Data(baseJSON(", \"futureFlag\": true").utf8))
        XCTAssertEqual(a, b, "Presets that differ only in preserved unknown fields should compare equal")
        XCTAssertEqual(a.hashValue, b.hashValue, "...and hash the same")
    }

    // MARK: - Full document round-trip

    func testFullDocumentRoundTripPreservesEverything() throws {
        let json = """
        {
          "version": 99,
          "futureToggle": true,
          "list": {
            "id": "list-1",
            "name": "Groceries",
            "modifiedAt": "2026-01-01T00:00:00Z",
            "futureListField": "x"
          },
          "items": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "note": "Apples",
              "quantity": 1,
              "checked": false,
              "modifiedAt": "2026-01-01T00:00:00Z",
              "isDeleted": false,
              "reminderRepeatMode": "afterDelay",
              "subItems": [{"text": "Granny Smith"}]
            }
          ],
          "labels": [
            {"id": "fruit", "name": "Fruit", "color": "#ff0000", "futureLabelField": 42}
          ],
          "deletedLabelIDs": []
        }
        """
        let doc = try decodeDoc(json)
        XCTAssertEqual(doc.version, 99)
        let dict = try roundTrip(doc)
        XCTAssertEqual(dict["futureToggle"] as? Bool, true)
        let list = try XCTUnwrap(dict["list"] as? [String: Any])
        XCTAssertEqual(list["futureListField"] as? String, "x")
        let items = try XCTUnwrap(dict["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["reminderRepeatMode"] as? String, "afterDelay")
        let subItems = try XCTUnwrap(items[0]["subItems"] as? [[String: Any]])
        XCTAssertEqual(subItems[0]["text"] as? String, "Granny Smith")
        let labels = try XCTUnwrap(dict["labels"] as? [[String: Any]])
        XCTAssertEqual(labels[0]["futureLabelField"] as? Double, 42)
    }
}

