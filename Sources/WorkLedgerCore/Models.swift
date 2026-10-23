import Foundation

public struct Project: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var isArchived: Bool

    public init(id: UUID = UUID(), name: String, colorHex: String = "3478F6", isArchived: Bool = false) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.isArchived = isArchived
    }
}

public struct Subtask: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var completedAt: Date?

    public init(id: UUID = UUID(), title: String, completedAt: Date? = nil) {
        self.id = id; self.title = title; self.completedAt = completedAt
    }
}

public struct Attachment: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var storedName: String
    public var size: Int64

    public init(id: UUID = UUID(), name: String, storedName: String, size: Int64) {
        self.id = id; self.name = name; self.storedName = storedName; self.size = size
    }
}

public enum RepeatUnit: String, Codable, CaseIterable {
    case day, week, month, year

    public var calendarComponent: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}

public enum RepeatBasis: String, Codable, CaseIterable {
    case completion, schedule
}

public struct RepeatRule: Codable, Equatable {
    public var every: Int
    public var unit: RepeatUnit
    public var basis: RepeatBasis

    public init(every: Int = 1, unit: RepeatUnit = .month, basis: RepeatBasis = .completion) {
        self.every = every; self.unit = unit; self.basis = basis
    }
}

public struct ScheduleAnchor: Codable, Equatable {
    public var date: Date
    public var occurrence: Int
    public var rule: RepeatRule

    public init(date: Date, occurrence: Int, rule: RepeatRule) {
        self.date = date; self.occurrence = occurrence; self.rule = rule
    }
}

public enum TaskPlanGranularity: String, Codable, CaseIterable {
    case day, week
}

public enum TaskPlanBucket: String, CaseIterable, Identifiable {
    case thisWeek, nextWeek, weekAfterNext, later, unscheduled

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thisWeek: return "本周"
        case .nextWeek: return "下周"
        case .weekAfterNext: return "下下周"
        case .later: return "后续"
        case .unscheduled: return "未安排"
        }
    }
}

public enum TaskPlanFilter: Codable, Hashable, Identifiable {
    case all, thisWeek, nextWeek, week(Date), unscheduled

    public var id: Self { self }

    public init(task: WorkTask, relativeTo date: Date = Date(), firstWeekday: Int, calendar: Calendar = .current) {
        if let completedAt = task.completedAt {
            let week = WorkPeriod.range(containing: completedAt, firstWeekday: firstWeekday, calendar: calendar)
            let current = WorkPeriod.range(containing: date, firstWeekday: firstWeekday, calendar: calendar)
            if week.start == current.start { self = .thisWeek }
            else if week.start == current.end { self = .nextWeek }
            else { self = .week(week.start) }
            return
        }
        guard let plannedAt = task.plannedAt else { self = .unscheduled; return }
        switch task.planBucket(relativeTo: date, firstWeekday: firstWeekday, calendar: calendar) {
        case .thisWeek: self = .thisWeek
        case .nextWeek: self = .nextWeek
        case .weekAfterNext, .later:
            self = .week(WorkPeriod.range(containing: plannedAt, firstWeekday: firstWeekday, calendar: calendar).start)
        case .unscheduled: self = .unscheduled
        }
    }

    public func includes(_ task: WorkTask, relativeTo date: Date = Date(), firstWeekday: Int, calendar: Calendar = .current) -> Bool {
        predicate(relativeTo: date, firstWeekday: firstWeekday, calendar: calendar)(task)
    }

