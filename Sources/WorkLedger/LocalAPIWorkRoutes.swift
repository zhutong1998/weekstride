import Foundation
import WorkLedgerCore

@MainActor
enum LocalAPIWorkRoutes {
    private static let taskFields: Set<String> = ["title", "details", "notes", "projectID", "tagIDs", "isStarred", "plannedAt", "planGranularity", "dueAt", "reminderAt", "repeatRule"]

    static func respond(to request: LocalAPIRequest, store: WorkStore, firstWeekday: Int) throws -> LocalAPIResponse? {
        guard let components = URLComponents(string: request.head.target), components.scheme == nil, components.host == nil else {
            throw invalid("Invalid request target.")
        }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.count >= 3, path[0].isEmpty, path[1] == "v1", ["projects", "tags", "tasks"].contains(path[2]) else { return nil }
        if request.head.method == "GET", !request.body.isEmpty { throw invalid("GET requests do not accept a body.") }
        let query = try queryValues(components.queryItems ?? [])
        if path[2] == "tags" { return try tags(request, path: path, query: query, store: store) }
        if path[2] == "projects" {
            if path.count == 3 { return try projects(request, query: query, store: store) }
            if path.count == 4 {
                let id = try uuid(path[3], field: "project ID")
                guard query.isEmpty else { throw invalid("This endpoint does not accept query parameters.") }
                guard let project = store.data.projects.first(where: { $0.id == id }) else { throw missing("Project not found.") }
                switch request.head.method {
                case "GET": return try .json(project)
                case "PATCH":
                    let json = try LocalAPIJSON(request, allowed: ["name", "colorHex", "isArchived"])
                    guard !json.raw.isEmpty else { throw invalid("Provide at least one project field.") }
                    let name = try json.string("name", allowEmpty: false)
                    let color = try json.string("colorHex", allowEmpty: false)
                    let archived = try json.bool("isArchived")
                    try validateProject(name: name, color: color)
                    return try .json(store.updateProject(id: id, name: name, colorHex: color, isArchived: archived))
                case "DELETE":
                    _ = try LocalAPIJSON(request, allowed: [], allowEmpty: true)
                    try LocalAPIJSON.flushEdits()
                    let taskIDs = store.data.tasks.filter { $0.projectID == id }.map(\.id)
                    let removed = try store.deleteProject(id: id)
                    return try .json(ProjectDeletion(project: removed, unassignedTaskIDs: taskIDs))
                default: throw methodNotAllowed()
                }
            }
            return nil
        }
        if path.count == 3 {
            switch request.head.method {
            case "GET": return try .json(tasks(query: query, store: store, firstWeekday: firstWeekday))
            case "POST":
                guard query.isEmpty else { throw invalid("This endpoint does not accept query parameters.") }
                let json = try LocalAPIJSON(request, allowed: taskFields, required: ["title"])
                let candidate = try patched(WorkTask(title: ""), json: json, store: store)
                try store.saveTask(candidate)
                return try .json(task(candidate.id, in: store), status: 201)
            default: throw methodNotAllowed()
            }
        }
        if path.count == 4, path[3] == "restore" {
            guard request.head.method == "POST" else { throw methodNotAllowed() }
            guard query.isEmpty else { throw invalid("This endpoint does not accept query parameters.") }
            let json = try LocalAPIJSON(request, allowed: ["snapshot"], required: ["snapshot"])
            try validateSnapshotFields(json.raw["snapshot"])
            let snapshot: TaskDeletion
            do {
                let bytes = try JSONSerialization.data(withJSONObject: json.raw["snapshot"]!)
                snapshot = try JSONDecoder().decode(TaskDeletion.self, from: bytes)
            } catch { throw invalid("snapshot must be an unchanged native-date task deletion response.") }
            try store.validateRestoringDeletedTask(snapshot)
            try LocalAPIJSON.flushEdits()
            try store.restoreDeletedTask(snapshot)
            return try .json(task(snapshot.task.id, in: store), status: 201)
        }
        let taskID = try uuid(path[3], field: "task ID")
        if path.count == 4 {
            guard query.isEmpty else { throw invalid("This endpoint does not accept query parameters.") }
            let current = try task(taskID, in: store)
            switch request.head.method {
            case "GET": return try .json(current)
            case "PATCH":
                let json = try LocalAPIJSON(request, allowed: taskFields)
                guard !json.raw.isEmpty else { throw invalid("Provide at least one task field.") }
                _ = try patched(current, json: json, store: store)
                try LocalAPIJSON.flushEdits(taskID: taskID)
                let candidate = try patched(task(taskID, in: store), json: json, store: store)
                try store.saveTask(candidate)
                return try .json(task(taskID, in: store))
            case "DELETE":
                _ = try LocalAPIJSON(request, allowed: [], allowEmpty: true)
                try LocalAPIJSON.flushEdits(taskID: taskID)
                // Exact timestamps protect edited recurring successors when deletion is undone.
                return try .json(store.deleteTask(id: taskID), dateEncodingStrategy: .deferredToDate)
            default: throw methodNotAllowed()
            }
        }
        if path.count == 5, path[4] == "reopen" {
            guard query.isEmpty else { throw invalid("This endpoint does not accept query parameters.") }
            guard request.head.method == "POST" else { throw methodNotAllowed() }
            _ = try LocalAPIJSON(request, allowed: [], allowEmpty: true)
            let current = try task(taskID, in: store)
            if current.completedAt != nil {
                try store.validateUndoCompletion(id: taskID)
                try LocalAPIJSON.flushEdits(taskID: taskID)
                if let followingID = current.nextTaskID { try LocalAPIJSON.flushEdits(taskID: followingID) }
                try store.undoCompletion(id: taskID)
            }
            return try .json(task(taskID, in: store))
        }
        if path.count == 5, path[4] == "plan" {
            guard query.isEmpty else { throw invalid("This endpoint does not accept query parameters.") }
            guard request.head.method == "POST" else { throw methodNotAllowed() }
            let json = try LocalAPIJSON(request, allowed: ["plan", "date"], required: ["plan"])
            let plan = try json.string("plan", allowEmpty: false)!
            let date = try json.date("date")
            let reference = Date()
            let current = try task(taskID, in: store)
            _ = try planned(current, plan: plan, date: date, reference: reference, firstWeekday: firstWeekday, store: store)
            try LocalAPIJSON.flushEdits(taskID: taskID)
            let candidate = try planned(task(taskID, in: store), plan: plan, date: date, reference: reference, firstWeekday: firstWeekday, store: store)
            try store.saveTask(candidate)
            return try .json(task(taskID, in: store))
        }
        if path.count == 5, path[4] == "completion-date" {
            guard query.isEmpty else { throw invalid("This endpoint does not accept query parameters.") }
            guard request.head.method == "PATCH" else { throw methodNotAllowed() }
            let date = try completionDate(request)
            guard try task(taskID, in: store).completedAt != nil else { throw conflict("Complete the task before changing its completion date.") }
            try LocalAPIJSON.flushEdits(taskID: taskID)
            try store.setCompletionDate(taskID: taskID, at: date)
            return try .json(task(taskID, in: store))
        }
        if path.count >= 5, path[4] == "subtasks" {
            guard query.isEmpty else { throw invalid("This endpoint does not accept query parameters.") }
            return try subtasks(request, path: path, taskID: taskID, store: store)
        }
        return nil
    }

