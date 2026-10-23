import Combine
import Foundation
import XCTest
import WorkLedgerCore
@testable import WorkLedger

final class TaskListRefreshTests: XCTestCase {
    func testRemovedPersistedPinIsDetectedFromLatestSnapshot() {
        let pinned = WorkTask(title: "已保存但仍在编辑的任务"), other = WorkTask(title: "保留任务")
        let displayed = TaskListStructure(data: LedgerData(tasks: [other]))
        let pending = TaskListStructure(data: LedgerData(tasks: [pinned, other]))
        let after = TaskListStructure(data: LedgerData(tasks: [other]))

        XCTAssertTrue(after.removesTask(pinned.id, comparedTo: pending), "备份或删除移除已落盘的pin时，必须清除创建会话")
        XCTAssertFalse(after.removesTask(other.id, comparedTo: pending))
        XCTAssertFalse(after.removesTask(pinned.id, comparedTo: displayed), "尚未展示的保存变动需要以pending快照比较")
        XCTAssertFalse(pending.removesTask(pinned.id, comparedTo: after), "新增记录不是移除")
    }

    func testUnsavedDraftMissingFromBothSnapshotsIsNotRemoved() {
        let draft = WorkTask(title: "尚未落盘的草稿"), other = WorkTask(title: "已有任务")
        let before = TaskListStructure(data: LedgerData(tasks: [other]))
        let after = TaskListStructure(data: LedgerData(tasks: [other, WorkTask(title: "另一新增任务")]))

        XCTAssertFalse(after.removesTask(draft.id, comparedTo: before), "不能把从未出现在store里的草稿当作删除")
        let empty = TaskListStructure(data: LedgerData())
        XCTAssertFalse(empty.removesTask(draft.id, comparedTo: empty))
    }

