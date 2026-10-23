import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class ReminderRefreshTests: XCTestCase {
    func testSlowOldReminderFinishesBeforeLatestSnapshotIsApplied() async throws {
        let project = UUID()
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let old = WorkTask(projectID: project, title: "旧提醒", reminderAt: date)
        let middle = WorkTask(projectID: project, title: "中间状态", reminderAt: date)
        let latest = WorkTask(projectID: project, title: "最新提醒", reminderAt: date)
        var writes: [String] = []
        var release: CheckedContinuation<Void, Never>?
        var activeWriters = 0
        var mostWriters = 0
        let queue = ReminderRefreshQueue { tasks in
            activeWriters += 1
            mostWriters = max(mostWriters, activeWriters)
            defer { activeWriters -= 1 }
            let title = tasks[0].title
            writes.append(title)
            if title == old.title { await withCheckedContinuation { release = $0 } }
            return title
        }
        let first = Task { try await queue.update([old]) }
        while release == nil { await Task.yield() }
        let second = try await queue.update([middle])
        let third = try await queue.update([latest])
        XCTAssertNil(second)
        XCTAssertNil(third)
        release?.resume()
        let status = try await first.value
        XCTAssertEqual(writes, [old.title, latest.title])
        XCTAssertEqual(mostWriters, 1)
        XCTAssertEqual(status, latest.title)
    }

    func testOnlyNotificationFieldsTriggerReplacement() async throws {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        var task = WorkTask(projectID: nil, title: "证书提醒", details: String(repeating: "a", count: 160), reminderAt: date)
        var other = WorkTask(projectID: nil, title: "没有提醒")
        var writes = 0
        let queue = ReminderRefreshQueue { _ in writes += 1; return "已安排" }
        _ = try await queue.update([task, other])
        task.notes = "只修改备注"
        task.plannedAt = date
        task.dueAt = date
        task.updatedAt = date
        task.details += "通知正文以外的内容"
        other.title = "修改未设置提醒的任务"
        let unchanged = try await queue.update([other, task])
        XCTAssertNil(unchanged)
        XCTAssertEqual(writes, 1)

        task.title = "新的提醒标题"
        _ = try await queue.update([task, other])
        XCTAssertEqual(writes, 2)
        task.reminderAt = date.addingTimeInterval(60)
        _ = try await queue.update([task, other])
        XCTAssertEqual(writes, 3)
        task.completedAt = date
        _ = try await queue.update([task, other])
        XCTAssertEqual(writes, 4)
        _ = try await queue.update([task, other], force: true)
        XCTAssertEqual(writes, 5, "权限变化后仍可强制重新同步系统通知")
    }

    func testDuplicateQueuedWhileApplyingDoesNotWriteAgain() async throws {
        var task = WorkTask(projectID: nil, title: "提醒", reminderAt: Date(timeIntervalSince1970: 2_000_000_000))
        var release: CheckedContinuation<Void, Never>?
        var writes = 0
        let queue = ReminderRefreshQueue { _ in
            writes += 1
            await withCheckedContinuation { release = $0 }
            return "已安排"
        }
        let first = Task { try await queue.update([task]) }
        while release == nil { await Task.yield() }
        task.notes = "进行中的无关修改"
        _ = try await queue.update([task])
        release?.resume()
        _ = try await first.value
        XCTAssertEqual(writes, 1)
    }

    func testOtherCompletedNoReminderDoesNotApplySnapshot() async throws {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        var reminder = WorkTask(title: "保留的提醒", reminderAt: date)
        var other = WorkTask(title: "无提醒任务")
        var writes = 0
        let queue = ReminderRefreshQueue { _ in writes += 1; return "已安排" }
        _ = try await queue.update([reminder, other])
        other.completedAt = date
        let completedOther = try await queue.update([reminder, other])
        XCTAssertNil(completedOther)
        let deletedOther = try await queue.update([reminder])
        XCTAssertNil(deletedOther)
        XCTAssertEqual(writes, 1, "无提醒任务完成或删除不应查询系统通知")

        reminder.completedAt = date
        _ = try await queue.update([reminder])
        XCTAssertEqual(writes, 2, "真正有提醒的任务完成仍需要清理通知")
        let removedHistory = try await queue.update([])
        XCTAssertNil(removedHistory)
        XCTAssertEqual(writes, 2)
    }

    func testFailedReplacementCanRetrySameSnapshot() async throws {
        struct Failure: Error {}
        let task = WorkTask(projectID: nil, title: "提醒", reminderAt: Date(timeIntervalSince1970: 2_000_000_000))
        var writes = 0
        let queue = ReminderRefreshQueue { _ in
            writes += 1
            if writes == 1 { throw Failure() }
            return "已安排"
        }
        do {
            _ = try await queue.update([task])
            XCTFail("第一次写入应失败")
        } catch is Failure {}
        let status = try await queue.update([task])
        XCTAssertEqual(status, "已安排")
        XCTAssertEqual(writes, 2)
    }
}
