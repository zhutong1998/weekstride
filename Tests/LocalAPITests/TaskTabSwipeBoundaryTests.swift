import AppKit
import XCTest
@testable import WorkLedger

@MainActor
final class TaskTabSwipeBoundaryTests: XCTestCase {
    private final class FixtureWindow: NSWindow {
        var reportedChildren: [NSWindow] = []
        override var childWindows: [NSWindow]? {
            reportedChildren.isEmpty ? super.childWindows : reportedChildren
        }
    }

    /// Reports the public properties of the screen-sharing child without ordering any window on screen.
    private final class SharingChildWindow: NSWindow {
        override var isVisible: Bool { true }
        override var canBecomeKey: Bool { false }
    }

    private final class InputEvent: NSEvent {
        var eventKind = NSEvent.EventType.scrollWheel
        weak var targetWindow: NSWindow?
        var point = NSPoint.zero
        var time: TimeInterval = 1
        var x: CGFloat = 0
        var y: CGFloat = 0
        var eventPhase: NSEvent.Phase = []
        var eventMomentum: NSEvent.Phase = []
        var flags: NSEvent.ModifierFlags = []
        var invalidPropertyReads: [String] = []

        override var type: NSEvent.EventType { eventKind }
        override var window: NSWindow? { targetWindow }
        override var windowNumber: Int { targetWindow?.windowNumber ?? 0 }
        override var locationInWindow: NSPoint { point }
        override var timestamp: TimeInterval { time }
        override var modifierFlags: NSEvent.ModifierFlags { flags }
        override var deltaX: CGFloat { x }
        override var deltaY: CGFloat { y }
        override var scrollingDeltaX: CGFloat { scrollOnly("scrollingDeltaX", x) }
        override var scrollingDeltaY: CGFloat { scrollOnly("scrollingDeltaY", y) }
        override var hasPreciseScrollingDeltas: Bool { scrollOnly("hasPreciseScrollingDeltas", true) }
        override var isDirectionInvertedFromDevice: Bool { scrollOnly("isDirectionInvertedFromDevice", false) }
        override var phase: NSEvent.Phase { scrollOnly("phase", eventPhase) }
        override var momentumPhase: NSEvent.Phase { scrollOnly("momentumPhase", eventMomentum) }

        private func scrollOnly<Value>(_ name: String, _ value: Value) -> Value {
            if eventKind != .scrollWheel { invalidPropertyReads.append(name) }
            return value
        }
    }

    private final class Fixture {
        let window: FixtureWindow
        let content: NSView
        let boundary: TaskTabSwipeBoundary.BoundaryView
        var directions: [TaskTabSwipeDirection] = []

        init() {
            _ = NSApplication.shared
            window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 360),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
            boundary = TaskTabSwipeBoundary.BoundaryView(frame: NSRect(x: 40, y: 40, width: 360, height: 240))
            window.contentView = content
            content.addSubview(boundary)
            boundary.onSwipe = { [weak self] direction in self?.directions.append(direction) }
            boundary.setEnabled(true)
            window.layoutIfNeeded()
            content.layoutSubtreeIfNeeded()
        }

        func event(x: CGFloat = 0, y: CGFloat = 0, phase: NSEvent.Phase = [],
                   momentum: NSEvent.Phase = [], time: TimeInterval = 1,
                   kind: NSEvent.EventType = .scrollWheel, inside: Bool = true) -> InputEvent {
            let event = InputEvent()
            event.targetWindow = window
            event.point = boundary.convert(inside ? NSPoint(x: 60, y: 60) : NSPoint(x: -20, y: -20), to: nil)
            event.x = x; event.y = y; event.eventPhase = phase; event.eventMomentum = momentum
            event.time = time; event.eventKind = kind
            return event
        }

