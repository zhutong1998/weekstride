import AppKit
import SwiftUI
import XCTest
@testable import WorkLedger

@MainActor
final class TaskAccessibilityFocusTests: XCTestCase {
    private final class FixtureState: ObservableObject {
        @Published var refresh = 0
        @Published var text = "Retained draft"
    }

    private struct Fixture: View {
        @ObservedObject var state: FixtureState
        @FocusState private var keyboardFocus: Bool
        @AccessibilityFocusState private var booleanFocus: Bool
        @AccessibilityFocusState private var namedFocus: String?

        var body: some View {
            VStack {
                TextField("Task draft", text: $state.text).focused($keyboardFocus)
                Text("Sibling update \(state.refresh)")
                HStack {
                    Button("Boolean action") { state.refresh += 1 }
                        .accessibilityLabel("Boolean action")
                        .taskAccessibilityFocused($booleanFocus)
                    Button("Named action") { state.refresh += 1 }
                        .accessibilityLabel("Named action")
                        .taskAccessibilityFocused($namedFocus, equals: "action")
                }
            }
            .padding(12)
            .environment(\.accessibilityEnabled, true)
        }
    }

    func testActiveDraftEditorSurvivesSiblingUpdates() async throws {
        _ = NSApplication.shared
        let state = FixtureState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Fixture(state: state))
        window.contentView = host
        await settle(window, host: host)

        let field = try XCTUnwrap(textField(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" + input", replacementRange: editor.selectedRange())
        await settle(window, host: host)
        var expected = "Retained draft + input"
        XCTAssertEqual(state.text, expected)

        for refresh in 1...3 {
            state.refresh = refresh
            await settle(window, host: host)

            XCTAssertTrue(textField(in: host) === field, "Updating sibling controls must not recreate an existing editor")
            XCTAssertTrue(field.currentEditor() === editor)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(state.text, expected)
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            let input = " + update \(refresh)"
            editor.insertText(input, replacementRange: editor.selectedRange())
            expected += input
            await settle(window, host: host)
            XCTAssertEqual(state.text, expected, "Typing must continue after a sibling control refreshes")
            XCTAssertEqual(editor.string, expected)
        }

        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" + continued", replacementRange: editor.selectedRange())
        await settle(window, host: host)
        XCTAssertEqual(state.text, expected + " + continued")
        XCTAssertFalse(window.isVisible, "The smoke test must not open or activate a desktop window")
    }

    private func settle(_ window: NSWindow, host: NSView) async {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(15))
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { self.textField(in: $0) }.first
    }

}