    private static func projects(_ request: LocalAPIRequest, query: [String: String], store: WorkStore) throws -> LocalAPIResponse {
        switch request.head.method {
        case "GET":
            guard Set(query.keys).isSubset(of: ["status"]) else { throw invalid("Unknown project query parameter.") }
            let status = query["status"] ?? "all"
            guard ["all", "active", "archived"].contains(status) else { throw invalid("status must be all, active, or archived.") }
            return try .json(store.data.projects.filter { status == "all" || $0.isArchived == (status == "archived") })
        case "POST":
            guard query.isEmpty else { throw invalid("This endpoint does not accept query parameters.") }
            let json = try LocalAPIJSON(request, allowed: ["name", "colorHex"], required: ["name"])
            let name = try json.string("name", allowEmpty: false)!
            let color = try json.string("colorHex", allowEmpty: false) ?? "3478F6"
            try validateProject(name: name, color: color)
            return try .json(store.addProject(name: name, colorHex: color), status: 201)
        default: throw methodNotAllowed()
        }
    }

    private static func tags(_ request: LocalAPIRequest, path: [String], query: [String: String], store: WorkStore) throws -> LocalAPIResponse? {
        guard path.count == 3 || path.count == 4 else { return nil }
        guard query.isEmpty else { throw invalid("Tag routes do not accept query parameters.") }
        if path.count == 3 {
            switch request.head.method {
            case "GET": return try .json(store.data.tags)
            case "POST":
                let json = try LocalAPIJSON(request, allowed: ["name", "colorHex"], required: ["name"])
                let name = try json.string("name", allowEmpty: false)!
                let color = try json.string("colorHex", allowEmpty: false) ?? "9462C4"
                try validateProject(name: name, color: color)
                return try .json(store.addTag(name: name, colorHex: color), status: 201)
            default: throw methodNotAllowed()
            }
        }
        let id = try uuid(path[3], field: "tag ID")
        guard let tag = store.data.tags.first(where: { $0.id == id }) else { throw missing("Tag not found.") }
        switch request.head.method {
        case "GET": return try .json(tag)
        case "PATCH":
            let json = try LocalAPIJSON(request, allowed: ["name", "colorHex"])
            guard !json.raw.isEmpty else { throw invalid("Provide at least one tag field.") }
            let name = try json.string("name", allowEmpty: false)
            let color = try json.string("colorHex", allowEmpty: false)
            try validateProject(name: name, color: color)
            return try .json(store.updateTag(id: id, name: name, colorHex: color))
        case "DELETE":
            _ = try LocalAPIJSON(request, allowed: [], allowEmpty: true)
            try LocalAPIJSON.flushEdits()
            let taskIDs = store.data.tasks.filter { $0.tagIDs.contains(id) }.map(\.id)
            return try .json(TagDeletion(tag: store.deleteTag(id: id), untaggedTaskIDs: taskIDs))
        default: throw methodNotAllowed()
        }
    }

