import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class TaskNavigationTests: XCTestCase {
    func testListSlidesTravelOneFullViewportInEitherDirection() {
        let viewport = CGSize(width: 800, height: 600)
        XCTAssertEqual(TaskListSlide.vertical(forward: true).offset(in: viewport), CGSize(width: 0, height: 600))
        XCTAssertEqual(TaskListSlide.vertical(forward: false).offset(in: viewport), CGSize(width: 0, height: -600))
        XCTAssertEqual(TaskListSlide.horizontal(forward: true).offset(in: viewport), CGSize(width: 800, height: 0))
        XCTAssertEqual(TaskListSlide.horizontal(forward: false).offset(in: viewport), CGSize(width: -800, height: 0))
        XCTAssertEqual(TaskListSlide.vertical(forward: true).offset(in: .zero), .zero)
    }

    func testListPageIdentityChangesOnlyForScopeOrPlanFilter() {
        let before = TaskViewContext(scope: .all, filter: .thisWeek, search: "")
        var after = before
        after.search = "证书"
        after.history = TaskHistoryContext(range: .all, weekAnchor: today, customStart: today, customEnd: today)
        let original = TaskListPageID(scope: before.scope, filter: before.filter)
        XCTAssertEqual(TaskListPageID(scope: after.scope, filter: after.filter), original)
        XCTAssertNotEqual(TaskListPageID(scope: .project(UUID()), filter: after.filter), original)
        XCTAssertNotEqual(TaskListPageID(scope: after.scope, filter: .all), original)
        XCTAssertEqual(Set([original, TaskListPageID(scope: after.scope, filter: after.filter)]).count, 1)
    }

    func testListEffectFramesMoveBothPagesAndKeepTheFinalPageUntransformed() {
        let viewport = CGSize(width: 800, height: 600)
        for slide in [TaskListSlide.horizontal(forward: true), .horizontal(forward: false), .vertical(forward: true), .vertical(forward: false)] {
            let incoming = TaskListEffect.slide.presentation(at: 0.5, slide: slide, viewport: viewport)
            let outgoing = TaskListEffect.slide.presentation(at: -0.5, slide: slide, viewport: viewport)
            let distance = slide.offset(in: viewport)
            XCTAssertEqual(incoming.offset, CGSize(width: distance.width / 2, height: distance.height / 2))
            XCTAssertEqual(outgoing.offset, CGSize(width: -distance.width / 2, height: -distance.height / 2))
            XCTAssertEqual(incoming.opacity, 1)
        }
        let fade = TaskListEffect.slideFade.presentation(at: 0.5, slide: .horizontal(forward: true), viewport: viewport)
        XCTAssertEqual(fade.offset, CGSize(width: 32, height: 0))
        XCTAssertEqual(fade.opacity, 0.5)
        let zoom = TaskListEffect.scaleFade.presentation(at: -0.5, slide: .vertical(forward: true), viewport: viewport)
        XCTAssertEqual(zoom.offset, .zero)
        XCTAssertEqual(zoom.scale, 0.96, accuracy: 0.0001)
        XCTAssertEqual(zoom.opacity, 0.5)
        for effect in TaskListEffect.allCases {
            let final = effect.presentation(at: 0, slide: .horizontal(forward: true), viewport: viewport)
            XCTAssertEqual(final.offset, .zero)
            XCTAssertEqual(final.scale, 1)
            XCTAssertEqual(final.opacity, 1)
        }
    }

    func testListEffectsExposeThreeEffectsAndAnOffChoice() {
        XCTAssertTrue((0.15...0.2).contains(TaskListEffect.duration))
        XCTAssertEqual(TaskListEffect.allCases.map(\.rawValue), ["slide", "slideFade", "scaleFade", "none"])
        XCTAssertEqual(TaskListEffect.allCases.map(\.title), [L("整页滑动"), L("滑动淡入淡出"), L("缩放淡入淡出"), L("关闭")])
        XCTAssertEqual(Set(TaskListEffect.allCases.map(\.id)).count, 4)
        XCTAssertTrue(TaskListEffect.allCases.allSatisfy { !$0.summary.isEmpty })
    }

    func testProjectSlideWinsWhenRestoringADifferentWeekFilter() {
        let first = UUID(), second = UUID()
        let before = TaskViewContext(scope: .project(first), filter: .all, search: "")
        let after = TaskViewContext(scope: .project(second), filter: .nextWeek, search: "")
        XCTAssertEqual(TaskListSlide.between(before, after, projectIDs: [first, second]), .vertical(forward: true))
        XCTAssertEqual(TaskListSlide.between(after, before, projectIDs: [first, second]), .vertical(forward: false))
    }

    func testWorkbenchUsesSidebarOrderForVerticalSlides() {
        let all = TaskViewContext(scope: .all, filter: .all, search: "")
        let week = TaskViewContext(scope: .thisWeek, filter: .thisWeek, search: "")
        XCTAssertEqual(TaskListSlide.between(all, week, projectIDs: []), .vertical(forward: true))
        XCTAssertEqual(TaskListSlide.between(week, all, projectIDs: []), .vertical(forward: false))
    }

    func testWeekTabsSlideHorizontallyInDisplayedOrder() {
        let filters: [TaskPlanFilter] = [.all, .thisWeek, .nextWeek,
                                       .week(date("2026-11-05T00:00:00+08:00")),
                                       .week(date("2026-11-12T00:00:00+08:00")), .unscheduled]
        for (left, right) in zip(filters, filters.dropFirst()) {
            let before = TaskViewContext(scope: .all, filter: left, search: "")
            let after = TaskViewContext(scope: .all, filter: right, search: "")
            XCTAssertEqual(TaskListSlide.between(before, after, projectIDs: []), .horizontal(forward: true))
            XCTAssertEqual(TaskListSlide.between(after, before, projectIDs: []), .horizontal(forward: false))
        }
    }

    func testSearchOrHistoryChangesDoNotRestartListSlide() {
        let before = TaskViewContext(scope: .all, filter: .thisWeek, search: "")
        var after = before
        after.search = "证书"
        after.history = TaskHistoryContext(range: .all, weekAnchor: today, customStart: today, customEnd: today)
        XCTAssertNil(TaskListSlide.between(before, after, projectIDs: []))
        XCTAssertNil(TaskListSlide.between(before, before, projectIDs: []))
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private var today: Date { date("2026-10-21T12:00:00+08:00") }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func destination(_ task: WorkTask, _ action: TaskNavigation.Action, _ scope: SidebarItem, _ filter: TaskPlanFilter = .thisWeek, search: String = "") -> TaskViewContext? {
        TaskNavigation.destination(for: task, after: action, from: TaskViewContext(scope: scope, filter: filter, search: search), relativeTo: today, firstWeekday: 5, calendar: calendar)
    }
    private func store() throws -> WorkStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerNavigationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try WorkStore(directory: directory)
    }

    func testCompletionAndRestoreNeverChooseAnotherScreen() {
        let projectID = UUID()
        let future = date("2026-11-12T00:00:00+08:00")
        let task = WorkTask(projectID: projectID, title: "保持当前列表", completedAt: today, plannedAt: future, planGranularity: .week)
        for scope in [SidebarItem.all, .thisWeek, .upcoming, .overdue, .completed, .project(projectID)] {
            XCTAssertNil(destination(task, .completed, scope, .week(future), search: "当前关键词"))
            XCTAssertNil(destination(task, .restored, scope, .week(future), search: "当前关键词"))
        }
    }

    func testDragFromSingleProjectFollowsDestinationAndActualPlan() {
        let originalProject = UUID(), targetProject = UUID()
        let planned = date("2026-10-23T10:00:00+08:00")
        var task = WorkTask(projectID: targetProject, title: "移动任务", plannedAt: planned, planGranularity: .day)
        XCTAssertEqual(destination(task, .moved, .project(originalProject), .all, search: "旧搜索"),
                       TaskViewContext(scope: .project(targetProject), filter: .nextWeek, search: ""))
        task.projectID = nil
        task.plannedAt = nil
        task.planGranularity = nil
        XCTAssertEqual(destination(task, .moved, .project(originalProject)),
                       TaskViewContext(scope: .all, filter: .unscheduled, search: ""))
    }

    func testDragInAggregateOrToSameProjectDoesNotNavigate() {
        let project = UUID()
        var task = WorkTask(projectID: project, title: "保持聚合视图", plannedAt: today)
        for scope in [SidebarItem.all, .thisWeek, .upcoming, .overdue, .completed, .project(project)] {
            XCTAssertNil(destination(task, .moved, scope, .all, search: "保留搜索"))
        }
        task.completedAt = today
        XCTAssertNil(destination(task, .moved, .project(UUID())))
    }

    func testPlanChangeFollowsOnlyWhenSpecificProjectOrAllFilterLosesTask() {
        let project = UUID()
        let task = WorkTask(projectID: project, title: "重新安排", plannedAt: date("2026-10-23T09:00:00+08:00"), planGranularity: .week)
        for scope in [SidebarItem.all, .project(project)] {
            XCTAssertEqual(destination(task, .planned, scope, .thisWeek, search: "旧搜索"),
                           TaskViewContext(scope: scope, filter: .nextWeek, search: ""))
            XCTAssertNil(destination(task, .planned, scope, .all, search: "保持搜索"))
            XCTAssertNil(destination(task, .planned, scope, .nextWeek))
        }
    }

    func testPlanChangeInFixedCategoriesDoesNotNavigate() {
        var task = WorkTask(title: "固定分类", plannedAt: date("2026-11-13T09:00:00+08:00"), planGranularity: .day)
        for scope in [SidebarItem.thisWeek, .upcoming, .overdue, .completed] {
            XCTAssertNil(destination(task, .planned, scope, .thisWeek, search: "保留关键词"))
        }
        task.completedAt = today
        XCTAssertNil(destination(task, .planned, .all))
    }

    func testPlanDestinationsRespectCustomWeekAndUnscheduled() {
        var task = WorkTask(title: "工作周从周四开始", plannedAt: date("2026-10-22T00:00:00+08:00"), planGranularity: .day)
        XCTAssertEqual(destination(task, .planned, .all)?.filter, .nextWeek)
        task.plannedAt = date("2026-11-03T12:00:00+08:00")
        XCTAssertEqual(destination(task, .planned, .all)?.filter, .week(date("2026-10-29T00:00:00+08:00")))
        task.plannedAt = nil
        task.planGranularity = nil
        XCTAssertEqual(destination(task, .planned, .all)?.filter, .unscheduled)
        task.plannedAt = date("2026-10-01T00:00:00+08:00")
        XCTAssertEqual(destination(task, .open, .all)?.filter, .thisWeek, "Past unfinished plans appear in this week")
    }

    func testExplicitOpenUsesProjectPlanOrCompletedHistoryAndClearsSearch() {
        let project = UUID()
        var task = WorkTask(projectID: project, title: "打开具体任务", plannedAt: date("2026-10-23T00:00:00+08:00"))
        XCTAssertEqual(destination(task, .open, .overdue, .all, search: "不匹配"),
                       TaskViewContext(scope: .project(project), filter: .nextWeek, search: ""))
        task.projectID = nil
        task.plannedAt = nil
        XCTAssertEqual(destination(task, .open, .completed), TaskViewContext(scope: .all, filter: .unscheduled, search: ""))
        task.completedAt = today
        let history = TaskHistoryContext(range: .week, weekAnchor: today, customStart: calendar.startOfDay(for: today), customEnd: today)
        XCTAssertEqual(destination(task, .open, .all), TaskViewContext(scope: .completed, filter: .all, search: "", history: history))
    }

    func testOpeningCompletedTaskRetainsOriginalHistoryPeriodForReturn() throws {
        let task = WorkTask(title: "打开另一个周期的完成记录", completedAt: today)
        for range in [HistoryRange.week, .custom, .all] {
            let history = TaskHistoryContext(range: range, weekAnchor: date("2026-10-01T00:00:00+08:00"),
                                             customStart: date("2026-09-01T00:00:00+08:00"), customEnd: date("2026-09-30T12:00:00+08:00"))
            let origin = TaskViewContext(scope: .completed, filter: .all, search: "", history: history)
            let target = try XCTUnwrap(TaskNavigation.destination(for: task, after: .open, from: origin, relativeTo: today, firstWeekday: 5, calendar: calendar))
            XCTAssertEqual(target.scope, .completed)
            XCTAssertNotEqual(target, origin, "Changing only the completed-history period still needs a Return action")
            XCTAssertEqual(target.history?.range, .week)
            XCTAssertEqual(target.history?.weekAnchor, task.completedAt)
            XCTAssertEqual(target.history?.customStart, history.customStart)
            XCTAssertEqual(target.history?.customEnd, history.customEnd)
            XCTAssertEqual(origin.history, history, "Opening another record must not mutate the captured Return context")
            let repeated = TaskNavigation.destination(for: task, after: .open, from: target, relativeTo: today, firstWeekday: 5, calendar: calendar)
            XCTAssertEqual(repeated, target)
        }
    }

    func testActiveTaskDestinationsPreserveInactiveHistorySelections() throws {
        let history = TaskHistoryContext(range: .custom, weekAnchor: date("2026-10-01T00:00:00+08:00"),
                                         customStart: date("2026-09-01T00:00:00+08:00"), customEnd: date("2026-09-30T12:00:00+08:00"))
        let origin = TaskViewContext(scope: .project(UUID()), filter: .thisWeek, search: "原搜索", history: history)
        let task = WorkTask(projectID: UUID(), title: "活动任务", plannedAt: date("2026-10-23T00:00:00+08:00"))
        for action in [TaskNavigation.Action.moved, .planned, .created, .open] {
            let target = try XCTUnwrap(TaskNavigation.destination(for: task, after: action, from: origin, relativeTo: today, firstWeekday: 5, calendar: calendar))
            XCTAssertEqual(target.history, history, "Active task navigation must preserve the user's historical date selections")
        }
    }

    func testCreatedTaskPreservesApplicableFilterAndFollowsChangedPlan() {
        let project = UUID()
        let task = WorkTask(projectID: project, title: "新任务", plannedAt: date("2026-10-23T00:00:00+08:00"))
        XCTAssertEqual(destination(task, .created, .project(project), .all), TaskViewContext(scope: .project(project), filter: .all, search: ""))
        XCTAssertEqual(destination(task, .created, .project(project), .thisWeek), TaskViewContext(scope: .project(project), filter: .nextWeek, search: ""))
        let unassigned = WorkTask(title: "未关联项目")
        XCTAssertEqual(destination(unassigned, .created, .all), TaskViewContext(scope: .all, filter: .unscheduled, search: ""))
    }

    func testRevealingSameTaskAgainHasNewRequestIdentity() {
        let taskID = UUID()
        let first = TaskReveal(taskID: taskID), second = TaskReveal(taskID: taskID)
        XCTAssertEqual(first.taskID, second.taskID)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first, second, "A repeated reveal must trigger another scroll")
    }

    func testUndoPlanPreservesLaterNotesAndRejectsAnotherPlanChange() async throws {
        let store = try store()
        let original = WorkTask(title: "调整计划", notes: "原备注", plannedAt: today, planGranularity: .week)
        try store.saveTask(original)
        let before = try XCTUnwrap(store.data.tasks.first)
        let newDate = date("2026-10-23T09:00:00+08:00")
        try store.updateTask(id: before.id) { $0.plannedAt = newDate; $0.planGranularity = .day }
        let after = try XCTUnwrap(store.data.tasks.first)
        try store.updateTask(id: before.id) { $0.notes = "计划变动后新增的备注" }
        let restored = try TaskOperationUndo.plan(before: before, after: after).apply(to: store)
        XCTAssertEqual(restored.plannedAt, before.plannedAt)
        XCTAssertEqual(restored.planGranularity, before.planGranularity)
        XCTAssertEqual(restored.notes, "计划变动后新增的备注")

        try store.updateTask(id: before.id) { $0.plannedAt = newDate; $0.planGranularity = .day }
        try store.updateTask(id: before.id) { $0.plannedAt = newDate.addingTimeInterval(86_400) }
        let changed = store.data
        XCTAssertThrowsError(try TaskOperationUndo.plan(before: before, after: after).apply(to: store))
        XCTAssertEqual(store.data, changed)
    }

    func testUndoProjectPreservesLaterNotesAndRejectsAnotherMove() async throws {
        let store = try store()
        let first = try store.addProject(name: "原项目"), second = try store.addProject(name: "目标项目")
        let task = WorkTask(projectID: first.id, title: "移动项目")
        try store.saveTask(task)
        let before = try XCTUnwrap(store.data.tasks.first)
        try store.moveTask(id: task.id, toProject: second.id)
        let after = try XCTUnwrap(store.data.tasks.first)
        try store.updateTask(id: task.id) { $0.notes = "移动后新增的备注" }
        let restored = try TaskOperationUndo.project(before: before, after: after).apply(to: store)
        XCTAssertEqual(restored.projectID, first.id)
        XCTAssertEqual(restored.notes, "移动后新增的备注")

        try store.moveTask(id: task.id, toProject: second.id)
        try store.moveTask(id: task.id, toProject: nil)
        let changed = store.data
        XCTAssertThrowsError(try TaskOperationUndo.project(before: before, after: after).apply(to: store))
        XCTAssertEqual(store.data, changed)
    }

    func testCompletionUndoRestoresPartialStepsAndRemovesUntouchedSuccessor() async throws {
        let store = try store()
        let first = Subtask(title: "已经完成", completedAt: today.addingTimeInterval(-86_400)), last = Subtask(title: "最后一步")
        let task = WorkTask(title: "循环任务", subtasks: [first, last], dueAt: today, repeatRule: RepeatRule())
        try store.saveTask(task)
        let result = try XCTUnwrap(store.completeSubtask(taskID: task.id, subtaskID: last.id, at: today))
        XCTAssertNotNil(result.nextTask)
        let restored = try TaskOperationUndo.completion(result.task).apply(to: store)
        XCTAssertNil(restored.completedAt)
        XCTAssertEqual(restored.subtasks, [first, last])
        XCTAssertEqual(store.data.tasks.count, 1)
    }

    func testCompletionUndoRejectsEditedSuccessorAndChangedCompletionDate() async throws {
        let store = try store()
        let task = WorkTask(title: "循环撤销保护", dueAt: today, repeatRule: RepeatRule())
        try store.saveTask(task)
        let result = try store.completeTask(id: task.id, at: today)
        let successor = try XCTUnwrap(result.nextTask)
        try store.updateTask(id: successor.id) { $0.notes = "下一次已经有工作记录" }
        let changed = store.data
        XCTAssertThrowsError(try TaskOperationUndo.completion(result.task).apply(to: store))
        XCTAssertEqual(store.data, changed)

        try store.setCompletionDate(taskID: task.id, at: today.addingTimeInterval(60))
        let changedDate = store.data
        XCTAssertThrowsError(try TaskOperationUndo.completion(result.task).apply(to: store))
        XCTAssertEqual(store.data, changedDate)
    }
}
