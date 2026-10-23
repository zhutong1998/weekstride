import Combine
import XCTest
@testable import WorkLedgerCore

@MainActor
final class SubtaskUndoTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerSubtaskUndo-\(UUID().uuidString)")
    }

    func testUndoOnlyClearsSelectedStepAndPersists() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "部署")
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(3600)
        let first = Subtask(title: "申请证书", completedAt: firstDate)
        let second = Subtask(title: "部署证书", completedAt: secondDate)
        let task = WorkTask(projectID: project.id, title: "上线", details: "保留明细", notes: "保留备注",
                            subtasks: [first, second, Subtask(title: "复查")], dueAt: secondDate,
                            reminderAt: firstDate, repeatRule: RepeatRule(every: 6, unit: .month),
                            plannedAt: firstDate, planGranularity: .week)
        try store.saveTask(task)
        var expected = try XCTUnwrap(store.data.tasks.first)

        try store.undoSubtaskCompletion(taskID: task.id, subtaskID: first.id)

        let restored = try XCTUnwrap(store.data.tasks.first)
        expected.subtasks[0].completedAt = nil
        expected.updatedAt = restored.updatedAt
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(restored.subtasks.map(\.id), task.subtasks.map(\.id))
        XCTAssertEqual(restored.subtasks[1].completedAt, secondDate)
        XCTAssertNil(restored.completedAt)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }

    func testUndoUnfinishedStepDoesNotPublishOrWrite() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let child = Subtask(title: "待办")
        let task = WorkTask(title: "任务", subtasks: [child])
        try store.saveTask(task)
        let saved = store.data
        let file = directory.appendingPathComponent("data.json")
        let contents = try Data(contentsOf: file)
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        var publications = 0
        let subscription = store.$data.dropFirst().sink { _ in publications += 1 }

        try store.undoSubtaskCompletion(taskID: task.id, subtaskID: child.id)

        XCTAssertEqual(store.data, saved)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(try Data(contentsOf: file), contents)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, modified)
        withExtendedLifetime(subscription) {}
    }

    func testCompletedParentMustBeUndoneBeforeItsSteps() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let child = Subtask(title: "执行")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let task = WorkTask(title: "循环任务", subtasks: [child], repeatRule: RepeatRule(every: 6, unit: .month))
        try store.saveTask(task)
        let next = try XCTUnwrap(store.completeTask(id: task.id, at: date).nextTask)
        try store.updateTask(id: next.id) { $0.notes = "下一次已开始安排" }
        let before = store.data

        XCTAssertThrowsError(try store.undoSubtaskCompletion(taskID: task.id, subtaskID: child.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("先撤销主任务"))
        }
        XCTAssertThrowsError(try store.undoCompletion(id: task.id))
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try WorkStore(directory: directory).data, before)
    }

    func testUndoMissingStepDoesNotChangeStore() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let task = WorkTask(title: "任务", subtasks: [Subtask(title: "步骤")])
        try store.saveTask(task)
        let before = store.data

        XCTAssertThrowsError(try store.undoSubtaskCompletion(taskID: UUID(), subtaskID: UUID()))
        XCTAssertThrowsError(try store.undoSubtaskCompletion(taskID: task.id, subtaskID: UUID()))
        XCTAssertEqual(store.data, before)
    }

    func testRecompletingUndoneStepCompletesParentWithCorrectSnapshot() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let first = Subtask(title: "第一步"), second = Subtask(title: "第二步")
        let task = WorkTask(title: "任务", subtasks: [first, second])
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.saveTask(task)
        XCTAssertNil(try store.completeSubtask(taskID: task.id, subtaskID: first.id, at: date))
        try store.undoSubtaskCompletion(taskID: task.id, subtaskID: first.id)
        XCTAssertNil(try store.completeSubtask(taskID: task.id, subtaskID: second.id, at: date.addingTimeInterval(3600)))
        let completion = try XCTUnwrap(store.completeSubtask(taskID: task.id, subtaskID: first.id, at: date.addingTimeInterval(7200)))
        XCTAssertEqual(completion.task.completedAt, date.addingTimeInterval(7200))

        try store.undoCompletion(id: task.id)
        let restored = try XCTUnwrap(store.data.tasks.first)
        XCTAssertNil(restored.subtasks[0].completedAt)
        XCTAssertEqual(restored.subtasks[1].completedAt, date.addingTimeInterval(3600))
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }
}
