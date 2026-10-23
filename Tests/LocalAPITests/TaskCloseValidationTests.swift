import AppKit
import XCTest
@testable import WorkLedger

@MainActor
final class TaskCloseValidationTests: XCTestCase {
    func testTerminationCancelsFailedSaveAndAllowsCorrectedEditingToFinish() {
        _ = NSApplication.shared
        let boundary = TaskEditingBoundary.BoundaryView()
        let taskID = UUID()
        var invalid = true
        var saves = 0
        boundary.onFinish = { request in
            if invalid { request.fail(for: taskID) }
            else { saves += 1 }
        }
        boundary.setEnabled(true)
        defer { boundary.setEnabled(false) }
        var recoveredID: UUID?
        let observer = NotificationCenter.default.addObserver(forName: .init("WorkLedger.openTask"), object: nil, queue: .main) { note in
            recoveredID = (note.object as? String).flatMap(UUID.init(uuidString:))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let delegate = TaskApplicationDelegate()

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(recoveredID, taskID, "A rejected quit must direct the user back to the invalid editor.")
        invalid = false
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
        XCTAssertEqual(saves, 1, "Saving must complete before termination is allowed.")
    }

    func testWindowCloseRejectsFailedSaveThenRespectsTheOriginalDelegate() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let original = RecordingWindowDelegate()
        let proxy = TaskWindowCloseProxy()
        proxy.originalDelegate = original
        let boundary = TaskEditingBoundary.BoundaryView()
        var invalid = true
        boundary.onFinish = { request in if invalid { request.fail(for: UUID()) } }
        boundary.setEnabled(true)
        defer { boundary.setEnabled(false) }

        XCTAssertFalse(proxy.windowShouldClose(window))
        XCTAssertEqual(original.closeRequests, 0, "Validation must run before SwiftUI can remove the editor's window.")
        invalid = false
        original.allowsClose = false
        XCTAssertFalse(proxy.windowShouldClose(window))
        XCTAssertEqual(original.closeRequests, 1)
        original.allowsClose = true
        XCTAssertTrue(proxy.windowShouldClose(window))
        XCTAssertEqual(original.closeRequests, 2)
        XCTAssertFalse(window.isVisible)
    }

    func testWindowBridgeForwardsCallbacksAndRestoresDelegateWithoutDeferredReinstallation() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let original = RecordingWindowDelegate()
        window.delegate = original
        let view = TaskWindowCloseBoundary.BridgeView(frame: .zero)
        window.contentView = view
        XCTAssertTrue(window.delegate === view.proxy)
        let selector = #selector(NSWindowDelegate.windowDidResize(_:))
        XCTAssertTrue(view.proxy.responds(to: selector))
        XCTAssertTrue(view.proxy.forwardingTarget(for: selector) as AnyObject? === original)
        let previousResizes = original.resizes
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        XCTAssertEqual(original.resizes, previousResizes + 1)

        TaskWindowCloseBoundary.dismantleNSView(view, coordinator: ())
        await Task.yield()
        XCTAssertTrue(window.delegate === original, "A queued installation cannot undo teardown.")
        view.installIfNeeded()
        let replacement = RecordingWindowDelegate()
        window.delegate = replacement
        TaskWindowCloseBoundary.dismantleNSView(view, coordinator: ())
        XCTAssertTrue(window.delegate === replacement, "Teardown must preserve a newer framework delegate.")
        XCTAssertFalse(window.isVisible)
    }
}

@MainActor
private final class RecordingWindowDelegate: NSObject, NSWindowDelegate {
    var allowsClose = true
    var closeRequests = 0
    var resizes = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool { closeRequests += 1; return allowsClose }
    func windowDidResize(_ notification: Notification) { resizes += 1 }
}
