import Foundation
import XCTest
@testable import WorkLedgerCore

@MainActor
final class RecurrenceValidationTests: XCTestCase {
    private let completedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WeekStride-recurrence-validation-\(UUID())", isDirectory: true)
    }

    private func chain(count: Int, closesCycle: Bool = false) -> [WorkTask] {
        let ids = (0..<count).map { _ in UUID() }
        return ids.enumerated().map { index, id in
            WorkTask(id: id, title: "Occurrence \(index)", repeatRule: RepeatRule(),
                     completedAt: completedAt, createdAt: completedAt, updatedAt: completedAt,
                     seriesID: ids[0], nextTaskID: index + 1 < ids.count ? ids[index + 1] : (closesCycle ? ids[0] : nil))
        }
    }

    private func write(_ ledger: LedgerData, to directory: URL) throws -> Data {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(ledger)
        try bytes.write(to: directory.appendingPathComponent("data.json"), options: .atomic)
        return bytes
    }

    private func assertInvalidLink(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case LedgerError.invalid(let message) = error else {
                return XCTFail("Expected invalid recurrence link, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(message, "循环任务关联无效。", file: file, line: line)
        }
    }

    func testLoadRejectsMultiTaskCyclesWithoutChangingSource() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for count in [2, 3] {
            let location = root.appendingPathComponent("cycle-\(count)")
            let tasks = chain(count: count, closesCycle: true)
            let feeder = WorkTask(title: "Preceding occurrence", completedAt: completedAt, nextTaskID: tasks[0].id)
            let bytes = try write(LedgerData(tasks: [feeder] + Array(tasks.reversed())), to: location)
            assertInvalidLink { _ = try WorkStore(directory: location) }
            XCTAssertEqual(try Data(contentsOf: location.appendingPathComponent("data.json")), bytes)
        }
    }

    func testImportRejectsCycleBeforeSafetyCopyOrReplacingData() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkStore(directory: root.appendingPathComponent("current"))
        try store.saveTask(WorkTask(title: "Keep current work"))
        let before = store.data
        let dataURL = store.directory.appendingPathComponent("data.json")
        let originalBytes = try Data(contentsOf: dataURL)
        let backup = root.appendingPathComponent("cyclic.workledgerbackup")
        _ = try write(LedgerData(tasks: chain(count: 3, closesCycle: true)), to: backup)

        assertInvalidLink { try store.importBackup(from: backup) }

        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try Data(contentsOf: dataURL), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("Backups").path))
    }

    func testCommitRejectsClosingCycleWithoutChangingExistingChain() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tasks = chain(count: 3)
        _ = try write(LedgerData(tasks: tasks), to: root)
        let store = try WorkStore(directory: root)
        let before = store.data
        let dataURL = root.appendingPathComponent("data.json")
        let originalBytes = try Data(contentsOf: dataURL)

        var cyclic = tasks[2]
        cyclic.nextTaskID = tasks[0].id
        assertInvalidLink { try store.validateTask(cyclic) }
        assertInvalidLink { try store.saveTask(cyclic) }

        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try Data(contentsOf: dataURL), originalBytes)
    }

    func testValidOutOfOrderAndDisconnectedChainsStillLoadAndExport() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var tasks = chain(count: 512)
        tasks[tasks.count - 1].completedAt = nil
        tasks.append(contentsOf: chain(count: 3))
        tasks.append(WorkTask(title: "Independent task"))
        let ledger = LedgerData(tasks: Array(tasks.reversed()))
        let source = root.appendingPathComponent("source")
        _ = try write(ledger, to: source)

        let store = try WorkStore(directory: source)
        XCTAssertEqual(store.data, ledger)
        let backup = root.appendingPathComponent("valid.workledgerbackup")
        try store.exportBackup(to: backup)
        XCTAssertEqual(try WorkStore(directory: backup).data, ledger)
    }
}