    func testUpdatedRetainedOrSearchHiddenTaskIsNotRemoved() {
        let task = WorkTask(title: "原任务"), other = WorkTask(title: "其他任务")
        let before = TaskListStructure(data: LedgerData(tasks: [task, other]))
        var edited = task
        edited.title = "修改后的任务"
        edited.notes = "保留其他字段"
        edited.plannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        edited.planGranularity = .week
        edited.completedAt = edited.plannedAt
        let after = TaskListStructure(data: LedgerData(tasks: [other, edited]), search: "不会命中的关键词")

        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.matchingTaskIDs, [])
        XCTAssertFalse(after.removesTask(task.id, comparedTo: before), "修改、完成、排序或搜索隐藏都不等于删除")
        XCTAssertFalse(after.removesTask(other.id, comparedTo: before))
        XCTAssertFalse(before.removesTask(task.id, comparedTo: before))
    }

    func testCompletionFeedbackOnlyHoldsNewlyCompletedVisibleTasks() {
        let task = WorkTask(title: "检查证书"), hidden = WorkTask(title: "其他项目")
        let before = TaskListStructure(data: LedgerData(tasks: [task, hidden]))
        var done = task, hiddenDone = hidden
        done.completedAt = Date(); hiddenDone.completedAt = Date()
        let after = TaskListStructure(data: LedgerData(tasks: [done, hiddenDone]))
        XCTAssertTrue(after.needsCompletionFeedback(comparedTo: before, visibleIDs: [task.id]))
        XCTAssertFalse(after.needsCompletionFeedback(comparedTo: before, visibleIDs: []))
        XCTAssertFalse(after.needsCompletionFeedback(comparedTo: after, visibleIDs: [task.id]))
        XCTAssertFalse(before.needsCompletionFeedback(comparedTo: after, visibleIDs: [task.id]), "撤销完成不应等待")
        var dateEdit = done
        dateEdit.completedAt = Date().addingTimeInterval(-1)
        XCTAssertFalse(TaskListStructure(data: LedgerData(tasks: [dateEdit])).needsCompletionFeedback(comparedTo: after, visibleIDs: [task.id]))
    }

    func testPresentationSnapshotCannotBeChangedByLaterStoreEdits() {
        var data = LedgerData(tasks: [WorkTask(title: "检查证书")])
        let snapshot = TaskListStructure(data: data)
        data.tasks[0].completedAt = Date()
        XCTAssertNil(snapshot.presentationData.tasks[0].completedAt)
        XCTAssertNotEqual(snapshot, TaskListStructure(data: data))
        data.tasks[0].completedAt = nil
        data.tasks[0].notes = "仅改备注不刷新列表"
        XCTAssertEqual(snapshot, TaskListStructure(data: data))
    }
    @MainActor func testContentAndPartialSubtaskChangesOnlyPublishToTaskObservers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let task = WorkTask(title: "证书更新", subtasks: [Subtask(title: "检查"), Subtask(title: "更新")])
        try store.saveTask(task)
        var listChanges = 0, dataChanges = 0
        let listSubscription = TaskListStructure.changes(in: store).sink { _ in listChanges += 1 }
        let dataSubscription = store.$data.sink { _ in dataChanges += 1 }

        try store.updateTask(id: task.id) { $0.title = "更新证书和部署脚本" }
        try store.updateTask(id: task.id) { $0.details = "先检查有效期，再更新部署文件" }
        try store.updateTask(id: task.id) { $0.notes = "已与同事确认" }
        try store.updateTask(id: task.id) { $0.subtasks[0].title = "检查证书有效期" }
        let file = directory.appendingPathComponent("说明.txt")
        try Data("附件内容".utf8).write(to: file)
        try store.addAttachments(urls: [file], to: task.id)
        try store.updateTask(id: task.id) { $0.repeatRule = RepeatRule(every: 6, unit: .month) }
        _ = try store.completeSubtask(taskID: task.id, subtaskID: task.subtasks[0].id)

        XCTAssertGreaterThan(dataChanges, 1)
        XCTAssertEqual(listChanges, 1, "Only the initial list structure should be published")
        XCTAssertNil(try XCTUnwrap(store.data.tasks.first).completedAt)
        withExtendedLifetime((listSubscription, dataSubscription)) {}
    }

    @MainActor func testListMembershipOrderingAndCountsPublishWhenTheyChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "网站运维")
        let task = WorkTask(title: "检查网站")
        try store.saveTask(task)
        var changes = 0
        let subscription = TaskListStructure.changes(in: store).sink { _ in changes += 1 }

        try store.updateTask(id: task.id) { $0.plannedAt = Date(); $0.planGranularity = .week }
        XCTAssertEqual(changes, 2)
        try store.updateTask(id: task.id) { $0.planGranularity = .day }
        XCTAssertEqual(changes, 3)
        try store.updateTask(id: task.id) { $0.dueAt = Date().addingTimeInterval(86_400) }
        XCTAssertEqual(changes, 4)
        try store.updateTask(id: task.id) { $0.reminderAt = Date() }
        XCTAssertEqual(changes, 5, "Reminder changes can add or remove tasks from pending reminders")
        try store.moveTask(id: task.id, toProject: project.id)
        XCTAssertEqual(changes, 6)
        _ = try store.completeTask(id: task.id)
        XCTAssertEqual(changes, 7)
        let added = WorkTask(title: "新增任务")
        try store.saveTask(added)
        XCTAssertEqual(changes, 8)
        let deleted = try store.deleteTask(id: added.id)
        XCTAssertEqual(changes, 9)
        try store.restoreDeletedTask(deleted)
        XCTAssertEqual(changes, 10)
        try store.archiveProject(id: project.id)
        XCTAssertEqual(changes, 11)
        try store.unarchiveProject(id: project.id)
        XCTAssertEqual(changes, 12)
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testSearchPublishesOnlyWhenMatchingIDsChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "证书运维")
        let task = WorkTask(title: "普通任务", subtasks: [Subtask(title: "检查")])
        let projectMatch = WorkTask(projectID: project.id, title: "项目名称匹配")
        try store.saveTask(task); try store.saveTask(projectMatch)
        var matches: [Set<UUID>?] = []
        let subscription = TaskListStructure.changes(in: store, search: "证书").sink { matches.append($0.matchingTaskIDs) }

        XCTAssertEqual(matches, [Set([projectMatch.id])])
        try store.updateTask(id: task.id) { $0.notes = "需要更新证书" }
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.last!, Set([task.id, projectMatch.id]))
        try store.updateTask(id: task.id) { $0.notes = "需要更新证书并部署" }
        try store.updateTask(id: task.id) { $0.details = "证书有效期检查" }
        try store.updateTask(id: task.id) { $0.notes = "" }
        XCTAssertEqual(matches.count, 2, "Edits retaining the same matches must not refresh the list")
        try store.updateTask(id: task.id) { $0.details = "" }
        XCTAssertEqual(matches.count, 3)
        try store.updateTask(id: task.id) { $0.subtasks[0].title = "检查证书" }
        XCTAssertEqual(matches.count, 4)
        try store.updateTask(id: task.id) {
            $0.attachments = [Attachment(name: "证书说明.txt", storedName: "test-certificate.txt", size: 0)]
            $0.subtasks[0].title = "检查"
        }
        XCTAssertEqual(matches.count, 4)
        try store.updateTask(id: task.id) { $0.attachments[0].name = "部署说明.txt" }
        XCTAssertEqual(matches.count, 5)
        XCTAssertEqual(matches.last!, Set([projectMatch.id]))
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testErrorsRemainIndependentOfListChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        var changes = 0
        var errors: [String?] = []
        let listSubscription = TaskListStructure.changes(in: store).sink { _ in changes += 1 }
        let errorSubscription = store.$errorMessage.removeDuplicates().sink { errors.append($0) }

        store.errorMessage = "保存失败，请检查磁盘空间"
        store.errorMessage = "保存失败，请检查磁盘空间"
        store.errorMessage = nil
        XCTAssertEqual(errors, [nil, "保存失败，请检查磁盘空间", nil])
        XCTAssertEqual(changes, 1)
        withExtendedLifetime((listSubscription, errorSubscription)) {}
    }
}
