import Foundation
import XCTest
@testable import WorkLedgerCore

@MainActor
final class BackupSnapshotTests: XCTestCase {
    func testBackgroundExportUsesCapturedSnapshotAndKeepsLaterEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedger-backup-snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory.appendingPathComponent("store"))
        let task = WorkTask(title: "导出开始时", notes: "保留原始备注")
        try store.saveTask(task)
        let snapshot = store.data
        try store.updateTask(id: task.id) { $0.title = "导出期间继续编辑" }
        let destination = directory.appendingPathComponent("captured.workledgerbackup")
        let source = store.directory
        try await Task.detached { try WorkStore.exportBackup(snapshot: snapshot, directory: source, to: destination) }.value
        let restored = try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: destination.appendingPathComponent("data.json")))
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(store.data.tasks.first?.title, "导出期间继续编辑")
        XCTAssertThrowsError(try WorkStore.exportBackup(snapshot: snapshot, directory: source, to: destination))
        XCTAssertEqual(try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: destination.appendingPathComponent("data.json"))), snapshot)
    }

    func testSnapshotExportRejectsMissingAttachmentsAndCleansTemporaryOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedger-backup-missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory.appendingPathComponent("store"))
        let attachment = Attachment(name: "尚存引用的文件", storedName: "missing.txt", size: 8)
        let snapshot = LedgerData(tasks: [WorkTask(title: "检查附件", attachments: [attachment])])
        let destination = directory.appendingPathComponent("missing.workledgerbackup")
        XCTAssertThrowsError(try WorkStore.exportBackup(snapshot: snapshot, directory: store.directory, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".workledger-export-") })
        XCTAssertTrue(store.data.tasks.isEmpty)
        try Data([1]).write(to: store.directory.appendingPathComponent("attachments/missing.txt"))
        XCTAssertThrowsError(try WorkStore.exportBackup(snapshot: snapshot, directory: store.directory, to: destination), "文件大小与记录不符也不能导出损坏备份")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSnapshotExportRejectsInvalidAttachmentPathsBeforeWriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedger-backup-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory.appendingPathComponent("store"))
        let attachment = Attachment(name: "路径不可越界", storedName: "../data.json", size: 1)
        let snapshot = LedgerData(tasks: [WorkTask(title: "无效快照", attachments: [attachment])])
        let destination = directory.appendingPathComponent("invalid.workledgerbackup")
        XCTAssertThrowsError(try WorkStore.exportBackup(snapshot: snapshot, directory: store.directory, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