    private static func tasks(query: [String: String], store: WorkStore, firstWeekday: Int) throws -> [WorkTask] {
        let allowed: Set<String> = ["status", "projectId", "tagId", "starred", "search", "plan", "week", "overduePlan", "urgent", "dueFrom", "dueBefore", "reminderFrom", "reminderBefore", "completedFrom", "completedBefore"]
        guard Set(query.keys).isSubset(of: allowed) else { throw invalid("Unknown task query parameter.") }
        var result = store.data.tasks
        if let status = query["status"] {
            guard ["all", "open", "completed"].contains(status) else { throw invalid("status must be all, open, or completed.") }
            if status != "all" { result = result.filter { ($0.completedAt != nil) == (status == "completed") } }
        }
        if let project = query["projectId"] {
            let id = project == "none" ? nil : try uuid(project, field: "projectId")
            result = result.filter { $0.projectID == id }
        }
        if let value = query["tagId"] {
            let id = try uuid(value, field: "tagId")
            guard store.data.tags.contains(where: { $0.id == id }) else { throw missing("Tag not found.") }
            result = result.filter { $0.tagIDs.contains(id) }
        }
        if let value = query["starred"] {
            guard ["true", "false"].contains(value) else { throw invalid("starred must be true or false.") }
            result = result.filter { $0.isStarred == (value == "true") }
        }
        if let search = query["search"], !search.isEmpty {
            let tagNames = Dictionary(uniqueKeysWithValues: store.data.tags.map { ($0.id, $0.name) })
            result = result.filter { task in
                let text = [task.title, task.details, task.notes] + task.subtasks.map(\.title) + task.attachments.map(\.name)
                    + task.tagIDs.compactMap { tagNames[$0] }
                return text.contains { $0.localizedCaseInsensitiveContains(search) }
            }
        }
        for key in ["overduePlan", "urgent"] {
            if let value = query[key] {
                guard ["true", "false"].contains(value) else { throw invalid("\(key) must be true or false.") }
                let now = Date()
                result = result.filter { task in
                    let matches: Bool
                    if key == "overduePlan" { matches = task.isPlanOverdue(relativeTo: now, firstWeekday: firstWeekday) }
                    else { matches = task.completedAt == nil && [task.dueAt, task.reminderAt].compactMap { $0 }.contains { $0 <= now } }
                    return matches == (value == "true")
                }
            }
        }
        if let plan = query["plan"] {
            let filter: TaskPlanFilter
            switch plan {
            case "thisWeek": filter = .thisWeek
            case "nextWeek": filter = .nextWeek
            case "unscheduled": filter = .unscheduled
            case "week":
                guard let value = query["week"] else { throw invalid("plan=week requires week as an ISO 8601 date-time.") }
                filter = .week(try LocalAPIJSON.date(value, field: "week"))
            default: throw invalid("plan must be thisWeek, nextWeek, week, or unscheduled.")
            }
            if query["week"] != nil, plan != "week" { throw invalid("week is only valid with plan=week.") }
            result = result.filter(filter.predicate(firstWeekday: firstWeekday))
        } else if query["week"] != nil { throw invalid("week requires plan=week.") }
        for (prefix, keyPath) in [("due", \WorkTask.dueAt), ("reminder", \WorkTask.reminderAt), ("completed", \WorkTask.completedAt)] {
            let from = try query[prefix + "From"].map { try LocalAPIJSON.date($0, field: prefix + "From") }
            let before = try query[prefix + "Before"].map { try LocalAPIJSON.date($0, field: prefix + "Before") }
            if let from, let before, from >= before { throw invalid("\(prefix)From must precede \(prefix)Before.") }
            if from != nil || before != nil {
                result = result.filter { task in
                    guard let date = task[keyPath: keyPath] else { return false }
                    return (from.map { date >= $0 } ?? true) && (before.map { date < $0 } ?? true)
                }
            }
        }
        return result
    }

