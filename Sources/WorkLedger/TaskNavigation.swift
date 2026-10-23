import Foundation
import WorkLedgerCore

enum SidebarItem: Hashable {
    case all, thisWeek, upcoming, overdue, reminders, completed, project(UUID)

    var planFilterPreferenceKey: String {
        switch self {
        case .all: return "all"
        case .thisWeek: return "thisWeek"
        case .upcoming: return "upcoming"
        case .overdue: return "overdue"
        case .reminders: return "reminders"
        case .completed: return "completed"
        case .project(let id): return "project.\(id.uuidString)"
        }
    }
}

enum HistoryRange: String, CaseIterable {
    case week = "工作周期", custom = "自选日期", all = "全部历史"
}

struct TaskHistoryContext: Equatable {
    var range: HistoryRange
    var weekAnchor: Date
    var customStart: Date
    var customEnd: Date
}

struct TaskViewContext: Equatable {
    var scope: SidebarItem
    var filter: TaskPlanFilter
    var search: String
    var history: TaskHistoryContext? = nil
}

struct TaskListPageID: Hashable {
    let scope: SidebarItem
    let filter: TaskPlanFilter
}

enum TaskListEffect: String, CaseIterable, Identifiable {
    case slide, slideFade, scaleFade, none

    static let duration: TimeInterval = 0.18

    var id: Self { self }

    var title: String {
        switch self {
        case .none: return L("关闭")
        case .slide: return L("整页滑动")
        case .slideFade: return L("滑动淡入淡出")
        case .scaleFade: return L("缩放淡入淡出")
        }
    }

    var summary: String {
        switch self {
        case .none: return L("立即切换，不播放列表动画。")
        case .slide: return L("旧列表完整滑出，新列表滑入。")
        case .slideFade: return L("列表轻滑，同时淡出和淡入。")
        case .scaleFade: return L("轻微缩放，同时淡出和淡入。")
        }
    }

    func presentation(at progress: CGFloat, slide: TaskListSlide?, viewport: CGSize) -> (offset: CGSize, scale: CGFloat, opacity: Double) {
        if self == .none { return (.zero, 1, 1) }
        let distance = slide?.offset(in: self == .slide ? viewport : CGSize(width: 64, height: 40)) ?? .zero
        return (self == .scaleFade ? .zero : CGSize(width: distance.width * progress, height: distance.height * progress),
                self == .scaleFade ? 1 - 0.08 * abs(progress) : 1,
                self == .slide ? 1 : 1 - Double(abs(progress)))
    }
}

enum TaskListSlide: Equatable {
    case vertical(forward: Bool)
    case horizontal(forward: Bool)

    func offset(in viewport: CGSize) -> CGSize {
        switch self {
        case .vertical(let forward): return CGSize(width: 0, height: forward ? viewport.height : -viewport.height)
        case .horizontal(let forward): return CGSize(width: forward ? viewport.width : -viewport.width, height: 0)
        }
    }

    static func between(_ before: TaskViewContext, _ after: TaskViewContext, projectIDs: [UUID]) -> Self? {
        if before.scope != after.scope {
            let scopes: [SidebarItem] = [.all, .thisWeek, .upcoming, .overdue, .reminders, .completed]
                + projectIDs.map(SidebarItem.project)
            return .vertical(forward: (scopes.firstIndex(of: after.scope) ?? scopes.count)
                             > (scopes.firstIndex(of: before.scope) ?? -1))
        }
        guard before.filter != after.filter else { return nil }
        let weeks = Set([before.filter, after.filter].compactMap { filter -> Date? in
            if case .week(let date) = filter { return date }
            return nil
        }).sorted().map(TaskPlanFilter.week)
        let filters: [TaskPlanFilter] = [.all, .thisWeek, .nextWeek] + weeks + [.unscheduled]
        return .horizontal(forward: filters.firstIndex(of: after.filter)! > filters.firstIndex(of: before.filter)!)
    }
}

struct TaskReveal: Equatable {
    let id = UUID()
    let taskID: UUID
    var animatedScroll = true
}

final class TaskEditingExitRequest {
    let taskID: UUID?
    var failed = false
    init(taskID: UUID? = nil) { self.taskID = taskID }
    func targets(_ id: UUID) -> Bool { taskID == nil || taskID == id }
}

