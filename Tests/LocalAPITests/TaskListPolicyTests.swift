import XCTest
import WorkLedgerCore
@testable import WorkLedger

final class TaskListPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private var today: Date { date("2026-10-21T12:00:00+08:00") }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func scoped(_ data: LedgerData, _ scope: SidebarItem) -> [WorkTask] {
        TaskListPolicy.tasks(in: scope, data: data, relativeTo: today, firstWeekday: 5, calendar: calendar)
    }
    private func visible(_ data: LedgerData, _ scope: SidebarItem, filter: TaskPlanFilter = .thisWeek, search: String = "") -> [WorkTask] {
        TaskListPolicy.visibleTasks(scoped(data, scope), projects: data.projects, scope: scope, filter: filter,
                                    search: search, relativeTo: today, firstWeekday: 5, calendar: calendar)
    }

    func testUpcomingAndOverdueIncludeEveryMatchingPlanWithoutCompletedOrArchivedTasks() {
        let archived = Project(name: "已归档", isArchived: true)
        let plannedDates: [Date?] = [nil, date("2026-10-20T00:00:00+08:00"), date("2026-10-23T00:00:00+08:00"), date("2026-11-05T00:00:00+08:00")]
        let upcoming = plannedDates.map { WorkTask(title: "即将到期", dueAt: date("2026-10-22T00:00:00+08:00"), plannedAt: $0) }
        let overdue = plannedDates.map { WorkTask(title: "已逾期", dueAt: date("2026-10-20T00:00:00+08:00"), plannedAt: $0) }
        let excluded = [WorkTask(title: "没有截止日期"),
                        WorkTask(projectID: archived.id, title: "归档任务", dueAt: today),
                        WorkTask(title: "已完成", dueAt: today, completedAt: today)]
        let data = LedgerData(projects: [archived], tasks: upcoming + overdue + excluded)
        for filter in [TaskPlanFilter.all, .thisWeek, .nextWeek, .week(date("2026-12-10T00:00:00+08:00")), .unscheduled] {
            XCTAssertEqual(Set(visible(data, .upcoming, filter: filter).map(\.id)), Set(upcoming.map(\.id)))
            XCTAssertEqual(Set(visible(data, .overdue, filter: filter).map(\.id)), Set(overdue.map(\.id)))
        }
    }

    func testDeadlineBoundariesUseLocalDaysAndExcludeTheEighthDayEnd() {
        let start = date("2026-10-21T00:00:00+08:00"), end = date("2026-10-29T00:00:00+08:00")
        let past = WorkTask(title: "昨天", dueAt: start.addingTimeInterval(-1))
        let first = WorkTask(title: "今天", dueAt: start)
        let last = WorkTask(title: "范围最后一秒", dueAt: end.addingTimeInterval(-1))
        let beyond = WorkTask(title: "范围之外", dueAt: end)
        let data = LedgerData(tasks: [beyond, last, past, first])
        XCTAssertEqual(visible(data, .upcoming).map(\.id), [first.id, last.id])
        XCTAssertEqual(visible(data, .overdue).map(\.id), [past.id])
    }

    func testUrgentOrderFollowsDeadlineAcrossProjectsAndPlanWeeks() {
        let firstProject = Project(name: "第一个项目"), secondProject = Project(name: "第二个项目")
        let later = WorkTask(projectID: firstProject.id, title: "七天后截止", dueAt: date("2026-10-28T00:00:00+08:00"), plannedAt: date("2026-10-15T00:00:00+08:00"))
        let first = WorkTask(projectID: secondProject.id, title: "明天截止未安排", dueAt: date("2026-10-22T00:00:00+08:00"))
        let middle = WorkTask(projectID: firstProject.id, title: "后天截止下月计划", dueAt: date("2026-10-23T00:00:00+08:00"), plannedAt: date("2026-11-05T00:00:00+08:00"))
        let data = LedgerData(projects: [firstProject, secondProject], tasks: [later, first, middle])
        XCTAssertTrue(TaskListPolicy.isTimeSensitive(.upcoming))
        XCTAssertEqual(visible(data, .upcoming).map(\.id), [first.id, middle.id, later.id])

        let mostOverdue = WorkTask(projectID: secondProject.id, title: "最早逾期", dueAt: date("2026-10-01T00:00:00+08:00"), plannedAt: date("2026-11-05T00:00:00+08:00"))
        let recentlyOverdue = WorkTask(projectID: firstProject.id, title: "昨天逾期", dueAt: date("2026-10-20T00:00:00+08:00"), plannedAt: date("2026-10-01T00:00:00+08:00"))
        let overdueData = LedgerData(projects: data.projects, tasks: [recentlyOverdue, mostOverdue])
        XCTAssertTrue(TaskListPolicy.isTimeSensitive(.overdue))
        XCTAssertEqual(visible(overdueData, .overdue).map(\.id), [mostOverdue.id, recentlyOverdue.id])
    }

    func testPendingRemindersIncludeReminderOnlyTasksAtTheirExactTimeAndKeepSearch() {
        let project = Project(name: "证书项目"), archived = Project(name: "归档项目", isArchived: true)
        let older = WorkTask(projectID: project.id, title: "仅提醒", notes: "检查部署", reminderAt: today.addingTimeInterval(-60), plannedAt: date("2026-11-05T00:00:00+08:00"))
        let reached = WorkTask(title: "刚到时间", reminderAt: today)
        let future = WorkTask(title: "尚未到时", reminderAt: today.addingTimeInterval(1))
        let completed = WorkTask(title: "已完成", reminderAt: today.addingTimeInterval(-120), completedAt: today)
        let archivedTask = WorkTask(projectID: archived.id, title: "已归档", reminderAt: today.addingTimeInterval(-120))
        let data = LedgerData(projects: [project, archived], tasks: [future, reached, completed, older, archivedTask])
        XCTAssertTrue(TaskListPolicy.isTimeSensitive(.reminders))
        XCTAssertEqual(visible(data, .reminders, filter: .unscheduled).map(\.id), [older.id, reached.id])
        XCTAssertNil(older.dueAt)
        XCTAssertEqual(visible(data, .reminders, search: "证书").map(\.id), [older.id])
        XCTAssertEqual(visible(data, .reminders, search: "部署").map(\.id), [older.id])
        XCTAssertTrue(visible(data, .reminders, search: "不存在").isEmpty)
        XCTAssertTrue(visible(data, .upcoming).isEmpty)
    }

    func testUrgentSearchAndNormalProjectPlanFilterRemainIndependent() {
        let project = Project(name: "网站维护")
        let planned = WorkTask(projectID: project.id, title: "本周任务", dueAt: today, plannedAt: today)
        let unplanned = WorkTask(projectID: project.id, title: "未安排", notes: "需要更新证书", dueAt: today)
        let data = LedgerData(projects: [project], tasks: [unplanned, planned])
        XCTAssertEqual(visible(data, .upcoming, search: "证书").map(\.id), [unplanned.id])
        XCTAssertEqual(visible(data, .project(project.id)).map(\.id), [planned.id])
        XCTAssertEqual(visible(data, .all).map(\.id), [planned.id])
        XCTAssertEqual(visible(data, .thisWeek).map(\.id), [planned.id])
        XCTAssertFalse(TaskListPolicy.isTimeSensitive(.project(project.id)))
        XCTAssertFalse(TaskListPolicy.isTimeSensitive(.all))
    }

    func testCompletedSourcesKeepPendingCountsAndPartialStepsIndependent() {
        let project = Project(name: "网站维护"), archived = Project(name: "归档项目", isArchived: true)
        let pending = WorkTask(projectID: project.id, title: "旧计划继续待办", plannedAt: date("2026-10-01T00:00:00+08:00"))
        let partial = WorkTask(projectID: project.id, title: "步骤部分完成", subtasks: [Subtask(title: "已做", completedAt: today), Subtask(title: "待做")], plannedAt: today)
        let finished = WorkTask(projectID: project.id, title: "上周计划本周完成", completedAt: today, plannedAt: date("2026-10-08T00:00:00+08:00"))
        let unplanned = WorkTask(title: "未安排也按实际完成周", completedAt: today)
        let older = WorkTask(projectID: project.id, title: "上周完成", completedAt: date("2026-10-14T23:59:59+08:00"), plannedAt: today)
        let archivedTask = WorkTask(projectID: archived.id, title: "归档完成", completedAt: today)
        let data = LedgerData(projects: [project, archived], tasks: [pending, partial, finished, unplanned, older, archivedTask])
        for scope in [SidebarItem.all, .thisWeek, .project(project.id)] {
            XCTAssertEqual(Set(scoped(data, scope).map(\.id)), Set([pending.id, partial.id]), "Pending counts must not include completed parents")
        }
        func completed(_ scope: SidebarItem) -> Set<UUID> {
            Set(TaskListPolicy.completedTasks(in: scope, data: data, relativeTo: today, firstWeekday: 5, calendar: calendar).map(\.id))
        }
        XCTAssertEqual(completed(.all), Set([finished.id, unplanned.id, older.id]))
        XCTAssertEqual(completed(.thisWeek), Set([finished.id, unplanned.id]))
        XCTAssertEqual(completed(.project(project.id)), Set([finished.id, older.id]))
        XCTAssertEqual(completed(.project(archived.id)), Set([archivedTask.id]))
        for scope in [SidebarItem.upcoming, .overdue, .reminders, .completed] {
            XCTAssertTrue(completed(scope).isEmpty)
        }
        XCTAssertEqual(Set(scoped(data, .completed).map(\.id)), Set([finished.id, unplanned.id, older.id, archivedTask.id]), "The independent history still includes archived projects")
    }

    func testCompletedVisibilityUsesCompletionWeekAndKeepsSearchAndNewestFirst() {
        let project = Project(name: "证书维护")
        let newest = WorkTask(projectID: project.id, title: "本周完成未来计划", details: "部署记录", notes: "核验成功", subtasks: [Subtask(title: "检查域名", completedAt: today)], attachments: [Attachment(name: "验收附件.txt", storedName: "fixture.txt", size: 10)], completedAt: today, plannedAt: date("2026-11-05T00:00:00+08:00"))
        let earlier = WorkTask(projectID: project.id, title: "本周完成未安排", completedAt: date("2026-10-20T09:00:00+08:00"))
        let older = WorkTask(projectID: project.id, title: "本周计划上周完成", completedAt: date("2026-10-14T23:59:59+08:00"), plannedAt: today)
        let data = LedgerData(projects: [project], tasks: [older, earlier, newest])
        let completed = TaskListPolicy.completedTasks(in: .project(project.id), data: data, relativeTo: today, firstWeekday: 5, calendar: calendar)
        func result(_ filter: TaskPlanFilter, search: String = "") -> [UUID] {
            TaskListPolicy.visibleTasks(completed, projects: data.projects, scope: .project(project.id), filter: filter,
                                        search: search, relativeTo: today, firstWeekday: 5, calendar: calendar).map(\.id)
        }
        XCTAssertEqual(result(.all), [newest.id, earlier.id, older.id])
        let pending = WorkTask(projectID: project.id, title: "待办始终排在完成工作之前", plannedAt: date("2026-11-06T00:00:00+08:00"))
        XCTAssertEqual(TaskListPolicy.visibleTasks([newest, pending, older, earlier], projects: data.projects,
                                                  scope: .project(project.id), filter: .all, search: "",
                                                  relativeTo: today, firstWeekday: 5, calendar: calendar).map(\.id),
                       [pending.id, newest.id, earlier.id, older.id])
        XCTAssertEqual(result(.thisWeek), [newest.id, earlier.id])
        XCTAssertEqual(result(.week(date("2026-10-08T00:00:00+08:00"))), [older.id])
        XCTAssertTrue(result(.nextWeek).isEmpty)
        XCTAssertTrue(result(.unscheduled).isEmpty)
        for term in ["部署记录", "核验成功", "检查域名", "验收附件"] {
            XCTAssertEqual(result(.thisWeek, search: term), [newest.id])
        }
        XCTAssertEqual(result(.thisWeek, search: "证书维护"), [newest.id, earlier.id])
        XCTAssertTrue(result(.thisWeek, search: "不存在").isEmpty)
        let interval = WorkPeriod.range(containing: today, firstWeekday: 5, calendar: calendar)
        let history = TaskListPolicy.tasks(in: .completed, data: data, relativeTo: today, firstWeekday: 5, calendar: calendar, historyInterval: interval)
        XCTAssertEqual(Set(history.map(\.id)), Set([newest.id, earlier.id]))
    }

    func testCompletedThisWeekUsesExactBoundariesAndConfiguredWeekday() {
        let start = date("2026-10-15T00:00:00+08:00"), end = date("2026-10-22T00:00:00+08:00")
        let dates = [start.addingTimeInterval(-1), start, end.addingTimeInterval(-1), end]
        let tasks = dates.map { WorkTask(title: "完成边界", completedAt: $0, plannedAt: today) }
        let data = LedgerData(tasks: tasks)
        let current = TaskListPolicy.completedTasks(in: .thisWeek, data: data, relativeTo: today, firstWeekday: 5, calendar: calendar)
        XCTAssertEqual(Set(current.map(\.id)), Set([tasks[1].id, tasks[2].id]))
        let sunday = WorkTask(title: "周日完成", completedAt: date("2026-10-18T12:00:00+08:00"))
        let custom = LedgerData(tasks: [sunday])
        XCTAssertEqual(TaskListPolicy.completedTasks(in: .thisWeek, data: custom, relativeTo: today, firstWeekday: 5, calendar: calendar).map(\.id), [sunday.id])
        XCTAssertTrue(TaskListPolicy.completedTasks(in: .thisWeek, data: custom, relativeTo: today, firstWeekday: 2, calendar: calendar).isEmpty)
    }

    func testLateCreationCallbackCannotFollowWhileNewDraftIsBeingEdited() {
        let oldID = UUID(), newID = UUID()
        let context = TaskViewContext(scope: .all, filter: .thisWeek, search: "")
        XCTAssertFalse(TaskListPolicy.shouldFollowCreatedTask(oldID, currentDraftID: newID, reveal: TaskReveal(taskID: newID), origin: context, current: context))
        XCTAssertFalse(TaskListPolicy.shouldFollowCreatedTask(oldID, currentDraftID: newID, reveal: TaskReveal(taskID: oldID), origin: context, current: context))
        XCTAssertFalse(TaskListPolicy.shouldFollowCreatedTask(oldID, currentDraftID: nil, reveal: TaskReveal(taskID: newID), origin: context, current: context), "The new draft may already be saved or cancelled before the old callback arrives")
        XCTAssertFalse(TaskListPolicy.shouldFollowCreatedTask(oldID, currentDraftID: nil, reveal: nil, origin: context, current: context))
        XCTAssertTrue(TaskListPolicy.shouldFollowCreatedTask(oldID, currentDraftID: nil, reveal: TaskReveal(taskID: oldID), origin: context, current: context))
        var changed = context
        changed.filter = .nextWeek
        XCTAssertFalse(TaskListPolicy.shouldFollowCreatedTask(oldID, currentDraftID: nil, reveal: TaskReveal(taskID: oldID), origin: context, current: changed))
    }
}
