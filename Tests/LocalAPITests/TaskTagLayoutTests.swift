import Foundation
import XCTest
import WorkLedgerCore
@testable import WorkLedger

final class TaskTagLayoutTests: XCTestCase {
    @MainActor func testStarredCardsPrecedeEveryProjectAndWeekGroupWithoutDuplicatingTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let first = try store.addProject(name: "First"), second = try store.addProject(name: "Second")
        let today = Calendar.current.startOfDay(for: Date())
        let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: today)!
        let ordinary = WorkTask(projectID: first.id, title: "Ordinary", plannedAt: today)
        let futureStar = WorkTask(projectID: second.id, title: "Future starred", plannedAt: nextMonth, isStarred: true)
        let unassignedStar = WorkTask(title: "Unassigned starred", isStarred: true)
        let completedStar = WorkTask(projectID: first.id, title: "Completed starred", completedAt: today, isStarred: true)
        for task in [ordinary, futureStar, unassignedStar, completedStar] { try store.saveTask(task) }
        let ordered = TaskListPolicy.visibleTasks(store.data.tasks, projects: store.data.projects, scope: .all,
                                                  filter: .all, search: "", relativeTo: today, firstWeekday: 5)
        let rows = TaskListRow.rows(for: ordered, projects: store.data.projects, scope: .all, filter: .all, relativeTo: today, firstWeekday: 5)
        let cards = rows.compactMap { row -> WorkTask? in
            if case .task(let task, _) = row { return task }
            return nil
        }
        XCTAssertEqual(Set(cards.prefix(2).map(\.id)), [futureStar.id, unassignedStar.id])
        XCTAssertEqual(cards[2].id, ordinary.id)
        XCTAssertEqual(cards.last?.id, completedStar.id)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(Set(cards.map(\.id)), Set(store.data.tasks.map(\.id)))
        let gridCards = TaskGridSection.grouped(rows).flatMap(\.tasks).compactMap { row -> UUID? in
            if case .task(let task, _) = row { return task.id }
            return nil
        }
        XCTAssertEqual(gridCards, cards.map(\.id))
    }

    func testStarAndTagChangesRefreshMembershipButOrdinaryTextEditsStayLocal() {
        let tag = TaskTag(name: "Operations")
        var data = LedgerData(tasks: [WorkTask(title: "Task")], tags: [tag])
        let before = TaskListStructure(data: data)
        data.tasks[0].isStarred = true
        XCTAssertNotEqual(before, TaskListStructure(data: data))
        let starred = TaskListStructure(data: data)
        data.tasks[0].tagIDs = [tag.id]
        XCTAssertNotEqual(starred, TaskListStructure(data: data))
        let tagged = TaskListStructure(data: data)
        data.tasks[0].notes = "No membership change"
        XCTAssertEqual(tagged, TaskListStructure(data: data))
        XCTAssertEqual(TaskListStructure(data: data, search: "Operations").matchingTaskIDs, [data.tasks[0].id])
        data.tags[0].name = "Renewals"
        XCTAssertNotEqual(tagged, TaskListStructure(data: data))
        XCTAssertEqual(TaskListStructure(data: data, search: "Operations").matchingTaskIDs, [])
    }

    func testCompletedHistoryAlsoPrioritizesStarsAcrossProjects() {
        let first = Project(name: "First"), second = Project(name: "Second")
        let today = Calendar.current.startOfDay(for: Date())
        let ordinary = WorkTask(projectID: first.id, title: "Ordinary", completedAt: today)
        let star = WorkTask(projectID: second.id, title: "Star", completedAt: today, isStarred: true)
        let rows = TaskListRow.rows(for: [ordinary, star], projects: [first, second], scope: .completed,
                                    filter: .all, relativeTo: today, firstWeekday: 5)
        let ids = rows.compactMap { row -> UUID? in
            if case .task(let task, _) = row { return task.id }
            return nil
        }
        XCTAssertEqual(ids, [star.id, ordinary.id])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testActiveDraftRemainsAboveCardsAfterRemovingItsDefaultTagOrStar() {
        let today = Calendar.current.startOfDay(for: Date())
        let draft = WorkTask(title: "", tagIDs: [], isStarred: false)
        let star = WorkTask(title: "Saved star", isStarred: true)
        for scope in [SidebarItem.starred, .tag(UUID())] {
            let rows = TaskListRow.rows(for: [star], projects: [], scope: scope, filter: .thisWeek,
                                        relativeTo: today, firstWeekday: 5, draft: draft)
            if case .task(let first, _) = rows.first { XCTAssertEqual(first.id, draft.id) }
            else { XCTFail("An active draft must remain visible until saving or cancellation.") }
        }
    }

    func testTagAndStarControlsHaveEnglishAndChineseLabels() {
        XCTAssertEqual(AppLocalization.string("星标任务", languageIdentifier: "en"), "Starred")
        XCTAssertEqual(AppLocalization.string("新建标签", languageIdentifier: "en"), "New tag")
        XCTAssertEqual(AppLocalization.string("取消星标", languageIdentifier: "en"), "Unstar")
        XCTAssertEqual(AppLocalization.string("任务标签", languageIdentifier: "zh-Hans"), "任务标签")
    }
}
