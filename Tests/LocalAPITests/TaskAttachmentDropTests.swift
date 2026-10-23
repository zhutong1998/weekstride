import AppKit
import CoreTransferable
import UniformTypeIdentifiers
import WorkLedgerCore
import XCTest

final class TaskAttachmentDropTests: XCTestCase {
    @MainActor func testFileURLTransferAddsMultipleFilesOnlyToTargetAndKeepsOriginals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerFileDrop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try WorkStore(directory: directory.appendingPathComponent("store"))
        let target = WorkTask(title: "接收文件的任务"), other = WorkTask(title: "其他任务")
        try store.saveTask(target)
        try store.saveTask(other)
        let otherBefore = try XCTUnwrap(store.data.tasks.first { $0.id == other.id })
        var received: [URL] = []
        for name in ["部署说明 中文.txt", "active.json"] {
            let source = directory.appendingPathComponent(name)
            try Data(name.utf8).write(to: source)
            let provider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadTransferable(type: URL.self) { continuation.resume(with: $0) }
            }
            XCTAssertTrue(url.isFileURL)
            received.append(url)
        }
        try store.addAttachments(urls: received, to: target.id)
        let saved = try XCTUnwrap(store.data.tasks.first { $0.id == target.id })
        XCTAssertEqual(saved.attachments.map(\.name), received.map(\.lastPathComponent))
        XCTAssertEqual(store.data.tasks.first { $0.id == other.id }, otherBefore)
        for (attachment, source) in zip(saved.attachments, received) {
            XCTAssertNotEqual(store.attachmentURL(attachment), source)
            XCTAssertEqual(try Data(contentsOf: store.attachmentURL(attachment)), try Data(contentsOf: source))
        }
        XCTAssertEqual(try WorkStore(directory: directory.appendingPathComponent("store")).data, store.data)
    }

    @MainActor func testInvalidFileBatchRollsBackCopiedAttachments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerFileDrop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try WorkStore(directory: directory.appendingPathComponent("store"))
        let task = WorkTask(title: "接收文件的任务")
        try store.saveTask(task)
        let source = directory.appendingPathComponent("valid.txt")
        try Data("keep original".utf8).write(to: source)
        let before = store.data
        XCTAssertThrowsError(try store.addAttachments(urls: [source, directory], to: task.id))
        XCTAssertEqual(store.data, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("store/attachments").path).isEmpty)
    }
}
