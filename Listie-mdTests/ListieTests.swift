//
//  ListieTests.swift
//  Listie-mdTests
//
//  Unit tests for pure-logic components: parser, generator, model helpers, reminder logic, and label sorting.
//

import XCTest
@testable import Listie_md

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

    private func makeItem(note: String, quantity: Double = 1, checked: Bool = false, labelId: String? = nil, markdownNotes: String? = nil) -> ShoppingItem {
        ShoppingItem(id: UUID(), note: note, quantity: quantity, checked: checked, labelId: labelId, markdownNotes: markdownNotes)
    }

    private func makeLabel(id: String, name: String, color: String = "#FF0000") -> ShoppingLabel {
        ShoppingLabel(id: id, name: name, color: color)
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

    private func makeLabel(id: String, name: String) -> ShoppingLabel {
        ShoppingLabel(id: id, name: name, color: "#000000")
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
        let labelA = ShoppingLabel(id: "id-a", name: "AAA", color: "#000")
        let labelB = ShoppingLabel(id: "id-b", name: "BBB", color: "#000")
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

    func testNextDateAfterCompleteUsesNow() {
        let pastDate = Date(timeIntervalSinceNow: -86400 * 365) // 1 year ago
        let rule = ReminderRepeatRule.daily
        let before = Date()
        let next = ReminderManager.nextReminderDate(from: pastDate, rule: rule, mode: .afterComplete)
        let after = Date()
        XCTAssertNotNil(next)
        // afterComplete uses now as base, result should be ~1 day from now
        let approxExpected = before.addingTimeInterval(86400)
        XCTAssertLessThan(abs(next!.timeIntervalSince(approxExpected)), 5.0)
        _ = after // suppress warning
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

final class ShoppingModelTests: XCTestCase {

    // MARK: - ShoppingListSummary cleanId

    func testCleanIdStripsLocalPrefix() {
        let summary = ShoppingListSummary(id: "local-abc-123", name: "Test")
        XCTAssertEqual(summary.cleanId, "abc-123")
    }

    func testCleanIdNoPrefix() {
        let id = UUID().uuidString
        let summary = ShoppingListSummary(id: id, name: "Test")
        XCTAssertEqual(summary.cleanId, id)
    }

    func testIsLocalListId() {
        XCTAssertTrue("local-abc".isLocalListId)
        XCTAssertFalse("abc".isLocalListId)
    }

    // MARK: - ShoppingLabel cleanId & isLocal

    func testLabelCleanId() {
        let label = ShoppingLabel(id: "local-xyz", name: "Test", color: "#000")
        XCTAssertEqual(label.cleanId, "xyz")
    }

    func testLabelIsLocal() {
        let local = ShoppingLabel(id: "local-xyz", name: "Test", color: "#000")
        let remote = ShoppingLabel(id: "xyz", name: "Test", color: "#000")
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

    // MARK: - ShoppingItem Codable round-trip

    func testShoppingItemCodableRoundTrip() throws {
        let original = ShoppingItem(
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
        let decoded = try decoder.decode(ShoppingItem.self, from: data)
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