    public func predicate(relativeTo date: Date = Date(), firstWeekday: Int, calendar: Calendar = .current) -> (WorkTask) -> Bool {
        switch self {
        case .all: return { _ in true }
        case .thisWeek:
            let current = WorkPeriod.range(containing: date, firstWeekday: firstWeekday, calendar: calendar)
            return { task in
                if let completed = task.completedAt { return WorkPeriod.contains(completed, in: current) }
                return task.plannedAt.map { $0 < current.end } ?? false
            }
        case .nextWeek:
            let start = WorkPeriod.range(containing: date, firstWeekday: firstWeekday, calendar: calendar).end
            let interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 7, to: start)!)
            return { task in (task.completedAt ?? task.plannedAt).map { WorkPeriod.contains($0, in: interval) } ?? false }
        case .week(let anchor):
            let interval = WorkPeriod.range(containing: anchor, firstWeekday: firstWeekday, calendar: calendar)
            return { task in (task.completedAt ?? task.plannedAt).map { WorkPeriod.contains($0, in: interval) } ?? false }
        case .unscheduled: return { $0.completedAt == nil && $0.plannedAt == nil }
        }
    }

    public static func grouped(for tasks: [WorkTask], relativeTo date: Date = Date(), firstWeekday: Int,
                               calendar: Calendar = .current) -> [(filter: Self, tasks: [WorkTask])] {
        let thisWeek = Self.thisWeek.predicate(relativeTo: date, firstWeekday: firstWeekday, calendar: calendar)
        let nextWeek = Self.nextWeek.predicate(relativeTo: date, firstWeekday: firstWeekday, calendar: calendar)
        var weekForDate: [Date: Self] = [:]
        let groups = Dictionary(grouping: tasks) { task -> Self in
            if thisWeek(task) { return .thisWeek }
            if nextWeek(task) { return .nextWeek }
            guard let date = task.completedAt ?? task.plannedAt else { return .unscheduled }
            if let filter = weekForDate[date] { return filter }
            let filter = Self.week(WorkPeriod.range(containing: date, firstWeekday: firstWeekday, calendar: calendar).start)
            weekForDate[date] = filter
            return filter
        }
        let weeks = groups.keys.compactMap { filter -> Date? in
            if case .week(let start) = filter { return start }
            return nil
        }.sorted().map(Self.week)
        return ([.thisWeek, .nextWeek] + weeks + [.unscheduled]).compactMap { filter in
            groups[filter].map { (filter, $0) }
        }
    }

    public static func options(for tasks: [WorkTask], relativeTo date: Date = Date(), firstWeekday: Int, calendar: Calendar = .current, including selected: Self? = nil) -> [Self] {
        var weeks = Set(grouped(for: tasks, relativeTo: date, firstWeekday: firstWeekday, calendar: calendar).compactMap { group -> Date? in
            if case .week(let start) = group.filter { return start }
            return nil
        })
        if let selected, case .week(let anchor) = selected {
            weeks.insert(WorkPeriod.range(containing: anchor, firstWeekday: firstWeekday, calendar: calendar).start)
        }
        return [.all, .thisWeek, .nextWeek] + weeks.sorted().map(Self.week) + [.unscheduled]
    }
}

public struct WorkTask: Codable, Identifiable, Equatable {
    public var id: UUID
    public var projectID: UUID?
    public var title: String
    public var details: String
    public var notes: String
    public var subtasks: [Subtask]
    public var attachments: [Attachment]
    public var dueAt: Date?
    public var reminderAt: Date?
    public var repeatRule: RepeatRule?
    public var completedAt: Date?
    public var completionSource: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var seriesID: UUID?
    public var nextTaskID: UUID?
    public var completionSubtaskSnapshot: [Subtask]?
    public var scheduleAnchor: ScheduleAnchor?
    public var plannedAt: Date?
    public var planGranularity: TaskPlanGranularity?

