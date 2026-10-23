import XCTest
@testable import WorkLedgerCore

@MainActor
final class RecurringReminderTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerRecurringReminder-\(UUID().uuidString)")
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
                      _ second: Int = 0, calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private func newYorkCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func testCompletionUsesDateAndPreservesReminderDayOffsetAndClockAfterMonthEnd() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let completed = date(2024, 1, 31, 18, 47, 12)
        let task = WorkTask(title: "月末检查", dueAt: date(2024, 1, 31), reminderAt: date(2024, 1, 29, 9, 15),
                            repeatRule: RepeatRule(every: 1, unit: .month))
        try store.saveTask(task)

        let next = try XCTUnwrap(store.completeTask(id: task.id, at: completed).nextTask)

        XCTAssertEqual(next.dueAt, date(2024, 2, 29))
        XCTAssertEqual(next.reminderAt, date(2024, 2, 27, 9, 15))
        XCTAssertEqual(store.data.tasks.first?.reminderAt, task.reminderAt)
        XCTAssertEqual(store.data.tasks.first?.completedAt, completed)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }

    func testWithoutDeadlineDelayedCompletionUsesNewCycleDateAndOriginalReminderClock() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let completed = date(2024, 10, 20, 19, 42)
        let task = WorkTask(title: "半年更新", reminderAt: date(2023, 1, 5, 9, 45),
                            repeatRule: RepeatRule(every: 6, unit: .month))
        try store.saveTask(task)

        let next = try XCTUnwrap(store.completeTask(id: task.id, at: completed).nextTask)

        XCTAssertEqual(next.dueAt, date(2025, 4, 20))
        XCTAssertEqual(next.reminderAt, date(2025, 4, 20, 9, 45))
        XCTAssertGreaterThan(try XCTUnwrap(next.reminderAt), completed)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }

    func testFixedScheduleRetainsExplicitTimeAndMonthEndAnchorAfterReload() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let january = date(2024, 1, 31, 17, 23, 11)
        let task = WorkTask(title: "API 固定时刻", dueAt: january, reminderAt: date(2024, 1, 29, 9, 5, 13),
                            repeatRule: RepeatRule(every: 1, unit: .month, basis: .schedule))
        try store.saveTask(task)
        let february = try XCTUnwrap(store.completeTask(id: task.id, at: date(2024, 2, 3, 12)).nextTask)
        XCTAssertEqual(february.dueAt, date(2024, 2, 29, 17, 23, 11))
        XCTAssertEqual(february.reminderAt, date(2024, 2, 27, 9, 5, 13))
        XCTAssertEqual(february.scheduleAnchor?.date, january)

        let loaded = try WorkStore(directory: directory)
        let march = try XCTUnwrap(loaded.completeTask(id: february.id, at: date(2024, 2, 29, 18)).nextTask)
        XCTAssertEqual(march.dueAt, date(2024, 3, 31, 17, 23, 11))
        XCTAssertEqual(march.reminderAt, date(2024, 3, 29, 9, 5, 13))
        XCTAssertEqual(march.scheduleAnchor?.date, january)
        XCTAssertEqual(march.scheduleAnchor?.occurrence, 2)
        XCTAssertEqual(try WorkStore(directory: directory).data, loaded.data)
    }

    func testReminderWallClockSurvivesSpringAndFallDSTChanges() async throws {
        let calendar = newYorkCalendar()
        for (month, beforeDay, afterDay) in [(3, 9, 10), (11, 2, 3)] {
            let before = date(2024, month, beforeDay, calendar: calendar)
            let nextDue = date(2024, month, afterDay, calendar: calendar)
            let reminder = try WorkStore.nextReminder(previousDue: before,
                                                       previousReminder: date(2024, month, beforeDay, 9, 15, calendar: calendar),
                                                       nextDue: nextDue, completedAt: before, calendar: calendar)
            XCTAssertEqual(reminder, date(2024, month, afterDay, 9, 15, calendar: calendar))
            XCTAssertNotEqual(try XCTUnwrap(reminder).timeIntervalSince(nextDue), 9 * 3600 + 15 * 60)
        }
    }

    func testReminderCalendarDayOffsetAcrossDSTDoesNotBecomeElapsedHours() async throws {
        let calendar = newYorkCalendar()
        let reminder = try WorkStore.nextReminder(previousDue: date(2024, 3, 5, calendar: calendar),
                                                   previousReminder: date(2024, 3, 3, 9, 15, calendar: calendar),
                                                   nextDue: date(2024, 3, 11, calendar: calendar),
                                                   completedAt: date(2024, 3, 5, 18, calendar: calendar), calendar: calendar)
        XCTAssertEqual(reminder, date(2024, 3, 9, 9, 15, calendar: calendar))
    }

    func testMissingDSTClockMovesForwardAndRepeatedClockUsesFirstOccurrence() async throws {
        let calendar = newYorkCalendar()
        let spring = try WorkStore.nextReminder(previousDue: nil,
                                                 previousReminder: date(2024, 3, 9, 2, 30, calendar: calendar),
                                                 nextDue: date(2024, 3, 10, calendar: calendar),
                                                 completedAt: date(2024, 3, 9, 18, calendar: calendar), calendar: calendar)
        XCTAssertEqual(spring, date(2024, 3, 10, 3, 30, calendar: calendar))
        let fall = try WorkStore.nextReminder(previousDue: nil,
                                               previousReminder: date(2024, 11, 2, 1, 30, calendar: calendar),
                                               nextDue: date(2024, 11, 3, calendar: calendar),
                                               completedAt: date(2024, 11, 2, 18, calendar: calendar), calendar: calendar)
        XCTAssertEqual(fall, ISO8601DateFormatter().date(from: "2024-11-03T01:30:00-04:00"))
    }

    func testPastReminderMovesToRecordedCompletionDayOrNextDayWithoutUsingSystemNow() async throws {
        let calendar = newYorkCalendar()
        let due = date(2024, 1, 10, calendar: calendar)
        let oldReminder = date(2024, 1, 1, 9, 15, calendar: calendar)
        let nextDue = date(2024, 1, 11, calendar: calendar)
        for (hour, minute, expectedDay) in [(8, 0, 10), (9, 15, 11), (18, 30, 11)] {
            let completed = date(2024, 1, 10, hour, minute, calendar: calendar)
            let reminder = try WorkStore.nextReminder(previousDue: due, previousReminder: oldReminder,
                                                       nextDue: nextDue, completedAt: completed, calendar: calendar)
            XCTAssertEqual(reminder, date(2024, 1, expectedDay, 9, 15, calendar: calendar))
            XCTAssertGreaterThan(try XCTUnwrap(reminder), completed)
            XCTAssertLessThan(try XCTUnwrap(reminder), date(2024, 2, 1, calendar: calendar))
        }
    }

    func testFixedLateCompletionKeepsDeadlineAnchorButDoesNotGeneratePastReminder() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let january = date(2024, 1, 31)
        let task = WorkTask(title: "延迟补录", dueAt: january, reminderAt: date(2024, 1, 29, 9, 15),
                            repeatRule: RepeatRule(every: 1, unit: .month, basis: .schedule))
        try store.saveTask(task)
        let completed = date(2024, 3, 5, 18)
        let next = try XCTUnwrap(store.completeTask(id: task.id, at: completed).nextTask)
        XCTAssertEqual(next.dueAt, date(2024, 2, 29))
        XCTAssertEqual(next.reminderAt, date(2024, 3, 6, 9, 15))
        XCTAssertEqual(next.scheduleAnchor?.date, january)
        XCTAssertEqual(next.scheduleAnchor?.occurrence, 1)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }

    func testRecurrenceWithoutReminderDoesNotCreateOne() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let task = WorkTask(title: "无提醒年度工作", repeatRule: RepeatRule(every: 1, unit: .year))
        try store.saveTask(task)
        let next = try XCTUnwrap(store.completeTask(id: task.id, at: date(2024, 2, 29, 18, 47)).nextTask)
        XCTAssertEqual(next.dueAt, date(2025, 2, 28))
        XCTAssertNil(next.reminderAt)
        XCTAssertNil(next.scheduleAnchor)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }
}
