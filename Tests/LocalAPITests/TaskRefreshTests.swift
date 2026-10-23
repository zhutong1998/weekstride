import Combine
import Foundation
import XCTest
import WorkLedgerCore
@testable import WorkLedger

final class TaskRefreshTests: XCTestCase {
    @MainActor func testOnlyChangedTaskPublishes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let first = WorkTask(title: "证书更新"), second = WorkTask(title: "版本发布")
        try store.saveTask(first); try store.saveTask(second)
        let firstState = TaskCardState(store: store, task: first)
        let secondState = TaskCardState(store: store, task: second)
        var firstChanges = 0, secondChanges = 0
        let firstSubscription = firstState.objectWillChange.sink { firstChanges += 1 }
        let secondSubscription = secondState.objectWillChange.sink { secondChanges += 1 }

        try store.updateTask(id: first.id) { $0.notes = "已确认续期窗口" }
        XCTAssertEqual(firstState.task.notes, "已确认续期窗口")
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 0)
        try store.updateTask(id: first.id) { $0.notes = "已确认续期窗口" }
        _ = try store.addProject(name: "与卡片无关的新项目")
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 0)
        try store.updateTask(id: second.id) { $0.title = "版本发布检查" }
        XCTAssertEqual(secondState.task.title, "版本发布检查")
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 1)
        withExtendedLifetime((firstSubscription, secondSubscription)) {}
    }

    @MainActor func testNextTaskOnlyRefreshesDisplayedLinkDependencies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let recurring = WorkTask(title: "每半年更新证书", dueAt: date, repeatRule: RepeatRule(every: 6, unit: .month))
        try store.saveTask(recurring)
        let result = try store.completeTask(id: recurring.id, at: date)
        let next = try XCTUnwrap(result.nextTask)
        let state = TaskCardState(store: store, task: result.task)
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }

        try store.updateTask(id: next.id) { $0.notes = "下一轮内部备注" }
        XCTAssertEqual(changes, 0)
        let updatedDue = try XCTUnwrap(next.dueAt).addingTimeInterval(86_400)
        try store.updateTask(id: next.id) { $0.dueAt = updatedDue }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(state.task.nextTaskID, next.id)
        try store.updateTask(id: next.id) { $0.dueAt = updatedDue }
        XCTAssertEqual(changes, 1)
        try store.updateTask(id: recurring.id) { $0.nextTaskID = nil }
        XCTAssertNil(state.task.nextTaskID)
        XCTAssertEqual(changes, 2)
        try store.updateTask(id: next.id) { $0.dueAt = updatedDue.addingTimeInterval(86_400) }
        XCTAssertEqual(changes, 2)
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testCompletionAndProjectMovePublishLatestTask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "网站运维")
        let task = WorkTask(title: "检查证书", notes: "保留备注")
        try store.saveTask(task)
        let state = TaskCardState(store: store, task: task)
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }

        try store.moveTask(id: task.id, toProject: project.id)
        XCTAssertEqual(state.task.projectID, project.id)
        let completion = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try store.completeTask(id: task.id, at: completion)
        XCTAssertEqual(state.task.completedAt, completion)
        XCTAssertEqual(state.task.notes, "保留备注")
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(state.task, try XCTUnwrap(store.data.tasks.first { $0.id == task.id }))
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testDeletedTaskDoesNotPublishOrRestoreItsSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let task = WorkTask(title: "将删除的任务"), other = WorkTask(title: "保留任务")
        try store.saveTask(task); try store.saveTask(other)
        let state = TaskCardState(store: store, task: task)
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }

        _ = try store.deleteTask(id: task.id)
        try store.updateTask(id: other.id) { $0.notes = "仅更新保留任务" }
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(store.data.tasks.contains { $0.id == task.id })
        XCTAssertThrowsError(try store.updateTask(id: task.id) { $0.notes = "不应恢复" })
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testDraftFirstSaveKeepsIDAndLatestFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        var draft = WorkTask(title: "")
        let state = TaskCardState(store: store, task: draft)
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }

        draft.title = "新任务"
        draft.details = "首次保存前填写的明细"
        draft.notes = "草稿备注"
        draft.subtasks = [Subtask(title: "第一步")]
        try store.saveTask(draft)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(state.task.id, draft.id)
        XCTAssertEqual(state.task, try XCTUnwrap(store.data.tasks.first))
        XCTAssertEqual(state.task.subtasks, draft.subtasks)
        try store.saveTask(state.task)
        XCTAssertEqual(changes, 1)
        let restoredState = TaskCardState(store: store, task: WorkTask(id: draft.id, title: "旧输入"))
        XCTAssertEqual(restoredState.task, state.task)
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testDraftPublisherRefreshesOnlyItsCardAndStopsAfterSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let saved = WorkTask(title: "已有任务")
        try store.saveTask(saved)
        var draft = WorkTask(title: "")
        let storage = TaskDraftStorage()
        storage.task = draft
        let draftState = TaskCardState(store: store, task: draft, draft: storage)
        let savedState = TaskCardState(store: store, task: saved)
        var draftCount = 0, savedCount = 0
        let draftSubscription = draftState.objectWillChange.sink { draftCount += 1 }
        let savedSubscription = savedState.objectWillChange.sink { savedCount += 1 }

        storage.task = draft
        XCTAssertEqual(draftCount, 0)
        draft.title = "本地草稿"
        draft.subtasks = [Subtask(title: "新步骤")]
        draft.notes = "尚未落盘的备注"
        storage.task = draft
        XCTAssertEqual(draftState.task, draft)
        XCTAssertEqual(draftCount, 1)
        XCTAssertEqual(savedCount, 0)
        XCTAssertFalse(store.data.tasks.contains { $0.id == draft.id })

        try store.saveTask(draft)
        let persisted = try XCTUnwrap(store.data.tasks.first { $0.id == draft.id })
        storage.task = nil
        draft.notes = "保存后到达的旧草稿"
        storage.task = draft
        storage.task = WorkTask(title: "另一个草稿")
        XCTAssertEqual(draftState.task, persisted)
        XCTAssertEqual(draftCount, 2)
        XCTAssertEqual(savedCount, 0)
        withExtendedLifetime((draftSubscription, savedSubscription)) {}
    }

    @MainActor func testSequentialDraftEditsAccumulateInSharedStorageBeforeSaving() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let initial = WorkTask(title: "")
        let storage = TaskDraftStorage()
        storage.task = initial
        let state = TaskCardState(store: store, task: initial, draft: storage)
        let child = Subtask(title: "明细填写后的子任务")

        storage.update(taskID: initial.id) { $0.details = "草稿明细失焦后必须保留显示" }
        XCTAssertEqual(state.task.details, "草稿明细失焦后必须保留显示")
        storage.update(taskID: initial.id) { $0.subtasks.append(child) }
        XCTAssertEqual(state.task.subtasks, [child])
        XCTAssertEqual(state.task.details, "草稿明细失焦后必须保留显示")
        storage.update(taskID: initial.id) { $0.notes = "最后填写的备注" }
        XCTAssertEqual(state.task.details, "草稿明细失焦后必须保留显示")
        XCTAssertEqual(state.task.subtasks, [child])
        XCTAssertEqual(state.task.notes, "最后填写的备注")
        XCTAssertTrue(store.data.tasks.isEmpty)

        storage.update(taskID: initial.id) { $0.title = "最后填写标题再保存" }
        try store.saveTask(XCTUnwrap(storage.task))
        storage.task = nil
        let persisted = try XCTUnwrap(store.data.tasks.first)
        XCTAssertEqual(persisted.id, initial.id)
        XCTAssertEqual(persisted.details, "草稿明细失焦后必须保留显示")
        XCTAssertEqual(persisted.subtasks, [child])
        XCTAssertEqual(persisted.notes, "最后填写的备注")
        XCTAssertEqual(state.task, persisted)

        let replacement = WorkTask(title: "另一张新草稿")
        storage.task = replacement
        XCTAssertNil(storage.update(taskID: initial.id) { $0.notes = "旧卡片回调不应写入新草稿" })
        XCTAssertEqual(storage.task, replacement)
        XCTAssertEqual(state.task, persisted)
    }
}
