import AppKit
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class RegistryLifecycleTests: XCTestCase {
    func testTerminationFinishesRegistryOnlyEditorAndPersistsItsValidDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WeekStride-registry-lifecycle-\(UUID())")
        let store = try WorkStore(directory: directory)
        let registry = TaskEditingRegistry()
        defer { registry.removeAll(); try? FileManager.default.removeItem(at: directory) }
        let draft = TaskDraftStorage()
        let task = WorkTask(title: "Synthetic unfinished draft")
        draft.task = task
        let state = registry.state(for: task, isDraft: true, initiallyExpanded: false)
        let field = InlineTextEditingState(input: InlineEditableText.Input(
            text: task.title, placeholder: "Title", help: "Edit title", multiline: false, required: true,
            font: .body, showsHoverBackground: true, taskID: task.id, sessionID: "title", saveOnBlur: true,
            allowEmpty: false, avoidsInitialSelection: true, onEmptySave: nil, onNextStep: nil,
            onEditingChanged: { _ in }, onDraftChange: { _ in },
            onSave: { value in draft.update(taskID: task.id) { $0.title = value } }, onFailure: { _ in }))
        field.draft = "Valid retained draft at termination"
        state.fields["title"] = field
        var finishCount = 0
        var persistenceError: Error?
        state.finishHandler = { [weak state] in
            finishCount += 1
            guard let state, state.flushFields(finish: true), let candidate = draft.task else { return false }
            do {
                try store.saveTask(candidate)
                state.finishHandler = nil
                return true
            } catch { persistenceError = error; return false }
        }

        XCTAssertTrue(store.data.tasks.isEmpty, "The registry-only draft must remain uncommitted before termination")
        // No native view or TaskCard notification observer exists in this fixture.
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(finishCount, 1)
        XCTAssertNil(persistenceError)
        XCTAssertFalse(field.active)
        XCTAssertEqual(store.data.tasks.first { $0.id == task.id }?.title, "Valid retained draft at termination")
        let persisted = try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: directory.appendingPathComponent("data.json")))
        XCTAssertEqual(persisted.tasks.first { $0.id == task.id }, store.data.tasks.first { $0.id == task.id })
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(finishCount, 1, "A finished session must not be committed twice")
    }

    func testNotificationObserversDoNotRetainReleasedRegistryOrItsHandlers() {
        weak var releasedRegistry: TaskEditingRegistry?
        weak var releasedState: TaskCardEditingState?
        var finishCount = 0
        do {
            let registry = TaskEditingRegistry()
            releasedRegistry = registry
            let state = registry.state(for: WorkTask(title: "Synthetic released session"), isDraft: false, initiallyExpanded: false)
            releasedState = state
            state.finishHandler = { finishCount += 1; return true }
        }
        XCTAssertNil(releasedRegistry)
        XCTAssertNil(releasedState)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.post(name: finishTaskEdits, object: TaskEditingExitRequest())
        XCTAssertEqual(finishCount, 0)
    }
}
