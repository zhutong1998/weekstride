import AppKit
import SwiftUI
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class InlineTextSessionTests: XCTestCase {
    @MainActor private final class FieldState: ObservableObject {
        let taskID = UUID()
        let editingOwner = TaskCardEditingState(task: WorkTask(title: "Synthetic field fixture"), isDraft: false)
        @Published var text = "Existing value"
        @Published var visible = true
        @Published var mounted = true
        var saved: [String] = []
        var editing: [Bool] = []
        var failures: [String] = []
        var removed = 0
    }

    private struct Fixture: View {
        @ObservedObject var state: FieldState
        let initiallyEditing: Bool
        let removesWhenEmpty: Bool

        var body: some View {
            if state.visible && state.mounted {
                InlineEditableText(text: state.text, placeholder: "Value", help: "Edit value", required: true,
                                   taskID: state.taskID, sessionID: "value", saveOnBlur: true, initiallyEditing: initiallyEditing,
                                   onEmptySave: removesWhenEmpty ? { state.removed += 1; state.visible = false } : nil,
                                   onEditingChanged: { state.editing.append($0) },
                                   onSave: { state.saved.append($0); state.text = $0 },
                                   onFailure: { state.failures.append($0) })
                    .environment(\.taskCardEditingState, state.editingOwner)
            }
        }
    }

    func testReadingFieldDoesNotMaterializeEditorOrEventBoundary() async throws {
        try await withFixture(initiallyEditing: false) { state, _, host in
            XCTAssertNil(self.editableField(in: host))
            XCTAssertFalse(self.descendants(host).contains { $0 is TaskEditingBoundary.BoundaryView })
            let request = InlineFlushRequest(taskID: state.taskID, finishEditing: true)
            NotificationCenter.default.post(name: flushTaskEdits, object: request)
            XCTAssertFalse(request.failed)
            XCTAssertEqual(state.editing, [false])
            XCTAssertTrue(state.saved.isEmpty)
            XCTAssertTrue(state.editingOwner.fields.isEmpty)
        }
    }

    func testInvalidFinishRetainsEditorAndCorrectedValueFinishes() async throws {
        try await withFixture { state, window, host in
            let field = try XCTUnwrap(self.editableField(in: host))
            try await self.replaceText("", window: window, host: host)
            let invalid = InlineFlushRequest(taskID: state.taskID, finishEditing: true)
            NotificationCenter.default.post(name: flushTaskEdits, object: invalid)
            await self.settle(host)
            XCTAssertTrue(invalid.failed)
            XCTAssertTrue(self.editableField(in: host) === field, "Validation must preserve the editor and its draft")
            XCTAssertTrue(state.saved.isEmpty)
            XCTAssertEqual(state.editing.last, true)

            try await self.replaceText("Corrected value", window: window, host: host)
            let valid = InlineFlushRequest(taskID: state.taskID, finishEditing: true)
            NotificationCenter.default.post(name: flushTaskEdits, object: valid)
            await self.settle(host)
            XCTAssertFalse(valid.failed)
            XCTAssertEqual(state.saved, ["Corrected value"])
            XCTAssertNil(self.editableField(in: host))
            XCTAssertFalse(self.descendants(host).contains { $0 is TaskEditingBoundary.BoundaryView })
            XCTAssertEqual(state.editing.last, false)
            XCTAssertTrue(state.failures.isEmpty)
        }
    }

    func testEmptyStepIsRemovedOnlyByExplicitFinishAndOnlyOnce() async throws {
        try await withFixture(removesWhenEmpty: true) { state, window, host in
            try await self.replaceText("", window: window, host: host)
            let flush = InlineFlushRequest(taskID: state.taskID)
            NotificationCenter.default.post(name: flushTaskEdits, object: flush)
            XCTAssertFalse(flush.failed)
            XCTAssertEqual(state.removed, 0)
            XCTAssertNotNil(self.editableField(in: host))

            let finish = InlineFlushRequest(taskID: state.taskID, finishEditing: true)
            NotificationCenter.default.post(name: flushTaskEdits, object: finish)
            await self.settle(host)
            XCTAssertFalse(finish.failed)
            XCTAssertEqual(state.removed, 1, "Unmounting a saved session must not repeat the removal")
            XCTAssertNil(self.editableField(in: host))
            XCTAssertTrue(state.saved.isEmpty)
            XCTAssertTrue(state.failures.isEmpty)
        }
    }

    func testDiscardDoesNotSavePendingInputWhenSessionUnmounts() async throws {
        try await withFixture { state, window, host in
            try await self.replaceText("Discard this input", window: window, host: host)
            NotificationCenter.default.post(name: discardTaskEdits, object: state.taskID)
            state.visible = false
            await self.settle(host)
            XCTAssertTrue(state.saved.isEmpty)
            XCTAssertTrue(state.failures.isEmpty)
            XCTAssertNil(self.editableField(in: host))
        }
    }

    func testUnmountedEditorRetainsInvalidDraftAndRestoresItOnRemount() async throws {
        try await withFixture { state, window, host in
            try await self.replaceText("", window: window, host: host)
            let session = try XCTUnwrap(state.editingOwner.fields["value"])
            state.mounted = false
            await self.settle(host)
            XCTAssertNil(self.editableField(in: host))
            XCTAssertTrue(session.active)
            XCTAssertEqual(session.draft, "")
            XCTAssertFalse(state.editingOwner.flushFields(finish: true), "An offscreen invalid edit must still block finishing")
            XCTAssertTrue(state.editingOwner.fields["value"] === session)

            state.mounted = true
            await self.settle(host)
            XCTAssertTrue(state.editingOwner.fields["value"] === session)
            XCTAssertEqual(try XCTUnwrap(self.editableField(in: host)).stringValue, "")
            try await self.replaceText("Corrected after remount", window: window, host: host)
            state.mounted = false
            await self.settle(host)
            XCTAssertTrue(state.editingOwner.flushFields(finish: true))
            XCTAssertEqual(state.saved, ["Corrected after remount"])
            XCTAssertTrue(state.editingOwner.fields.isEmpty)
            XCTAssertFalse(session.active)
        }
    }

    func testUnmountedEmptyStepCanBeFinishedAndRemovedOnlyOnce() async throws {
        try await withFixture(removesWhenEmpty: true) { state, window, host in
            try await self.replaceText("", window: window, host: host)
            let session = try XCTUnwrap(state.editingOwner.fields["value"])
            state.mounted = false
            await self.settle(host)
            XCTAssertEqual(state.removed, 0)
            XCTAssertTrue(state.editingOwner.flushFields(finish: true))
            XCTAssertEqual(state.removed, 1)
            XCTAssertTrue(state.editingOwner.fields.isEmpty)
            XCTAssertTrue(session.finish())
            XCTAssertTrue(session.flush(commitEmpty: true))
            XCTAssertEqual(state.removed, 1)
        }
    }

    private func withFixture(initiallyEditing: Bool = true, removesWhenEmpty: Bool = false,
                             _ test: (FieldState, NSWindow, NSHostingView<Fixture>) async throws -> Void) async throws {
        _ = NSApplication.shared
        let state = FieldState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Fixture(state: state, initiallyEditing: initiallyEditing, removesWhenEmpty: removesWhenEmpty))
        window.contentView = host
        window.layoutIfNeeded()
        await settle(host)
        try await test(state, window, host)
        XCTAssertFalse(window.isVisible)
    }

    private func replaceText(_ value: String, window: NSWindow, host: NSView) async throws {
        let field = try XCTUnwrap(editableField(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText(value, replacementRange: editor.selectedRange())
        await settle(host)
    }

    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
    }

    private func editableField(in view: NSView) -> NSTextField? {
        descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
