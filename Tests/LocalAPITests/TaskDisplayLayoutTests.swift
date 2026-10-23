import Foundation
import XCTest
import WorkLedgerCore
@testable import WorkLedger

final class TaskDisplayLayoutTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func calendar(_ timeZone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timeZone)!
        return value
    }

    private func taskValues(_ rows: [TaskListRow]) -> [WorkTask] {
        rows.compactMap { row in
            if case .task(let task, _) = row { return task }
            return nil
        }
    }

    private func taskFixture() -> WorkTask {
        let old = date("2024-01-01T00:00:00+08:00")
        return WorkTask(projectID: UUID(), title: "需要重新安排的工作", details: "保留任务明细", notes: "保留备注",
                        subtasks: [Subtask(title: "已做步骤", completedAt: old), Subtask(title: "待做步骤")],
                        attachments: [Attachment(name: "资料.txt", storedName: "fixture.txt", size: 10)],
                        dueAt: date("2024-03-25T18:00:00+08:00"), reminderAt: date("2024-03-20T09:00:00+08:00"),
                        repeatRule: RepeatRule(every: 6, unit: .month), createdAt: old,
                        updatedAt: date("2024-02-01T09:00:00+08:00"), seriesID: UUID(), plannedAt: old, planGranularity: .day)
    }

    func testGridGroupingPreservesTaskOrderAndWeekProjectCompletedHeadings() {
        let firstProject = Project(name: "第一个项目"), secondProject = Project(name: "第二个项目")
        let first = WorkTask(projectID: firstProject.id, title: "第一项")
        let second = WorkTask(projectID: firstProject.id, title: "第二项")
        let third = WorkTask(projectID: secondProject.id, title: "第三项")
        let completed = WorkTask(title: "已完成项", completedAt: date("2026-10-20T10:00:00+08:00"))
        let firstHeadings: [TaskListRow] = [.week(.thisWeek, 3, "pending"), .project(firstProject, 2, "pending:thisWeek")]
        let secondHeadings: [TaskListRow] = [.project(secondProject, 1, "pending:thisWeek")]
        let completedHeadings: [TaskListRow] = [.completed(1), .week(.thisWeek, 1, "completed"), .project(nil, 1, "completed:thisWeek")]
        let rows = firstHeadings + [.task(first, firstProject), .task(second, firstProject)]
            + secondHeadings + [.task(third, secondProject)] + completedHeadings + [.task(completed, nil)]

        let sections = TaskGridSection.grouped(rows)

        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections.map { $0.headings.map(\.id) }, [firstHeadings.map(\.id), secondHeadings.map(\.id), completedHeadings.map(\.id)])
        XCTAssertEqual(sections.map { taskValues($0.tasks) }, [[first, second], [third], [completed]])
        XCTAssertEqual(taskValues(sections.flatMap(\.tasks)), taskValues(rows), "分列不能重排、复制或丢失任务")
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
        XCTAssertTrue(sections.allSatisfy { $0.tasks.allSatisfy { if case .task = $0 { return true }; return false } })
        XCTAssertTrue(sections.allSatisfy { $0.headings.allSatisfy { if case .task = $0 { return false }; return true } })
    }

    func testGridGroupingOmitsEmptyAndTrailingHeadingOnlySections() {
        let headings: [TaskListRow] = [.week(.thisWeek, 0, "pending"), .project(nil, 0, "empty"), .completed(0)]
        XCTAssertTrue(TaskGridSection.grouped([]).isEmpty)
        XCTAssertTrue(TaskGridSection.grouped(headings).isEmpty)

        let task = WorkTask(title: "唯一任务")
        let rows: [TaskListRow] = [.week(.thisWeek, 1, "pending"), .task(task, nil)] + headings
        let sections = TaskGridSection.grouped(rows)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(taskValues(sections[0].tasks), [task])
        XCTAssertEqual(sections[0].headings.map(\.id), [rows[0].id])
        XCTAssertTrue(sections.allSatisfy { !$0.tasks.isEmpty })
    }

    func testRemovingPreviousProjectGroupKeepsRemainingGroupIdentity() throws {
        let firstProject = Project(name: "第一个项目"), secondProject = Project(name: "正在编辑的项目")
        for section in ["pending", "completed"] {
            let completion = section == "completed" ? date("2026-10-20T10:00:00+08:00") : nil
            let first = WorkTask(projectID: firstProject.id, title: "待移走的任务", completedAt: completion)
            let second = WorkTask(projectID: secondProject.id, title: "正在编辑的任务", completedAt: completion)
            let week = TaskListRow.week(.thisWeek, 2, section)
            let firstHeading = TaskListRow.project(firstProject, 1, "\(section):thisWeek")
            let secondHeading = TaskListRow.project(secondProject, 1, "\(section):thisWeek")
            let prefix: [TaskListRow] = section == "completed" ? [.completed(2), week] : [week]
            let afterWeek = TaskListRow.week(.thisWeek, 1, section)
            let afterPrefix: [TaskListRow] = section == "completed" ? [.completed(1), afterWeek] : [afterWeek]
            let before = TaskGridSection.grouped(prefix + [firstHeading, .task(first, firstProject), secondHeading, .task(second, secondProject)])
            let after = TaskGridSection.grouped(afterPrefix + [secondHeading, .task(second, secondProject)])
            let original = try XCTUnwrap(before.last), remaining = try XCTUnwrap(after.first)
            XCTAssertEqual(original.headings.map(\.id), [secondHeading.id])
            XCTAssertGreaterThan(remaining.headings.count, original.headings.count)
            XCTAssertEqual(original.id, remaining.id, "接手周或已完成标题，不应重建未修改项目的卡片和编辑框")
            XCTAssertEqual(taskValues(original.tasks), taskValues(remaining.tasks))
        }
    }

    func testUnheadedTasksRemainOneGroupWithIdentityDistinctFromLaterGroups() {
        let tasks = (1...4).map { WorkTask(title: "任务 \($0)") }
        let initialRows: [TaskListRow] = [.task(tasks[0], nil), .task(tasks[1], nil)]
        let unheaded = TaskGridSection.grouped(initialRows)
        XCTAssertEqual(unheaded.count, 1)
        XCTAssertTrue(unheaded[0].headings.isEmpty)
        XCTAssertEqual(taskValues(unheaded[0].tasks), Array(tasks.prefix(2)))

        let rows = initialRows + [.week(.nextWeek, 1, "pending"), .task(tasks[2], nil), .completed(1), .task(tasks[3], nil)]
        let sections = TaskGridSection.grouped(rows)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
        XCTAssertEqual(taskValues(sections.flatMap(\.tasks)), tasks)
    }

    func testDroppingOnAllPreservesEveryFieldForOpenAndCompletedTasks() throws {
        let task = taskFixture()
        let reference = date("2024-03-07T12:00:00+08:00")
        XCTAssertEqual(try TaskPlanDrop.applying(.all, to: task, relativeTo: reference, firstWeekday: 5, calendar: calendar()), task)
        var completed = task
        completed.completedAt = date("2024-02-15T14:00:00+08:00")
        completed.completionSource = "API"
        XCTAssertEqual(try TaskPlanDrop.applying(.all, to: completed, relativeTo: reference, firstWeekday: 2, calendar: calendar()), completed)
    }

    func testThisAndNextWeekDropClearOverdueWithoutChangingOtherTaskFields() throws {
        let task = taskFixture(), reference = date("2024-03-12T12:00:00+08:00"), calendar = calendar()
        for firstWeekday in [2, 5, 1] {
            XCTAssertTrue(task.isPlanOverdue(relativeTo: reference, firstWeekday: firstWeekday, calendar: calendar))
            for (filter, target) in [(TaskPlanFilter.thisWeek, date("2024-03-12T00:00:00+08:00")), (.nextWeek, date("2024-03-19T00:00:00+08:00"))] {
                let updated = try TaskPlanDrop.applying(filter, to: task, relativeTo: reference, firstWeekday: firstWeekday, calendar: calendar)
                var expected = task
                expected.plannedAt = target; expected.planGranularity = .week
                XCTAssertEqual(updated, expected)
                XCTAssertTrue(filter.includes(updated, relativeTo: reference, firstWeekday: firstWeekday, calendar: calendar))
                XCTAssertFalse(updated.isPlanOverdue(relativeTo: reference, firstWeekday: firstWeekday, calendar: calendar))
            }
        }
    }

    func testSpecificWeekDropNormalizesToConfiguredWeekStart() throws {
        let task = taskFixture(), reference = date("2024-03-07T12:00:00+08:00"), calendar = calendar()
        let anchor = date("2024-03-15T15:30:00+08:00")
        for (firstWeekday, expectedStart) in [(2, "2024-03-11T00:00:00+08:00"), (5, "2024-03-14T00:00:00+08:00"), (1, "2024-03-10T00:00:00+08:00")] {
            let updated = try TaskPlanDrop.applying(.week(anchor), to: task, relativeTo: reference, firstWeekday: firstWeekday, calendar: calendar)
            var expected = task
            expected.plannedAt = date(expectedStart); expected.planGranularity = .week
            XCTAssertEqual(updated, expected)
            XCTAssertEqual(calendar.component(.weekday, from: updated.plannedAt!), firstWeekday)
            XCTAssertFalse(updated.isPlanOverdue(relativeTo: reference, firstWeekday: firstWeekday, calendar: calendar))
        }
    }

    func testNextWeekDropPreservesLocalMidnightAcrossBothDSTChanges() throws {
        let calendar = calendar("America/Los_Angeles"), task = taskFixture()
        let cases: [(String, String, TimeInterval)] = [
            ("2024-03-07T12:00:00-08:00", "2024-03-14T00:00:00-07:00", 167 * 3600),
            ("2024-10-31T12:00:00-07:00", "2024-11-07T00:00:00-08:00", 169 * 3600),
        ]
        for (referenceText, targetText, elapsed) in cases {
            let reference = date(referenceText), target = date(targetText)
            for firstWeekday in [2, 5] {
                let updated = try TaskPlanDrop.applying(.nextWeek, to: task, relativeTo: reference, firstWeekday: firstWeekday, calendar: calendar)
                var expected = task
                expected.plannedAt = target; expected.planGranularity = .week
                XCTAssertEqual(updated, expected)
                XCTAssertEqual(target.timeIntervalSince(calendar.startOfDay(for: reference)), elapsed)
                XCTAssertTrue(TaskPlanFilter.nextWeek.includes(updated, relativeTo: reference, firstWeekday: firstWeekday, calendar: calendar))
                XCTAssertFalse(updated.isPlanOverdue(relativeTo: reference, firstWeekday: firstWeekday, calendar: calendar))
            }
        }
    }

    func testUnscheduledDropOnlyClearsIndependentPlan() throws {
        let task = taskFixture()
        let updated = try TaskPlanDrop.applying(.unscheduled, to: task, relativeTo: date("2024-03-07T12:00:00+08:00"), firstWeekday: 5, calendar: calendar())
        var expected = task
        expected.plannedAt = nil; expected.planGranularity = nil
        XCTAssertEqual(updated, expected)
        XCTAssertNil(updated.completedAt)
    }

    func testCompletedTasksRejectPlanChangesAndInvalidWeekDatesAreRejected() throws {
        let task = taskFixture(), reference = date("2024-03-07T12:00:00+08:00")
        var completed = task
        completed.completedAt = date("2024-02-15T14:00:00+08:00")
        for filter in [TaskPlanFilter.thisWeek, .nextWeek, .week(reference), .unscheduled] {
            XCTAssertThrowsError(try TaskPlanDrop.applying(filter, to: completed, relativeTo: reference, firstWeekday: 5, calendar: calendar())) { error in
                guard case LedgerError.invalid = error else { return XCTFail("应返回任务校验错误：\(error)") }
            }
        }
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try TaskPlanDrop.applying(.week(Date(timeIntervalSince1970: value)), to: task, relativeTo: reference, firstWeekday: 5, calendar: calendar()))
        }
        XCTAssertEqual(completed.plannedAt, task.plannedAt)
    }

    func testDisabledListEffectAlwaysKeepsThePageUntransformed() {
        let directions: [TaskListSlide?] = [nil, .horizontal(forward: true), .horizontal(forward: false), .vertical(forward: true), .vertical(forward: false)]
        for direction in directions {
            for progress: CGFloat in [-1, -0.5, 0, 0.5, 1] {
                let frame = TaskListEffect.none.presentation(at: progress, slide: direction, viewport: CGSize(width: 800, height: 600))
                XCTAssertEqual(frame.offset, .zero)
                XCTAssertEqual(frame.scale, 1)
                XCTAssertEqual(frame.opacity, 1)
            }
        }
    }
}
