import Foundation
import WorkLedgerCore

enum TaskListPolicy {
    static func isTimeSensitive(_ scope: SidebarItem) -> Bool {
        switch scope {
        case .upcoming, .overdue, .reminders: return true
        default: return false
        }
    }

    static func tasks(in scope: SidebarItem, data: LedgerData, relativeTo now: Date, firstWeekday: Int,
                      calendar: Calendar = .current, historyInterval: DateInterval? = nil) -> [WorkTask] {
        let activeProjects = Set(data.projects.filter { !$0.isArchived }.map(\.id))
        let today = calendar.startOfDay(for: now)
        let soon = calendar.date(byAdding: .day, value: 8, to: today)!
        let thisWeek = TaskPlanFilter.thisWeek.predicate(relativeTo: now, firstWeekday: firstWeekday, calendar: calendar)
        return data.tasks.filter { task in
            if scope == .completed { return task.matchesCompletedHistory(in: historyInterval) }
            if case .project(let id) = scope { return task.projectID == id && task.completedAt == nil }
            guard task.completedAt == nil, task.projectID.map(activeProjects.contains) != false else { return false }
            switch scope {
            case .all: return true
            case .thisWeek: return thisWeek(task)
            case .upcoming: return task.dueAt.map { $0 >= today && $0 < soon } == true
            case .overdue: return task.dueAt.map { $0 < today } == true
            case .reminders: return task.reminderAt.map { $0 <= now } == true
            case .completed, .project: return false
            }
        }
    }

    static func visibleTasks(_ tasks: [WorkTask], projects: [Project], scope: SidebarItem, filter: TaskPlanFilter,
                             search: String, relativeTo today: Date, firstWeekday: Int, calendar: Calendar = .current) -> [WorkTask] {
        let includes = filter.predicate(relativeTo: today, firstWeekday: firstWeekday, calendar: calendar)
        return tasks.filter { task in
            TaskListStructure.matches(task, projects: projects, search: search)
                && (scope == .completed || isTimeSensitive(scope) || includes(task))
        }.sorted {
            if ($0.completedAt == nil) != ($1.completedAt == nil) { return $0.completedAt == nil }
            if scope == .completed || ($0.completedAt != nil && $1.completedAt != nil) {
                let firstDate = $0.completedAt ?? $0.updatedAt, secondDate = $1.completedAt ?? $1.updatedAt
                return firstDate == secondDate ? $0.id.uuidString > $1.id.uuidString : firstDate > secondDate
            }
            if isTimeSensitive(scope) {
                let firstDate = scope == .reminders ? $0.reminderAt : $0.dueAt
                let secondDate = scope == .reminders ? $1.reminderAt : $1.dueAt
                if firstDate != secondDate { return (firstDate ?? .distantFuture) < (secondDate ?? .distantFuture) }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            return ($0.plannedAt ?? .distantFuture, $0.dueAt ?? .distantFuture, $0.createdAt)
                < ($1.plannedAt ?? .distantFuture, $1.dueAt ?? .distantFuture, $1.createdAt)
        }
    }

    static func completedTasks(in scope: SidebarItem, data: LedgerData, relativeTo today: Date,
                               firstWeekday: Int, calendar: Calendar = .current) -> [WorkTask] {
        let activeProjects = Set(data.projects.filter { !$0.isArchived }.map(\.id))
        let thisWeek = TaskPlanFilter.thisWeek.predicate(relativeTo: today, firstWeekday: firstWeekday, calendar: calendar)
        return data.tasks.filter { task in
            guard task.completedAt != nil else { return false }
            if case .project(let id) = scope { return task.projectID == id }
            guard task.projectID.map(activeProjects.contains) != false else { return false }
            switch scope {
            case .all: return true
            case .thisWeek: return thisWeek(task)
            default: return false
            }
        }
    }

    static func shouldFollowCreatedTask(_ id: UUID, currentDraftID: UUID?, reveal: TaskReveal?,
                                        origin: TaskViewContext, current: TaskViewContext) -> Bool {
        currentDraftID == nil && reveal?.taskID == id && current == origin
    }
}
