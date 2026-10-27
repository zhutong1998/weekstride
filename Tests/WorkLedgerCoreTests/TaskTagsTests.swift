import Combine
import XCTest
@testable import WorkLedgerCore

@MainActor
final class TaskTagsTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WeekStride-tags-\(UUID())", isDirectory: true)
    }

    func testLegacyDataAndDeletionSnapshotsDecodeWithoutTagsOrStars() async throws {
        let task = WorkTask(title: "Existing work", details: "Keep details", notes: "Keep notes", subtasks: [Subtask(title: "Keep step")], dueAt: Date(timeIntervalSince1970: 1_700_000_000))
        let original = LedgerData(tasks: [task])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "tags")
        var oldTask = try XCTUnwrap((json["tasks"] as? [[String: Any]])?.first)
        oldTask.removeValue(forKey: "tagIDs")
        oldTask.removeValue(forKey: "isStarred")
        json["tasks"] = [oldTask]
        let bytes = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(LedgerData.self, from: bytes), original)
        let deletion = try JSONSerialization.data(withJSONObject: ["task": oldTask, "predecessorIDs": []])
        XCTAssertEqual(try JSONDecoder().decode(TaskDeletion.self, from: deletion), TaskDeletion(task: task))

        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent("data.json"))
        XCTAssertEqual(try WorkStore(directory: directory).data, original)
    }

    func testNewFieldsRejectExplicitNullAndIncorrectTypes() async throws {
        let task = WorkTask(title: "Keep strict decoding")
        let encoded = try JSONEncoder().encode(task)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let invalidFields: [(String, Any)] = [
            ("tagIDs", NSNull()), ("tagIDs", "not an array"), ("tagIDs", ["not a UUID"]),
            ("isStarred", NSNull()), ("isStarred", "true"), ("isStarred", 1)
        ]
        for (key, value) in invalidFields {
            var json = original; json[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(WorkTask.self, from: JSONSerialization.data(withJSONObject: json)), key)
        }
        let ledger = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LedgerData(tasks: [task]))) as? [String: Any])
        for value in [NSNull(), "not an array"] as [Any] {
            var json = ledger; json["tags"] = value
            XCTAssertThrowsError(try JSONDecoder().decode(LedgerData.self, from: JSONSerialization.data(withJSONObject: json)))
        }
    }

    func testIndependentProjectTagsAndStarPersistAndTagDeletionRetainsWork() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "Operations")
        let first = try store.addTag(name: " Urgent ")
        let second = try store.addTag(name: "Customer", colorHex: "3478F6")
        XCTAssertEqual(first.name, "Urgent")
        let task = WorkTask(projectID: project.id, title: "Follow up", subtasks: [Subtask(title: "Contact owner")])
        try store.saveTask(task)
        try store.addTagToTask(id: task.id, tagID: first.id)
        try store.addTagToTask(id: task.id, tagID: second.id)
        try store.setTaskStarred(id: task.id, isStarred: true)
        let completed = try store.completeTask(id: task.id)
        let other = WorkTask(title: "Unassigned project", tagIDs: [first.id])
        try store.saveTask(other)
        let updated = try store.updateTag(id: first.id, name: " Priority ", colorHex: "#ABCDEF")
        XCTAssertEqual(updated.name, "Priority")
        XCTAssertEqual(updated.colorHex, "#ABCDEF")
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)

        XCTAssertEqual(try store.deleteTag(id: first.id), updated)
        let retained = try XCTUnwrap(store.data.tasks.first { $0.id == task.id })
        XCTAssertEqual(retained.projectID, project.id)
        XCTAssertEqual(retained.tagIDs, [second.id])
        XCTAssertTrue(retained.isStarred)
        XCTAssertEqual(retained.subtasks, completed.task.subtasks)
        XCTAssertEqual(retained.completedAt, completed.task.completedAt)
        XCTAssertEqual(store.data.tasks.count, 2)
        XCTAssertEqual(store.data.tasks.first { $0.id == other.id }?.tagIDs, [])
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }

    func testEquivalentAssignmentsAndStarTogglesDoNotWriteOrPublish() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let first = try store.addTag(name: "First")
        let second = try store.addTag(name: "Second")
        let task = WorkTask(title: "Keep stable", tagIDs: [first.id], isStarred: true)
        try store.saveTask(task)
        let before = store.data
        let url = directory.appendingPathComponent("data.json")
        let bytes = try Data(contentsOf: url)
        var publications = 0
        let observation = store.$data.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        try store.addTagToTask(id: task.id, tagID: first.id)
        try store.removeTagFromTask(id: task.id, tagID: second.id)
        try store.setTaskStarred(id: task.id, isStarred: true)
        _ = try store.updateTag(id: first.id, name: " First ", colorHex: first.colorHex)
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        try store.removeTagFromTask(id: task.id, tagID: first.id)
        try store.setTaskStarred(id: task.id, isStarred: false)
        XCTAssertEqual(store.data.tasks.first?.tagIDs, [])
        XCTAssertEqual(store.data.tasks.first?.isStarred, false)
        XCTAssertEqual(publications, 2)
    }

    func testInvalidTagEditsAndReferencesAreAtomic() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let tag = try store.addTag(name: "Existing")
        let task = WorkTask(title: "Existing task", tagIDs: [tag.id])
        try store.saveTask(task)
        let before = store.data
        let url = directory.appendingPathComponent("data.json")
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.addTag(name: " \n "))
        XCTAssertThrowsError(try store.addTag(name: "Bad color", colorHex: "FFFFFFF"))
        XCTAssertThrowsError(try store.updateTag(id: tag.id, name: ""))
        XCTAssertThrowsError(try store.updateTag(id: tag.id, colorHex: "ZZZZZZ"))
        XCTAssertThrowsError(try store.updateTag(id: UUID(), name: "Missing"))
        XCTAssertThrowsError(try store.deleteTag(id: UUID()))
        XCTAssertThrowsError(try store.addTagToTask(id: task.id, tagID: UUID()))
        XCTAssertThrowsError(try store.removeTagFromTask(id: task.id, tagID: UUID()))
        XCTAssertThrowsError(try store.addTagToTask(id: UUID(), tagID: tag.id))
        XCTAssertThrowsError(try store.removeTagFromTask(id: UUID(), tagID: tag.id))
        XCTAssertThrowsError(try store.setTaskStarred(id: UUID(), isStarred: true))
        XCTAssertThrowsError(try store.updateTask(id: task.id) { $0.tagIDs = [tag.id, tag.id] })
        XCTAssertThrowsError(try store.updateTask(id: task.id) { $0.tagIDs = [UUID()] })
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testLoadingOrExportingInvalidTagDefinitionsNeverOverwritesData() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tag = TaskTag(name: "Existing")
        let task = WorkTask(title: "Existing", tagIDs: [tag.id])
        let original = LedgerData(tasks: [task], tags: [tag])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("data.json")
        var duplicate = original; duplicate.tags.append(tag)
        var unknown = original; unknown.tasks[0].tagIDs = [UUID()]
        var repeated = original; repeated.tasks[0].tagIDs = [tag.id, tag.id]
        var badName = original; badName.tags[0].name = "\n"
        var badColor = original; badColor.tags[0].colorHex = "123"
        for data in [duplicate, unknown, repeated, badName, badColor] {
            let bytes = try JSONEncoder().encode(data)
            try bytes.write(to: url)
            XCTAssertThrowsError(try WorkStore(directory: directory))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            let backup = directory.appendingPathComponent("invalid.workledgerbackup")
            XCTAssertThrowsError(try WorkStore.exportBackup(snapshot: data, directory: directory, to: backup))
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        }
    }

    func testRecurrenceBackupAndDeletionRestoreRetainTagsAndStar() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory.appendingPathComponent("store"))
        let tag = try store.addTag(name: "Maintenance")
        let project = try store.addProject(name: "Infrastructure")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let task = WorkTask(projectID: project.id, title: "Renew certificate", repeatRule: RepeatRule(every: 6, unit: .month), tagIDs: [tag.id], isStarred: true)
        try store.saveTask(task)
        let result = try store.completeTask(id: task.id, at: date)
        let next = try XCTUnwrap(result.nextTask)
        XCTAssertEqual(result.task.tagIDs, [tag.id])
        XCTAssertTrue(result.task.isStarred)
        XCTAssertEqual(next.tagIDs, [tag.id])
        XCTAssertTrue(next.isStarred)
        XCTAssertEqual(next.projectID, project.id)

        let backup = directory.appendingPathComponent("tagged.workledgerbackup")
        try store.exportBackup(to: backup)
        let restored = try WorkStore(directory: directory.appendingPathComponent("restored"))
        try restored.importBackup(from: backup)
        XCTAssertEqual(restored.data, store.data)
        let deletion = try restored.deleteTask(id: next.id)
        try restored.restoreDeletedTask(deletion)
        XCTAssertEqual(restored.data.tasks.first { $0.id == next.id }, next)

        try store.setTaskStarred(id: next.id, isStarred: false)
        let beforeUndo = store.data
        XCTAssertThrowsError(try store.undoCompletion(id: task.id), "Changing a successor's star must protect that work from completion undo")
        XCTAssertEqual(store.data, beforeUndo)
    }
}
