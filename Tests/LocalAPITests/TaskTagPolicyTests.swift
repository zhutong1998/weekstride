import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class TaskTagPolicyTests: XCTestCase {
    private var today: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private func tasks(_ data: LedgerData, in scope: SidebarItem, completed: Bool = false) -> [WorkTask] {
        if completed {
            return TaskListPolicy.completedTasks(in: scope, data: data, relativeTo: today, firstWeekday: 5)
        }
        return TaskListPolicy.tasks(in: scope, data: data, relativeTo: today, firstWeekday: 5)
    }

    private func visible(_ tasks: [WorkTask], scope: SidebarItem, filter: TaskPlanFilter = .all,
                         tags: [TaskTag] = [], search: String = "") -> [WorkTask] {
        TaskListPolicy.visibleTasks(tasks, projects: [], tags: tags, scope: scope, filter: filter,
                                    search: search, relativeTo: today, firstWeekday: 5)
    }

    func testTagsFilterIndependentlyOfProjectAndOtherTagsWithoutShowingArchivedWork() {
        let project = Project(name: "Operations"), archived = Project(name: "Archive", isArchived: true)
        let first = TaskTag(name: "Certificates"), second = TaskTag(name: "Urgent")
        let shared = WorkTask(projectID: project.id, title: "Shared task", tagIDs: [first.id, second.id], isStarred: true)
        let unassigned = WorkTask(title: "No project", tagIDs: [first.id])
        let hidden = WorkTask(projectID: archived.id, title: "Archived", tagIDs: [first.id], isStarred: true)
        let completed = WorkTask(title: "Done", completedAt: today, tagIDs: [first.id], isStarred: true)
        let data = LedgerData(projects: [project, archived], tasks: [shared, unassigned, hidden, completed], tags: [first, second])

        XCTAssertEqual(Set(tasks(data, in: .tag(first.id)).map(\.id)), Set([shared.id, unassigned.id]))
        XCTAssertEqual(tasks(data, in: .tag(second.id)).map(\.id), [shared.id])
        XCTAssertEqual(tasks(data, in: .tag(first.id), completed: true).map(\.id), [completed.id])
        XCTAssertEqual(tasks(data, in: .project(project.id)).map(\.id), [shared.id])
        XCTAssertEqual(tasks(data, in: .starred).map(\.id), [shared.id])
        XCTAssertEqual(tasks(data, in: .starred, completed: true).map(\.id), [completed.id])
        XCTAssertFalse(TaskListPolicy.isTimeSensitive(.tag(first.id)))
    }

    func testStarredScopeIgnoresWeekTabsButKeepsPlannedOrderInsteadOfDeadlineOrder() {
        let current = WorkTask(title: "Current", dueAt: today.addingTimeInterval(7 * 86400), plannedAt: today, isStarred: true)
        let future = WorkTask(title: "Future", dueAt: today, plannedAt: today.addingTimeInterval(30 * 86400), isStarred: true)
        let unplanned = WorkTask(title: "Unplanned", dueAt: today.addingTimeInterval(-86400), isStarred: true)
        let ordinary = WorkTask(title: "Ordinary", plannedAt: today)
        let data = LedgerData(tasks: [unplanned, future, ordinary, current])
        let pending = tasks(data, in: .starred)

        XCTAssertTrue(TaskListPolicy.isTimeSensitive(.starred))
        for filter in [TaskPlanFilter.all, .thisWeek, .nextWeek, .week(today.addingTimeInterval(60 * 86400)), .unscheduled] {
            XCTAssertEqual(visible(pending, scope: .starred, filter: filter).map(\.id), [current.id, future.id, unplanned.id])
        }
    }

    func testStarredPriorityPreservesPendingBeforeCompletedAndExistingOrderWithinEachPartition() {
        let ordinary = WorkTask(title: "Ordinary", dueAt: today, plannedAt: today)
        let first = WorkTask(title: "First star", dueAt: today.addingTimeInterval(86400), createdAt: today.addingTimeInterval(-2), plannedAt: today, isStarred: true)
        let second = WorkTask(title: "Second star", dueAt: today.addingTimeInterval(2 * 86400), createdAt: today.addingTimeInterval(-1), plannedAt: today.addingTimeInterval(86400), isStarred: true)
        let done = WorkTask(title: "Recent done", completedAt: today)
        let starredDone = WorkTask(title: "Older starred done", completedAt: today.addingTimeInterval(-86400), isStarred: true)
        let input = [done, second, ordinary, starredDone, first]

        for scope in [SidebarItem.all, .upcoming, .overdue, .reminders, .tag(UUID())] {
            XCTAssertEqual(visible(input, scope: scope).map(\.id), [first.id, second.id, ordinary.id, starredDone.id, done.id])
        }
        XCTAssertEqual(visible([done, starredDone], scope: .completed).map(\.id), [starredDone.id, done.id])
    }

    func testTagNamesAreSearchableAndDoNotBypassTheSelectedWeek() {
        let tag = TaskTag(name: "Certificate renewals")
        let current = WorkTask(title: "Deploy", plannedAt: today, tagIDs: [tag.id])
        let unplanned = WorkTask(title: "Research", tagIDs: [tag.id])
        let other = WorkTask(title: "Unrelated", plannedAt: today)

        XCTAssertEqual(visible([current, unplanned, other], scope: .all, filter: .thisWeek,
                               tags: [tag], search: "certificate").map(\.id), [current.id])
        XCTAssertEqual(visible([current, unplanned, other], scope: .all, tags: [tag], search: "renewals").map(\.id), [current.id, unplanned.id])
        XCTAssertTrue(visible([other], scope: .all, tags: [tag], search: "certificate").isEmpty)
    }

    func testNavigationRetainsMatchingTagOrStarredScopeAndFollowsTagWeekChanges() throws {
        let tag = TaskTag(name: "Focus")
        let project = Project(name: "Operations")
        let task = WorkTask(projectID: project.id, title: "Task", plannedAt: today.addingTimeInterval(30 * 86400), tagIDs: [tag.id], isStarred: true)
        let tagged = TaskViewContext(scope: .tag(tag.id), filter: .thisWeek, search: "Draft")
        let starred = TaskViewContext(scope: .starred, filter: .all, search: "Draft")

        for action in [TaskNavigation.Action.created, .open] {
            let destination = try XCTUnwrap(TaskNavigation.destination(for: task, after: action, from: tagged, relativeTo: today, firstWeekday: 5))
            XCTAssertEqual(destination.scope, tagged.scope)
            XCTAssertTrue(destination.filter.includes(task, relativeTo: today, firstWeekday: 5))
            XCTAssertEqual(destination.search, "")
            XCTAssertEqual(TaskNavigation.destination(for: task, after: action, from: starred, relativeTo: today, firstWeekday: 5)?.scope, .starred)
            XCTAssertEqual(TaskNavigation.destination(for: task, after: action, from: starred, relativeTo: today, firstWeekday: 5)?.filter, .all)
        }
        XCTAssertEqual(TaskNavigation.destination(for: task, after: .planned, from: tagged, relativeTo: today, firstWeekday: 5)?.scope, tagged.scope)
        XCTAssertNil(TaskNavigation.destination(for: task, after: .planned, from: starred, relativeTo: today, firstWeekday: 5))
        XCTAssertNil(TaskNavigation.destination(for: task, after: .moved, from: tagged, relativeTo: today, firstWeekday: 5))

        let untagged = WorkTask(projectID: project.id, title: "Other")
        XCTAssertEqual(TaskNavigation.destination(for: untagged, after: .created, from: tagged, relativeTo: today, firstWeekday: 5)?.scope, .project(project.id))
        XCTAssertEqual(TaskNavigation.destination(for: untagged, after: .open, from: starred, relativeTo: today, firstWeekday: 5)?.scope, .project(project.id))
    }

    func testTagPreferenceKeysAndSlideDirectionRemainIndependentOfProjectAndOtherTags() {
        let first = UUID(), second = UUID()
        XCTAssertEqual(SidebarItem.starred.planFilterPreferenceKey, "starred")
        XCTAssertEqual(SidebarItem.tag(first).planFilterPreferenceKey, "tag.\(first.uuidString)")
        XCTAssertNotEqual(SidebarItem.tag(first).planFilterPreferenceKey, SidebarItem.project(first).planFilterPreferenceKey)
        let week = TaskViewContext(scope: .thisWeek, filter: .thisWeek, search: "")
        let starred = TaskViewContext(scope: .starred, filter: .all, search: "")
        let upcoming = TaskViewContext(scope: .upcoming, filter: .all, search: "")
        XCTAssertEqual(TaskListSlide.between(week, starred, projectIDs: []), .vertical(forward: true))
        XCTAssertEqual(TaskListSlide.between(upcoming, starred, projectIDs: []), .vertical(forward: false))
        let firstTag = TaskViewContext(scope: .tag(first), filter: .thisWeek, search: "")
        let secondTag = TaskViewContext(scope: .tag(second), filter: .all, search: "")
        XCTAssertEqual(TaskListSlide.between(firstTag, secondTag, projectIDs: [], tagIDs: [first, second]), .vertical(forward: true))
        XCTAssertEqual(TaskListSlide.between(secondTag, firstTag, projectIDs: [], tagIDs: [first, second]), .vertical(forward: false))
    }

    func testTagUndoPreservesLaterEditsAndRejectsRetagging() throws {
        let store = try temporaryStore()
        let first = try store.addTag(name: "First"), second = try store.addTag(name: "Second"), later = try store.addTag(name: "Later")
        let project = try store.addProject(name: "Project")
        let before = WorkTask(title: "Task", tagIDs: [first.id])
        try store.saveTask(before)
        try store.addTagToTask(id: before.id, tagID: second.id)
        let after = try XCTUnwrap(store.data.tasks.first)
        let undo = TaskOperationUndo.tags(before: before, after: after)
        try store.updateTask(id: before.id) { $0.notes = "Keep this"; $0.projectID = project.id; $0.isStarred = true }

        let restored = try undo.apply(to: store)
        XCTAssertEqual(restored.tagIDs, [first.id])
        XCTAssertEqual(restored.notes, "Keep this")
        XCTAssertEqual(restored.projectID, project.id)
        XCTAssertTrue(restored.isStarred)
        try store.addTagToTask(id: before.id, tagID: later.id)
        let changed = store.data
        XCTAssertThrowsError(try undo.apply(to: store))
        XCTAssertEqual(store.data, changed)
    }

    func testTagUndoCannotRestoreADeletedTagOrDeletedTask() throws {
        let store = try temporaryStore()
        let removed = try store.addTag(name: "Removed"), retained = try store.addTag(name: "Retained")
        let before = WorkTask(title: "Task", tagIDs: [removed.id])
        try store.saveTask(before)
        try store.updateTask(id: before.id) { $0.tagIDs = [retained.id] }
        let after = try XCTUnwrap(store.data.tasks.first)
        let undo = TaskOperationUndo.tags(before: before, after: after)
        _ = try store.deleteTag(id: removed.id)
        let changed = store.data
        XCTAssertThrowsError(try undo.apply(to: store))
        XCTAssertEqual(store.data, changed)
        _ = try store.deleteTask(id: before.id)
        XCTAssertThrowsError(try undo.apply(to: store))
        XCTAssertTrue(store.data.tasks.isEmpty)
    }

    private func temporaryStore() throws -> WorkStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaskTagPolicyTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try WorkStore(directory: directory)
    }
}