enum TaskNavigation {
    enum Action { case moved, planned, completed, restored, created, open }

    static func destination(for task: WorkTask, after action: Action, from current: TaskViewContext,
                            relativeTo today: Date = Date(), firstWeekday: Int, calendar: Calendar = .current) -> TaskViewContext? {
        let targetFilter = TaskPlanFilter(task: task, relativeTo: today, firstWeekday: firstWeekday, calendar: calendar)
        switch action {
        case .completed, .restored: return nil
        case .open:
            var destination = TaskViewContext(scope: task.completedAt == nil ? (task.projectID.map(SidebarItem.project) ?? .all) : .completed,
                                              filter: task.completedAt == nil ? targetFilter : .all, search: "", history: current.history)
            if let completedAt = task.completedAt {
                var history = current.history ?? TaskHistoryContext(range: .week, weekAnchor: completedAt,
                                                                    customStart: calendar.startOfDay(for: completedAt), customEnd: completedAt)
                history.range = .week
                history.weekAnchor = completedAt
                destination.history = history
            }
            return destination
        case .moved:
            guard task.completedAt == nil, case .project(let sourceID) = current.scope, sourceID != task.projectID else { return nil }
            return TaskViewContext(scope: task.projectID.map(SidebarItem.project) ?? .all, filter: targetFilter, search: "", history: current.history)
        case .planned:
            guard task.completedAt == nil else { return nil }
            switch current.scope {
            case .all, .project:
                guard !current.filter.includes(task, relativeTo: today, firstWeekday: firstWeekday, calendar: calendar) else { return nil }
                return TaskViewContext(scope: current.scope, filter: targetFilter, search: "", history: current.history)
            case .thisWeek, .upcoming, .overdue, .reminders, .completed: return nil
            }
        case .created:
            return TaskViewContext(scope: task.projectID.map(SidebarItem.project) ?? .all,
                                   filter: current.filter.includes(task, relativeTo: today, firstWeekday: firstWeekday, calendar: calendar) ? current.filter : targetFilter,
                                   search: "", history: current.history)
        }
    }
}

enum TaskOperationEvent {
    case planned(before: WorkTask, after: WorkTask)
    case completed(CompletionResult)
    case restored(WorkTask)
    case edited(task: WorkTask, message: String, symbol: String, undo: TaskUndoRecord?)

    static let notification = Notification.Name("WorkLedger.taskOperation")

    func post() { NotificationCenter.default.post(name: Self.notification, object: self) }
}

enum TaskOperationUndo {
    case plan(before: WorkTask, after: WorkTask)
    case project(before: WorkTask, after: WorkTask)
    case completion(WorkTask)
    case subtaskCompletion(taskID: UUID, subtaskID: UUID, before: Date?, after: Date?)
    case removedSubtask(taskID: UUID, child: Subtask, index: Int, parentCompletedAt: Date?)
    case removedAttachment(taskID: UUID, attachment: Attachment, index: Int)