    private static func patched(_ original: WorkTask, json: LocalAPIJSON, store: WorkStore) throws -> WorkTask {
        var candidate = original
        if let title = try json.string("title", allowEmpty: false) { candidate.title = title }
        if let details = try json.string("details") { candidate.details = details }
        if let notes = try json.string("notes") { candidate.notes = notes }
        if json.contains("tagIDs") {
            guard let ids = try json.decode("tagIDs", as: [UUID].self), Set(ids).count == ids.count else {
                throw invalid("tagIDs must be an array of unique tag UUIDs; use [] to remove all tags.")
            }
            let known = Set(store.data.tags.map(\.id))
            guard ids.allSatisfy(known.contains) else { throw missing("Target tag not found.") }
            candidate.tagIDs = ids
        }
        if let starred = try json.bool("isStarred") { candidate.isStarred = starred }
        if json.contains("projectID") {
            candidate.projectID = try json.uuid("projectID")
            if let id = candidate.projectID {
                guard let project = store.data.projects.first(where: { $0.id == id }) else { throw missing("Target project not found.") }
                guard !project.isArchived else { throw conflict("Restore the target project before moving tasks into it.") }
            }
        }
        if json.contains("plannedAt") {
            candidate.plannedAt = try json.date("plannedAt")
            if candidate.plannedAt == nil { candidate.planGranularity = nil }
            else if candidate.planGranularity == nil { candidate.planGranularity = .day }
        }
        if json.contains("planGranularity") {
            candidate.planGranularity = try json.decode("planGranularity", as: TaskPlanGranularity.self)
        }
        if json.contains("dueAt") {
            candidate.dueAt = try json.date("dueAt")
            if candidate.dueAt == nil {
                candidate.scheduleAnchor = nil
                if candidate.repeatRule?.basis == .schedule { candidate.repeatRule?.basis = .completion }
            }
        }
        if json.contains("reminderAt") { candidate.reminderAt = try json.date("reminderAt") }
        if json.contains("repeatRule") {
            try validateRepeatFields(json.raw["repeatRule"])
            let rule = try json.decode("repeatRule", as: RepeatRule.self)
            if candidate.repeatRule != rule { candidate.scheduleAnchor = nil }
            candidate.repeatRule = rule
        }
        try store.validateTask(candidate)
        return candidate
    }

