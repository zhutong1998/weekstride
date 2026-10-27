import XCTest
import WorkLedgerCore
@testable import WorkLedger

final class LocalAPIHelpTests: XCTestCase {
    @MainActor
    func testRootHelpIsPublicStaticAndOtherRoutesStayProtected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WeekStride-Help-test-\(UUID())")
        let suite = "WeekStride-Help-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "PRIVATE-PROJECT-NOT-FOR-HELP")
        try store.saveTask(WorkTask(projectID: project.id, title: "PRIVATE-TASK-NOT-FOR-HELP"))
        defaults.set("dark", forKey: "appAppearance")
        let before = store.data
        let token = String(repeating: "a", count: 64)
        let server = LocalAPIServer()
        let ready = expectation(description: "Help test listener ready")
        server.onStatus = { if $0.hasPrefix("已开启") { ready.fulfill() } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer {
            server.stop()
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try server.start(token: token, store: store, port: .any, defaults: defaults)
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(server.boundPort)

        func send(_ path: String, authorized: Bool = false, host: String? = nil, origin: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let host { request.setValue(host, forHTTPHeaderField: "Host") }
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            let (data, response) = try await session.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }

        let help = try await send("/")
        XCTAssertEqual(help.1.statusCode, 200)
        XCTAssertEqual(help.1.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        XCTAssertEqual(help.1.value(forHTTPHeaderField: "Content-Length"), String(help.0.count))
        XCTAssertEqual(help.1.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(help.1.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(help.1.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer")
        let policy = try XCTUnwrap(help.1.value(forHTTPHeaderField: "Content-Security-Policy"))
        XCTAssertTrue(policy.contains("default-src 'none'"))
        XCTAssertTrue(policy.contains("frame-ancestors 'none'"))
        let html = try XCTUnwrap(String(data: help.0, encoding: .utf8))
        for text in ["WeekStride Local API", "Settings → Local API", "Authorization: Bearer YOUR_TOKEN", "curl", "--request POST",
                     "/v1/tasks/TASK_ID/complete", "repeatRule", "plannedAt", "dueAt", "reminderAt", "Content-Type: application/json",
                     "replace-current-data", "401", "403", "ISO 8601", "numeric dates", "runInMenuBar",
                     "/v1/tags", "tagIDs", "isStarred", "starred=true|false"] {
            XCTAssertTrue(html.contains(text), "Root help is missing \(text)")
        }
        for route in LocalAPICapabilities().routes { XCTAssertTrue(html.contains(route), "Root help must use the discovery route list: \(route)") }
        XCTAssertFalse(html.contains(token))
        XCTAssertFalse(html.contains("PRIVATE-PROJECT-NOT-FOR-HELP"))
        XCTAssertFalse(html.contains("PRIVATE-TASK-NOT-FOR-HELP"))
        XCTAssertFalse(html.contains("<script"))
        let authorizedHelp = try await send("/", authorized: true)
        XCTAssertEqual(authorizedHelp.0, help.0, "The help page must never contain personalized data")

        for path in ["/health", "/v1", "/v1/capabilities", "/v1/tasks", "/v1/settings", "/?help=true"] {
            let denied = try await send(path)
            XCTAssertEqual(denied.1.statusCode, 401, "Only exact GET / is public: \(path)")
        }
        let wrongHost = try await send("/", host: "attacker.example:\(port)")
        XCTAssertEqual(wrongHost.1.statusCode, 403)
        let wrongPort = try await send("/", host: "127.0.0.1:0")
        XCTAssertEqual(wrongPort.1.statusCode, 403)
        let foreignOrigin = try await send("/", origin: "https://attacker.example")
        XCTAssertEqual(foreignOrigin.1.statusCode, 403)
        let sameOrigin = try await send("/", origin: "http://127.0.0.1:\(port)")
        XCTAssertEqual(sameOrigin.1.statusCode, 403, "The help exemption must retain the existing Origin guard")
        let health = try await send("/health", authorized: true)
        XCTAssertEqual(health.1.statusCode, 200)
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(defaults.string(forKey: "appAppearance"), "dark")

        if let renderDirectory = ProcessInfo.processInfo.environment["WORKLEDGER_RENDER_DIR"] {
            let output = URL(fileURLWithPath: renderDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try help.0.write(to: output.appendingPathComponent("local-api-help.html"))
        }
    }

    @MainActor
    func testHelpRoutingDoesNotAcceptBodyOrNormalizedTargets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WeekStride-Help-route-test-\(UUID())")
        let store = try WorkStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = LocalAPIServer()
        func response(_ target: String, method: String = "GET", body: Data = Data()) -> LocalAPIResponse {
            server.respond(to: LocalAPIRequest(head: .init(method: method, target: target, headers: [:], bodyLength: body.count, headerLength: 0), body: body), store: store)
        }
        XCTAssertEqual(response("/").status, 200)
        XCTAssertEqual(response("/", body: Data("x".utf8)).status, 400)
        XCTAssertEqual(response("/", method: "POST").status, 404)
        XCTAssertEqual(response("/", method: "HEAD").status, 405)
        for target in ["/?", "/?help=true", "/%2f", "/%2e"] { XCTAssertEqual(response(target).status, 404, target) }
    }
}
