import XCTest
@testable import WorkLedgerCore

@MainActor
final class WorkStoreProjectTests: XCTestCase {
    func testUnsupportedNativeDatesCannotBeSavedOrRestored() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WeekStride-date-boundary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let original = WorkTask(title: "Keep existing work")
        try store.saveTask(original)
        let before = store.data
        for date in [Date(timeIntervalSinceReferenceDate: 1e300), Date(timeIntervalSinceReferenceDate: -1e300)] {
            var invalid = original
            invalid.plannedAt = date
            XCTAssertThrowsError(try store.saveTask(invalid))
            var deleted = WorkTask(title: "Invalid snapshot")
            deleted.reminderAt = date
            XCTAssertThrowsError(try store.restoreDeletedTask(TaskDeletion(task: deleted)))
            XCTAssertEqual(store.data, before)
        }
    }

    func testProjectUpdatesAreValidatedAndDeletionOnlyUnassignsTasks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerProjectTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "Original")
        let task = WorkTask(projectID: project.id, title: "Keep", subtasks: [Subtask(title: "Step")])
        try store.saveTask(task)
        let done = try store.completeTask(id: task.id, at: Date(timeIntervalSince1970: 1_700_000_000))
        let updated = try store.updateProject(id: project.id, name: " New name ", colorHex: "ABCDEF", isArchived: true)
        XCTAssertEqual(updated.name, "New name")
        XCTAssertTrue(updated.isArchived)
        let beforeInvalid = store.data
        XCTAssertThrowsError(try store.updateProject(id: project.id, colorHex: "not a color"))
        XCTAssertThrowsError(try store.updateProject(id: project.id, name: "  "))
        XCTAssertEqual(store.data, beforeInvalid)
        _ = try store.deleteProject(id: project.id)
        let retained = try XCTUnwrap(store.data.tasks.first)
        XCTAssertTrue(store.data.projects.isEmpty)
        XCTAssertNil(retained.projectID)
        XCTAssertEqual(retained.completedAt, done.task.completedAt)
        XCTAssertEqual(retained.subtasks, done.task.subtasks)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }

    func testPreflightValidationNeverWritesOrMutatesStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerPreflightTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let task = WorkTask(title: "Validate only", repeatRule: RepeatRule(every: 1, unit: .month))
        try store.saveTask(task)
        let before = store.data
        let url = directory.appendingPathComponent("data.json")
        let bytes = try Data(contentsOf: url)
        var candidate = task; candidate.notes = "Not yet saved"
        try store.validateTask(candidate)
        candidate.projectID = UUID()
        XCTAssertThrowsError(try store.validateTask(candidate))
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        _ = try store.completeTask(id: task.id)
        let beforeReopen = store.data
        let completedBytes = try Data(contentsOf: url)
        try store.validateUndoCompletion(id: task.id)
        XCTAssertEqual(store.data, beforeReopen)
        XCTAssertEqual(try Data(contentsOf: url), completedBytes)
        let snapshot = try store.deleteTask(id: task.id)
        let beforeRestore = store.data
        let deletedBytes = try Data(contentsOf: url)
        try store.validateRestoringDeletedTask(snapshot)
        XCTAssertEqual(store.data, beforeRestore)
        XCTAssertEqual(try Data(contentsOf: url), deletedBytes)
        try store.restoreDeletedTask(snapshot)
        XCTAssertThrowsError(try store.validateRestoringDeletedTask(snapshot))
    }
}
