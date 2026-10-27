import AppKit
import SwiftUI
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class TaskTagTooltipTests: XCTestCase {
    func testNativeTooltipTracksTagNameVisibilityAndScaledIconBoundsWithoutInterceptingClicks() async throws {
        _ = NSApplication.shared
        let state = TagTooltipState()
        let host = NSHostingView(rootView: TagTooltipFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.layoutIfNeeded()
        await settle(host)

        let tooltip = try XCTUnwrap(descendants(host).first { $0.toolTip == state.tag.name })
        XCTAssertEqual(tooltip.bounds.width, 22, accuracy: 0.5)
        XCTAssertEqual(tooltip.bounds.height, 24, accuracy: 0.5)
        XCTAssertNil(tooltip.hitTest(NSPoint(x: tooltip.bounds.midX, y: tooltip.bounds.midY)),
                     "The tooltip region must leave button clicks with the surrounding SwiftUI control.")
        XCTAssertFalse(tooltip.isAccessibilityElement(), "The region must not repeat the button's accessible label.")

        var renamed = state.tag
        renamed.name = "A long tag name that must remain complete in the native tooltip after renaming"
        state.tag = renamed
        await settle(host)
        XCTAssertEqual(tooltip.toolTip, renamed.name)

        state.hoverEnabled = false
        await settle(host)
        XCTAssertNil(tooltip.toolTip, "Scrolling must disable tag hints.")
        state.hoverEnabled = true
        await settle(host)
        XCTAssertEqual(tooltip.toolTip, renamed.name)

        state.pickerPresented = true
        await settle(host)
        XCTAssertNil(tooltip.toolTip, "A tag picker must not compete with a tooltip.")
        state.pickerPresented = false
        await settle(host)
        XCTAssertEqual(tooltip.toolTip, renamed.name)

        state.scale = 1.5
        await settle(host)
        XCTAssertEqual(tooltip.bounds.width, 33, accuracy: 0.5)
        XCTAssertEqual(tooltip.bounds.height, 36, accuracy: 0.5)
        XCTAssertNil(tooltip.hitTest(NSPoint(x: tooltip.bounds.midX, y: tooltip.bounds.midY)))
        XCTAssertFalse(window.isVisible, "Tooltip checks must not open a desktop window.")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func settle(_ host: NSView) async {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(15))
        }
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class TagTooltipState: ObservableObject {
    @Published var tag = TaskTag(name: "Certificate", colorHex: "D98C32")
    @Published var hoverEnabled = true
    @Published var pickerPresented = false
    @Published var scale = 1.0
}

@MainActor
private struct TagTooltipFixture: View {
    @ObservedObject var state: TagTooltipState

    var body: some View {
        TaskTagIconButton(tag: state.tag, isPickerPresented: state.pickerPresented, action: {})
            .environment(\.taskHoverEnabled, state.hoverEnabled)
            .environment(\.appTextScale, state.scale)
            .fixedSize()
            .frame(width: 400, height: 200)
    }
}
