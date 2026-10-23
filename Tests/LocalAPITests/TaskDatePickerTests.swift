import XCTest
@testable import WorkLedger

final class TaskDatePickerTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    func testNextWeekUsesConfiguredWeekStartAndRetainsReminderTime() {
        let reference = date("2026-10-20T16:35:12+08:00")
        XCTAssertEqual(TaskDateShortcut.nextWeek.date(relativeTo: reference, firstWeekday: 5, calendar: calendar()),
                       date("2026-10-22T16:35:12+08:00"))
        XCTAssertEqual(TaskDateShortcut.nextWeek.date(relativeTo: reference, firstWeekday: 2, calendar: calendar()),
                       date("2026-10-26T16:35:12+08:00"))
        let thursday = date("2026-10-22T09:15:00+08:00")
        XCTAssertEqual(TaskDateShortcut.nextWeek.date(relativeTo: thursday, firstWeekday: 5, calendar: calendar()),
                       date("2026-10-29T09:15:00+08:00"))
    }

    func testShortcutsHandleMonthAndYearBoundaries() {
        let reference = date("2026-12-31T09:40:00+08:00")
        XCTAssertEqual(TaskDateShortcut.today.date(relativeTo: reference, firstWeekday: 5, calendar: calendar()), reference)
        XCTAssertEqual(TaskDateShortcut.tomorrow.date(relativeTo: reference, firstWeekday: 5, calendar: calendar()),
                       date("2027-01-01T09:40:00+08:00"))
        XCTAssertEqual(TaskDateShortcut.nextWeek.date(relativeTo: reference, firstWeekday: 5, calendar: calendar()),
                       date("2027-01-07T09:40:00+08:00"))
        XCTAssertEqual(TaskDateShortcut.nextMonth.date(relativeTo: reference, firstWeekday: 5, calendar: calendar()),
                       date("2027-01-31T09:40:00+08:00"))
        XCTAssertEqual(TaskDateShortcut.nextMonth.date(relativeTo: date("2024-01-31T18:20:00+08:00"), firstWeekday: 5, calendar: calendar()),
                       date("2024-02-29T18:20:00+08:00"))
    }

    func testTomorrowKeepsLocalTimeAcrossDaylightSavingChange() {
        let reference = date("2026-03-07T09:30:00-08:00")
        XCTAssertEqual(TaskDateShortcut.tomorrow.date(relativeTo: reference, firstWeekday: 5, calendar: calendar("America/Los_Angeles")),
                       date("2026-03-08T09:30:00-07:00"))
    }

    func testCalendarGridIncludesLeapDayAndPadsCompleteWeeks() {
        var calendar = calendar()
        calendar.firstWeekday = 2
        let days = TaskCalendarGrid.days(in: date("2024-02-18T09:00:00+08:00"), calendar: calendar)
        XCTAssertEqual(days.count, 35)
        XCTAssertTrue(days.prefix(3).allSatisfy { $0 == nil })
        XCTAssertEqual(days[3], date("2024-02-01T00:00:00+08:00"))
        XCTAssertEqual(days[31], date("2024-02-29T00:00:00+08:00"))
        XCTAssertTrue(days.suffix(3).allSatisfy { $0 == nil })
    }

    func testCalendarGridRespectsConfiguredWeekStartAtYearBoundary() {
        var calendar = calendar()
        calendar.firstWeekday = 5
        let days = TaskCalendarGrid.days(in: date("2027-01-20T09:00:00+08:00"), calendar: calendar)
        XCTAssertNil(days[0])
        XCTAssertEqual(days[1], date("2027-01-01T00:00:00+08:00"))
        XCTAssertEqual(days.compactMap { $0 }.count, 31)
        XCTAssertEqual(days.count % 7, 0)
        calendar.firstWeekday = 6
        XCTAssertEqual(TaskCalendarGrid.days(in: date("2027-01-20T09:00:00+08:00"), calendar: calendar)[0],
                       date("2027-01-01T00:00:00+08:00"))
    }

    func testChangingMonthAndSelectingDayPreservesReminderTime() {
        let calendar = calendar()
        let initial = date("2024-01-31T18:20:12+08:00")
        XCTAssertEqual(TaskCalendarGrid.shiftedMonth(initial, by: 1, calendar: calendar),
                       date("2024-02-29T18:20:12+08:00"))
        XCTAssertEqual(TaskCalendarGrid.shiftedMonth(date("2026-12-01T00:00:00+08:00"), by: 1, calendar: calendar),
                       date("2027-01-01T00:00:00+08:00"))
        XCTAssertEqual(TaskCalendarGrid.selecting(date("2027-01-04T00:00:00+08:00"), preservingTimeOf: initial, calendar: calendar),
                       date("2027-01-04T18:20:12+08:00"))
    }

    func testTimeSelectionKeepsDateAtMidnightAndEndOfDay() {
        let calendar = calendar()
        let initial = date("2026-12-31T09:30:12+08:00")
        XCTAssertEqual(TaskCalendarGrid.settingTime(hour: 0, minute: 0, on: initial, calendar: calendar),
                       date("2026-12-31T00:00:00+08:00"))
        XCTAssertEqual(TaskCalendarGrid.settingTime(hour: 23, minute: 59, on: initial, calendar: calendar),
                       date("2026-12-31T23:59:00+08:00"))
        XCTAssertEqual(TaskCalendarGrid.settingTime(hour: 24, minute: 0, on: initial, calendar: calendar), initial)
        XCTAssertEqual(TaskCalendarGrid.settingTime(hour: 9, minute: 60, on: initial, calendar: calendar), initial)
    }

    func testCalendarSelectionRetainsArbitraryChosenTimeAcrossYearAndMonth() {
        let calendar = calendar()
        let selection = TaskCalendarGrid.settingTime(hour: 7, minute: 43,
                                                     on: date("2026-12-31T09:30:12+08:00"), calendar: calendar)
        XCTAssertEqual(TaskCalendarGrid.selecting(date("2027-01-04T00:00:00+08:00"), preservingTimeOf: selection, calendar: calendar),
                       date("2027-01-04T07:43:00+08:00"))
        XCTAssertEqual(TaskCalendarGrid.settingTime(hour: 18, minute: 0,
                                                    on: date("2024-02-29T09:30:12+08:00"), calendar: calendar),
                       date("2024-02-29T18:00:00+08:00"))
    }
}
