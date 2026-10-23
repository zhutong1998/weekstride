import AppKit
import SwiftUI
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class TaskNavigationStateTests: XCTestCase {
    func testProjectNavigationLoadsItsDisplayAndKeepsTheRequestedFilter() async throws {
        try await withFixture { fixture in
            self.open(fixture.firstCurrent)
            await self.assertEventually(fixture.host, "Opening the first project must use its two-column, titles-only setting and the task's current-week filter.") {
                let cards = self.visibleCards(in: fixture.host)
                guard let target = cards[fixture.firstCurrent.id], let peer = cards[fixture.firstPeer.id] else { return false }
                return Set(cards.keys) == [fixture.firstCurrent.id, fixture.firstPeer.id]
                    && target.bounds.width < 750 && peer.bounds.height < 110
            }

            let scope = SidebarItem.project(fixture.firstProject.id).planFilterPreferenceKey
            try self.setFilter(.all, for: scope)
            await self.assertEventually(fixture.host, "Changing a tab must preserve the project's display setting.") {
                let cards = self.visibleCards(in: fixture.host)
                return Set(cards.keys) == Set(fixture.firstProjectTasks.map(\.id))
                    && cards[fixture.firstPeer.id].map { $0.bounds.width < 750 && $0.bounds.height < 110 } == true
            }

            self.open(fixture.secondCurrent)
            await self.assertEventually(fixture.host, "The second project must use its own one-column, expanded setting and current-week filter.") {
                let cards = self.visibleCards(in: fixture.host)
                return Set(cards.keys) == [fixture.secondCurrent.id]
                    && cards[fixture.secondCurrent.id].map { $0.bounds.width > 800 && $0.bounds.height > 130 } == true
            }

            self.open(fixture.firstCurrent)
            await self.assertEventually(fixture.host, "Opening a task must use its requested week even if the project last viewed All.") {
                let cards = self.visibleCards(in: fixture.host)
                return Set(cards.keys) == [fixture.firstCurrent.id, fixture.firstPeer.id]
                    && cards[fixture.firstPeer.id].map { $0.bounds.width < 750 && $0.bounds.height < 110 } == true
            }

            NotificationCenter.default.post(name: .init("WorkLedger.showAll"), object: nil)
            await self.assertEventually(fixture.host, "Returning to All must restore the global one-column, expanded display.") {
                self.visibleCards(in: fixture.host)[fixture.firstCurrent.id].map {
                    $0.bounds.width > 800 && $0.bounds.height > 130
                } == true
            }
            XCTAssertEqual(fixture.store.data, fixture.original)
        }
    }

    func testProjectNavigationKeepsAnInvalidDraftAndWorksAfterItIsCorrected() async throws {
        try await withFixture { fixture in
            NotificationCenter.default.post(name: .init("WorkLedger.newTask"), object: nil)
            let originalIDs = Set(fixture.original.tasks.map(\.id))
            await self.assertEventually(fixture.host) {
                !Set(self.visibleCards(in: fixture.host).keys).subtracting(originalIDs).isEmpty
                    && self.editableFields(in: fixture.host).first != nil
            }
            let draftID = try XCTUnwrap(Set(self.visibleCards(in: fixture.host).keys).subtracting(originalIDs).first)
            let details = try XCTUnwrap(self.descendants(fixture.host).compactMap { $0 as? NSTextView }
                .first { $0.isEditable && !$0.isFieldEditor })
            XCTAssertTrue(fixture.window.makeFirstResponder(details))
            details.insertText("Keep these unfinished draft details.", replacementRange: NSRange(location: 0, length: 0))
            await self.settle(fixture.host)

            self.open(fixture.secondCurrent)
            await self.settle(fixture.host)
            XCTAssertNotNil(self.visibleCards(in: fixture.host)[draftID], "An untitled draft containing details must block project navigation.")
            XCTAssertEqual(fixture.store.data, fixture.original)

            let title = try XCTUnwrap(self.editableFields(in: fixture.host).first)
            XCTAssertTrue(fixture.window.makeFirstResponder(title))
            let editor = try XCTUnwrap(title.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText("Corrected navigation draft", replacementRange: editor.selectedRange())
            await self.settle(fixture.host)

            self.open(fixture.secondCurrent)
            await self.assertEventually(fixture.host, "A corrected draft must save before the requested project opens.") {
                Set(self.visibleCards(in: fixture.host).keys) == [fixture.secondCurrent.id]
            }
            let saved = try XCTUnwrap(fixture.store.data.tasks.first { $0.id == draftID })
            XCTAssertEqual(saved.title, "Corrected navigation draft")
            XCTAssertEqual(saved.details, "Keep these unfinished draft details.")
            XCTAssertEqual(fixture.store.data.tasks.count, fixture.original.tasks.count + 1)
        }
    }

    func testBlockedNavigationRevealsAnInvalidOffscreenDraft() async throws {
        try await withFixture(extraTaskCount: 200) { fixture in
            NotificationCenter.default.post(name: .init("WorkLedger.newTask"), object: nil)
            let originalIDs = Set(fixture.original.tasks.map(\.id))
            await self.assertEventually(fixture.host) {
                !Set(self.visibleCards(in: fixture.host).keys).subtracting(originalIDs).isEmpty
            }
            let draftID = try XCTUnwrap(Set(self.visibleCards(in: fixture.host).keys).subtracting(originalIDs).first)
            let details = try XCTUnwrap(self.descendants(fixture.host).compactMap { $0 as? NSTextView }
                .first { $0.isEditable && !$0.isFieldEditor })
            XCTAssertTrue(fixture.window.makeFirstResponder(details))
            details.insertText("Recover this offscreen draft.", replacementRange: NSRange(location: 0, length: 0))
            await self.settle(fixture.host)
            XCTAssertTrue(fixture.window.makeFirstResponder(nil))
            let scroll = try XCTUnwrap(self.descendants(fixture.host).compactMap { $0 as? NSScrollView }
                .filter { $0.contentView.bounds.width > 500 }
                .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height)))
            scroll.reflectScrolledClipView(clip)
            await self.assertEventually(fixture.host, "The invalid draft must leave the viewport before testing recovery.") {
                self.visibleCards(in: fixture.host)[draftID] == nil
            }

            self.open(fixture.secondCurrent)
            await self.assertEventually(fixture.host, "Blocked project navigation must reveal the editor that requires correction.") {
                self.visibleCards(in: fixture.host)[draftID] != nil && !self.editableFields(in: fixture.host).isEmpty
            }
            XCTAssertTrue(fixture.store.data == fixture.original, "A failed navigation cannot commit an untitled draft.")
            let title = try XCTUnwrap(self.editableFields(in: fixture.host).first)
            XCTAssertTrue(fixture.window.makeFirstResponder(title))
            let editor = try XCTUnwrap(title.currentEditor() as? NSTextView)
            editor.insertText("Recovered navigation draft", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            await self.settle(fixture.host)
            self.open(fixture.secondCurrent)
            await self.assertEventually(fixture.host) {
                Set(self.visibleCards(in: fixture.host).keys) == [fixture.secondCurrent.id]
            }
            let saved = try XCTUnwrap(fixture.store.data.tasks.first { $0.id == draftID })
            XCTAssertEqual(saved.title, "Recovered navigation draft")
            XCTAssertEqual(saved.details, "Recover this offscreen draft.")
        }
    }

    func testCompletedOnlyEmptySavedFilterCanReturnToAllTasks() async throws {
        try await withFixture(completedOnly: true, initialFilter: .nextWeek) { fixture in
            XCTAssertTrue(self.visibleCards(in: fixture.host).isEmpty,
                          "Completed tasks from this week must not appear in the saved Next Week filter.")
            NotificationCenter.default.post(name: .init("WorkLedger.showAll"), object: nil)
            await self.assertEventually(fixture.host, "Returning to All Tasks must reveal completed tasks hidden by a saved non-All filter.") {
                !self.visibleCards(in: fixture.host).isEmpty
            }
            XCTAssertTrue(Set(self.visibleCards(in: fixture.host).keys).isSubset(of: Set(fixture.original.tasks.map(\.id))))
            XCTAssertEqual(fixture.store.data, fixture.original)
        }
    }

    private struct Fixture {
        let store: WorkStore
        let original: LedgerData
        let firstProject: Project
        let firstProjectTasks: [WorkTask]
        let firstCurrent: WorkTask
        let firstPeer: WorkTask
        let secondCurrent: WorkTask
        let window: NSWindow
        let host: NSHostingView<AnyView>
    }

    private func withFixture(extraTaskCount: Int = 0, completedOnly: Bool = false, initialFilter: TaskPlanFilter = .all,
                             _ test: (Fixture) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        let first = Project(name: "Compact project", colorHex: "168C83")
        let second = Project(name: "Detailed project", colorHex: "3478F6")
        let today = Calendar.current.startOfDay(for: Date())
        let current = TaskPlanning.weekDate(offset: 0, relativeTo: today, firstWeekday: 6)
        let next = TaskPlanning.weekDate(offset: 1, relativeTo: today, firstWeekday: 6)
        func task(_ title: String, project: Project, plan: Date?, order: Int) -> WorkTask {
            WorkTask(projectID: project.id, title: title, details: "Check the full task details.\nRetain this second line.",
                     notes: "Record the result and the next action.",
                     subtasks: [Subtask(title: "Verify the result"), Subtask(title: "Record the outcome")],
                     createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(order)),
                     plannedAt: plan, planGranularity: plan == nil ? nil : .week)
        }
        let firstTasks = [task("First current task", project: first, plan: current, order: 0),
                          task("First current peer", project: first, plan: current, order: 1),
                          task("First next-week task", project: first, plan: next, order: 2),
                          task("First unscheduled task", project: first, plan: nil, order: 3)]
        let secondTasks = [task("Second current task", project: second, plan: current, order: 4),
                           task("Second next-week task", project: second, plan: next, order: 5)]
        var tasks = firstTasks + secondTasks + (0..<extraTaskCount).map {
            task("Scrolling fixture \($0)", project: first, plan: current, order: $0 + 6)
        }
        if completedOnly { tasks = tasks.map { var task = $0; task.completedAt = today; return task } }
        let original = LedgerData(projects: [first, second], tasks: tasks)
        let encoder = JSONEncoder()
        var domain: [String: Any] = ["appLanguage": "en", "appTextSize": "standard", "weekStart": 6,
                                     "taskColumns": "one", "taskDetails": "expanded", "taskListEffect": "none",
                                     "apiEnabled": false, "remindersEnabled": false]
        for (scope, setting) in [(SidebarItem.all, TaskDisplaySetting(columns: .one, details: .expanded)),
                                  (.project(first.id), TaskDisplaySetting(columns: .two, details: .titles)),
                                  (.project(second.id), TaskDisplaySetting(columns: .one, details: .expanded))] {
            domain["taskDisplay.\(scope.planFilterPreferenceKey)"] = try encoder.encode(setting)
            domain["taskPlanFilter.\(scope.planFilterPreferenceKey)"] = try encoder.encode(TaskPlanFilter.all)
        }
        domain["taskPlanFilter.all"] = try encoder.encode(initialFilter)
        defaults.setVolatileDomain(arguments.merging(domain) { _, fixture in fixture }, forName: UserDefaults.argumentDomain)
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("WeekStride-navigation-state-\(UUID())")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        try encoder.encode(original).write(to: directory.appendingPathComponent("data.json"))
        let store = try WorkStore(directory: directory)
        let services = AppServices(store: store, recoveryMode: true)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1520, height: 1100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let root = RootView(store: store).environmentObject(store).environmentObject(services)
            .environment(\.locale, Locale(identifier: "en")).environment(\.appTextScale, 1)
            .environment(\.colorScheme, .light).appFont(.body)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = NSHostingView(rootView: AnyView(root))
        window.contentView = host
        window.layoutIfNeeded()
        await settle(host)
        await settle(host)
        try await test(Fixture(store: store, original: original, firstProject: first, firstProjectTasks: firstTasks,
                               firstCurrent: firstTasks[0], firstPeer: firstTasks[1], secondCurrent: secondTasks[0], window: window, host: host))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(files.fileExists(atPath: directory.appendingPathComponent("api-token").path))
    }

    private func open(_ task: WorkTask) {
        NotificationCenter.default.post(name: .init("WorkLedger.openTask"), object: task.id.uuidString)
    }

    private func setFilter(_ filter: TaskPlanFilter, for scope: String) throws {
        let defaults = UserDefaults.standard
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["taskPlanFilter.\(scope)"] = try JSONEncoder().encode(filter)
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: .init("WorkLedger.viewPreferencesChanged"), object: scope)
    }

    private func visibleCards(in view: NSView) -> [UUID: TaskNativeDragSource.ProbeView] {
        var result: [UUID: TaskNativeDragSource.ProbeView] = [:]
        for case let probe as TaskNativeDragSource.ProbeView in descendants(view) {
            if let id = probe.taskID, !probe.isHiddenOrHasHiddenAncestor,
               !probe.bounds.intersection(probe.visibleRect).isEmpty { result[id] = probe }
        }
        return result
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        descendants(view).compactMap { $0 as? NSTextField }.filter { $0.isEditable && !($0 is NSSearchField) }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(25))
        host.layoutSubtreeIfNeeded()
    }

    private func waitFor(_ host: NSView, _ predicate: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if predicate() { return true }
            await settle(host)
        }
        return predicate()
    }

    private func assertEventually(_ host: NSView, _ message: String = "", file: StaticString = #filePath,
                                  line: UInt = #line, _ predicate: () -> Bool) async {
        let matched = await waitFor(host, predicate)
        XCTAssertTrue(matched, message, file: file, line: line)
    }
}
