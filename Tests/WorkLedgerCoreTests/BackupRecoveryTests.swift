import Foundation
import XCTest
@testable import WorkLedgerCore

@MainActor
final class BackupRecoveryTests: XCTestCase {
    private let files = FileManager.default

    private func location() -> URL {
        files.temporaryDirectory.appendingPathComponent("WeekStride-backup-recovery-\(UUID())", isDirectory: true)
    }

    private func makeFixture(at root: URL) throws -> (store: WorkStore, backup: URL, snapshot: LedgerData, attachments: [Attachment]) {
        let store = try WorkStore(directory: root.appendingPathComponent("current"))
        let task = WorkTask(title: "Restore local files")
        try store.saveTask(task)
        let inputs = [root.appendingPathComponent("first.txt"), root.appendingPathComponent("second.txt")]
        for (index, input) in inputs.enumerated() { try Data("Original file \(index)".utf8).write(to: input) }
        try store.addAttachments(urls: inputs, to: task.id)
        let backup = root.appendingPathComponent("healthy.workledgerbackup")
        try store.exportBackup(to: backup)
        let snapshot = store.data
        try store.updateTask(id: task.id) { $0.notes = "Work immediately before restoring" }
        return (store, backup, snapshot, snapshot.tasks[0].attachments)
    }

    private func rescue(in store: WorkStore) throws -> URL {
        let entries = try files.contentsOfDirectory(at: store.directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 1)
        let rescue = try XCTUnwrap(entries.first)
        XCTAssertEqual(rescue.pathExtension, "workledgerrescue")
        XCTAssertFalse(files.fileExists(atPath: rescue.appendingPathComponent("data.json").path))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: rescue.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["format"] as? String, "weekstride-rescue-v1")
        XCTAssertEqual(manifest["completeBackup"] as? Bool, false)
        XCTAssertFalse(try XCTUnwrap(manifest["issues"] as? [String]).isEmpty)
        XCTAssertTrue(try String(contentsOf: rescue.appendingPathComponent("README.txt"), encoding: .utf8).contains("NOT a complete"))
        return rescue
    }

    func testMissingCurrentFileAllowsRestoreAndPreservesRescueMetadataAndReadableFiles() throws {
        let root = location()
        defer { try? files.removeItem(at: root) }
        let fixture = try makeFixture(at: root)
        let store = fixture.store
        let before = store.data
        let originalMetadata = try Data(contentsOf: store.directory.appendingPathComponent("data.json"))
        try files.removeItem(at: store.attachmentURL(fixture.attachments[0]))
        XCTAssertThrowsError(try store.exportBackup(to: root.appendingPathComponent("invalid.workledgerbackup")))

        try store.importBackup(from: fixture.backup)

        XCTAssertEqual(store.data, fixture.snapshot)
        let rescue = try rescue(in: store)
        XCTAssertEqual(try Data(contentsOf: rescue.appendingPathComponent("original-data.json")), originalMetadata)
        XCTAssertEqual(try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: rescue.appendingPathComponent("snapshot.json"))), before)
        let readable = fixture.attachments[1]
        XCTAssertEqual(try Data(contentsOf: rescue.appendingPathComponent("attachments").appendingPathComponent(readable.storedName)),
                       try Data(contentsOf: store.attachmentURL(readable)))
        for attachment in fixture.attachments {
            XCTAssertEqual(try Data(contentsOf: store.attachmentURL(attachment)),
                           try Data(contentsOf: fixture.backup.appendingPathComponent("attachments").appendingPathComponent(attachment.storedName)))
        }
        XCTAssertThrowsError(try store.importBackup(from: rescue), "A rescue folder must not be accepted as an ordinary backup")
        XCTAssertEqual(store.data, fixture.snapshot)
        try store.exportBackup(to: root.appendingPathComponent("valid-again.workledgerbackup"))
    }

    func testDamagedSameNameFileIsRepairedAndOriginalBytesRetained() throws {
        let root = location()
        defer { try? files.removeItem(at: root) }
        let fixture = try makeFixture(at: root)
        let attachment = fixture.attachments[0]
        let damaged = Data("bad".utf8)
        try damaged.write(to: fixture.store.attachmentURL(attachment))
        XCTAssertThrowsError(try fixture.store.exportBackup(to: root.appendingPathComponent("invalid.workledgerbackup")))

        try fixture.store.importBackup(from: fixture.backup)

        XCTAssertEqual(fixture.store.data, fixture.snapshot)
        XCTAssertEqual(try Data(contentsOf: fixture.store.attachmentURL(attachment)),
                       try Data(contentsOf: fixture.backup.appendingPathComponent("attachments").appendingPathComponent(attachment.storedName)))
        let rescue = try rescue(in: fixture.store)
        for folder in ["attachments", "replaced-originals"] {
            XCTAssertEqual(try Data(contentsOf: rescue.appendingPathComponent(folder).appendingPathComponent(attachment.storedName)), damaged)
        }
    }

    func testFailedCommitRestoresDisplacedFileAndKeepsCurrentLedger() throws {
        let root = location()
        defer { try? files.removeItem(at: root) }
        let fixture = try makeFixture(at: root)
        let store = fixture.store
        let before = store.data
        let attachment = fixture.attachments[0]
        let damaged = Data("bad".utf8)
        try damaged.write(to: store.attachmentURL(attachment))
        let dataURL = store.directory.appendingPathComponent("data.json")
        try files.moveItem(at: dataURL, to: root.appendingPathComponent("original-data.json"))
        try files.createDirectory(at: dataURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.importBackup(from: fixture.backup))

        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(attachment)), damaged)
        XCTAssertEqual(try files.attributesOfItem(atPath: dataURL.path)[.type] as? FileAttributeType, .typeDirectory)
        let rescue = try rescue(in: store)
        XCTAssertEqual(try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: rescue.appendingPathComponent("snapshot.json"))), before)
    }

    func testUnavailableSafetyCopyLocationPreventsAnyRestoreMutation() throws {
        let root = location()
        defer { try? files.removeItem(at: root) }
        let fixture = try makeFixture(at: root)
        let store = fixture.store
        let before = store.data
        let dataURL = store.directory.appendingPathComponent("data.json")
        let originalMetadata = try Data(contentsOf: dataURL)
        let missing = store.attachmentURL(fixture.attachments[0])
        try files.removeItem(at: missing)
        try Data("Not a writable safety-copy directory".utf8).write(to: store.directory.appendingPathComponent("Backups"))

        XCTAssertThrowsError(try store.importBackup(from: fixture.backup))

        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try Data(contentsOf: dataURL), originalMetadata)
        XCTAssertFalse(files.fileExists(atPath: missing.path))
    }

    func testHealthySameNameContentConflictStillRejectsBeforeSafetyCopy() throws {
        let root = location()
        defer { try? files.removeItem(at: root) }
        let fixture = try makeFixture(at: root)
        let store = fixture.store
        let before = store.data
        let attachment = fixture.attachments[0]
        let conflicting = Data(repeating: 0x78, count: Int(attachment.size))
        try conflicting.write(to: store.attachmentURL(attachment))

        XCTAssertThrowsError(try store.importBackup(from: fixture.backup)) { error in
            guard case LedgerError.conflict = error else { return XCTFail("Expected a content conflict, got \(error)") }
        }

        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(attachment)), conflicting)
        XCTAssertFalse(files.fileExists(atPath: store.directory.appendingPathComponent("Backups").path))
    }
}
