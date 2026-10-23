import XCTest
import UserNotifications
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class TaskReminderPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func plan(_ tasks: [WorkTask], pending: [UNNotificationRequest] = [],
                      delivered: [UNNotificationRequest] = [], handled: Set<String> = []) -> TaskReminderPlan {
        TaskReminderPlan(tasks: tasks, pending: pending, delivered: delivered, handledKeys: handled, now: now, calendar: calendar)
    }

    func testMissedReminderIsCaughtUpOnlyOnceAfterRestartAndTitleChange() throws {
        var task = WorkTask(title: "只有提醒，没有截止日期", reminderAt: now.addingTimeInterval(-3600))
        let first = plan([task])
        let addition = try XCTUnwrap(first.additions.first)
        let key = try XCTUnwrap(addition.missedKey)
        XCTAssertEqual(first.additions.count, 1)
        XCTAssertTrue(addition.request.trigger is UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(addition.request.content.userInfo["taskID"] as? String, task.id.uuidString)

        task.title = "修改标题不能再次补发"
        let queued = plan([task], pending: [addition.request], handled: [key])
        XCTAssertTrue(queued.additions.isEmpty)
        XCTAssertTrue(queued.removePending.isEmpty, "补发已成功提交但尚未显示时，应保留请求")
        XCTAssertTrue(plan([task], handled: [key]).additions.isEmpty, "重启后即使系统通知已被清除，也不能重复补发")

        task.reminderAt = now.addingTimeInterval(-60)
        XCTAssertEqual(plan([task], handled: [key]).additions.count, 1, "重新设置的提醒日期是一个新提醒")
    }

    func testDeliveredReminderIsRecordedWithoutAnotherCatchup() throws {
        let task = WorkTask(title: "已显示", reminderAt: now.addingTimeInterval(-60))
        let request = try XCTUnwrap(plan([task]).additions.first?.request)
        let result = plan([task], pending: [request], delivered: [request])
        XCTAssertTrue(result.additions.isEmpty)
        XCTAssertEqual(result.deliveredKeys, [try XCTUnwrap(TaskReminderPlan.key(for: task))])
        XCTAssertEqual(result.removePending, [request.identifier])
        XCTAssertTrue(result.removeDelivered.isEmpty)

        let legacyContent = UNMutableNotificationContent()
        legacyContent.userInfo = ["taskID": task.id.uuidString]
        let legacy = UNNotificationRequest(identifier: request.identifier, content: legacyContent, trigger: nil)
        XCTAssertEqual(plan([task], delivered: [legacy]).additions.count, 1, "无法识别提醒日期的旧通知不能证明当前提醒已经投递")
    }

    func testLegacyDeliveredDateMustMatchCurrentReminderBeforeSuppressingCatchup() throws {
        var task = WorkTask(title: "旧版通知日期核对", reminderAt: now.addingTimeInterval(-3600))
        let content = UNMutableNotificationContent()
        content.userInfo = ["taskID": task.id.uuidString]
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: task.reminderAt!)
        let legacy = UNNotificationRequest(identifier: "task-\(task.id.uuidString)", content: content,
                                           trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        let matching = plan([task], delivered: [legacy])
        XCTAssertTrue(matching.additions.isEmpty)
        XCTAssertEqual(matching.deliveredKeys, [try XCTUnwrap(TaskReminderPlan.key(for: task))])
        XCTAssertTrue(matching.removeDelivered.isEmpty)

        task.reminderAt = now.addingTimeInterval(-60)
        let changed = plan([task], delivered: [legacy])
        XCTAssertEqual(changed.additions.count, 1, "旧日期R1已投递不应阻止改成R2后的新提醒")
        XCTAssertTrue(changed.deliveredKeys.isEmpty, "不能把旧通知永久记录为新日期已投递")
        XCTAssertEqual(changed.removeDelivered, [legacy.identifier])
    }

    func testReconcileKeepsValidRequestsAndRemovesDeletedCompletedOrClearedReminders() throws {
        var changed = WorkTask(title: "需更新内容", reminderAt: now.addingTimeInterval(3600))
        let unchanged = WorkTask(title: "保持有效", reminderAt: now.addingTimeInterval(7200))
        var completed = WorkTask(title: "已完成", reminderAt: now.addingTimeInterval(3600))
        var cleared = WorkTask(title: "移除提醒", reminderAt: now.addingTimeInterval(3600))
        let deleted = WorkTask(title: "已删除", reminderAt: now.addingTimeInterval(3600))
        let original = plan([changed, unchanged, completed, cleared, deleted]).additions.map(\.request)
        let unrelated = UNNotificationRequest(identifier: "test", content: UNMutableNotificationContent(), trigger: nil)
        changed.title = "新内容"
        completed.completedAt = now
        cleared.reminderAt = nil
        let result = plan([changed, unchanged, completed, cleared], pending: original + [unrelated])
        XCTAssertEqual(result.additions.map(\.request.identifier), ["task-\(changed.id.uuidString)"])
        XCTAssertEqual(Set(result.removePending), Set([completed, cleared, deleted].map { "task-\($0.id.uuidString)" }))
        XCTAssertFalse(result.removePending.contains("task-\(changed.id.uuidString)"), "替换失败时应保留旧的有效请求")
        XCTAssertEqual(result.futureCount, 2)

        let oldDelivered = try XCTUnwrap(plan([WorkTask(id: deleted.id, title: "旧通知", reminderAt: now.addingTimeInterval(-60))]).additions.first?.request)
        XCTAssertEqual(plan([], delivered: [oldDelivered]).removeDelivered, [oldDelivered.identifier])
    }

    func testChangingReminderDateClearsOldDeliveredNotification() throws {
        var task = WorkTask(title: "重新安排", reminderAt: now.addingTimeInterval(-3600))
        let previous = try XCTUnwrap(plan([task]).additions.first?.request)
        task.reminderAt = now.addingTimeInterval(-60)
        let result = plan([task], delivered: [previous])
        XCTAssertEqual(result.removeDelivered, [previous.identifier])
        XCTAssertEqual(result.additions.count, 1)

        let pending = plan([WorkTask(id: task.id, title: task.title, reminderAt: now.addingTimeInterval(60))]).additions.map(\.request)
        task.reminderAt = now.addingTimeInterval(3600)
        let rescheduled = plan([task], pending: pending)
        XCTAssertEqual(rescheduled.removePending, pending.map(\.identifier), "已改日期的旧请求失效，应移除，不能在替换失败时仍按旧日期提醒")
        XCTAssertEqual(rescheduled.additions.count, 1)
    }

    func testFutureTriggerCarriesExplicitCalendarAndTimeZone() throws {
        let task = WorkTask(title: "绝对提醒时刻", reminderAt: Date(timeIntervalSince1970: 1_900_000_000))
        for zone in ["Asia/Shanghai", "America/Los_Angeles"] {
            var calendar = calendar
            calendar.timeZone = TimeZone(identifier: zone)!
            let result = TaskReminderPlan(tasks: [task], pending: [], delivered: [], handledKeys: [], now: now, calendar: calendar)
            let trigger = try XCTUnwrap(result.additions.first?.request.trigger as? UNCalendarNotificationTrigger)
            XCTAssertEqual(trigger.dateComponents.timeZone, calendar.timeZone)
            XCTAssertEqual(trigger.dateComponents.calendar?.identifier, calendar.identifier)
            XCTAssertEqual(calendar.date(from: trigger.dateComponents), task.reminderAt)
        }
    }

    func testRetryAfterPartialFailureDoesNotRepeatSuccessfulCatchup() throws {
        let caughtUp = WorkTask(title: "成功补发", reminderAt: now.addingTimeInterval(-3600))
        let retry = WorkTask(title: "此前失败", reminderAt: now.addingTimeInterval(-60))
        let first = plan([caughtUp, retry])
        let succeeded = try XCTUnwrap(first.additions.first)
        let result = plan([caughtUp, retry], pending: [succeeded.request], handled: [try XCTUnwrap(succeeded.missedKey)])
        XCTAssertEqual(result.additions.map(\.request.identifier), ["task-\(retry.id.uuidString)"])
        XCTAssertTrue(result.removePending.isEmpty)
    }

    func testJustReachedCalendarRequestGetsDeliveryGraceBeforeCatchup() throws {
        let task = WorkTask(title: "等待系统正常投递", reminderAt: now)
        let before = TaskReminderPlan(tasks: [task], pending: [], delivered: [], handledKeys: [],
                                      now: now.addingTimeInterval(-1), calendar: calendar)
        let original = try XCTUnwrap(before.additions.first?.request)
        for offset in [0.0, 30, 59] {
            let waiting = TaskReminderPlan(tasks: [task], pending: [original], delivered: [], handledKeys: [],
                                           now: now.addingTimeInterval(offset), calendar: calendar)
            XCTAssertTrue(waiting.additions.isEmpty, "正常日历通知正在投递时，不应改成补发以免双弹")
            XCTAssertTrue(waiting.removePending.isEmpty)
        }
        let retryDate = now.addingTimeInterval(TaskReminderPlan.deliveryGrace)
        XCTAssertEqual(TaskReminderPlan.nextCheckDate(for: [now], now: now), retryDate)
        let expired = TaskReminderPlan(tasks: [task], pending: [original], delivered: [], handledKeys: [], now: retryDate, calendar: calendar)
        XCTAssertEqual(expired.additions.count, 1)
        XCTAssertTrue(expired.additions.first?.request.trigger is UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(expired.additions.first?.request.identifier, original.identifier, "仍使用同一标识替换残留的旧请求")
        XCTAssertNil(TaskReminderPlan.nextCheckDate(for: [now], now: retryDate))

        let delivered = TaskReminderPlan(tasks: [task], pending: [], delivered: [original], handledKeys: [], now: retryDate, calendar: calendar)
        XCTAssertTrue(delivered.additions.isEmpty, "宽限期内已经投递的提醒无需补发")
    }

    func testTaskIssueExplainsPermissionFailureAndReachedReminder() {
        var task = WorkTask(title: "提醒状态", reminderAt: now.addingTimeInterval(60))
        XCTAssertNil(AppServices.reminderIssue(for: task, authorization: .authorized, error: nil, now: now))
        XCTAssertTrue(AppServices.reminderIssue(for: task, authorization: .notDetermined, error: nil, now: now)!.contains("尚未开启通知"))
        XCTAssertTrue(AppServices.reminderIssue(for: task, authorization: .denied, error: nil, now: now)!.contains("系统设置"))
        XCTAssertTrue(AppServices.reminderIssue(for: task, authorization: .authorized, error: "安排失败", now: now)!.contains("安排失败"))
        task.reminderAt = now.addingTimeInterval(-1)
        XCTAssertEqual(AppServices.reminderIssue(for: task, authorization: .authorized, error: nil, now: now), "提醒时间已到，请处理或重新安排。")
        task.completedAt = now
        XCTAssertNil(AppServices.reminderIssue(for: task, authorization: .denied, error: "失败", now: now))
    }
}
