import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class DemoTasksTests: XCTestCase {
    func testDemoTasksPreserveExistingDataAndAreSafeToImportAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let realProject = try store.addProject(name: "真实项目")
        let realTask = WorkTask(projectID: realProject.id, title: "保留我的任务", notes: "不要覆盖已有内容")
        try store.saveTask(realTask)
        let savedRealTask = try XCTUnwrap(store.data.tasks.first { $0.id == realTask.id })

        // A previous import may have stopped after creating the first project.
        _ = try store.addProject(name: "示例 · 网站运维", colorHex: "168C83")
        let previousProduct = try store.addProject(name: "示例 · 产品开发", colorHex: "397CC6")
        let previousSample = WorkTask(projectID: previousProduct.id, title: "完成工作清单交互走查", details: "保留旧示例的编辑", notes: "重命名后不重复导入")
        try store.saveTask(previousSample)
        let savedPreviousSample = try XCTUnwrap(store.data.tasks.first { $0.id == previousSample.id })
        try store.addDemoTasks()
        let imported = store.data
        try store.addDemoTasks()
        XCTAssertEqual(store.data, imported)
        XCTAssertEqual(store.data.tasks.first { $0.id == realTask.id }, savedRealTask)
        XCTAssertEqual(store.data.tasks.first { $0.id == previousSample.id }, savedPreviousSample)
        XCTAssertFalse(store.data.tasks.contains { $0.title == "完成周程交互走查" })
        XCTAssertEqual(store.data.projects.filter { $0.name.hasPrefix("示例 · ") }.count, 3)
        let demoTasks = store.data.tasks.filter { $0.projectID != realProject.id }
        XCTAssertEqual(demoTasks.count, 14)
        XCTAssertTrue(demoTasks.allSatisfy { $0.reminderAt == nil && !$0.details.isEmpty && !$0.notes.isEmpty })
        XCTAssertEqual(demoTasks.filter { $0.completedAt != nil }.count, 3)

        let currentPeriod = WorkPeriod.range(containing: Date(), firstWeekday: 5)
        XCTAssertTrue(demoTasks.contains { task in
            task.completedAt.map { WorkPeriod.contains($0, in: currentPeriod) } == true
        })
        XCTAssertTrue(demoTasks.contains { task in
            task.completedAt.map { $0 < currentPeriod.start } == true
        })
        XCTAssertTrue(demoTasks.contains { task in
            task.completedAt == nil && task.subtasks.contains { $0.completedAt != nil }
        })
        for completed in demoTasks.filter({ $0.nextTaskID != nil }) {
            let next = try XCTUnwrap(demoTasks.first { $0.id == completed.nextTaskID })
            XCTAssertNotNil(completed.completedAt)
            XCTAssertNil(next.completedAt)
            XCTAssertTrue(next.subtasks.allSatisfy { $0.completedAt == nil })
            XCTAssertEqual(next.attachments, completed.attachments)
        }

        let attachments = demoTasks.flatMap(\.attachments)
        XCTAssertEqual(Set(attachments.map(\.storedName)).count, 3)
        XCTAssertEqual(Set(attachments.map { store.attachmentURL($0).pathExtension }), ["md", "txt", "json"])
        for attachment in attachments {
            let bytes = try Data(contentsOf: store.attachmentURL(attachment))
            XCTAssertEqual(Int64(bytes.count), attachment.size)
            XCTAssertFalse(bytes.isEmpty)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".demo-staging-") })
        XCTAssertEqual(try WorkStore(directory: directory).data, imported)
    }
}