        func close() {
            boundary.setEnabled(false)
            boundary.onSwipe = nil
            window.reportedChildren = []
            window.close()
        }
    }

    func testNativeBoundaryProcessesACompleteGestureExactlyOnce() {
        let fixture = Fixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.boundary.window === fixture.window)
        let began = fixture.event(phase: .began)
        XCTAssertTrue(fixture.boundary.process(began) === began)
        XCTAssertNil(fixture.boundary.process(fixture.event(x: 18, phase: .changed, time: 1.01)))
        XCTAssertTrue(fixture.directions.isEmpty)
        XCTAssertNil(fixture.boundary.process(fixture.event(x: 18, phase: .changed, time: 1.02)))
        XCTAssertEqual(fixture.directions, [.next])
        XCTAssertNil(fixture.boundary.process(fixture.event(x: 70, phase: .changed, time: 1.03)))
        let ended = fixture.event(phase: .ended, time: 1.04)
        XCTAssertTrue(fixture.boundary.process(ended) === ended)
        XCTAssertEqual(fixture.directions, [.next])
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testNonKeyWindowWithVisibleInteractiveSharingChildStillReceivesNavigation() {
        let fixture = Fixture()
        defer { fixture.close() }
        let sharing = SharingChildWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        sharing.isReleasedWhenClosed = false
        sharing.ignoresMouseEvents = false
        fixture.window.reportedChildren = [sharing]
        defer { sharing.close() }
        XCTAssertFalse(fixture.window.isKeyWindow)
        XCTAssertTrue(sharing.isVisible)
        XCTAssertFalse(sharing.ignoresMouseEvents)
        XCTAssertFalse(sharing.isKeyWindow)

        _ = fixture.boundary.process(fixture.event(phase: .began))
        _ = fixture.boundary.process(fixture.event(x: 18, phase: .changed, time: 1.01))
        _ = fixture.boundary.process(fixture.event(x: 18, phase: .changed, time: 1.02))
        XCTAssertEqual(fixture.directions, [.next], "A system sharing child is not a modal editor or a task popover")
        XCTAssertFalse(fixture.window.isVisible, "The fixture must never display or activate a desktop window")
    }

    func testOtherWindowAndPointsOutsideTheBoundaryArePassedThrough() {
        let fixture = Fixture()
        defer { fixture.close() }
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        for index in 0..<3 {
            let foreign = fixture.event(x: 40, phase: index == 0 ? .began : .changed, time: 1 + Double(index) * 0.01)
            foreign.targetWindow = other
            XCTAssertTrue(fixture.boundary.process(foreign) === foreign)
            let outside = fixture.event(x: 40, phase: index == 0 ? .began : .changed,
                                        time: 2 + Double(index) * 0.01, inside: false)
            XCTAssertTrue(fixture.boundary.process(outside) === outside)
        }
        XCTAssertTrue(fixture.directions.isEmpty)
        XCTAssertFalse(other.isVisible)
    }

    func testNativeTextEditingBlocksNavigationWhileNativeListFocusAllowsIt() {
        let fixture = Fixture()
        defer { fixture.close() }
        let editor = NSTextView(frame: NSRect(x: 40, y: 40, width: 160, height: 70))
        editor.isEditable = true
        fixture.content.addSubview(editor)
        XCTAssertTrue(fixture.window.makeFirstResponder(editor))
        let began = fixture.event(phase: .began)
        XCTAssertTrue(fixture.boundary.process(began) === began)
        let changed = fixture.event(x: 50, phase: .changed, time: 1.01)
        XCTAssertTrue(fixture.boundary.process(changed) === changed)
        XCTAssertTrue(fixture.directions.isEmpty)

        let list = NSTableView(frame: NSRect(x: 40, y: 40, width: 200, height: 120))
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Synthetic task")))
        fixture.content.addSubview(list)
        XCTAssertTrue(fixture.window.makeFirstResponder(list))
        _ = fixture.boundary.process(fixture.event(phase: .began, time: 2))
        _ = fixture.boundary.process(fixture.event(x: 40, phase: .changed, time: 2.01))
        XCTAssertEqual(fixture.directions, [.next])
    }

    func testVerticalGestureIsPassedThroughWithoutInvokingTheTabAction() {
        let fixture = Fixture()
        defer { fixture.close() }
        let events = [fixture.event(phase: .began),
                      fixture.event(x: 1, y: -24, phase: .changed, time: 1.01),
                      fixture.event(x: 2, y: -40, phase: .changed, time: 1.02),
                      fixture.event(phase: .ended, time: 1.03)]
        for event in events {
            XCTAssertTrue(fixture.boundary.process(event) === event)
            XCTAssertTrue(event.invalidPropertyReads.isEmpty)
        }
        XCTAssertTrue(fixture.directions.isEmpty)
    }

    func testRefreshingTheCallbackDoesNotRestartAnInProgressNativeGesture() {
        let fixture = Fixture()
        defer { fixture.close() }
        var refreshedDirections: [TaskTabSwipeDirection] = []
        _ = fixture.boundary.process(fixture.event(phase: .began))
        _ = fixture.boundary.process(fixture.event(x: 18, phase: .changed, time: 1.01))
        fixture.boundary.onSwipe = { refreshedDirections.append($0) }
        fixture.boundary.setEnabled(true)
        _ = fixture.boundary.process(fixture.event(x: 18, phase: .changed, time: 1.02))
        XCTAssertEqual(refreshedDirections, [.next], "Refreshing the SwiftUI callback must preserve accumulated travel")
        fixture.boundary.onSwipe = { refreshedDirections.append($0) }
        fixture.boundary.setEnabled(true)
        _ = fixture.boundary.process(fixture.event(x: 80, phase: .changed, time: 1.03))
        XCTAssertEqual(refreshedDirections, [.next], "The destination view must not navigate again during the same gesture")
        XCTAssertTrue(fixture.directions.isEmpty)
    }

    func testDiscreteSwipeUsesItsOwnLegalDeltaPropertiesAndRoutesBothDirections() {
        let fixture = Fixture()
        defer { fixture.close() }
        let left = fixture.event(x: 1, kind: .swipe)
        let right = fixture.event(x: -1, time: 2, kind: .swipe)
        XCTAssertNil(fixture.boundary.process(left))
        XCTAssertNil(fixture.boundary.process(right))
        XCTAssertEqual(fixture.directions, [.next, .previous])
        XCTAssertEqual(left.invalidPropertyReads, [])
        XCTAssertEqual(right.invalidPropertyReads, [])

        let vertical = fixture.event(y: 1, time: 3, kind: .swipe)
        XCTAssertTrue(fixture.boundary.process(vertical) === vertical)
        XCTAssertEqual(fixture.directions, [.next, .previous])
        XCTAssertEqual(vertical.invalidPropertyReads, [])
    }

    func testReverseSettingSwapsBothDirectionsForScrollAndDiscreteSwipes() {
        for reversed in [false, true] {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.boundary.reverseDirection = reversed
            for (index, delta) in [CGFloat(1), -1].enumerated() {
                let time = Double(index + 1)
                _ = fixture.boundary.process(fixture.event(phase: .began, time: time))
                _ = fixture.boundary.process(fixture.event(x: delta * 40, phase: .changed, time: time + 0.01))
            }
            _ = fixture.boundary.process(fixture.event(x: 1, time: 3, kind: .swipe))
            _ = fixture.boundary.process(fixture.event(x: -1, time: 4, kind: .swipe))
            XCTAssertEqual(fixture.directions, reversed ? [.previous, .next, .previous, .next] : [.next, .previous, .next, .previous])
        }
    }

    func testChangingReverseSettingKeepsTheCurrentGestureAndDoesNotRepeatNavigation() {
        let fixture = Fixture()
        defer { fixture.close() }
        _ = fixture.boundary.process(fixture.event(phase: .began))
        _ = fixture.boundary.process(fixture.event(x: 18, phase: .changed, time: 1.01))
        fixture.boundary.reverseDirection = true
        fixture.boundary.setEnabled(true)
        _ = fixture.boundary.process(fixture.event(x: 18, phase: .changed, time: 1.02))
        XCTAssertEqual(fixture.directions, [.previous])
        fixture.boundary.reverseDirection = false
        fixture.boundary.setEnabled(true)
        _ = fixture.boundary.process(fixture.event(x: 80, phase: .changed, time: 1.03))
        XCTAssertEqual(fixture.directions, [.previous])
        _ = fixture.boundary.process(fixture.event(phase: .began, time: 2))
        _ = fixture.boundary.process(fixture.event(x: 40, phase: .changed, time: 2.01))
        XCTAssertEqual(fixture.directions, [.previous, .next])
    }
}
