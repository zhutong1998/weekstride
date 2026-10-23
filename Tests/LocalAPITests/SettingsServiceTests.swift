import Foundation
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class SettingsServiceTests: XCTestCase {
    func testHealthCheckRequiresSuccessfulStatusAndExpectedJSON() {
        let healthy = AppServices.healthMessage(data: Data(#"{"status":"ok"}"#.utf8), status: 200)
        for body in [#"{"status":"error"}"#, #"{"error":"failure"}"#, "[]", "null", "invalid"] {
            let rejected = AppServices.healthMessage(data: Data(body.utf8), status: 200)
            XCTAssertNotEqual(rejected, healthy)
            XCTAssertTrue(rejected.contains("200"))
        }
        XCTAssertNotEqual(AppServices.healthMessage(data: Data(#"{"status":"ok"}"#.utf8), status: 401), healthy)
        XCTAssertNotEqual(AppServices.healthMessage(data: Data(#"{"status":"ok"}"#.utf8), status: 500), healthy)
    }

    func testResumingRemindersSuppressesOnlyExistingMissedReminders() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let overdue = WorkTask(title: "暂停期间已到", reminderAt: now.addingTimeInterval(-60))
        let boundary = WorkTask(title: "刚好到点", reminderAt: now)
        let future = WorkTask(title: "未来继续提醒", reminderAt: now.addingTimeInterval(60))
        var completed = WorkTask(title: "已经完成", reminderAt: now.addingTimeInterval(-60))
        completed.completedAt = now
        let noReminder = WorkTask(title: "没有提醒")
        let tasks = [overdue, boundary, future, completed, noReminder]
        let original = tasks
        let suppressed = TaskReminderPlan.keysToSuppressAfterResuming(tasks, through: now)
        XCTAssertEqual(suppressed, Set([try XCTUnwrap(TaskReminderPlan.key(for: overdue)), try XCTUnwrap(TaskReminderPlan.key(for: boundary))]))
        let plan = TaskReminderPlan(tasks: tasks, pending: [], delivered: [], handledKeys: suppressed, now: now, calendar: .current)
        XCTAssertEqual(plan.additions.map(\.request.identifier), ["task-\(future.id.uuidString)"])
        XCTAssertEqual(tasks, original, "暂停与恢复系统提醒不能改写任务日期或完成记录")
    }

    func testBackupEditBoundaryRejectsFailedSaveAndTargetsEveryTask() {
        var seen = false
        let observer = NotificationCenter.default.addObserver(forName: finishTaskEdits, object: nil, queue: nil) { note in
            guard let request = note.object as? TaskEditingExitRequest else { return }
            seen = true
            XCTAssertNil(request.taskID)
            request.failed = true
        }
        XCTAssertFalse(AppServices.finishPendingTaskEdits())
        XCTAssertTrue(seen)
        NotificationCenter.default.removeObserver(observer)
        XCTAssertTrue(AppServices.finishPendingTaskEdits())
    }
}
