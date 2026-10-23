import XCTest
@testable import WorkLedgerCore

@MainActor
final class TaskMoveTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerMoveTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testMovePreservesCompletedTaskContentsDatesAndRecurrenceAndPersistsRemoval() async throws {
        let directory = location()
        let source = location().appendingPathExtension("txt")
        defer { for url in [directory, source] { try? FileManager.default.removeItem(at: url) } }
        let store = try WorkStore(directory: directory)
        let initialProject = try store.addProject(name: "原项目")
        let destination = try store.addProject(name: "目标项目")
        let due = Date(timeIntervalSince1970: 1_706_702_400)
        let task = WorkTask(projectID: initialProject.id, title: "有完整资料的工作", details: "执行明细", notes: "保留备注", subtasks: [Subtask(title: "已完成步骤", completedAt: due.addingTimeInterval(-86400)), Subtask(title: "最后一步")], dueAt: due, reminderAt: due.addingTimeInterval(-7 * 86400), repeatRule: RepeatRule(every: 1, unit: .month, basis: .schedule), plannedAt: due.addingTimeInterval(-14 * 86400), planGranularity: .week)
        try store.saveTask(task)
        let fileData = Data("真实本地附件内容".utf8)
        try fileData.write(to: source)
        try store.addAttachments(urls: [source], to: task.id)
        let completion = try store.completeTask(id: task.id, at: due, source: "API")
        let before = completion.task
        let successor = try XCTUnwrap(completion.nextTask)
        try store.moveTask(id: task.id, toProject: destination.id)
        let moved = try XCTUnwrap(store.data.tasks.first(where: { $0.id == task.id }))
        var expected = before
        expected.projectID = destination.id
        expected.updatedAt = moved.updatedAt
        XCTAssertEqual(moved, expected, "Moving must change only the project and modification date")
        XCTAssertEqual(store.data.tasks.first(where: { $0.id == successor.id }), successor)
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(try XCTUnwrap(moved.attachments.first))), fileData)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)

        try store.moveTask(id: task.id, toProject: nil)
        let unassigned = try XCTUnwrap(store.data.tasks.first(where: { $0.id == task.id }))
        expected.projectID = nil
        expected.updatedAt = unassigned.updatedAt
        XCTAssertEqual(unassigned, expected)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
        XCTAssertEqual(store.data.tasks.first(where: { $0.id == successor.id })?.projectID, initialProject.id)
    }

    func testMovingToSameProjectOrAlreadyUnassignedDoesNotWriteOrChangeTimestamp() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "同一个项目")
        let task = WorkTask(projectID: project.id, title: "保持原位")
        try store.saveTask(task)
        let before = store.data
        let dataURL = directory.appendingPathComponent("data.json")
        let bytes = try Data(contentsOf: dataURL)
        try store.moveTask(id: task.id, toProject: project.id)
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        try store.moveTask(id: task.id, toProject: nil)
        let unassigned = store.data
        let unassignedBytes = try Data(contentsOf: dataURL)
        try store.moveTask(id: task.id, toProject: nil)
        XCTAssertEqual(store.data, unassigned)
        XCTAssertEqual(try Data(contentsOf: dataURL), unassignedBytes)
    }

    func testInvalidArchivedDestinationsAndMissingTasksLeaveAllDataUnchanged() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let active = try store.addProject(name: "可用项目")
        let archived = try store.addProject(name: "归档项目")
        try store.archiveProject(id: archived.id)
        let task = WorkTask(title: "等待分类")
        try store.saveTask(task)
        let before = store.data
        let dataURL = directory.appendingPathComponent("data.json")
        let bytes = try Data(contentsOf: dataURL)
        XCTAssertThrowsError(try store.moveTask(id: task.id, toProject: UUID()))
        XCTAssertThrowsError(try store.moveTask(id: task.id, toProject: archived.id))
        XCTAssertThrowsError(try store.moveTask(id: UUID(), toProject: active.id))
        XCTAssertThrowsError(try store.moveTask(id: UUID(), toProject: nil))
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        XCTAssertEqual(try WorkStore(directory: directory).data, before)
        try store.moveTask(id: task.id, toProject: active.id)
        XCTAssertEqual(store.data.tasks.first(where: { $0.id == task.id })?.projectID, active.id)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }
}
