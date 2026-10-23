import XCTest
@testable import WorkLedgerCore

@MainActor
final class OptionalProjectTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerOptionalProjectTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testUnassignedTaskPersistsBacksUpAndRestoresWithoutCreatingProject() async throws {
        let directory = location()
        let destination = location()
        let backup = location()
        defer { for url in [directory, destination, backup] { try? FileManager.default.removeItem(at: url) } }
        let store = try WorkStore(directory: directory)
        let task = WorkTask(title: "临时工作", details: "无需先选择项目", notes: "保留资料")
        XCTAssertNil(task.projectID)
        try store.saveTask(task)
        let saved = try XCTUnwrap(store.data.tasks.first)
        XCTAssertTrue(store.data.projects.isEmpty)
        XCTAssertNil(saved.projectID)
        let reloaded = try WorkStore(directory: directory)
        XCTAssertEqual(reloaded.data, store.data)
        try store.exportBackup(to: backup)
        let restored = try WorkStore(directory: destination)
        try restored.importBackup(from: backup)
        XCTAssertEqual(restored.data, store.data)
        XCTAssertTrue(restored.data.projects.isEmpty)
        let deletion = try restored.deleteTask(id: task.id)
        XCTAssertTrue(restored.data.tasks.isEmpty)
        try restored.restoreDeletedTask(deletion)
        XCTAssertEqual(restored.data.tasks, [saved])
        XCTAssertTrue(restored.data.projects.isEmpty)
    }

    func testUnassignedRecurringTaskCompletesAndKeepsSuccessorUnassigned() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let completed = Date(timeIntervalSince1970: 1_600_000_000)
        let task = WorkTask(title: "周期检查", subtasks: [Subtask(title: "执行检查")], dueAt: completed, repeatRule: RepeatRule(every: 6, unit: .month))
        try store.saveTask(task)
        let result = try store.completeTask(id: task.id, at: completed, source: "API")
        let successor = try XCTUnwrap(result.nextTask)
        XCTAssertNil(result.task.projectID)
        XCTAssertNil(successor.projectID)
        XCTAssertEqual(result.task.completedAt, completed)
        XCTAssertEqual(result.task.subtasks.first?.completedAt, completed)
        XCTAssertNil(successor.completedAt)
        XCTAssertTrue(store.data.projects.isEmpty)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
        try store.undoCompletion(id: task.id)
        XCTAssertEqual(store.data.tasks.count, 1)
        XCTAssertNil(store.data.tasks[0].projectID)
    }

    func testReassigningOptionalProjectValidatesOnlyNonNilReferences() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let task = WorkTask(title: "稍后归类")
        try store.saveTask(task)
        let project = try store.addProject(name: "正式项目")
        try store.updateTask(id: task.id) { $0.projectID = project.id }
        XCTAssertEqual(store.data.tasks[0].projectID, project.id)
        try store.updateTask(id: task.id) { $0.projectID = nil }
        XCTAssertNil(store.data.tasks[0].projectID)
        let before = store.data
        XCTAssertThrowsError(try store.updateTask(id: task.id) { $0.projectID = UUID() })
        XCTAssertEqual(store.data, before)
        XCTAssertThrowsError(try store.saveTask(WorkTask(projectID: UUID(), title: "无效引用")))
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try WorkStore(directory: directory).data, before)
    }

    func testProjectJSONAcceptsLegacyUUIDMissingAndNull() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let projectID = UUID()
        let assigned = WorkTask(projectID: projectID, title: "旧项目任务")
        XCTAssertEqual(try decoder.decode(WorkTask.self, from: encoder.encode(assigned)).projectID, projectID)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(assigned)) as? [String: Any])
        XCTAssertEqual(json["projectID"] as? String, projectID.uuidString)
        json.removeValue(forKey: "projectID")
        XCTAssertNil(try decoder.decode(WorkTask.self, from: JSONSerialization.data(withJSONObject: json)).projectID)
        json["projectID"] = NSNull()
        XCTAssertNil(try decoder.decode(WorkTask.self, from: JSONSerialization.data(withJSONObject: json)).projectID)
        let unassigned = WorkTask(title: "无项目任务")
        XCTAssertNil(try decoder.decode(WorkTask.self, from: encoder.encode(unassigned)).projectID)
    }
}
