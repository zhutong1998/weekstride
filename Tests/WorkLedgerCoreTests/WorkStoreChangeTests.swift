import XCTest
import Combine
@testable import WorkLedgerCore

@MainActor
final class WorkStoreChangeTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerChangeTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testEquivalentEditsDoNotWriteChangeTimestampsOrPublish() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "保持原样")
        let date = Date(timeIntervalSince1970: 1_706_702_400)
        let rule = RepeatRule(every: 1, unit: .month, basis: .schedule)
        let task = WorkTask(projectID: project.id, title: "证书维护", details: "执行步骤", notes: "记录", dueAt: date, reminderAt: date.addingTimeInterval(-86400), repeatRule: rule, scheduleAnchor: ScheduleAnchor(date: date, occurrence: 0, rule: rule), plannedAt: date, planGranularity: .week)
        try store.saveTask(task)
        let child = Subtask(title: "完成的步骤", completedAt: date)
        let completed = WorkTask(title: "历史任务", subtasks: [child], completedAt: date)
        try store.saveTask(completed)
        let before = store.data
        let savedTask = try XCTUnwrap(before.tasks.first(where: { $0.id == task.id }))
        let dataURL = directory.appendingPathComponent("data.json")
        let bytes = try Data(contentsOf: dataURL)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dataURL.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: dataURL.path)
        var publications = 0
        var invalidations = 0
        let dataObservation = store.$data.dropFirst().sink { _ in publications += 1 }
        let changeObservation = store.objectWillChange.sink { invalidations += 1 }
        defer { dataObservation.cancel(); changeObservation.cancel() }

        try store.updateTask(id: task.id) { _ in }
        try store.updateTask(id: task.id) {
            $0.details = savedTask.details; $0.notes = savedTask.notes
            $0.dueAt = savedTask.dueAt; $0.reminderAt = savedTask.reminderAt
            $0.repeatRule = rule; $0.plannedAt = date; $0.planGranularity = .week
        }
        try store.saveTask(savedTask)
        var equivalent = savedTask
        equivalent.title = " \n\(savedTask.title)  "
        equivalent.updatedAt = Date().addingTimeInterval(86400)
        try store.saveTask(equivalent)
        try store.updateTask(id: task.id) { $0.title = " \(savedTask.title)\n" }
        try store.moveTask(id: task.id, toProject: project.id)
        try store.unarchiveProject(id: project.id)
        try store.addAttachments(urls: [], to: task.id)
        try store.setCompletionDate(taskID: completed.id, at: date)
        try store.setSubtaskCompletionDate(taskID: completed.id, subtaskID: child.id, at: date)
        XCTAssertTrue(try store.completeTask(id: completed.id).alreadyCompleted)
        XCTAssertTrue(try XCTUnwrap(store.completeSubtask(taskID: completed.id, subtaskID: child.id)).alreadyCompleted)

        XCTAssertEqual(store.data, before)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(invalidations, 0)
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: dataURL.path)
        XCTAssertEqual(afterAttributes[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(afterAttributes[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
        XCTAssertEqual(try WorkStore(directory: directory).data, before)
    }

    func testChangesPublishOnlyAfterPersistenceAndInvalidEditsDoNotPublish() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "真实变更")
        let task = WorkTask(projectID: project.id, title: "保留标题")
        try store.saveTask(task)
        let dataURL = directory.appendingPathComponent("data.json")
        var published: [LedgerData] = []
        var invalidations = 0
        let dataObservation = store.$data.dropFirst().sink { value in
            published.append(value)
            do {
                let persisted = try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: dataURL))
                XCTAssertEqual(persisted, value)
            } catch { XCTFail("发布变更前应已保存数据：\(error)") }
        }
        let changeObservation = store.objectWillChange.sink { invalidations += 1 }
        defer { dataObservation.cancel(); changeObservation.cancel() }

        try store.updateTask(id: task.id) { $0.notes = "新增工作记录" }
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(store.data.tasks.first?.notes, "新增工作记录")
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
        let beforeInvalid = store.data
        let bytes = try Data(contentsOf: dataURL)
        XCTAssertThrowsError(try store.updateTask(id: task.id) { $0.title = "  \n" })
        XCTAssertThrowsError(try store.updateTask(id: task.id) { $0.projectID = UUID() })
        XCTAssertThrowsError(try store.updateTask(id: UUID()) { $0.notes = "不可恢复已删除任务" })
        XCTAssertThrowsError(try store.addAttachments(urls: [], to: UUID()))
        XCTAssertEqual(store.data, beforeInvalid)
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(invalidations, 1)

        try store.archiveProject(id: project.id)
        XCTAssertEqual(published.count, 2)
        let archivedBytes = try Data(contentsOf: dataURL)
        try store.archiveProject(id: project.id)
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(try Data(contentsOf: dataURL), archivedBytes)
        try store.unarchiveProject(id: project.id)
        XCTAssertEqual(published.count, 3)
        XCTAssertEqual(invalidations, 3)
        XCTAssertEqual(published.last, store.data)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }

    func testFailedWriteAndAttachmentImportDoNotPublishOrMutateMemory() async throws {
        let directory = location()
        let source = location().appendingPathExtension("txt")
        defer { for url in [directory, source] { try? FileManager.default.removeItem(at: url) } }
        let store = try WorkStore(directory: directory)
        let task = WorkTask(title: "写入失败保护")
        try store.saveTask(task)
        try Data("附件内容".utf8).write(to: source)
        let before = store.data
        let dataURL = directory.appendingPathComponent("data.json")
        let bytes = try Data(contentsOf: dataURL)
        let retainedURL = directory.appendingPathComponent("data-retained.json")
        try FileManager.default.moveItem(at: dataURL, to: retainedURL)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: false)
        var publications = 0
        var invalidations = 0
        let dataObservation = store.$data.dropFirst().sink { _ in publications += 1 }
        let changeObservation = store.objectWillChange.sink { invalidations += 1 }
        defer { dataObservation.cancel(); changeObservation.cancel() }

        XCTAssertThrowsError(try store.updateTask(id: task.id) { $0.notes = "不能提交" })
        XCTAssertThrowsError(try store.addAttachments(urls: [source], to: task.id))
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(invalidations, 0)
        XCTAssertEqual(try Data(contentsOf: retainedURL), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("attachments").path), [])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".data-") }))
        try FileManager.default.removeItem(at: dataURL)
        try FileManager.default.moveItem(at: retainedURL, to: dataURL)
        XCTAssertEqual(try WorkStore(directory: directory).data, before)
    }
}