    private static func subtasks(_ request: LocalAPIRequest, path: [String], taskID: UUID, store: WorkStore) throws -> LocalAPIResponse? {
        let current = try task(taskID, in: store)
        if path.count == 5 {
            switch request.head.method {
            case "GET": return try .json(current.subtasks)
            case "POST":
                let json = try LocalAPIJSON(request, allowed: ["title"], required: ["title"])
                let title = try json.string("title", allowEmpty: false)!
                guard current.completedAt == nil else { throw conflict("Reopen the parent task before adding subtasks.") }
                let child = Subtask(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
                var candidate = current; candidate.subtasks.append(child)
                try store.validateTask(candidate)
                try LocalAPIJSON.flushEdits(taskID: taskID)
                guard try task(taskID, in: store).completedAt == nil else { throw conflict("Reopen the parent task before adding subtasks.") }
                try store.updateTask(id: taskID) { $0.subtasks.append(child) }
                return try .json(child, status: 201)
            default: throw methodNotAllowed()
            }
        }
        guard path.count >= 6 else { return nil }
        let childID = try uuid(path[5], field: "subtask ID")
        guard let child = current.subtasks.first(where: { $0.id == childID }) else { throw missing("Subtask not found.") }
        if path.count == 6 {
            switch request.head.method {
            case "GET": return try .json(child)
            case "PATCH":
                let json = try LocalAPIJSON(request, allowed: ["title"], required: ["title"])
                let title = try json.string("title", allowEmpty: false)!.trimmingCharacters(in: .whitespacesAndNewlines)
                var candidate = current
                candidate.subtasks[candidate.subtasks.firstIndex(where: { $0.id == childID })!].title = title
                try store.validateTask(candidate)
                try LocalAPIJSON.flushEdits(taskID: taskID)
                guard let index = try task(taskID, in: store).subtasks.firstIndex(where: { $0.id == childID }) else { throw missing("Subtask not found.") }
                try store.updateTask(id: taskID) { $0.subtasks[index].title = title }
                return try .json(task(taskID, in: store).subtasks[index])
            case "DELETE":
                _ = try LocalAPIJSON(request, allowed: [], allowEmpty: true)
                try LocalAPIJSON.flushEdits(taskID: taskID)
                guard let latest = try task(taskID, in: store).subtasks.first(where: { $0.id == childID }) else { throw missing("Subtask not found.") }
                try store.updateTask(id: taskID) { $0.subtasks.removeAll { $0.id == childID } }
                return try .json(latest)
            default: throw methodNotAllowed()
            }
        }
        if path.count == 7, path[6] == "reopen" {
            guard request.head.method == "POST" else { throw methodNotAllowed() }
            _ = try LocalAPIJSON(request, allowed: [], allowEmpty: true)
            guard current.completedAt == nil else { throw conflict("Reopen the parent task before reopening its subtasks.") }
            if child.completedAt != nil {
                try LocalAPIJSON.flushEdits(taskID: taskID)
                try store.undoSubtaskCompletion(taskID: taskID, subtaskID: childID)
            }
            return try .json(task(taskID, in: store))
        }
        if path.count == 7, path[6] == "completion-date" {
            guard request.head.method == "PATCH" else { throw methodNotAllowed() }
            let date = try completionDate(request)
            guard child.completedAt != nil else { throw conflict("Complete the subtask before changing its completion date.") }
            try LocalAPIJSON.flushEdits(taskID: taskID)
            try store.setSubtaskCompletionDate(taskID: taskID, subtaskID: childID, at: date)
            return try .json(task(taskID, in: store))
        }
        return nil
    }

    private static func planned(_ task: WorkTask, plan: String, date: Date?, reference: Date, firstWeekday: Int, store: WorkStore) throws -> WorkTask {
        guard task.completedAt == nil else { throw conflict("Reopen a completed task before changing its plan.") }
        let candidate: WorkTask
        if ["day", "week"].contains(plan) {
            guard let date else { throw invalid("day and week planning require date as an ISO 8601 date-time.") }
            if plan == "week" { candidate = try TaskPlanDrop.applying(.week(date), to: task, relativeTo: reference, firstWeekday: firstWeekday) }
            else {
                var updated = task
                updated.plannedAt = Calendar.current.startOfDay(for: date)
                updated.planGranularity = .day
                candidate = updated
            }
        } else {
            guard date == nil else { throw invalid("date is only accepted for day or week planning.") }
            switch plan {
            case "thisWeek": candidate = try TaskPlanDrop.applying(.thisWeek, to: task, relativeTo: reference, firstWeekday: firstWeekday)
            case "nextWeek": candidate = try TaskPlanDrop.applying(.nextWeek, to: task, relativeTo: reference, firstWeekday: firstWeekday)
            case "weekAfterNext":
                var updated = task
                updated.plannedAt = TaskPlanning.weekDate(offset: 2, relativeTo: reference, firstWeekday: firstWeekday)
                updated.planGranularity = .week
                candidate = updated
            case "unscheduled": candidate = try TaskPlanDrop.applying(.unscheduled, to: task, relativeTo: reference, firstWeekday: firstWeekday)
            default: throw invalid("plan must be thisWeek, nextWeek, weekAfterNext, week, day, or unscheduled.")
            }
        }
        try store.validateTask(candidate)
        return candidate
    }

    private static func completionDate(_ request: LocalAPIRequest) throws -> Date {
        let json = try LocalAPIJSON(request, allowed: ["completedAt"], required: ["completedAt"])
        guard let text = try json.string("completedAt", allowEmpty: false) else { throw invalid("completedAt is required.") }
        return try LocalAPIJSON.date(text, field: "completedAt", allowFuture: false)
    }

    private static func validateProject(name: String?, color: String?) throws {
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw invalid("Project name cannot be empty.") }
        if let color {
            let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
            guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw invalid("colorHex requires six hexadecimal digits, optionally prefixed with #.") }
        }
    }

    private static func validateRepeatFields(_ value: Any?) throws {
        guard let value, !(value is NSNull) else { return }
        let fields: Set<String> = ["every", "unit", "basis"]
        guard let object = value as? [String: Any], Set(object.keys) == fields else { throw invalid("repeatRule requires exactly every, unit, and basis.") }
        // Decode through the shared strict helper to reject boolean/float intervals and invalid enum values.
        let data = try JSONSerialization.data(withJSONObject: object)
        let head = LocalAPIRequestHead(method: "POST", target: "/", headers: ["content-type": "application/json"], bodyLength: data.count, headerLength: 0)
        let json = try LocalAPIJSON(LocalAPIRequest(head: head, body: data), allowed: fields, required: fields)
        guard let every = try json.int("every"), (1...10000).contains(every) else { throw invalid("repeatRule.every must be an integer from 1 to 10000.") }
        guard let unit = try json.string("unit"), RepeatUnit(rawValue: unit) != nil,
              let basis = try json.string("basis"), RepeatBasis(rawValue: basis) != nil else { throw invalid("Invalid repeatRule unit or basis.") }
    }

    private static func validateSnapshotFields(_ value: Any?) throws {
        guard let snapshot = value as? [String: Any], Set(snapshot.keys) == ["task", "predecessorIDs"], let task = snapshot["task"] as? [String: Any] else {
            throw invalid("snapshot must contain a task and predecessorIDs from a task deletion response.")
        }
        let fields: Set<String> = ["id", "projectID", "tagIDs", "isStarred", "title", "details", "notes", "subtasks", "attachments", "dueAt", "reminderAt", "repeatRule", "completedAt", "completionSource", "createdAt", "updatedAt", "seriesID", "nextTaskID", "completionSubtaskSnapshot", "scheduleAnchor", "plannedAt", "planGranularity"]
        guard Set(task.keys).isSubset(of: fields) else { throw invalid("Unknown task snapshot fields.") }
        try validateRepeatFields(task["repeatRule"])
        for name in ["subtasks", "completionSubtaskSnapshot"] {
            if let value = task[name], !(value is NSNull) {
                guard let children = value as? [[String: Any]], children.allSatisfy({ Set($0.keys).isSubset(of: ["id", "title", "completedAt"]) }) else { throw invalid("Invalid subtask snapshot fields.") }
            }
        }
        if let value = task["attachments"] {
            guard let attachments = value as? [[String: Any]], attachments.allSatisfy({ Set($0.keys) == ["id", "name", "storedName", "size"] }) else { throw invalid("Invalid attachment snapshot fields.") }
        }
        if let value = task["scheduleAnchor"], !(value is NSNull) {
            guard let anchor = value as? [String: Any], Set(anchor.keys) == ["date", "occurrence", "rule"] else { throw invalid("Invalid scheduleAnchor snapshot fields.") }
            try validateRepeatFields(anchor["rule"])
        }
    }

    private static func queryValues(_ items: [URLQueryItem]) throws -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            guard result[item.name] == nil, let value = item.value else { throw invalid("Query parameters require a value and cannot be repeated.") }
            result[item.name] = value
        }
        return result
    }

    private static func task(_ id: UUID, in store: WorkStore) throws -> WorkTask {
        guard let task = store.data.tasks.first(where: { $0.id == id }) else { throw missing("Task not found.") }
        return task
    }

    private static func uuid(_ value: String, field: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw invalid("\(field) must be a UUID.") }
        return id
    }

    private static func invalid(_ message: String) -> LocalAPIHTTPError { LocalAPIHTTPError(status: 400, message: message) }
    private static func missing(_ message: String) -> LocalAPIHTTPError { LocalAPIHTTPError(status: 404, message: message) }
    private static func conflict(_ message: String) -> LocalAPIHTTPError { LocalAPIHTTPError(status: 409, message: message) }
    private static func methodNotAllowed() -> LocalAPIHTTPError { LocalAPIHTTPError(status: 405, message: "Method not allowed for this endpoint.") }

    private struct ProjectDeletion: Encodable {
        let project: Project
        let unassignedTaskIDs: [UUID]
    }

    private struct TagDeletion: Encodable {
        let tag: TaskTag
        let untaggedTaskIDs: [UUID]
    }
}
