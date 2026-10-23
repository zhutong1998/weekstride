import AppKit
import SwiftUI
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class TaskSystemListTests: XCTestCase {
    func testSystemListReusesVisibleCardsAndRealizesOnlyANearbySubset() async throws {
        try await withFixture { fixture in
            let scroll = try XCTUnwrap(self.taskScrollView(in: fixture.host))
            XCTAssertTrue(self.descendants(scroll).contains { $0 is NSTableView || $0 is NSCollectionView },
                          "The single-column task area must use the system list.")
            let original = fixture.store.data
            let bytes = try Data(contentsOf: fixture.dataURL)
            let initial = self.visibleProbes(in: scroll).mapValues { ObjectIdentifier($0) }
            XCTAssertFalse(initial.isEmpty, "The fixture must realize actual task cards.")
            XCTAssertLessThan(self.allProbes(in: scroll).count, 50, "A 200-task list must not host every task.")

            let initialOffset = scroll.contentView.bounds.origin.y
            self.scroll(scroll, to: initialOffset + 1)
            await self.settle(fixture.host)
            let nearby = self.visibleProbes(in: scroll)
            let common = Set(initial.keys).intersection(nearby.keys)
            XCTAssertFalse(common.isEmpty)
            for id in common {
                XCTAssertEqual(initial[id], nearby[id].map { ObjectIdentifier($0) },
                               "A small scroll must preserve the native subtree of an unchanged visible card.")
            }

            self.scroll(scroll, to: initialOffset + scroll.contentView.bounds.height)
            await self.settle(fixture.host)
            let moved = Set(self.visibleProbes(in: scroll).keys)
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y - initialOffset, 100)
            XCTAssertFalse(moved.subtracting(initial.keys).isEmpty, "Scrolling must reveal different task content.")
            XCTAssertLessThan(self.allProbes(in: scroll).count, 50)
            XCTAssertEqual(fixture.store.data, original)
            XCTAssertEqual(try Data(contentsOf: fixture.dataURL), bytes, "Scrolling must not save the task file.")
        }
    }

    func testOpenTaskRevealsAnInitiallyUnrealizedTask() async throws {
        try await withFixture { fixture in
            let target = try XCTUnwrap(fixture.store.data.tasks.last)
            let original = fixture.store.data
            let bytes = try Data(contentsOf: fixture.dataURL)
            XCTAssertNil(self.visibleProbes(in: fixture.host)[target.id])

            NotificationCenter.default.post(name: .init("WorkLedger.openTask"), object: target.id.uuidString)
            let revealed = await self.waitFor(fixture.host) {
                self.visibleProbes(in: fixture.host)[target.id] != nil
            }
            XCTAssertTrue(revealed, "Opening a task must scroll the system list to its string row identifier.")
            let scroll = try XCTUnwrap(self.taskScrollView(in: fixture.host))
            self.scroll(scroll, to: 0)
            await self.settle(fixture.host)
            XCTAssertNil(self.visibleProbes(in: fixture.host)[target.id])
            self.scroll(scroll, to: .greatestFiniteMagnitude)
            let remounted = await self.waitFor(fixture.host) { self.visibleProbes(in: fixture.host)[target.id] != nil }
            XCTAssertTrue(remounted)
            self.scroll(scroll, to: scroll.contentView.bounds.origin.y - scroll.contentView.bounds.height)
            await self.settle(fixture.host)
            await self.settle(fixture.host)
            XCTAssertNil(self.visibleProbes(in: fixture.host)[target.id], "An old reveal must not recenter a manually scrolled list.")
            let bottomGap = (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.maxY
            XCTAssertGreaterThan(bottomGap, scroll.contentView.bounds.height / 2,
                                 "The viewport must remain away from the old reveal at the bottom.")
            XCTAssertEqual(fixture.store.data, original)
            XCTAssertEqual(try Data(contentsOf: fixture.dataURL), bytes)
        }
    }

    func testDraftEditorRetainsFocusAndInputWhileASiblingMoves() async throws {
        try await withFixture(taskCount: 8) { fixture in
            let count = fixture.store.data.tasks.count
            let sibling = try XCTUnwrap(fixture.store.data.tasks.last)
            NotificationCenter.default.post(name: .init("WorkLedger.newTask"), object: nil)
            let appeared = await self.waitFor(fixture.host) { self.draftTitleField(in: fixture.host) != nil }
            XCTAssertTrue(appeared)
            let field = try XCTUnwrap(self.draftTitleField(in: fixture.host))
            XCTAssertTrue(fixture.window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText("Retained draft", replacementRange: editor.selectedRange())
            await self.settle(fixture.host)
            var expected = "Retained draft"

            for update in 1...3 {
                let selection = NSRange(location: (expected as NSString).length, length: 0)
                editor.setSelectedRange(selection)
                try fixture.store.updateTask(id: sibling.id) {
                    $0.dueAt = Date(timeIntervalSince1970: 1_900_000_000 + Double(update) * 86_400)
                }
                await self.settle(fixture.host)
                XCTAssertTrue(self.draftTitleField(in: fixture.host) === field)
                XCTAssertTrue(field.currentEditor() === editor)
                XCTAssertTrue(fixture.window.firstResponder === editor)
                XCTAssertEqual(editor.string, expected)
                XCTAssertEqual(editor.selectedRange(), selection)

                let suffix = " + \(update)"
                editor.insertText(suffix, replacementRange: editor.selectedRange())
                expected += suffix
                await self.settle(fixture.host)
                XCTAssertEqual(editor.string, expected, "Typing must continue after an unrelated row moves.")
                XCTAssertEqual(fixture.store.data.tasks.count, count, "A sibling update must not finish the new-task draft.")
            }
        }
    }

    func testScrollingDraftOffscreenDoesNotFinishItsEditingSession() async throws {
        try await withFixture { fixture in
            let original = fixture.store.data
            let draftID = try await self.editAndScrollDraftOffscreen(fixture)

            self.scroll(try XCTUnwrap(self.taskScrollView(in: fixture.host)), to: 0)
            let returned = await self.waitFor(fixture.host) { self.visibleProbes(in: fixture.host)[draftID] != nil }
            XCTAssertTrue(returned, "The same draft must remain available after scrolling back.")
            let returnedTitle = self.draftTitleField(in: fixture.host)
            XCTAssertNotNil(returnedTitle, "The draft title must return as an open editor.")
            XCTAssertEqual(returnedTitle?.stringValue, "Retained scrolling draft")
            let returnedStep = self.descendants(fixture.host).compactMap { $0 as? NSTextField }
                .first { $0.isEditable && $0.placeholderString == L("步骤名称") }
            XCTAssertNotNil(returnedStep, "The unfinished step editor must remain open.")
            XCTAssertEqual(returnedStep?.stringValue, "Keep this unfinished step")
            if let returnedTitle {
                try await self.replaceText("Retained scrolling draft + continued", in: returnedTitle, fixture: fixture)
                XCTAssertEqual(returnedTitle.currentEditor()?.string, "Retained scrolling draft + continued")
            }
            XCTAssertTrue(fixture.store.data == original, "Scrolling back must leave the draft uncommitted.")
        }
    }

    func testFinishRequestCommitsOffscreenDraftAndItsStep() async throws {
        try await withFixture { fixture in
            let count = fixture.store.data.tasks.count
            let draftID = try await self.editAndScrollDraftOffscreen(fixture)
            let request = TaskEditingExitRequest()
            NotificationCenter.default.post(name: finishTaskEdits, object: request)
            XCTAssertFalse(request.failed)
            await self.settle(fixture.host)
            XCTAssertEqual(fixture.store.data.tasks.count, count + 1)
            try self.assertSavedDraft(draftID, fixture: fixture)
        }
    }

    func testDetachingRootCommitsOffscreenDraftAndItsStep() async throws {
        try await withFixture { fixture in
            let count = fixture.store.data.tasks.count
            let draftID = try await self.editAndScrollDraftOffscreen(fixture)
            fixture.window.contentView = nil
            let saved = await self.waitFor(fixture.host) { fixture.store.data.tasks.contains { $0.id == draftID } }
            XCTAssertTrue(saved, "Removing the root must finish an offscreen draft before its handlers disappear.")
            XCTAssertEqual(fixture.store.data.tasks.count, count + 1)
            try self.assertSavedDraft(draftID, fixture: fixture)
        }
    }

    func testSeveralEditedCardsKeepTheirDraftsWithoutRetainingEveryNativeRow() async throws {
        let registry = TaskEditingRegistry()
        defer { registry.removeAll() }
        try await withFixture(editingRegistry: registry) { fixture in
            let visibleIDs = Set(self.visibleProbes(in: fixture.host).keys)
            let tasks = Array(fixture.store.data.tasks.filter { visibleIDs.contains($0.id) }.prefix(3))
            XCTAssertEqual(tasks.count, 3)
            var sessions: [UUID: InlineTextEditingState] = [:]
            for task in tasks {
                let session = self.openTitleSession(for: task, registry: registry, store: fixture.store)
                sessions[task.id] = session
                let opened = await self.waitFor(fixture.host) { self.titleField(with: task.title, in: fixture.host) != nil }
                XCTAssertTrue(opened)
                let field = try XCTUnwrap(self.titleField(with: task.title, in: fixture.host))
                try await self.replaceText("Edited \(task.title)", in: field, fixture: fixture)
                XCTAssertTrue(fixture.window.makeFirstResponder(nil))
                await self.settle(fixture.host)
            }

            let scroll = try XCTUnwrap(self.taskScrollView(in: fixture.host))
            self.scroll(scroll, to: .greatestFiniteMagnitude)
            await self.settle(fixture.host)
            await self.settle(fixture.host)
            let remainingVisible = Set(self.visibleProbes(in: fixture.host).keys)
            XCTAssertTrue(tasks.allSatisfy { !remainingVisible.contains($0.id) })
            XCTAssertLessThan(self.allProbes(in: fixture.host).count, 50,
                              "Editing several cards must not disable native row recycling for all 200 tasks.")
            for task in tasks {
                XCTAssertTrue(sessions[task.id]?.active == true)
                XCTAssertEqual(sessions[task.id]?.draft, "Edited \(task.title)")
            }

            self.scroll(scroll, to: 0)
            for task in tasks {
                let remounted = await self.waitFor(fixture.host) {
                    self.titleField(with: "Edited \(task.title)", in: fixture.host) != nil
                }
                XCTAssertTrue(remounted, "Every edited card must return with its title editor still open.")
                XCTAssertTrue(registry.state(for: task, isDraft: false, initiallyExpanded: false).fields["title"] === sessions[task.id])
            }
            XCTAssertLessThan(self.allProbes(in: fixture.host).count, 50)
        }
    }

    func testInvalidExistingTitleBlocksOffscreenFinishAndCanBeCorrectedAfterRemount() async throws {
        let registry = TaskEditingRegistry()
        defer { registry.removeAll() }
        try await withFixture(editingRegistry: registry) { fixture in
            let task = try XCTUnwrap(fixture.store.data.tasks.first)
            let session = self.openTitleSession(for: task, registry: registry, store: fixture.store)
            let opened = await self.waitFor(fixture.host) { self.titleField(with: task.title, in: fixture.host) != nil }
            XCTAssertTrue(opened)
            try await self.replaceText("", in: XCTUnwrap(self.titleField(with: task.title, in: fixture.host)), fixture: fixture)
            XCTAssertTrue(fixture.window.makeFirstResponder(nil))
            await self.settle(fixture.host)
            let scroll = try XCTUnwrap(self.taskScrollView(in: fixture.host))
            self.scroll(scroll, to: .greatestFiniteMagnitude)
            await self.settle(fixture.host)
            await self.settle(fixture.host)
            XCTAssertNil(self.visibleProbes(in: fixture.host)[task.id])

            let invalid = TaskEditingExitRequest()
            NotificationCenter.default.post(name: finishTaskEdits, object: invalid)
            XCTAssertTrue(invalid.failed, "An offscreen required title must still block finishing the edit session.")
            XCTAssertTrue(session.active)
            XCTAssertEqual(session.draft, "")
            XCTAssertEqual(fixture.store.data.tasks.first { $0.id == task.id }?.title, task.title)

            self.scroll(scroll, to: 0)
            let returned = await self.waitFor(fixture.host) { self.titleField(with: "", in: fixture.host) != nil }
            XCTAssertTrue(returned, "The invalid title must return as the same editable draft.")
            let field = try XCTUnwrap(self.titleField(with: "", in: fixture.host))
            try await self.replaceText("Corrected existing task title", in: field, fixture: fixture)
            let corrected = TaskEditingExitRequest(taskID: task.id)
            NotificationCenter.default.post(name: finishTaskEdits, object: corrected)
            XCTAssertFalse(corrected.failed)
            await self.settle(fixture.host)
            XCTAssertEqual(fixture.store.data.tasks.count, 200)
            XCTAssertEqual(fixture.store.data.tasks.first { $0.id == task.id }?.title, "Corrected existing task title")
            let persisted = try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: fixture.dataURL))
            XCTAssertEqual(persisted.tasks.first { $0.id == task.id }?.title, "Corrected existing task title")
        }
    }

    func testRegistryResetExpansionPreservesActiveEditorDrafts() {
        let registry = TaskEditingRegistry()
        defer { registry.removeAll() }
        let first = WorkTask(title: "Expanded task"), second = WorkTask(title: "Collapsed task")
        let expanded = registry.state(for: first, isDraft: false, initiallyExpanded: true)
        let collapsed = registry.state(for: second, isDraft: false, initiallyExpanded: false)
        collapsed.expandedOverride = false
        let field = titleSession(for: first)
        field.draft = "Uncommitted title"
        expanded.fields["title"] = field

        registry.resetExpansion()

        XCTAssertNil(expanded.expandedOverride)
        XCTAssertNil(collapsed.expandedOverride)
        XCTAssertTrue(registry.state(for: first, isDraft: false, initiallyExpanded: false) === expanded)
        XCTAssertTrue(expanded.fields["title"] === field)
        XCTAssertTrue(field.active)
        XCTAssertEqual(field.draft, "Uncommitted title")
    }

    func testRegistryPruningAndRemovalReleaseModelsFieldsAndFinishHandlers() {
        var registry: TaskEditingRegistry? = TaskEditingRegistry()
        weak var weakRegistry = registry
        let first = WorkTask(title: "Retained task"), second = WorkTask(title: "Removed task")
        var kept = registry?.state(for: first, isDraft: false, initiallyExpanded: false)
        var removed = registry?.state(for: second, isDraft: false, initiallyExpanded: false)
        weak var weakRemoved = removed
        var field: InlineTextEditingState? = titleSession(for: second)
        weak var weakField = field
        removed?.fields["title"] = field
        var captured: NSObject? = NSObject()
        weak var weakCaptured = captured
        removed?.finishHandler = { [held = captured!] in held.isEqual(held) }
        captured = nil
        XCTAssertNotNil(weakCaptured)

        registry?.retainTasks([first.id])

        XCTAssertTrue(registry?.state(for: first, isDraft: false, initiallyExpanded: false) === kept)
        XCTAssertNil(removed?.finishHandler)
        XCTAssertTrue(removed?.fields.isEmpty == true)
        XCTAssertTrue(field?.discarded == true)
        XCTAssertNil(weakCaptured, "Pruning must release the finish closure even while the old model is externally retained.")
        field = nil; removed = nil
        XCTAssertNil(weakField)
        XCTAssertNil(weakRemoved)

        weak var weakKept = kept
        kept?.fields["title"] = titleSession(for: first)
        registry?.removeAll()
        XCTAssertTrue(kept?.fields.isEmpty == true)
        kept = nil; registry = nil
        XCTAssertNil(weakKept)
        XCTAssertNil(weakRegistry, "The notification observer must not retain its registry.")
    }

    private struct Fixture {
        let store: WorkStore
        let dataURL: URL
        let window: NSWindow
        let host: NSHostingView<AnyView>
    }

    private func withFixture(taskCount: Int = 200, editingRegistry: TaskEditingRegistry? = nil,
                             _ test: (Fixture) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let filter = try JSONEncoder().encode(TaskPlanFilter.all)
        let display = try JSONEncoder().encode(TaskDisplaySetting(columns: .one, details: .expanded))
        defaults.setVolatileDomain(arguments.merging([
            "appLanguage": "en", "appTextSize": "standard", "appTimeFormat": "24",
            "taskColumns": "one", "taskDetails": "expanded", "taskListEffect": "none",
            "taskPlanFilter.all": filter, "taskDisplay.all": display,
            "apiEnabled": false, "remindersEnabled": false
        ]) { _, value in value }, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }

        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("TaskSystemListTests-\(UUID())")
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let tasks = (0..<taskCount).map { index in
            WorkTask(title: "Synthetic task \(index + 1)", details: "Review the result and retain the next action.",
                     subtasks: [Subtask(title: "Verify the result"), Subtask(title: "Record the outcome")],
                     createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        let dataURL = directory.appendingPathComponent("data.json")
        try JSONEncoder().encode(LedgerData(tasks: tasks)).write(to: dataURL)
        let store = try WorkStore(directory: directory)
        let services = AppServices(store: store, recoveryMode: true)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let content: AnyView
        if let editingRegistry {
            content = AnyView(List(store.data.tasks) { task in
                VStack(alignment: .leading, spacing: 0) {
                    ObservedTaskCard(store: store, task: task, project: nil, isHistory: false,
                                     editingState: editingRegistry.state(for: task, isDraft: false, initiallyExpanded: false))
                }
                .padding(.bottom, 4)
                .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }.listStyle(.plain).environment(\.taskDetailsMode, .expanded).environment(\.taskListPreservesEditing, true))
        } else { content = AnyView(RootView(store: store)) }
        let root = content.environmentObject(store).environmentObject(services)
            .environment(\.locale, Locale(identifier: "en")).environment(\.appTextScale, 1)
            .environment(\.colorScheme, .light).appFont(.body)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = NSHostingView(rootView: AnyView(root))
        window.contentView = host
        window.layoutIfNeeded()
        await settle(host)
        await settle(host)
        try await test(Fixture(store: store, dataURL: dataURL, window: window, host: host))
        XCTAssertFalse(window.isVisible, "System-list fixtures must never show or activate a desktop window.")
        XCTAssertFalse(files.fileExists(atPath: directory.appendingPathComponent("api-token").path))
    }

    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
    }

    private func replaceText(_ value: String, in field: NSTextField, fixture: Fixture) async throws {
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText(value, replacementRange: editor.selectedRange())
        await settle(fixture.host)
    }

    private func editAndScrollDraftOffscreen(_ fixture: Fixture) async throws -> UUID {
        let original = fixture.store.data
        NotificationCenter.default.post(name: .init("WorkLedger.newTask"), object: nil)
        let appeared = await waitFor(fixture.host) { self.draftTitleField(in: fixture.host) != nil }
        XCTAssertTrue(appeared)
        try await replaceText("Retained scrolling draft", in: XCTUnwrap(draftTitleField(in: fixture.host)), fixture: fixture)
        let step = try XCTUnwrap(descendants(fixture.host).compactMap { $0 as? NSTextField }
            .first { $0.isEditable && $0.placeholderString == L("步骤名称") })
        try await replaceText("Keep this unfinished step", in: step, fixture: fixture)
        let existingIDs = Set(original.tasks.map(\.id))
        let draftID = try XCTUnwrap(visibleProbes(in: fixture.host).keys.first { !existingIDs.contains($0) })
        let scroll = try XCTUnwrap(taskScrollView(in: fixture.host))
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        await settle(fixture.host)
        self.scroll(scroll, to: .greatestFiniteMagnitude)
        await settle(fixture.host)
        await settle(fixture.host)
        let offscreen = visibleProbes(in: fixture.host)[draftID] == nil
        let retainedNativeView = allProbes(in: fixture.host).contains { $0.taskID == draftID }
        print("Draft scroll lifecycle: offscreen=\(offscreen), retainedNativeView=\(retainedNativeView), persistedTaskCount=\(fixture.store.data.tasks.count)")
        XCTAssertTrue(offscreen, "The test must move the edited draft outside the viewport.")
        XCTAssertTrue(fixture.store.data == original, "Scrolling must leave the new-task draft uncommitted.")
        return draftID
    }

    private func assertSavedDraft(_ id: UUID, fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let saved = try XCTUnwrap(fixture.store.data.tasks.first { $0.id == id }, file: file, line: line)
        XCTAssertEqual(saved.title, "Retained scrolling draft", file: file, line: line)
        XCTAssertEqual(saved.subtasks.map(\.title), ["Keep this unfinished step"], file: file, line: line)
        let persisted = try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: fixture.dataURL))
        XCTAssertEqual(persisted.tasks.first { $0.id == id }, saved, "Finishing must save the draft to disk.", file: file, line: line)
    }

    private func openTitleSession(for task: WorkTask, registry: TaskEditingRegistry, store: WorkStore) -> InlineTextEditingState {
        let session = titleSession(for: task,
                                   onSave: { value in try store.updateTask(id: task.id) { $0.title = value } },
                                   onFailure: { store.errorMessage = $0 })
        registry.state(for: task, isDraft: false, initiallyExpanded: false).fields["title"] = session
        return session
    }

    private func titleSession(for task: WorkTask, onSave: @escaping (String) throws -> Void = { _ in },
                              onFailure: @escaping (String) -> Void = { _ in }) -> InlineTextEditingState {
        let input = InlineEditableText.Input(
            text: task.title, placeholder: L("任务名称"), help: L("点击修改任务名称，回车保存任务"),
            multiline: false, required: true, font: .body, showsHoverBackground: true,
            taskID: task.id, sessionID: "title", saveOnBlur: false, allowEmpty: false, avoidsInitialSelection: true,
            onEmptySave: nil, onNextStep: nil, onEditingChanged: { _ in }, onDraftChange: { _ in },
            onSave: onSave, onFailure: onFailure)
        return InlineTextEditingState(input: input)
    }

    private func waitFor(_ host: NSView, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<30 {
            await settle(host)
            if condition() { return true }
        }
        return false
    }

    private func scroll(_ scroll: NSScrollView, to offset: CGFloat) {
        let clip = scroll.contentView
        let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(maximum, max(0, offset))))
        scroll.reflectScrolledClipView(clip)
    }

    private func taskScrollView(in host: NSView) -> NSScrollView? {
        descendants(host).compactMap { $0 as? NSScrollView }
            .filter { $0.contentView.bounds.width > 500 && ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1 }
            .max { $0.contentView.bounds.width < $1.contentView.bounds.width }
    }

    private func allProbes(in host: NSView) -> [TaskNativeDragSource.ProbeView] {
        descendants(host).compactMap { $0 as? TaskNativeDragSource.ProbeView }
    }

    private func visibleProbes(in host: NSView) -> [UUID: TaskNativeDragSource.ProbeView] {
        allProbes(in: host).reduce(into: [:]) { result, probe in
            if let id = probe.taskID, !probe.isHiddenOrHasHiddenAncestor,
               !probe.bounds.intersection(probe.visibleRect).isEmpty { result[id] = probe }
        }
    }

    private func draftTitleField(in host: NSView) -> NSTextField? {
        descendants(host).compactMap { $0 as? NSTextField }
            .first { $0.isEditable && $0.placeholderString == L("任务名称") }
    }

    private func titleField(with text: String, in host: NSView) -> NSTextField? {
        descendants(host).compactMap { $0 as? NSTextField }
            .first { $0.isEditable && $0.placeholderString == L("任务名称") && $0.stringValue == text }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
