import XCTest
import Foundation
import WorkLedgerCore
@testable import WorkLedger

final class LocalAPIIntegrationTests: XCTestCase {
    @MainActor
    func testAuthenticatedLoopbackCompletionIsIdempotentAndStops() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedger-API-test-\(UUID().uuidString)")
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "API 测试")
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = due.addingTimeInterval(-86400)
        let planned = due.addingTimeInterval(-30 * 86400)
        let task = WorkTask(projectID: project.id, title: "更新证书", subtasks: [Subtask(title: "验证")], dueAt: due, reminderAt: reminder, repeatRule: RepeatRule(every: 6, unit: .month), plannedAt: planned, planGranularity: .week)
        try store.saveTask(task)
        let server = LocalAPIServer()
        let ready = expectation(description: "loopback server ready")
        server.onStatus = { if $0.hasPrefix("已开启") { ready.fulfill() } }
        let token = String(repeating: "b", count: 64)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer {
            server.stop()
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
        }
        try server.start(token: token, store: store, port: .any)
        await fulfillment(of: [ready], timeout: 3)
        var port = try XCTUnwrap(server.boundPort, "Do not send requests unless this test listener is ready")

        func send(_ path: String, method: String = "GET", body: String? = nil, authorized: Bool = true, origin: Bool = false, bearer: String? = nil, host: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            if let host { request.setValue(host, forHTTPHeaderField: "Host") }
            if authorized { request.setValue("Bearer \(bearer ?? token)", forHTTPHeaderField: "Authorization") }
            if origin { request.setValue("https://malicious.example", forHTTPHeaderField: "Origin") }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(body.utf8)
            }
            let (data, response) = try await session.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }

        let unauthorized = try await send("/v1/projects", authorized: false)
        XCTAssertEqual(unauthorized.1.statusCode, 401)
        let origin = try await send("/health", origin: true)
        XCTAssertEqual(origin.1.statusCode, 403)
        let mismatchedPort = try await send("/health", host: "127.0.0.1:0")
        XCTAssertEqual(mismatchedPort.1.statusCode, 403)
        let localHost = try await send("/health", host: "localhost:\(port)")
        XCTAssertEqual(localHost.1.statusCode, 200)
        let projects = try await send("/v1/projects")
        XCTAssertEqual(projects.1.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode([Project].self, from: projects.0), [project])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let beforeRead = store.data
        let tasks = try await send("/v1/tasks?status=open&projectId=\(project.id)")
        XCTAssertEqual(tasks.1.statusCode, 200)
        let exported = try XCTUnwrap(decoder.decode([WorkTask].self, from: tasks.0).first)
        XCTAssertEqual(exported.id, task.id)
        XCTAssertEqual(exported.plannedAt, planned)
        XCTAssertEqual(exported.planGranularity, .week)
        XCTAssertEqual(exported.dueAt, due)
        XCTAssertEqual(exported.reminderAt, reminder)
        XCTAssertEqual(store.data, beforeRead, "Reading a plan must not modify due dates, reminders, or saved task data")

        let invalidBodies = [
            #"{"completedAt":"yesterday"}"#,
            #"{"completed_at":"2020-10-20T08:30:00+08:00"}"#,
            #"{"unexpected":true}"#,
            #"{"completedAt":"2020-10-20T08:30:00+08:00","unexpected":true}"#,
            #"{"completedAt":"2020-02-31T09:00:00+08:00"}"#,
            #"{"completedAt":"2020-10-20T24:00:00+08:00"}"#,
            #"{"completedAt":"2020-10-20T09:60:00+08:00"}"#,
            #"{"completedAt":"2020-10-20T09:00:00Zjunk"}"#,
            #"{"completedAt":"2020-10-20T09:00:00"}"#,
            #"{"completedAt":"2020-10-20T09:00:00Z\n"}"#,
            #"{"completedAt":42}"#,
            #"{"completedAt":null}"#,
            #"{"completedAt":false}"#,
            #"{"completedAt":{}}"#,
            "[]", "null", "42", #""not-an-object""#, "{"
        ]
        let beforeInvalid = store.data
        for body in invalidBodies {
            let rejected = try await send("/v1/tasks/\(task.id)/complete", method: "POST", body: body)
            XCTAssertEqual(rejected.1.statusCode, 400, "拒绝错误完成正文：\(body)")
            XCTAssertNotNil(try JSONDecoder().decode([String: String].self, from: rejected.0)["error"])
            XCTAssertEqual(store.data, beforeInvalid, "错误字段或日期不能完成任务或创建下一次循环：\(body)")
        }
        let unknownSubtask = try await send("/v1/tasks/\(task.id)/subtasks/\(UUID())/complete", method: "POST")
        XCTAssertEqual(unknownSubtask.1.statusCode, 404)
        XCTAssertNil(store.data.tasks.first?.completedAt)
        XCTAssertEqual(store.data.tasks.count, 1)

        let first = try await send("/v1/tasks/\(task.id)/complete", method: "POST", body: #"{"completedAt":"2020-10-20T08:30:00.125+08:00"}"#)
        XCTAssertEqual(first.1.statusCode, 200)
        let result = try decoder.decode(CompletionResult.self, from: first.0)
        XCTAssertFalse(result.alreadyCompleted)
        let completionFormatter = ISO8601DateFormatter()
        completionFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let preciseCompletion = try XCTUnwrap(completionFormatter.date(from: "2020-10-20T08:30:00.125+08:00"))
        XCTAssertEqual(store.data.tasks.first(where: { $0.id == task.id })?.completedAt, preciseCompletion, "带时区和小数秒的合法日期应完整保存")
        XCTAssertLessThan(abs(try XCTUnwrap(result.task.completedAt).timeIntervalSince(preciseCompletion)), 1, "现有响应日期精度为秒，不能改变完成日或时刻")
        XCTAssertNotNil(result.nextTask)
        XCTAssertEqual(result.task.completionSource, "API")
        XCTAssertEqual(result.task.plannedAt, planned)
        XCTAssertEqual(result.task.planGranularity, .week)
        XCTAssertEqual(result.task.dueAt, due)
        XCTAssertEqual(result.task.reminderAt, reminder)
        XCTAssertNil(result.nextTask?.plannedAt)
        XCTAssertNil(result.nextTask?.planGranularity)
        let second = try await send("/v1/tasks/\(task.id)/complete", method: "POST")
        XCTAssertEqual(second.1.statusCode, 200)
        let repeatResult = try decoder.decode(CompletionResult.self, from: second.0)
        XCTAssertTrue(repeatResult.alreadyCompleted)
        XCTAssertEqual(repeatResult.nextTask?.id, result.nextTask?.id)
        XCTAssertEqual(store.data.tasks.count, 2)

        let open = try await send("/v1/tasks?status=open&projectId=\(project.id)")
        XCTAssertEqual(try decoder.decode([WorkTask].self, from: open.0).map(\.id), [try XCTUnwrap(result.nextTask?.id)])

        let unassigned = WorkTask(title: "未归类的临时工作")
        try store.saveTask(unassigned)
        let allTasks = try await send("/v1/tasks?status=open")
        let allDecoded = try decoder.decode([WorkTask].self, from: allTasks.0)
        XCTAssertTrue(allDecoded.contains(where: { $0.id == unassigned.id && $0.projectID == nil }))
        let assignedOnly = try await send("/v1/tasks?status=open&projectId=\(project.id)")
        XCTAssertFalse(try decoder.decode([WorkTask].self, from: assignedOnly.0).contains(where: { $0.id == unassigned.id }))
        let unassignedRead = try await send("/v1/tasks/\(unassigned.id)")
        XCTAssertEqual(unassignedRead.1.statusCode, 200)
        XCTAssertNil(try decoder.decode(WorkTask.self, from: unassignedRead.0).projectID)
        let unassignedComplete = try await send("/v1/tasks/\(unassigned.id)/complete", method: "POST", body: "{}")
        XCTAssertEqual(unassignedComplete.1.statusCode, 200)
        let unassignedResult = try decoder.decode(CompletionResult.self, from: unassignedComplete.0)
        XCTAssertNil(unassignedResult.task.projectID)
        XCTAssertNotNil(unassignedResult.task.completedAt)
        XCTAssertNil(unassignedResult.nextTask)

        let firstStep = Subtask(title: "检查部署"), lastStep = Subtask(title: "验证结果")
        let steppedTask = WorkTask(title: "API 分步循环", notes: "提交前备注", subtasks: [firstStep, lastStep], repeatRule: RepeatRule(every: 6, unit: .month))
        try store.saveTask(steppedTask)
        let countBeforeSteps = store.data.tasks.count
        let pendingEditor = TaskEditingBoundary.BoundaryView()
        var rejectPendingEdits = true
        var pendingNotes = "完成第一步前刚刚输入的备注"
        var flushCount = 0
        pendingEditor.onFlush = { request in
            guard request.taskID == steppedTask.id else { return }
            flushCount += 1
            guard !rejectPendingEdits else { request.failed = true; return }
            do { try store.updateTask(id: steppedTask.id) { $0.notes = pendingNotes } }
            catch { request.failed = true }
        }
        pendingEditor.setEnabled(true)
        defer { pendingEditor.reset() }

        let beforeBlocked = store.data
        let blockedStep = try await send("/v1/tasks/\(steppedTask.id)/subtasks/\(firstStep.id)/complete", method: "POST")
        XCTAssertEqual(blockedStep.1.statusCode, 400, "未提交编辑校验失败时不能从 API 完成步骤")
        XCTAssertEqual(store.data, beforeBlocked)
        XCTAssertEqual(flushCount, 1)

        rejectPendingEdits = false
        let partial = try await send("/v1/tasks/\(steppedTask.id)/subtasks/\(firstStep.id)/complete", method: "POST", body: #"{"completedAt":"2020-10-20T08:30:00+08:00"}"#)
        XCTAssertEqual(partial.1.statusCode, 200)
        let partialResult = try decoder.decode(CompletionResult.self, from: partial.0)
        XCTAssertFalse(partialResult.alreadyCompleted)
        XCTAssertNil(partialResult.task.completedAt)
        XCTAssertNotNil(partialResult.task.subtasks.first(where: { $0.id == firstStep.id })?.completedAt)
        XCTAssertNil(partialResult.task.subtasks.first(where: { $0.id == lastStep.id })?.completedAt)
        XCTAssertEqual(partialResult.task.notes, pendingNotes)
        XCTAssertNil(partialResult.nextTask)
        XCTAssertEqual(store.data.tasks.count, countBeforeSteps)
        XCTAssertEqual(flushCount, 2)

        rejectPendingEdits = true
        let afterPartial = store.data
        let repeatedPartial = try await send("/v1/tasks/\(steppedTask.id)/subtasks/\(firstStep.id)/complete", method: "POST")
        XCTAssertEqual(repeatedPartial.1.statusCode, 200)
        XCTAssertTrue(try decoder.decode(CompletionResult.self, from: repeatedPartial.0).alreadyCompleted)
        XCTAssertEqual(store.data, afterPartial, "重试已完成的步骤不能再次提交编辑或修改完成日期")
        XCTAssertEqual(flushCount, 2)

        let blockedTask = try await send("/v1/tasks/\(steppedTask.id)/complete", method: "POST", body: "{}")
        XCTAssertEqual(blockedTask.1.statusCode, 400, "主任务也必须先通过待提交编辑的校验")
        XCTAssertEqual(store.data, afterPartial)
        XCTAssertEqual(flushCount, 3)

        rejectPendingEdits = false
        pendingNotes = "完成前最后输入的备注，下一次循环必须继承"
        let final = try await send("/v1/tasks/\(steppedTask.id)/subtasks/\(lastStep.id)/complete", method: "POST", body: #"{"completedAt":"2020-10-21T08:30:00+08:00"}"#)
        XCTAssertEqual(final.1.statusCode, 200)
        let finalResult = try decoder.decode(CompletionResult.self, from: final.0)
        let following = try XCTUnwrap(finalResult.nextTask)
        XCTAssertFalse(finalResult.alreadyCompleted)
        XCTAssertNotNil(finalResult.task.completedAt)
        XCTAssertTrue(finalResult.task.subtasks.allSatisfy { $0.completedAt != nil })
        XCTAssertEqual(finalResult.task.notes, pendingNotes)
        XCTAssertEqual(following.notes, pendingNotes, "循环任务必须继承完成前提交的最新备注")
        XCTAssertTrue(following.subtasks.allSatisfy { $0.completedAt == nil })
        XCTAssertEqual(store.data.tasks.count, countBeforeSteps + 1)
        XCTAssertEqual(flushCount, 4)

        rejectPendingEdits = true
        let afterFinal = store.data
        let repeatedFinal = try await send("/v1/tasks/\(steppedTask.id)/subtasks/\(lastStep.id)/complete", method: "POST")
        XCTAssertEqual(repeatedFinal.1.statusCode, 200)
        let repeatedFinalResult = try decoder.decode(CompletionResult.self, from: repeatedFinal.0)
        XCTAssertTrue(repeatedFinalResult.alreadyCompleted)
        XCTAssertEqual(repeatedFinalResult.nextTask?.id, following.id)
        let repeatedParent = try await send("/v1/tasks/\(steppedTask.id)/complete", method: "POST")
        XCTAssertEqual(repeatedParent.1.statusCode, 200)
        XCTAssertTrue(try decoder.decode(CompletionResult.self, from: repeatedParent.0).alreadyCompleted)
        XCTAssertEqual(store.data, afterFinal)
        XCTAssertEqual(flushCount, 4, "已完成的任务与步骤重试应跳过编辑提交")

        let replacementToken = String(repeating: "c", count: 64)
        let restarted = expectation(description: "loopback server restarted with new token")
        server.onStatus = { if $0.hasPrefix("已开启") { restarted.fulfill() } }
        try server.start(token: token, store: store, port: .any)
        server.stop()
        try server.start(token: token, store: store, port: .any)
        server.stop()
        try server.start(token: replacementToken, store: store, port: .any)
        await fulfillment(of: [restarted], timeout: 3)
        port = try XCTUnwrap(server.boundPort, "Do not send requests unless the replacement listener is ready")
        let staleToken = try await send("/health")
        XCTAssertEqual(staleToken.1.statusCode, 401, "重置后旧令牌不能访问")
        let newToken = try await send("/health", bearer: replacementToken)
        XCTAssertEqual(newToken.1.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: newToken.0)["status"], "ok")
        server.stop()
        do {
            _ = try await send("/health", bearer: replacementToken)
            XCTFail("Disabled API must refuse new requests")
        } catch { /* A stopped listener refuses the connection. */ }
    }
}