    public init(id: UUID = UUID(), projectID: UUID? = nil, title: String, details: String = "", notes: String = "", subtasks: [Subtask] = [], attachments: [Attachment] = [], dueAt: Date? = nil, reminderAt: Date? = nil, repeatRule: RepeatRule? = nil, completedAt: Date? = nil, completionSource: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), seriesID: UUID? = nil, nextTaskID: UUID? = nil, completionSubtaskSnapshot: [Subtask]? = nil, scheduleAnchor: ScheduleAnchor? = nil, plannedAt: Date? = nil, planGranularity: TaskPlanGranularity? = nil) {
        self.id = id; self.projectID = projectID; self.title = title; self.details = details; self.notes = notes
        self.subtasks = subtasks; self.attachments = attachments; self.dueAt = dueAt; self.reminderAt = reminderAt
        self.repeatRule = repeatRule; self.completedAt = completedAt; self.completionSource = completionSource
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.seriesID = seriesID; self.nextTaskID = nextTaskID
        self.completionSubtaskSnapshot = completionSubtaskSnapshot
        self.scheduleAnchor = scheduleAnchor
        self.plannedAt = plannedAt; self.planGranularity = planGranularity
    }

    public func matchesCompletedHistory(in interval: DateInterval? = nil) -> Bool {
        guard let completedAt else { return false }
        return interval.map { WorkPeriod.contains(completedAt, in: $0) } ?? true
    }

    public func planBucket(relativeTo date: Date = Date(), firstWeekday: Int, calendar: Calendar = .current) -> TaskPlanBucket {
        guard let plannedAt else { return .unscheduled }
        let current = WorkPeriod.range(containing: date, firstWeekday: firstWeekday, calendar: calendar)
        if plannedAt < current.end { return .thisWeek }
        let nextEnd = calendar.date(byAdding: .day, value: 7, to: current.end)!
        if plannedAt < nextEnd { return .nextWeek }
        let followingEnd = calendar.date(byAdding: .day, value: 14, to: current.end)!
        return plannedAt < followingEnd ? .weekAfterNext : .later
    }

    public func isPlanOverdue(relativeTo date: Date = Date(), firstWeekday: Int, calendar: Calendar = .current) -> Bool {
        guard completedAt == nil, let plannedAt else { return false }
        let today = calendar.startOfDay(for: date)
        if planGranularity == .week {
            return WorkPeriod.range(containing: plannedAt, firstWeekday: firstWeekday, calendar: calendar).end <= today
        }
        return calendar.startOfDay(for: plannedAt) < today
    }
}

public enum TaskPlanning {
    public static func weekDate(offset: Int, relativeTo date: Date = Date(), firstWeekday: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: offset * 7, to: calendar.startOfDay(for: date))!
    }
}

public struct TaskDeletion: Codable, Equatable {
    public var task: WorkTask
    public var predecessorIDs: [UUID]

    public init(task: WorkTask, predecessorIDs: [UUID] = []) {
        self.task = task; self.predecessorIDs = predecessorIDs
    }
}

public struct LedgerData: Codable, Equatable {
    public var schemaVersion: Int
    public var projects: [Project]
    public var tasks: [WorkTask]

    public init(schemaVersion: Int = 1, projects: [Project] = [], tasks: [WorkTask] = []) {
        self.schemaVersion = schemaVersion; self.projects = projects; self.tasks = tasks
    }
}

public struct CompletionResult: Codable {
    public var task: WorkTask
    public var nextTask: WorkTask?
    public var alreadyCompleted: Bool

    public init(task: WorkTask, nextTask: WorkTask?, alreadyCompleted: Bool) {
        self.task = task; self.nextTask = nextTask; self.alreadyCompleted = alreadyCompleted
    }
}

public enum LedgerError: LocalizedError {
    case invalid(String)
    case notFound(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .notFound(let message), .conflict(let message): return message
        }
    }
}

public enum WorkPeriod {
    public static func range(containing date: Date, firstWeekday: Int, calendar: Calendar = .current) -> DateInterval {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: date)
        let safeFirst = (1...7).contains(firstWeekday) ? firstWeekday : 2
        let daysBack = (weekday - safeFirst + 7) % 7
        let start = calendar.date(byAdding: .day, value: -daysBack, to: startOfDay)!
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 7, to: start)!)
    }

    public static func contains(_ date: Date, in interval: DateInterval) -> Bool {
        date >= interval.start && date < interval.end
    }
}
