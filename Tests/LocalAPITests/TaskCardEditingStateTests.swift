import Foundation
import AppKit
import SwiftUI
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class TaskCardEditingStateTests: XCTestCase {
    func testDeferredFooterPreservesEditingFocusGeometryAndAssistiveActions() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WeekStride-footer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let task = WorkTask(title: "Footer fixture", notes: "The task notes stay visible.")
        try store.saveTask(task)
        let original = store.data
        let bytes = try Data(contentsOf: directory.appendingPathComponent("data.json"))
        let state = TaskCardEditingState(task: task, isDraft: false)
        let services = AppServices(store: store, recoveryMode: true)
        func content(accessibilityEnabled: Bool) -> some View {
            VStack {
                TaskCard(store: store, task: task, project: nil, isHistory: false, editingState: state)
                Spacer(minLength: 0)
            }
            .environmentObject(store).environmentObject(services)
            .environment(\.taskDetailsMode, .expanded)
            .environment(\.accessibilityEnabled, accessibilityEnabled)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        }
        let host = NSHostingView(rootView: content(accessibilityEnabled: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        await settle(host)
        let probe = try XCTUnwrap(descendants(host).compactMap { $0 as? TaskNativeDragSource.ProbeView }.first)
        let height = probe.bounds.height
        XCTAssertGreaterThan(height, 60, "Deferring the controls must retain the expanded details.")

        state.editingBaseline = task
        await settle(host)
        XCTAssertNotNil(state.finishHandler, "The card must observe the editing session and register its save handler.")
        XCTAssertEqual(probe.bounds.height, height, accuracy: 1, "Footer mounting must not resize the task card.")

        state.focusDetailsOnAppear = true
        state.detailsEditing = true
        await settle(host)
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }
            .first { $0.isEditable && !$0.isFieldEditor })
        XCTAssertTrue(window.makeFirstResponder(editor))
        await settle(host)
        // Disabled accessibility does not provide a live AX tree; verify native editing here and AX actions below.
        XCTAssertTrue(window.firstResponder === editor, "Keyboard focus must remain in the actual task editor.")
        XCTAssertTrue(state.fields["details"]?.active == true, "The mounted editor must retain its input session.")
        XCTAssertNotNil(state.finishHandler, "The open editor must remain saveable while its footer is mounted.")

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertTrue(state.flushFields(finish: true))
        state.detailsEditing = false
        state.editorsOpen = false
        state.editingBaseline = nil
        await settle(host)
        XCTAssertNil(state.finishHandler)
        XCTAssertTrue(state.fields.isEmpty)
        XCTAssertEqual(probe.bounds.height, height, accuracy: 1)

        host.rootView = content(accessibilityEnabled: true)
        await settle(host)
        let actions = Set(accessibilityLabels(host))
        XCTAssertTrue(Set([L("任务标签"), L("添加任务明细"), L("添加步骤"), L("提醒日期"), L("截止日期"), L("循环"), L("删除任务")]).isSubset(of: actions),
                      "Assistive navigation must retain idle footer actions without requiring a pointer hover.")
        XCTAssertEqual(probe.bounds.height, height, accuracy: 1)
        XCTAssertEqual(store.data, original)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("data.json")), bytes)
        XCTAssertFalse(window.isVisible)
    }

    func testDeletedStepSessionCannotBlockOtherEditsFromFinishing() {
        let deletedID = UUID(), retainedID = UUID()
        let owner = TaskCardEditingState(task: WorkTask(title: "Task"), isDraft: false)
        var deletedSaves = 0
        var retainedValue: String?
        let deleted = field(key: "step:\(deletedID)") { _ in
            deletedSaves += 1
            throw LedgerError.notFound("Step was removed externally")
        }
        let retained = field(key: "step:\(retainedID)") { retainedValue = $0 }
        deleted.draft = "Pending deleted step"
        retained.draft = "Updated retained step"
        owner.fields = ["step:\(deletedID)": deleted, "step:\(retainedID)": retained]

        owner.discardMissingStepFields(existingIDs: [retainedID])

        XCTAssertTrue(deleted.discarded)
        XCTAssertNil(owner.fields["step:\(deletedID)"])
        XCTAssertTrue(retained.active)
        XCTAssertTrue(owner.flushFields(finish: true))
        XCTAssertEqual(retainedValue, "Updated retained step")
        XCTAssertEqual(deletedSaves, 0)
    }

    func testMissingStepReconciliationPreservesCurrentUnsavedChildAndOtherFields() {
        let owner = TaskCardEditingState(task: WorkTask(title: ""), isDraft: true)
        let childKey = "step:\(owner.childInputID)"
        var childValue: String?
        var titleValue: String?
        let child = field(key: childKey) { childValue = $0 }
        let title = field(key: "title") { titleValue = $0 }
        child.draft = "Unsaved new child"
        title.draft = "Unsaved task title"
        owner.fields = [childKey: child, "title": title]

        owner.discardMissingStepFields(existingIDs: [])

        XCTAssertTrue(owner.fields[childKey] === child)
        XCTAssertTrue(owner.fields["title"] === title)
        XCTAssertTrue(child.active)
        XCTAssertTrue(title.active)
        XCTAssertTrue(owner.flushFields())
        XCTAssertEqual(childValue, "Unsaved new child")
        XCTAssertEqual(titleValue, "Unsaved task title")
    }

    private func field(key: String, onSave: @escaping (String) throws -> Void) -> InlineTextEditingState {
        let input = InlineEditableText.Input(text: "Original", placeholder: "Name", help: "Edit name", multiline: false,
                                            required: true, font: .body, showsHoverBackground: true, taskID: UUID(), sessionID: key,
                                            saveOnBlur: true, allowEmpty: false, avoidsInitialSelection: false,
                                            onEmptySave: nil, onNextStep: nil, onEditingChanged: { _ in }, onDraftChange: { _ in },
                                            onSave: onSave, onFailure: { _ in })
        return InlineTextEditingState(input: input)
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func accessibilityLabels(_ root: NSObject) -> [String] {
        var visited = Set<ObjectIdentifier>()
        func read(_ object: NSObject, _ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func walk(_ object: NSObject) -> [String] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            let labels = ["accessibilityLabel", "accessibilityTitle"].compactMap { read(object, $0) as? String }
            let children = read(object, "accessibilityChildren") as? [NSObject] ?? []
            return labels + children.flatMap(walk)
        }
        return walk(root)
    }
}
