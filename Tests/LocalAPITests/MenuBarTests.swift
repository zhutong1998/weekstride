import Combine
import Foundation
import XCTest
import WorkLedgerCore
@testable import WorkLedger

final class MenuBarTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    func testMenuShowsOnlyActiveThisWeekAndOverdueWorkUsingConfiguredWeek() {
        let project = Project(name: "Current"), archived = Project(name: "Archived", isArchived: true)
        let overdue = WorkTask(title: "Catch up", plannedAt: date("2026-10-10T00:00:00+08:00"), planGranularity: .day)
        let current = WorkTask(projectID: project.id, title: "This week", plannedAt: date("2026-10-20T00:00:00+08:00"), planGranularity: .week)
        let sunday = WorkTask(title: "Sunday", plannedAt: date("2026-10-25T00:00:00+08:00"), planGranularity: .day)
        let nextWeek = WorkTask(title: "Later", plannedAt: date("2026-11-01T00:00:00+08:00"), planGranularity: .day)
        let completed = WorkTask(title: "Done", completedAt: date("2026-10-20T09:00:00+08:00"), plannedAt: current.plannedAt, planGranularity: .week)
        let archivedTask = WorkTask(projectID: archived.id, title: "Archived work", plannedAt: current.plannedAt, planGranularity: .week)
        let data = LedgerData(projects: [project, archived], tasks: [nextWeek, completed, current, archivedTask, sunday, WorkTask(title: "Unscheduled"), overdue])
        let today = date("2026-10-20T12:00:00+08:00")

        XCTAssertEqual(MenuBarTask.items(in: data, relativeTo: today, firstWeekday: 5, calendar: calendar).map(\.id), [overdue.id, current.id])
        XCTAssertEqual(MenuBarTask.items(in: data, relativeTo: today, firstWeekday: 2, calendar: calendar).map(\.id), [overdue.id, current.id, sunday.id])
        XCTAssertEqual(MenuBarTask.items(in: data, relativeTo: date("2026-10-22T12:00:00+08:00"), firstWeekday: 5, calendar: calendar).map(\.id), [overdue.id, current.id, sunday.id])
    }

    func testLongMenuTitlesUseOneLineAndKeepGraphemeBoundaries() {
        let id = UUID()
        XCTAssertEqual(MenuBarTask(id: id, title: "  Task\n  with\tspaces  ").menuTitle, "Task with spaces")
        XCTAssertEqual(MenuBarTask(id: id, title: String(repeating: "A", count: 36)).menuTitle, String(repeating: "A", count: 36))
        let family = "👨‍👩‍👧‍👦"
        let task = MenuBarTask(id: id, title: String(repeating: family, count: 37))
        XCTAssertEqual(task.menuTitle, String(repeating: family, count: 35) + "…")
        XCTAssertEqual(task.menuTitle.count, 36)
        XCTAssertEqual(task.title.count, 37, "The full task title remains available for help and accessibility")
    }

    func testMenuUsesMainListPlanThenDeadlineOrderAndReflectsDeadlineChanges() {
        let today = date("2026-10-20T12:00:00+08:00")
        let plan = calendar.startOfDay(for: today)
        var later = WorkTask(title: "Later deadline", dueAt: today.addingTimeInterval(172800), plannedAt: plan, planGranularity: .week)
        let earlier = WorkTask(title: "Earlier deadline", dueAt: today.addingTimeInterval(86400), plannedAt: plan, planGranularity: .week)
        let noDeadline = WorkTask(title: "No deadline", plannedAt: plan, planGranularity: .week)
        func items() -> [UUID] {
            MenuBarTask.items(in: LedgerData(tasks: [noDeadline, later, earlier]), relativeTo: today,
                              firstWeekday: 5, calendar: calendar).map(\.id)
        }
        XCTAssertEqual(items(), [earlier.id, later.id, noDeadline.id])
        later.dueAt = today
        XCTAssertEqual(items(), [later.id, earlier.id, noDeadline.id])
    }

    @MainActor
    func testMenuPublisherIncludesTitleChangesButIgnoresUnrelatedTaskDetails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WeekStride-menu-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let today = date("2026-10-20T12:00:00+08:00")
        let task = WorkTask(title: "Original title", plannedAt: today, planGranularity: .week)
        try store.saveTask(task)
        var updates: [[MenuBarTask]] = []
        let subscription = store.$data.map {
            MenuBarTask.items(in: $0, relativeTo: today, firstWeekday: 5, calendar: self.calendar)
        }.removeDuplicates().sink { updates.append($0) }
        try store.updateTask(id: task.id) { $0.notes = "Do not refresh the menu" }
        XCTAssertEqual(updates.count, 1)
        try store.updateTask(id: task.id) { $0.title = "Updated title" }
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.last?.first?.title, "Updated title")
        _ = try store.completeTask(id: task.id, at: today)
        XCTAssertEqual(updates.count, 3)
        XCTAssertTrue(try XCTUnwrap(updates.last).isEmpty)
        withExtendedLifetime(subscription) {}
    }
}
