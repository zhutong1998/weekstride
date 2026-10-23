import Foundation
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class TaskUndoTests: XCTestCase {
    private func store() throws -> WorkStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaskUndoTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try WorkStore(directory: directory)
    }

    func testStepCompletionUndoPreservesLaterEditsAndRejectsNewCompletion() throws {
        let store = try store()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let child = Subtask(title: "检查证书")
        let task = WorkTask(title: "发布", subtasks: [child, Subtask(title: "验证部署")])
        try store.saveTask(task)
        _ = try store.completeSubtask(taskID: task.id, subtaskID: child.id, at: date)
        let undo = TaskOperationUndo.subtaskCompletion(taskID: task.id, subtaskID: child.id, before: nil, after: date)
        try store.updateTask(id: task.id) { $0.notes = "保留后续工作"; $0.subtasks[0].title = "检查完整证书链" }
        let restored = try undo.apply(to: store)
        XCTAssertNil(restored.subtasks[0].completedAt)
        XCTAssertEqual(restored.subtasks[0].id, child.id)
        XCTAssertEqual(restored.subtasks[0].title, "检查完整证书链")
        XCTAssertEqual(restored.notes, "保留后续工作")
        _ = try store.completeSubtask(taskID: task.id, subtaskID: child.id, at: date.addingTimeInterval(60))
        let changed = store.data
        XCTAssertThrowsError(try undo.apply(to: store))
        XCTAssertEqual(store.data, changed)
    }

    func testCancelStepCanBeUndoneWithOriginalCompletionDate() throws {
        let store = try store()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let child = Subtask(title: "已完成步骤", completedAt: date)
        let task = WorkTask(title: "恢复进度", subtasks: [child, Subtask(title: "后续步骤")])
        try store.saveTask(task)
        try store.undoSubtaskCompletion(taskID: task.id, subtaskID: child.id)
        let restored = try TaskOperationUndo.subtaskCompletion(taskID: task.id, subtaskID: child.id, before: date, after: nil).apply(to: store)
        XCTAssertEqual(restored.subtasks[0].completedAt, date)
        XCTAssertNil(restored.subtasks[1].completedAt)
        XCTAssertNil(restored.completedAt)
    }

    func testRemovedStepRestoresPositionAndDateWithoutReplacingOtherWork() throws {
        let store = try store()
        let first = Subtask(title: "第一步"), removed = Subtask(title: "第二步", completedAt: Date()), last = Subtask(title: "第三步")
        let task = WorkTask(title: "整理资料", subtasks: [first, removed, last])
        try store.saveTask(task)
        try store.updateTask(id: task.id) { $0.subtasks.remove(at: 1) }
        let undo = TaskOperationUndo.removedSubtask(taskID: task.id, child: removed, index: 1, parentCompletedAt: nil)
        try store.updateTask(id: task.id) { $0.notes = "新备注"; $0.subtasks.append(Subtask(title: "新步骤")) }
        let restored = try undo.apply(to: store)
        XCTAssertEqual(Array(restored.subtasks.prefix(3)), [first, removed, last])
        XCTAssertEqual(restored.subtasks.last?.title, "新步骤")
        XCTAssertEqual(restored.notes, "新备注")
        XCTAssertThrowsError(try undo.apply(to: store), "恢复两次不能产生重复ID")
        XCTAssertEqual(try WorkStore(directory: store.directory).data, store.data)
    }

    func testUndoStepCancellationCannotSilentlyCompleteChangedParentOrCreateNextCycle() throws {
        let store = try store()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Subtask(title: "已完成", completedAt: date), second = Subtask(title: "待完成")
        let task = WorkTask(title: "跨入口修改", subtasks: [first, second], repeatRule: RepeatRule())
        try store.saveTask(task)
        try store.undoSubtaskCompletion(taskID: task.id, subtaskID: first.id)
        let undo = TaskOperationUndo.subtaskCompletion(taskID: task.id, subtaskID: first.id, before: date, after: nil)
        _ = try store.completeSubtask(taskID: task.id, subtaskID: second.id, at: date, source: "API")
        let changed = store.data
        XCTAssertThrowsError(try undo.apply(to: store))
        XCTAssertEqual(store.data, changed)
        XCTAssertEqual(store.data.tasks.count, 1)
        XCTAssertNil(store.data.tasks[0].completedAt)
        XCTAssertNil(store.data.tasks[0].nextTaskID)
    }

    func testStepRemovalUndoRejectsParentCompletionOrTaskDeletion() throws {
        let store = try store()
        let child = Subtask(title: "待恢复步骤")
        let task = WorkTask(title: "随后已完成", subtasks: [child])
        try store.saveTask(task)
        try store.updateTask(id: task.id) { $0.subtasks = [] }
        let undo = TaskOperationUndo.removedSubtask(taskID: task.id, child: child, index: 0, parentCompletedAt: nil)
        _ = try store.completeTask(id: task.id)
        let completed = store.data
        XCTAssertThrowsError(try undo.apply(to: store))
        XCTAssertEqual(store.data, completed)
        _ = try store.deleteTask(id: task.id)
        XCTAssertThrowsError(try undo.apply(to: store))
        XCTAssertTrue(store.data.tasks.isEmpty)
    }

    private func attachedTask(in store: WorkStore) throws -> (WorkTask, Attachment) {
        let task = WorkTask(title: "附件恢复")
        try store.saveTask(task)
        let source = store.directory.appendingPathComponent("source.txt")
        try Data("审查合成附件".utf8).write(to: source)
        try store.addAttachments(urls: [source], to: task.id)
        let saved = try XCTUnwrap(store.data.tasks.first)
        return (saved, try XCTUnwrap(saved.attachments.first))
    }

    func testAttachmentRestoreUsesRetainedBytesAndPreservesOtherEdits() throws {
        let store = try store()
        let (task, attachment) = try attachedTask(in: store)
        try store.removeAttachment(taskID: task.id, attachmentID: attachment.id)
        try store.updateTask(id: task.id) { $0.notes = "移除后添加的备注" }
        let restored = try TaskOperationUndo.removedAttachment(taskID: task.id, attachment: attachment, index: 0).apply(to: store)
        XCTAssertEqual(restored.attachments, [attachment])
        XCTAssertEqual(restored.notes, "移除后添加的备注")
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(attachment)), Data("审查合成附件".utf8))
        XCTAssertEqual(try WorkStore(directory: store.directory).data, store.data)
    }

    func testAttachmentRestoreRejectsMissingOrChangedFileWithoutLosingTask() throws {
        let store = try store()
        let (task, attachment) = try attachedTask(in: store)
        try store.removeAttachment(taskID: task.id, attachmentID: attachment.id)
        let undo = TaskOperationUndo.removedAttachment(taskID: task.id, attachment: attachment, index: 0)
        try Data([0]).write(to: store.attachmentURL(attachment))
        let before = store.data
        XCTAssertThrowsError(try undo.apply(to: store))
        XCTAssertEqual(store.data, before)
        try FileManager.default.removeItem(at: store.attachmentURL(attachment))
        XCTAssertThrowsError(try undo.apply(to: store))
        XCTAssertEqual(store.data, before)
    }

    func testOnScreenUndoConsumesOnlyItsKeyboardUndoEntry() throws {
        let store = try store()
        let (task, attachment) = try attachedTask(in: store)
        let child = Subtask(title: "保留步骤")
        try store.updateTask(id: task.id) { $0.subtasks = [child] }
        let manager = UndoManager()
        manager.groupsByEvent = false
        try store.removeAttachment(taskID: task.id, attachmentID: attachment.id)
        let attachmentUndo = TaskUndoRecord(.removedAttachment(taskID: task.id, attachment: attachment, index: 0))
        manager.beginUndoGrouping()
        attachmentUndo.register(in: manager, store: store, name: "移除附件")
        manager.endUndoGrouping()
        try store.updateTask(id: task.id) { $0.subtasks = [] }
        let stepUndo = TaskUndoRecord(.removedSubtask(taskID: task.id, child: child, index: 0, parentCompletedAt: nil))
        manager.beginUndoGrouping()
        stepUndo.register(in: manager, store: store, name: "移除步骤")
        manager.endUndoGrouping()

        _ = try stepUndo.apply(to: store)
        XCTAssertTrue(manager.canUndo, "底部撤销步骤后，前一次附件撤销仍应可用")
        XCTAssertEqual(manager.undoActionName, "移除附件")
        manager.undo()
        XCTAssertEqual(store.data.tasks[0].subtasks, [child])
        XCTAssertEqual(store.data.tasks[0].attachments, [attachment])
        XCTAssertFalse(manager.canUndo)
        XCTAssertNil(store.errorMessage)
    }
}
