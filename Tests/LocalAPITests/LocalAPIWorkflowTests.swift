import XCTest
import Network
import WorkLedgerCore
@testable import WorkLedger

final class LocalAPIWorkflowTests: XCTestCase {
    @MainActor
    func testHTTPWorkflowKeepsPlanningFilesSettingsAndBackupConsistent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WeekStride-workflow-\(UUID())")
        let suite = "WeekStride-workflow-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = try WorkStore(directory: root)
        let server = LocalAPIServer()
        let token = String(repeating: "d", count: 64)
        let ready = expectation(description: "isolated API listener")
        server.onStatus = { if $0.hasPrefix("已开启") { ready.fulfill() } }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer {
            server.stop(); session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try server.start(token: token, store: store, port: .any, defaults: defaults)
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(server.boundPort)
        func send(_ method: String, _ path: String, _ json: [String: Any]? = nil) async throws -> (Data, Int) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let json {
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
        }
        func object(_ result: (Data, Int), status: Int = 200) throws -> [String: Any] {
            XCTAssertEqual(result.1, status, String(decoding: result.0, as: UTF8.self))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: result.0) as? [String: Any])
        }
        let capabilities = try object(await send("GET", "/v1/capabilities"))
        XCTAssertEqual(capabilities["apiVersion"] as? Int, 1)
        let project = try object(await send("POST", "/v1/projects", ["name": "Release", "colorHex": "3478F6"]), status: 201)
        let projectID = try XCTUnwrap(project["id"] as? String)
        let created = try object(await send("POST", "/v1/tasks", ["title": "Ship the update", "projectID": projectID]), status: 201)
        let taskID = try XCTUnwrap(created["id"] as? String)
        let base = "/v1/tasks/\(taskID)"
        _ = try object(await send("POST", base + "/plan", ["plan": "thisWeek"]))
        _ = try object(await send("PATCH", base, ["details": "Verify the build", "notes": "Keep local work safe", "repeatRule": ["every": 6, "unit": "month", "basis": "completion"]]))
        let step = try object(await send("POST", base + "/subtasks", ["title": "Check the app"]), status: 201)
        let stepID = try XCTUnwrap(step["id"] as? String)
        let bytes = Data("A synthetic release note".utf8)
        let attachment = try object(await send("POST", base + "/attachments", ["name": "note.txt", "contentBase64": bytes.base64EncodedString()]), status: 201)
        let attachmentID = try XCTUnwrap(attachment["id"] as? String)
        let download = try await send("GET", base + "/attachments/\(attachmentID)/content")
        XCTAssertEqual(download.1, 200)
        XCTAssertEqual(download.0, bytes)
        let settings = try object(await send("PATCH", "/v1/settings", ["weekStart": 4, "appLanguage": "en"]))
        XCTAssertEqual(settings["weekStart"] as? Int, 4)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
        let view = try object(await send("PATCH", "/v1/projects/\(projectID)/view", ["columns": "two", "planFilter": "thisWeek"]))
        XCTAssertEqual(view["columns"] as? String, "two")
        let backup = try object(await send("POST", "/v1/backups"), status: 201)
        let backupID = try XCTUnwrap(backup["id"] as? String)
        let snapshot = store.data
        let portable = try object(await send("GET", "/v1/backups/\(backupID)"))
        XCTAssertEqual(portable["format"] as? String, "weekstride-backup-v1")
        _ = try object(await send("PATCH", base, ["notes": "Changed after backup"]))
        let missingConfirmation = try await send("POST", "/v1/backups/\(backupID)/restore", [:])
        XCTAssertEqual(missingConfirmation.1, 400)
        XCTAssertNotEqual(store.data, snapshot)
        _ = try object(await send("POST", "/v1/backups/\(backupID)/restore", ["confirm": "replace-current-data"]))
        XCTAssertEqual(store.data, snapshot)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path).isEmpty)
        let completed = try object(await send("POST", base + "/subtasks/\(stepID)/complete"))
        XCTAssertNotNil(completed["nextTask"])
        XCTAssertEqual(store.data.tasks.count, 2)
        _ = try object(await send("POST", base + "/complete"))
        XCTAssertEqual(store.data.tasks.count, 2)
        _ = try object(await send("POST", base + "/reopen"))
        XCTAssertEqual(store.data.tasks.count, 1)
        XCTAssertNil(store.data.tasks.first?.completedAt)
        _ = try object(await send("DELETE", "/v1/projects/\(projectID)"))
        XCTAssertNil(store.data.tasks.first?.projectID)
        let deletion = try object(await send("DELETE", base))
        XCTAssertTrue(store.data.tasks.isEmpty)
        _ = try object(await send("POST", "/v1/tasks/restore", ["snapshot": deletion]), status: 201)
        XCTAssertEqual(store.data.tasks.count, 1)
        XCTAssertEqual(store.data.tasks.first?.attachments.first?.id.uuidString, attachmentID)
    }
}
