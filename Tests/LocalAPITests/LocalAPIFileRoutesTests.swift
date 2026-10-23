import Foundation
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class LocalAPIFileRoutesTests: XCTestCase {
    private let files = FileManager.default

    private func withStore(_ operation: (WorkStore, URL) throws -> Void) throws {
        let root = files.temporaryDirectory.appendingPathComponent("WeekStride-file-api-test-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let store = try WorkStore(directory: root.appendingPathComponent("store"))
        try operation(store, root)
    }

    private func request(_ path: String, method: String = "GET", body: Any? = nil) throws -> LocalAPIRequest {
        let bytes = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data()
        return LocalAPIRequest(head: LocalAPIRequestHead(method: method, target: path, headers: body == nil ? [:] : ["content-type": "application/json"], bodyLength: bytes.count, headerLength: 0), body: bytes)
    }

    private func send(_ path: String, method: String = "GET", body: Any? = nil, store: WorkStore) throws -> LocalAPIResponse {
        let response = try LocalAPIFileRoutes.respond(to: request(path, method: method, body: body), store: store)
        return try XCTUnwrap(response)
    }

    private func object(_ response: LocalAPIResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func assertHTTP(_ status: Int, _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual(($0 as? LocalAPIHTTPError)?.status, status, "\($0)", file: file, line: line)
        }
    }

    private func createBackup(_ store: WorkStore) throws -> UUID {
        let response = try send("/v1/backups", method: "POST", store: store)
        XCTAssertEqual(response.status, 201)
        return try XCTUnwrap(UUID(uuidString: XCTUnwrap(object(response)["id"] as? String)))
    }

    private func upload(_ bytes: Data, name: String = "report.txt", task: WorkTask, store: WorkStore) throws -> Attachment {
        let response = try send("/v1/tasks/\(task.id)/attachments", method: "POST", body: ["name": name, "contentBase64": bytes.base64EncodedString()], store: store)
        XCTAssertEqual(response.status, 201)
        return try JSONDecoder().decode(Attachment.self, from: response.body)
    }

    func testAttachmentLifecyclePreservesSharedStoredBytes() throws {
        try withStore { store, _ in
            let task = WorkTask(title: "Read attachment")
            try store.saveTask(task)
            let bytes = Data("A small local attachment.\n".utf8)
            let attachment = try upload(bytes, name: "report 说明.txt", task: task, store: store)
            XCTAssertEqual(attachment.name, "report 说明.txt")
            XCTAssertEqual(attachment.size, Int64(bytes.count))
            XCTAssertNotEqual(attachment.storedName, attachment.name)
            let list = try send("/v1/tasks/\(task.id)/attachments", store: store)
            XCTAssertEqual(try JSONDecoder().decode([Attachment].self, from: list.body), [attachment])
            let metadata = try send("/v1/tasks/\(task.id)/attachments/\(attachment.id)", store: store)
            XCTAssertEqual(try JSONDecoder().decode(Attachment.self, from: metadata.body), attachment)
            let response = try send("/v1/tasks/\(task.id)/attachments/\(attachment.id)/content", store: store)
            XCTAssertEqual(response.contentType, "application/octet-stream")
            XCTAssertEqual(response.body, bytes)
            let other = WorkTask(title: "Shared recurrence history", attachments: [attachment])
            try store.saveTask(other)
            _ = try send("/v1/tasks/\(task.id)/attachments/\(attachment.id)", method: "DELETE", store: store)
            XCTAssertTrue(try XCTUnwrap(store.data.tasks.first(where: { $0.id == task.id })).attachments.isEmpty)
            XCTAssertEqual(try send("/v1/tasks/\(other.id)/attachments/\(attachment.id)/content", store: store).body, bytes)
            XCTAssertEqual(try Data(contentsOf: store.attachmentURL(attachment)), bytes)
            let hidden = try upload(Data("LOCAL_ONLY=true".utf8), name: ".env", task: task, store: store)
            XCTAssertEqual(hidden.name, ".env")
            XCTAssertEqual(try send("/v1/tasks/\(task.id)/attachments/\(hidden.id)/content", store: store).body, Data("LOCAL_ONLY=true".utf8))
        }
    }

    func testAttachmentRejectsUnsafeNamesAndNoncanonicalBase64WithoutChanges() throws {
        try withStore { store, _ in
            let task = WorkTask(title: "Keep unchanged")
            try store.saveTask(task)
            let before = store.data
            for name in ["", " ", ".", "..", "../outside.txt", "/tmp/outside.txt", "folder/file", "folder\\file", "bad\0name", "bad\nname", String(repeating: "a", count: 256)] {
                assertHTTP(400) {
                    _ = try self.send("/v1/tasks/\(task.id)/attachments", method: "POST", body: ["name": name, "contentBase64": "YQ=="], store: store)
                }
            }
            for value in ["a", "!!!!", "YQ", "YQ==\n", "YQ=", "YR=="] {
                assertHTTP(400) {
                    _ = try self.send("/v1/tasks/\(task.id)/attachments", method: "POST", body: ["name": "safe.txt", "contentBase64": value], store: store)
                }
            }
            for body: [String: Any] in [["name": "safe.txt", "contentBase64": NSNull()], ["name": "safe.txt", "path": "/tmp/file"], ["name": "safe.txt", "contentBase64": "", "extra": true]] {
                assertHTTP(400) { _ = try self.send("/v1/tasks/\(task.id)/attachments", method: "POST", body: body, store: store) }
            }
            XCTAssertEqual(store.data, before)
            XCTAssertEqual(try files.contentsOfDirectory(atPath: store.directory.appendingPathComponent("attachments").path), [])
            let empty = try upload(Data(), name: "empty.txt", task: task, store: store)
            XCTAssertEqual(try send("/v1/tasks/\(task.id)/attachments/\(empty.id)/content", store: store).body, Data())
        }
    }

    func testAttachmentContentRejectsSymlinksSizeMismatchAndOversizedFiles() throws {
        try withStore { store, root in
            let outside = root.appendingPathComponent("outside.txt")
            try Data("private".utf8).write(to: outside)
            let linked = Attachment(name: "linked.txt", storedName: "linked.txt", size: 7)
            try files.createSymbolicLink(at: store.attachmentURL(linked), withDestinationURL: outside)
            let mismatched = Attachment(name: "wrong.txt", storedName: "wrong.txt", size: 1)
            try Data("longer".utf8).write(to: store.attachmentURL(mismatched))
            let large = Attachment(name: "large.bin", storedName: "large.bin", size: Int64(LocalAPIFileRoutes.maximumBytes + 1))
            XCTAssertTrue(files.createFile(atPath: store.attachmentURL(large).path, contents: nil))
            let handle = try FileHandle(forWritingTo: store.attachmentURL(large))
            try handle.truncate(atOffset: UInt64(large.size))
            try handle.close()
            let task = WorkTask(title: "Unsafe file references", attachments: [linked, mismatched, large])
            try store.saveTask(task)
            for attachment in [linked, mismatched] {
                assertHTTP(400) { _ = try self.send("/v1/tasks/\(task.id)/attachments/\(attachment.id)/content", store: store) }
            }
            assertHTTP(413) { _ = try self.send("/v1/tasks/\(task.id)/attachments/\(large.id)/content", store: store) }
            XCTAssertEqual(try Data(contentsOf: outside), Data("private".utf8))
        }
    }

    func testBackupPortableRoundTripRetainsExactLedgerAndCreatesSafetyCopy() throws {
        try withStore { store, _ in
            let project = try store.addProject(name: "Portable project")
            let fractional = Date(timeIntervalSinceReferenceDate: 700_000_000.1234567)
            let task = WorkTask(projectID: project.id, title: "Recurring file task", details: "Details", notes: "Notes", subtasks: [Subtask(title: "Check file")], dueAt: fractional, repeatRule: RepeatRule(every: 6, unit: .month), createdAt: fractional, updatedAt: fractional)
            try store.saveTask(task)
            let attachment = try upload(Data("first,second\n1,2\n".utf8), name: "records.csv", task: task, store: store)
            _ = try store.completeTask(id: task.id, at: fractional, source: "test")
            let snapshot = store.data
            let id = try createBackup(store)
            var portable = try object(send("/v1/backups/\(id)", store: store))
            XCTAssertEqual(portable["format"] as? String, "weekstride-backup-v1")
            let nativeObject = try XCTUnwrap(portable["data"] as? [String: Any])
            let nativeBytes = try JSONSerialization.data(withJSONObject: nativeObject)
            XCTAssertEqual(try JSONDecoder().decode(LedgerData.self, from: nativeBytes), snapshot, "Native date doubles protect recurrence successor equality during undo")
            let exportedFiles = try XCTUnwrap(portable["attachments"] as? [[String: Any]])
            XCTAssertEqual(exportedFiles.count, 1, "Shared recurrence attachments are exported once")
            XCTAssertEqual(exportedFiles.first?["storedName"] as? String, attachment.storedName)
            try store.updateTask(id: task.id) { $0.notes = "Changed after backup" }
            try store.saveTask(WorkTask(title: "New task after backup"))
            let beforeRestore = store.data
            portable["confirm"] = "replace-current-data"
            _ = try send("/v1/backups/import", method: "POST", body: portable, store: store)
            XCTAssertEqual(store.data, snapshot)
            let safetyRoot = store.directory.appendingPathComponent("Backups")
            let safety = try XCTUnwrap(files.contentsOfDirectory(at: safetyRoot, includingPropertiesForKeys: nil).first)
            let safetyData = try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: safety.appendingPathComponent("data.json")))
            XCTAssertEqual(safetyData, beforeRestore)
            XCTAssertEqual(try Data(contentsOf: store.attachmentURL(attachment)), Data("first,second\n1,2\n".utf8))
            let successor = try XCTUnwrap(store.data.tasks.first(where: { $0.id != task.id }))
            XCTAssertEqual(successor.createdAt, successor.updatedAt)
            try store.undoCompletion(id: task.id)
            XCTAssertEqual(store.data.tasks.count, 1, "A round trip cannot make an untouched recurrence successor look modified")
        }
    }

    func testManagedRestoreAndDeleteAffectOnlyManagedSnapshot() throws {
        try withStore { store, _ in
            let task = WorkTask(title: "Before snapshot")
            try store.saveTask(task)
            let snapshot = store.data
            let id = try createBackup(store)
            let managed = store.directory.appendingPathComponent("APIBackups/\(id.uuidString).workledgerbackup")
            let unrelated = store.directory.appendingPathComponent("APIBackups/not-a-managed-backup")
            try files.createDirectory(at: unrelated, withIntermediateDirectories: false)
            let listed = try JSONSerialization.jsonObject(with: send("/v1/backups", store: store).body) as? [[String: Any]]
            XCTAssertEqual(listed?.count, 1)
            XCTAssertEqual(listed?.first?["id"] as? String, id.uuidString)
            try store.updateTask(id: task.id) { $0.title = "After snapshot" }
            let before = store.data
            for body: [String: Any] in [[:], ["confirm": false], ["confirm": NSNull()], ["confirm": "yes"], ["confirm": "replace-current-data", "path": "/tmp/ignored"]] {
                assertHTTP(400) { _ = try self.send("/v1/backups/\(id)/restore", method: "POST", body: body, store: store) }
                XCTAssertEqual(store.data, before)
            }
            _ = try send("/v1/backups/\(id)/restore", method: "POST", body: ["confirm": "replace-current-data"], store: store)
            XCTAssertEqual(store.data, snapshot)
            _ = try send("/v1/backups/\(id)", method: "DELETE", store: store)
            XCTAssertFalse(files.fileExists(atPath: managed.path))
            XCTAssertTrue(files.fileExists(atPath: unrelated.path))
            XCTAssertTrue(files.fileExists(atPath: store.directory.appendingPathComponent("Backups").path))
            XCTAssertEqual(store.data, snapshot)
        }
    }

    func testBackupImportRejectsMalformedFilesAndGraphWithoutReplacingData() throws {
        try withStore { store, root in
            let task = WorkTask(title: "Preserve current work")
            try store.saveTask(task)
            _ = try upload(Data("original".utf8), task: task, store: store)
            let id = try createBackup(store)
            var valid = try object(send("/v1/backups/\(id)", store: store))
            valid["confirm"] = "replace-current-data"
            let entry = try XCTUnwrap((valid["attachments"] as? [[String: Any]])?.first)
            let before = store.data
            var flushes = 0
            let observer = NotificationCenter.default.addObserver(forName: finishTaskEdits, object: nil, queue: nil) { _ in flushes += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            var invalid: [[String: Any]] = []
            for name in ["../outside.txt", "/tmp/outside.txt", ".", "..", "folder\\file"] {
                var body = valid; var file = entry; file["storedName"] = name; body["attachments"] = [file]; invalid.append(body)
            }
            var duplicate = valid; duplicate["attachments"] = [entry, entry]; invalid.append(duplicate)
            var missing = valid; missing["attachments"] = []; invalid.append(missing)
            var orphan = valid; var orphanEntry = entry; orphanEntry["storedName"] = "orphan.txt"; orphan["attachments"] = [entry, orphanEntry]; invalid.append(orphan)
            var malformed = valid; var malformedEntry = entry; malformedEntry["contentBase64"] = "not base64"; malformed["attachments"] = [malformedEntry]; invalid.append(malformed)
            var wrongSize = valid; var wrongEntry = entry; wrongEntry["contentBase64"] = Data("different size".utf8).base64EncodedString(); wrongSize["attachments"] = [wrongEntry]; invalid.append(wrongSize)
            var extra = valid; var extraEntry = entry; extraEntry["path"] = "/tmp/no"; extra["attachments"] = [extraEntry]; invalid.append(extra)
            var unsupported = valid; unsupported["format"] = "other"; invalid.append(unsupported)
            for body in invalid {
                assertHTTP(400) { _ = try self.send("/v1/backups/import", method: "POST", body: body, store: store) }
                XCTAssertEqual(store.data, before)
            }
            var graph = valid
            var ledger = try XCTUnwrap(graph["data"] as? [String: Any])
            var tasks = try XCTUnwrap(ledger["tasks"] as? [[String: Any]])
            tasks[0]["projectID"] = UUID().uuidString
            ledger["tasks"] = tasks
            graph["data"] = ledger
            XCTAssertThrowsError(try send("/v1/backups/import", method: "POST", body: graph, store: store))
            XCTAssertEqual(store.data, before)
            XCTAssertEqual(flushes, 0, "Invalid graph data must not save pending UI edits")
            var emptyTitle = valid
            var emptyLedger = try XCTUnwrap(valid["data"] as? [String: Any])
            var emptyTasks = try XCTUnwrap(emptyLedger["tasks"] as? [[String: Any]])
            emptyTasks[0]["title"] = ""
            emptyLedger["tasks"] = emptyTasks
            emptyTitle["data"] = emptyLedger
            XCTAssertThrowsError(try send("/v1/backups/import", method: "POST", body: emptyTitle, store: store))
            XCTAssertEqual(flushes, 0)
            XCTAssertEqual(store.data, before)
            var hugeDate = valid
            var hugeLedger = try XCTUnwrap(valid["data"] as? [String: Any])
            var hugeTasks = try XCTUnwrap(hugeLedger["tasks"] as? [[String: Any]])
            hugeTasks[0]["plannedAt"] = 1e300
            hugeLedger["tasks"] = hugeTasks
            hugeDate["data"] = hugeLedger
            XCTAssertThrowsError(try send("/v1/backups/import", method: "POST", body: hugeDate, store: store))
            XCTAssertEqual(flushes, 0)
            XCTAssertEqual(store.data, before)
            let managedJSON = store.directory.appendingPathComponent("APIBackups/\(id.uuidString).workledgerbackup/data.json")
            try JSONSerialization.data(withJSONObject: emptyLedger).write(to: managedJSON, options: .atomic)
            XCTAssertThrowsError(try send("/v1/backups/\(id)/restore", method: "POST", body: ["confirm": "replace-current-data"], store: store))
            XCTAssertEqual(flushes, 0, "A corrupt managed snapshot must be rejected before UI edits are flushed")
            XCTAssertEqual(store.data, before)
            XCTAssertFalse(files.fileExists(atPath: store.directory.appendingPathComponent("Backups").path), "A bad source must be rejected before replacement or safety-copy creation")
            XCTAssertFalse(files.fileExists(atPath: root.appendingPathComponent("outside.txt").path))
        }
    }

    func testBackupDirectoriesAndFilesCannotRedirectThroughSymlinks() throws {
        try withStore { store, root in
            let outside = root.appendingPathComponent("outside")
            try files.createDirectory(at: outside, withIntermediateDirectories: false)
            let marker = outside.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: marker)
            let backupRoot = store.directory.appendingPathComponent("APIBackups")
            try files.createSymbolicLink(at: backupRoot, withDestinationURL: outside)
            assertHTTP(400) { _ = try self.send("/v1/backups", method: "POST", store: store) }
            assertHTTP(400) { _ = try self.send("/v1/backups", store: store) }
            try files.removeItem(at: backupRoot)
            try files.createDirectory(at: backupRoot, withIntermediateDirectories: false)
            let id = UUID()
            let linked = backupRoot.appendingPathComponent("\(id.uuidString).workledgerbackup")
            try files.createSymbolicLink(at: linked, withDestinationURL: outside)
            assertHTTP(400) { _ = try self.send("/v1/backups/\(id)", method: "DELETE", store: store) }
            XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
            let created = try createBackup(store)
            let json = backupRoot.appendingPathComponent("\(created.uuidString).workledgerbackup/data.json")
            try files.removeItem(at: json)
            try files.createSymbolicLink(at: json, withDestinationURL: marker)
            assertHTTP(400) { _ = try self.send("/v1/backups/\(created)", store: store) }
        }
    }

    func testFailedEditorFlushBlocksBackupAndAttachmentMutations() throws {
        try withStore { store, _ in
            let task = WorkTask(title: "Pending editor")
            try store.saveTask(task)
            let attachment = try upload(Data("keep".utf8), task: task, store: store)
            let id = try createBackup(store)
            var portable = try object(send("/v1/backups/\(id)", store: store))
            portable["confirm"] = "replace-current-data"
            var allFlushes = 0
            let allObserver = NotificationCenter.default.addObserver(forName: finishTaskEdits, object: nil, queue: nil) { note in
                guard let request = note.object as? TaskEditingExitRequest else { return }
                XCTAssertNil(request.taskID)
                allFlushes += 1
                request.failed = true
            }
            let taskObserver = NotificationCenter.default.addObserver(forName: flushTaskEdits, object: nil, queue: nil) { note in
                guard let request = note.object as? InlineFlushRequest else { return }
                XCTAssertEqual(request.taskID, task.id)
                request.failed = true
            }
            defer { NotificationCenter.default.removeObserver(allObserver); NotificationCenter.default.removeObserver(taskObserver) }
            let before = store.data
            assertHTTP(400) { _ = try self.send("/v1/backups", method: "POST", store: store) }
            assertHTTP(400) { _ = try self.send("/v1/backups/\(id)/restore", method: "POST", body: ["confirm": "replace-current-data"], store: store) }
            assertHTTP(400) { _ = try self.send("/v1/backups/import", method: "POST", body: portable, store: store) }
            assertHTTP(400) { _ = try self.send("/v1/tasks/\(task.id)/attachments", method: "POST", body: ["name": "new.txt", "contentBase64": "YQ=="], store: store) }
            assertHTTP(400) { _ = try self.send("/v1/tasks/\(task.id)/attachments/\(attachment.id)", method: "DELETE", store: store) }
            XCTAssertEqual(allFlushes, 3)
            XCTAssertEqual(store.data, before)
            XCTAssertFalse(files.fileExists(atPath: store.directory.appendingPathComponent("Backups").path))
        }
    }

    func testFileRoutesRejectQueriesBodiesUnknownMethodsAndUnrelatedPaths() throws {
        try withStore { store, _ in
            let task = WorkTask(title: "Routes")
            try store.saveTask(task)
            assertHTTP(400) { _ = try self.send("/v1/backups?path=/tmp/file", store: store) }
            assertHTTP(400) { _ = try self.send("/v1/tasks/\(task.id)/attachments", body: [:], store: store) }
            assertHTTP(405) { _ = try self.send("/v1/backups", method: "PATCH", body: [:], store: store) }
            assertHTTP(404) { _ = try self.send("/v1/backups/not-an-id", store: store) }
            XCTAssertNil(try LocalAPIFileRoutes.respond(to: request("/v1/projects"), store: store))
        }
    }

    func testImportRejectsFileNamesThatCollideOnTheDestinationFileSystem() throws {
        try withStore { store, root in
            let probe = root.appendingPathComponent("CaseProbe")
            try Data().write(to: probe)
            guard files.fileExists(atPath: root.appendingPathComponent("caseprobe").path) else { throw XCTSkip("Requires a case-insensitive file system") }
            let first = Attachment(name: "First", storedName: "A.txt", size: 1)
            let second = Attachment(name: "Second", storedName: "a.txt", size: 1)
            let ledger = LedgerData(tasks: [WorkTask(title: "Imported", attachments: [first, second])])
            let native = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger))
            let payload: [String: Any] = ["format": "weekstride-backup-v1", "data": native,
                "attachments": [["storedName": "A.txt", "contentBase64": "YQ=="], ["storedName": "a.txt", "contentBase64": "Yg=="]],
                "confirm": "replace-current-data"]
            var flushes = 0
            let observer = NotificationCenter.default.addObserver(forName: finishTaskEdits, object: nil, queue: nil) { _ in flushes += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            let before = store.data
            assertHTTP(400) { _ = try self.send("/v1/backups/import", method: "POST", body: payload, store: store) }
            XCTAssertEqual(store.data, before)
            XCTAssertEqual(flushes, 0)
        }
    }

    func testBackupBoundsDecodedAggregateAndEncodedResponse() throws {
        try withStore { store, _ in
            let attachment = Attachment(name: "large.bin", storedName: "large.bin", size: 13 * 1024 * 1024)
            XCTAssertTrue(files.createFile(atPath: store.attachmentURL(attachment).path, contents: nil))
            let handle = try FileHandle(forWritingTo: store.attachmentURL(attachment))
            try handle.truncate(atOffset: UInt64(attachment.size))
            try handle.close()
            let task = WorkTask(title: "Bound encoded response", attachments: [attachment])
            try store.saveTask(task)
            let id = try createBackup(store)
            assertHTTP(413) { _ = try self.send("/v1/backups/\(id)", store: store) }
            let original = store.data
            let second = Attachment(name: "second.bin", storedName: "second.bin", size: 4 * 1024 * 1024)
            XCTAssertTrue(files.createFile(atPath: store.attachmentURL(second).path, contents: nil))
            let secondHandle = try FileHandle(forWritingTo: store.attachmentURL(second))
            try secondHandle.truncate(atOffset: UInt64(second.size))
            try secondHandle.close()
            try store.updateTask(id: task.id) { $0.attachments.append(second) }
            assertHTTP(413) { _ = try self.send("/v1/backups", method: "POST", store: store) }
            XCTAssertEqual(store.data.tasks.first?.attachments.count, 2)
            XCTAssertEqual(original.tasks.first?.attachments, [attachment])
            XCTAssertEqual(try files.contentsOfDirectory(atPath: store.directory.appendingPathComponent("APIBackups").path).count, 1)
        }
    }
}
