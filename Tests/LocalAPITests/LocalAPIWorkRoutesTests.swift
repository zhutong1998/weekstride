import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class LocalAPIWorkRoutesTests: XCTestCase {
    private func withStore(_ body: (WorkStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerWorkRoutes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(WorkStore(directory: directory))
    }

    private func request(_ method: String, _ target: String, body: [String: Any]? = nil, raw: String? = nil) throws -> LocalAPIRequest {
        let data = try raw.map { Data($0.utf8) } ?? body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let head = LocalAPIRequestHead(method: method, target: target, headers: data.isEmpty ? [:] : ["content-type": "application/json"], bodyLength: data.count, headerLength: 0)
        return LocalAPIRequest(head: head, body: data)
    }

    private func route(_ method: String, _ target: String, store: WorkStore, body: [String: Any]? = nil, raw: String? = nil) throws -> LocalAPIResponse {
        let response = try LocalAPIWorkRoutes.respond(to: request(method, target, body: body, raw: raw), store: store, firstWeekday: 5)
        return try XCTUnwrap(response)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: LocalAPIResponse) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: response.body)
    }

    private func assertHTTP(_ status: Int, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? LocalAPIHTTPError)?.status, status, "\(error)", file: file, line: line)
        }
    }

    func testProjectLifecycleAndDeletingProjectPreservesTasks() async throws {
        try withStore { store in
            let created = try route("POST", "/v1/projects", store: store, body: ["name": " Website ", "colorHex": "#ABCDEF"])
            XCTAssertEqual(created.status, 201)
            let project = try decode(Project.self, created)
            XCTAssertEqual(project.name, "Website")
            let task = WorkTask(projectID: project.id, title: "Keep this work", notes: "Must remain after deleting project")
            try store.saveTask(task)
            let updated = try route("PATCH", "/v1/projects/\(project.id)", store: store, body: ["name": "Operations", "colorHex": "112233", "isArchived": true])
            XCTAssertTrue(try decode(Project.self, updated).isArchived)
            XCTAssertEqual(try decode([Project].self, route("GET", "/v1/projects?status=active", store: store)).count, 0)
            XCTAssertEqual(try decode([Project].self, route("GET", "/v1/projects?status=archived", store: store)).map(\.id), [project.id])
            assertHTTP(409) { _ = try route("POST", "/v1/tasks", store: store, body: ["title": "Cannot assign", "projectID": project.id.uuidString]) }
            assertHTTP(400) { _ = try route("PATCH", "/v1/projects/\(project.id)", store: store, body: ["isArchived": 1]) }
            _ = try route("DELETE", "/v1/projects/\(project.id)", store: store)
            XCTAssertTrue(store.data.projects.isEmpty)
            XCTAssertEqual(store.data.tasks.count, 1)
            XCTAssertNil(store.data.tasks[0].projectID)
            XCTAssertEqual(store.data.tasks[0].notes, task.notes)
            XCTAssertEqual(try decode([WorkTask].self, route("GET", "/v1/tasks?projectId=none", store: store)).map(\.id), [task.id])
            XCTAssertNil(try LocalAPIWorkRoutes.respond(to: request("GET", "/v1/projects/\(project.id)/view"), store: store, firstWeekday: 5), "Unknown suffixes must remain available to the settings router")
        }
    }

    func testTaskPatchRebasesOnFlushedEditsAndRejectsInvalidRequestsBeforeFlushing() async throws {
        try withStore { store in
            let created = try route("POST", "/v1/tasks", store: store, body: ["title": "Original", "details": "Steps", "plannedAt": "2020-01-02T00:00:00Z", "planGranularity": "week"])
            let task = try decode(WorkTask.self, created)
            let bridge = TaskEditingBoundary.BoundaryView()
            var flushes = 0
            bridge.onFlush = { request in
                guard request.taskID == task.id else { return }
                flushes += 1
                do { try store.updateTask(id: task.id) { $0.notes = "Typed locally before API patch" } }
                catch { request.failed = true }
            }
            bridge.setEnabled(true); defer { bridge.setEnabled(false) }
            let invalidBodies: [[String: Any]] = [
                ["title": NSNull()], ["completedAt": "2020-01-01T00:00:00Z"], ["attachments": []],
                ["repeatRule": ["every": true, "unit": "month", "basis": "completion"]],
                ["repeatRule": ["every": 1, "unit": "month", "basis": "completion", "extra": true]],
                ["plannedAt": NSNull(), "planGranularity": "week"], ["projectID": UUID().uuidString]
            ]
            for body in invalidBodies { XCTAssertThrowsError(try route("PATCH", "/v1/tasks/\(task.id)", store: store, body: body)) }
            assertHTTP(400) { _ = try route("PATCH", "/v1/tasks/\(task.id)", store: store, raw: #"{"title":"one","title":"two"}"#) }
            XCTAssertEqual(flushes, 0)
            let response = try route("PATCH", "/v1/tasks/\(task.id)", store: store, body: ["title": " API title ", "plannedAt": NSNull()])
            let updated = try decode(WorkTask.self, response)
            XCTAssertEqual(flushes, 1)
            XCTAssertEqual(updated.title, "API title")
            XCTAssertEqual(updated.notes, "Typed locally before API patch")
            XCTAssertEqual(updated.details, "Steps")
            XCTAssertNil(updated.plannedAt)
            XCTAssertNil(updated.planGranularity)
            XCTAssertNil(updated.completedAt)
        }
    }

    func testRepeatPatchAndRelativePlanningPreserveIndependentDates() async throws {
        try withStore { store in
            let due = Date(timeIntervalSince1970: 1_700_000_000)
            let task = WorkTask(title: "Repeat", dueAt: due, reminderAt: due.addingTimeInterval(-3600), repeatRule: RepeatRule(every: 1, unit: .month, basis: .schedule), plannedAt: due, planGranularity: .day)
            try store.saveTask(task)
            XCTAssertTrue(task.isPlanOverdue(firstWeekday: 5))
            let planned = try decode(WorkTask.self, route("POST", "/v1/tasks/\(task.id)/plan", store: store, body: ["plan": "thisWeek"]))
            XCTAssertFalse(planned.isPlanOverdue(firstWeekday: 5))
            XCTAssertEqual(planned.planGranularity, .week)
            XCTAssertEqual(planned.dueAt, due)
            XCTAssertEqual(planned.reminderAt, task.reminderAt)
            _ = try route("POST", "/v1/tasks/\(task.id)/plan", store: store, body: ["plan": "weekAfterNext"])
            let week = WorkPeriod.range(containing: store.data.tasks[0].plannedAt!, firstWeekday: 5)
            let current = WorkPeriod.range(containing: Date(), firstWeekday: 5)
            XCTAssertEqual(week.start, Calendar.current.date(byAdding: .day, value: 7, to: current.end))
            let cleared = try decode(WorkTask.self, route("PATCH", "/v1/tasks/\(task.id)", store: store, body: ["dueAt": NSNull()]))
            XCTAssertNil(cleared.dueAt)
            XCTAssertEqual(cleared.repeatRule?.basis, .completion, "Removing a fixed due date mirrors the native editor's switch to completion-based recurrence")
            _ = try route("POST", "/v1/tasks/\(task.id)/plan", store: store, body: ["plan": "unscheduled"])
            XCTAssertNil(store.data.tasks[0].plannedAt)
            assertHTTP(400) { _ = try route("POST", "/v1/tasks/\(task.id)/plan", store: store, body: ["plan": "week"]) }
        }
    }

    func testSubtaskCRUDReopenAndCompletionDateUseSharedLifecycle() async throws {
        try withStore { store in
            let task = WorkTask(title: "Parent", repeatRule: RepeatRule(every: 6, unit: .month))
            try store.saveTask(task)
            let first = try decode(Subtask.self, route("POST", "/v1/tasks/\(task.id)/subtasks", store: store, body: ["title": "First"]))
            let second = try decode(Subtask.self, route("POST", "/v1/tasks/\(task.id)/subtasks", store: store, body: ["title": "Second"]))
            let renamed = try decode(Subtask.self, route("PATCH", "/v1/tasks/\(task.id)/subtasks/\(first.id)", store: store, body: ["title": "Renamed"]))
            XCTAssertEqual(renamed.title, "Renamed")
            _ = try store.completeSubtask(taskID: task.id, subtaskID: first.id)
            _ = try route("PATCH", "/v1/tasks/\(task.id)/subtasks/\(first.id)/completion-date", store: store, body: ["completedAt": "2020-10-20T08:00:00+08:00"])
            XCTAssertEqual(store.data.tasks[0].subtasks[0].completedAt, ISO8601DateFormatter().date(from: "2020-10-20T00:00:00Z"))
            _ = try route("POST", "/v1/tasks/\(task.id)/subtasks/\(first.id)/reopen", store: store)
            XCTAssertNil(store.data.tasks[0].subtasks[0].completedAt)
            _ = try store.completeSubtask(taskID: task.id, subtaskID: first.id)
            let completion = try XCTUnwrap(store.completeSubtask(taskID: task.id, subtaskID: second.id))
            XCTAssertNotNil(completion.nextTask)
            XCTAssertEqual(store.data.tasks.count, 2)
            assertHTTP(409) { _ = try route("POST", "/v1/tasks/\(task.id)/subtasks/\(first.id)/reopen", store: store) }
            assertHTTP(409) { _ = try route("POST", "/v1/tasks/\(task.id)/subtasks", store: store, body: ["title": "Cannot add after completion"]) }
            assertHTTP(400) { _ = try route("PATCH", "/v1/tasks/\(task.id)/completion-date", store: store, body: ["completedAt": "9999-01-01T00:00:00Z"]) }
            _ = try route("PATCH", "/v1/tasks/\(task.id)/completion-date", store: store, body: ["completedAt": "2020-10-21T00:00:00Z"])
            _ = try route("POST", "/v1/tasks/\(task.id)/reopen", store: store)
            XCTAssertEqual(store.data.tasks.count, 1)
            XCTAssertNil(store.data.tasks[0].completedAt)
            XCTAssertNotNil(store.data.tasks[0].subtasks[0].completedAt, "Reopening restores the previous partial completion snapshot")
            XCTAssertNil(store.data.tasks[0].subtasks[1].completedAt)
            _ = try route("DELETE", "/v1/tasks/\(task.id)/subtasks/\(second.id)", store: store)
            XCTAssertEqual(store.data.tasks[0].subtasks.map(\.id), [first.id])
            XCTAssertNil(store.data.tasks[0].completedAt, "Deleting a subtask must not implicitly generate another occurrence")
        }
    }

    func testReopenFlushesNextOccurrenceBeforeCheckingWhetherItCanBeRemoved() async throws {
        try withStore { store in
            let task = WorkTask(title: "Recurring", repeatRule: RepeatRule(every: 1, unit: .day))
            try store.saveTask(task)
            let next = try XCTUnwrap(store.completeTask(id: task.id).nextTask)
            let bridge = TaskEditingBoundary.BoundaryView()
            bridge.onFlush = { request in
                guard request.taskID == next.id else { return }
                do { try store.updateTask(id: next.id) { $0.notes = "Uncommitted next occurrence edit" } }
                catch { request.failed = true }
            }
            bridge.setEnabled(true); defer { bridge.setEnabled(false) }
            XCTAssertThrowsError(try route("POST", "/v1/tasks/\(task.id)/reopen", store: store))
            XCTAssertEqual(store.data.tasks.count, 2)
            XCTAssertNotNil(store.data.tasks.first(where: { $0.id == task.id })?.completedAt)
            XCTAssertEqual(store.data.tasks.first(where: { $0.id == next.id })?.notes, "Uncommitted next occurrence edit")
        }
    }

    func testDeleteRestoreRoundTripRejectsInvalidOrDuplicateSnapshots() async throws {
        try withStore { store in
            let task = WorkTask(title: "Restore me", details: "Original detail", subtasks: [Subtask(title: "Step")])
            try store.saveTask(task)
            let original = store.data
            let deletion = try route("DELETE", "/v1/tasks/\(task.id)", store: store)
            XCTAssertTrue(store.data.tasks.isEmpty)
            let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: deletion.body) as? [String: Any])
            var invalid = snapshot
            var invalidTask = try XCTUnwrap(snapshot["task"] as? [String: Any])
            invalidTask["unknown"] = "Forbidden"
            invalid["task"] = invalidTask
            assertHTTP(400) { _ = try route("POST", "/v1/tasks/restore", store: store, body: ["snapshot": invalid]) }
            XCTAssertTrue(store.data.tasks.isEmpty)
            let restored = try decode(WorkTask.self, route("POST", "/v1/tasks/restore", store: store, body: ["snapshot": snapshot]))
            XCTAssertEqual(restored.id, task.id)
            XCTAssertEqual(restored.details, task.details)
            XCTAssertEqual(restored.subtasks.map(\.id), task.subtasks.map(\.id))
            XCTAssertThrowsError(try route("POST", "/v1/tasks/restore", store: store, body: ["snapshot": snapshot]))
            XCTAssertEqual(store.data.tasks.count, 1)
            XCTAssertEqual(store.data, original, "Deletion snapshots must preserve every timestamp exactly")
        }
    }

    func testDeleteRestoreCannotMakeEditedRecurringSuccessorLookUnmodified() throws {
        try withStore { store in
            let original = WorkTask(title: "Recurring", repeatRule: RepeatRule(every: 1, unit: .month))
            try store.saveTask(original)
            let result = try store.completeTask(id: original.id)
            let nextID = try XCTUnwrap(result.nextTask?.id)
            try store.updateTask(id: nextID) { $0.notes = "Work already started" }
            let before = store.data
            let response = try route("DELETE", "/v1/tasks/\(nextID)", store: store)
            let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            _ = try route("POST", "/v1/tasks/restore", store: store, body: ["snapshot": snapshot])
            XCTAssertEqual(store.data, before)
            XCTAssertThrowsError(try route("POST", "/v1/tasks/\(original.id)/reopen", store: store))
            XCTAssertEqual(store.data, before, "Reopening must never delete a restored successor that was edited")
        }
    }

    func testTaskQueriesRespectConfiguredWorkWeekAndExclusiveDateRanges() async throws {
        try withStore { store in
            let project = try store.addProject(name: "Grouped")
            let current = WorkPeriod.range(containing: Date(), firstWeekday: 5)
            let first = WorkTask(projectID: project.id, title: "Find me", notes: "certificate detail", dueAt: current.start, plannedAt: current.start, planGranularity: .week)
            let second = WorkTask(title: "Next", dueAt: current.end, plannedAt: current.end, planGranularity: .week)
            let third = WorkTask(title: "No schedule")
            for task in [first, second, third] { try store.saveTask(task) }
            XCTAssertEqual(try decode([WorkTask].self, route("GET", "/v1/tasks?status=open&plan=thisWeek", store: store)).map(\.id), [first.id])
            XCTAssertEqual(try decode([WorkTask].self, route("GET", "/v1/tasks?plan=nextWeek", store: store)).map(\.id), [second.id])
            XCTAssertEqual(try decode([WorkTask].self, route("GET", "/v1/tasks?plan=unscheduled", store: store)).map(\.id), [third.id])
            XCTAssertEqual(try decode([WorkTask].self, route("GET", "/v1/tasks?search=certificate&projectId=\(project.id)", store: store)).map(\.id), [first.id])
            var components = URLComponents()
            components.path = "/v1/tasks"
            let formatter = ISO8601DateFormatter()
            components.queryItems = [URLQueryItem(name: "dueFrom", value: formatter.string(from: current.start)), URLQueryItem(name: "dueBefore", value: formatter.string(from: current.end))]
            XCTAssertEqual(try decode([WorkTask].self, route("GET", components.string!, store: store)).map(\.id), [first.id])
            components.queryItems = [URLQueryItem(name: "plan", value: "week"), URLQueryItem(name: "week", value: formatter.string(from: current.end))]
            XCTAssertEqual(try decode([WorkTask].self, route("GET", components.string!, store: store)).map(\.id), [second.id])
            assertHTTP(400) { _ = try route("GET", "/v1/tasks?status=open&status=completed", store: store) }
            assertHTTP(400) { _ = try route("GET", "/v1/tasks?week=2020-01-01T00:00:00Z", store: store) }
            assertHTTP(400) { _ = try route("GET", "/v1/tasks?overduePlan=1", store: store) }
        }
    }
}
