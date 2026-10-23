import Foundation
import WorkLedgerCore

enum TaskPlanDrop {
    static func applying(_ filter: TaskPlanFilter, to task: WorkTask, relativeTo date: Date,
                         firstWeekday: Int, calendar: Calendar = .current) throws -> WorkTask {
        if filter == .all { return task }
        guard task.completedAt == nil else { throw LedgerError.invalid(L("已完成任务按实际完成周归类，请先撤销完成再调整计划。")) }
        var result = task
        switch filter {
        case .all: break
        case .thisWeek, .nextWeek:
            result.plannedAt = TaskPlanning.weekDate(offset: filter == .thisWeek ? 0 : 1, relativeTo: date,
                                                      firstWeekday: firstWeekday, calendar: calendar)
            result.planGranularity = .week
        case .week(let anchor):
            guard anchor.timeIntervalSince1970.isFinite else { throw LedgerError.invalid(L("任务日期无效。")) }
            result.plannedAt = WorkPeriod.range(containing: anchor, firstWeekday: firstWeekday, calendar: calendar).start
            result.planGranularity = .week
        case .unscheduled:
            result.plannedAt = nil; result.planGranularity = nil
        }
        return result
    }
}
