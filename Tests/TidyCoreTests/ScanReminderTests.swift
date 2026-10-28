import XCTest
@testable import TidyCore

final class ScanReminderTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func reminder(days: Int, lastScan: String? = nil, enabledAt: String? = nil, enabled: Bool = true) -> ScanReminders.Reminder {
        var reminder = ScanReminders.Reminder(days: days)
        reminder.isEnabled = enabled
        reminder.lastScan = lastScan.map(date)
        reminder.enabledAt = enabledAt.map(date)
        return reminder
    }

    func testOffUntilTurnedOn() {
        let reminders = ScanReminders()
        XCTAssertFalse(reminders.smartCare.isEnabled)
        XCTAssertFalse(reminders.malware.isEnabled)
        XCTAssertEqual(reminders.smartCare.days, 14)
        XCTAssertEqual(reminders.malware.days, 30)
        let old = reminder(days: 7, lastScan: "2026-01-01T10:00:00Z", enabled: false)
        XCTAssertNil(old.dueDate(calendar: calendar))
        XCTAssertFalse(old.isDue(now: date("2026-10-28T10:00:00Z"), calendar: calendar))
    }

    func testDueTheChosenNumberOfDaysAfterTheLastScan() {
        let smartCare = reminder(days: 14, lastScan: "2026-10-01T10:00:00Z", enabledAt: "2026-09-01T10:00:00Z")
        XCTAssertEqual(smartCare.dueDate(calendar: calendar), date("2026-10-15T10:00:00Z"), "the last scan counts, not when it was turned on")
        XCTAssertFalse(smartCare.isDue(now: date("2026-10-15T09:59:00Z"), calendar: calendar))
        XCTAssertTrue(smartCare.isDue(now: date("2026-10-15T10:00:00Z"), calendar: calendar))
        XCTAssertEqual(smartCare.daysSinceLastScan(now: date("2026-10-20T08:00:00Z"), calendar: calendar), 19)
    }

    func testWithoutAScanTheDaysCountFromTurningItOn() {
        let malware = reminder(days: 30, enabledAt: "2026-10-01T10:00:00Z")
        XCTAssertEqual(malware.dueDate(calendar: calendar), date("2026-10-31T10:00:00Z"))
        XCTAssertNil(malware.daysSinceLastScan(now: date("2026-11-02T10:00:00Z"), calendar: calendar))
        XCTAssertNil(reminder(days: 30).dueDate(calendar: calendar), "no scan and no start: nothing to count from")
    }

    func testDueLinesInOrderWithHowLongItHasBeen() {
        var reminders = ScanReminders()
        reminders.malware = reminder(days: 30, enabledAt: "2026-09-01T10:00:00Z")
        reminders.smartCare = reminder(days: 14, lastScan: "2026-10-01T10:00:00Z")
        let due = reminders.due(now: date("2026-10-28T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(due.map(\.scan), [.smartCare, .malware])
        XCTAssertEqual(due.map(\.text), ["It's been 27 days since your last Smart Care scan.",
                                         "You haven't run a malware Quick Scan yet."])

        reminders.smartCare.lastScan = date("2026-10-28T11:00:00Z")
        XCTAssertEqual(reminders.due(now: date("2026-10-28T12:00:00Z"), calendar: calendar).map(\.scan), [.malware],
                       "a new scan clears its reminder")
        XCTAssertEqual(ScanReminders.text(for: .malware, daysSinceLastScan: 1), "It's been 1 day since your last malware Quick Scan.")
    }

    func testLastScanTextCountsCalendarDays() {
        let now = date("2026-10-28T08:00:00Z")
        XCTAssertEqual(reminder(days: 7).lastScanText(now: now, calendar: calendar), "Never")
        XCTAssertEqual(reminder(days: 7, lastScan: "2026-10-28T07:00:00Z").lastScanText(now: now, calendar: calendar), "Today")
        XCTAssertEqual(reminder(days: 7, lastScan: "2026-10-27T23:00:00Z").lastScanText(now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(reminder(days: 7, lastScan: "2026-10-25T09:00:00Z").lastScanText(now: now, calendar: calendar), "3 days ago")
        XCTAssertEqual(reminder(days: 7, lastScan: "2026-10-29T09:00:00Z").lastScanText(now: now, calendar: calendar), "Today",
                       "a clock that moved back doesn't show a negative count")
    }

    func testStoreRoundTripsAndFallsBackWhenMissingOrBroken() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ScanReminderStore(url: folder.appendingPathComponent("Tidy/reminders.json"))
        XCTAssertEqual(store.load(), ScanReminders(), "all off until you turn one on")

        var reminders = ScanReminders()
        reminders.malware = reminder(days: 90, lastScan: "2026-10-28T07:00:00Z", enabledAt: "2026-10-01T07:00:00Z")
        try store.save(reminders)
        XCTAssertEqual(store.load(), reminders)

        try Data("not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), ScanReminders())
    }
}