    @MainActor func apply(to store: WorkStore) throws -> WorkTask {
        switch self {
        case .plan(let before, let after):
            guard let current = store.data.tasks.first(where: { $0.id == after.id }), current.completedAt == after.completedAt,
                  current.plannedAt == after.plannedAt, current.planGranularity == after.planGranularity else {
                throw LedgerError.conflict(L("任务计划已经再次更改，无法撤销这次操作。"))
            }
            try store.updateTask(id: after.id) { $0.plannedAt = before.plannedAt; $0.planGranularity = before.planGranularity }
            return store.data.tasks.first { $0.id == after.id }!
        case .project(let before, let after):
            guard let current = store.data.tasks.first(where: { $0.id == after.id }), current.completedAt == after.completedAt,
                  current.projectID == after.projectID else {
                throw LedgerError.conflict(L("任务所属项目已经再次更改，无法撤销这次操作。"))
            }
            try store.moveTask(id: after.id, toProject: before.projectID)
            return store.data.tasks.first { $0.id == after.id }!
        case .completion(let completed):
            guard store.data.tasks.first(where: { $0.id == completed.id })?.completedAt == completed.completedAt else {
                throw LedgerError.conflict(L("完成记录已经更改，无法撤销这次操作。"))
            }
            try store.undoCompletion(id: completed.id)
            return store.data.tasks.first { $0.id == completed.id }!
        case .subtaskCompletion(let taskID, let subtaskID, let before, let after):
            guard let current = store.data.tasks.first(where: { $0.id == taskID }), current.completedAt == nil,
                  let child = current.subtasks.first(where: { $0.id == subtaskID }), child.completedAt == after else {
                throw LedgerError.conflict(L("步骤完成状态已经更改，无法撤销这次操作。"))
            }
            if let before {
                guard current.subtasks.contains(where: { $0.id != subtaskID && $0.completedAt == nil }) else {
                    throw LedgerError.conflict(L("其他步骤已完成，请直接勾选此步骤以完成主任务。"))
                }
                _ = try store.completeSubtask(taskID: taskID, subtaskID: subtaskID, at: before)
            }
            else { try store.undoSubtaskCompletion(taskID: taskID, subtaskID: subtaskID) }
            return store.data.tasks.first { $0.id == taskID }!
        case .removedSubtask(let taskID, let child, let index, let parentCompletedAt):
            guard let current = store.data.tasks.first(where: { $0.id == taskID }),
                  current.completedAt == parentCompletedAt, !current.subtasks.contains(where: { $0.id == child.id }) else {
                throw LedgerError.conflict(L("任务或步骤状态已经更改，无法恢复此步骤。"))
            }
            try store.updateTask(id: taskID) { $0.subtasks.insert(child, at: min(max(index, 0), $0.subtasks.count)) }
            return store.data.tasks.first { $0.id == taskID }!
        case .removedAttachment(let taskID, let attachment, let index):
            guard let current = store.data.tasks.first(where: { $0.id == taskID }),
                  !current.attachments.contains(where: { $0.id == attachment.id }) else {
                throw LedgerError.conflict(L("任务或附件状态已经更改，无法恢复此附件。"))
            }
            let info = try store.attachmentURL(attachment).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, Int64(info.fileSize ?? -1) == attachment.size else {
                throw LedgerError.conflict(L("附件文件已改变或不存在，无法恢复引用。"))
            }
            try store.updateTask(id: taskID) { $0.attachments.insert(attachment, at: min(max(index, 0), $0.attachments.count)) }
            return store.data.tasks.first { $0.id == taskID }!
        }
    }
}

@MainActor
final class TaskUndoRecord {
    private let operation: TaskOperationUndo
    private weak var manager: UndoManager?
    private var applied = false

    init(_ operation: TaskOperationUndo) { self.operation = operation }

    func register(in manager: UndoManager?, store: WorkStore, name: String) {
        self.manager = manager
        manager?.registerUndo(withTarget: self) { record in
            do {
                let task = try record.apply(to: store)
                TaskOperationEvent.edited(task: task, message: L("已撤销\(name)"), symbol: "arrow.uturn.backward", undo: nil).post()
            } catch { store.errorMessage = L("无法撤销\(name)：\(error.localizedDescription)") }
        }
        manager?.setActionName(name)
    }

    func apply(to store: WorkStore) throws -> WorkTask {
        guard !applied else { throw LedgerError.conflict(L("这次操作已经撤销。")) }
        let restored = try operation.apply(to: store)
        applied = true
        // The on-screen Undo and ⌘Z share one record; using either consumes both entries.
        if let manager, !manager.isUndoing { manager.removeAllActions(withTarget: self) }
        return restored
    }
}

@MainActor
struct TaskOperationNotice {
    let id = UUID()
    let taskID: UUID
    let title: String
    let message: String
    let symbol: String
    var undo: TaskUndoRecord?
    var origin: TaskViewContext?
    var nextTaskID: UUID?

    init(taskID: UUID, title: String, message: String, symbol: String, undo: TaskOperationUndo? = nil,
         origin: TaskViewContext? = nil, nextTaskID: UUID? = nil) {
        self.taskID = taskID; self.title = title; self.message = message; self.symbol = symbol
        self.undo = undo.map(TaskUndoRecord.init)
        self.origin = origin; self.nextTaskID = nextTaskID
    }
}
