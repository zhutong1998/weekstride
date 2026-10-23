import AppKit
import XCTest
@testable import WorkLedger

final class TaskTabSwipeTests: XCTestCase {
    func testDiscreteSwipeUsesItsSignedDirectionAndRejectsVerticalOrDiagonalEvents() {
        for (delta, expected) in [(CGFloat(1), TaskTabSwipeDirection.next), (-1, .previous)] {
            var tracker = TaskTabSwipeTracker()
            let decision = tracker.handleSwipe(horizontal: delta, vertical: 0, timestamp: 1)
            XCTAssertEqual(decision.direction, expected)
            XCTAssertTrue(decision.consumesEvent)
        }
        for (x, y) in [(CGFloat(0), CGFloat(0)), (0, 1), (1, 1), (-1, -1)] {
            var tracker = TaskTabSwipeTracker()
            XCTAssertEqual(tracker.handleSwipe(horizontal: x, vertical: y, timestamp: 1), .pass)
        }
    }

    func testDiscreteSwipeDoesNotRepeatNavigationAlreadyTriggeredByTheScrollGesture() {
        var tracker = TaskTabSwipeTracker()
        _ = tracker.handle(horizontal: 0, vertical: 0, phase: .began, momentum: [], timestamp: 1)
        XCTAssertEqual(tracker.handle(horizontal: 40, vertical: 0, phase: .changed,
                                      momentum: [], timestamp: 1.01).direction, .next)
        _ = tracker.handle(horizontal: 0, vertical: 0, phase: .ended, momentum: [], timestamp: 1.02)
        XCTAssertNil(tracker.handleSwipe(horizontal: 1, vertical: 0, timestamp: 1.03).direction,
                     "One physical gesture delivered as both scroll and swipe must navigate only once.")
    }

    func testSwipeDeduplicationTracksPhysicalEndWithoutBeingExtendedByMomentum() {
        var longGesture = TaskTabSwipeTracker()
        _ = longGesture.handle(horizontal: 0, vertical: 0, phase: .began, momentum: [], timestamp: 1)
        XCTAssertEqual(longGesture.handle(horizontal: 40, vertical: 0, phase: .changed,
                                          momentum: [], timestamp: 1.01).direction, .next)
        _ = longGesture.handle(horizontal: 10, vertical: 0, phase: .changed, momentum: [], timestamp: 2)
        _ = longGesture.handle(horizontal: 0, vertical: 0, phase: .ended, momentum: [], timestamp: 2.01)
        XCTAssertNil(longGesture.handleSwipe(horizontal: 1, vertical: 0, timestamp: 2.02).direction,
                     "The physical end, rather than the initial navigation, anchors duplicate-swipe detection.")

        // Use a fresh tracker: the preceding duplicate swipe resets its tracker and would mask stale momentum timing.
        var momentumGesture = TaskTabSwipeTracker()
        _ = momentumGesture.handle(horizontal: 0, vertical: 0, phase: .began, momentum: [], timestamp: 3)
        XCTAssertEqual(momentumGesture.handle(horizontal: 40, vertical: 0, phase: .changed,
                                              momentum: [], timestamp: 3.01).direction, .next)
        _ = momentumGesture.handle(horizontal: 0, vertical: 0, phase: .ended, momentum: [], timestamp: 3.02)
        _ = momentumGesture.handle(horizontal: 10, vertical: 0, phase: [], momentum: .began, timestamp: 3.03)
        _ = momentumGesture.handle(horizontal: 4, vertical: 0, phase: [], momentum: .changed, timestamp: 5)
        XCTAssertEqual(momentumGesture.handleSwipe(horizontal: -1, vertical: 0, timestamp: 5.01).direction, .previous,
                       "Long-running momentum must not suppress a later independent swipe.")
    }

    func testSeparateDiscreteSwipesEachNavigateEvenWithinTheScrollGroupingInterval() {
        var tracker = TaskTabSwipeTracker()
        XCTAssertEqual(tracker.handleSwipe(horizontal: 1, vertical: 0, timestamp: 1).direction, .next)
        XCTAssertEqual(tracker.handleSwipe(horizontal: 1, vertical: 0, timestamp: 1.01).direction, .next)
        XCTAssertEqual(tracker.handleSwipe(horizontal: -1, vertical: 0, timestamp: 1.02).direction, .previous)
    }

    func testPreflightAndStationaryEventsPassThroughBeforeARecognizedGesture() {
        var tracker = TaskTabSwipeTracker()
        XCTAssertEqual(tracker.handle(horizontal: 0, vertical: 0, phase: .mayBegin, momentum: [], timestamp: 1), .pass)
        XCTAssertEqual(tracker.handle(horizontal: 0, vertical: 0, phase: .stationary, momentum: [], timestamp: 1.01), .pass)
        XCTAssertEqual(tracker.handle(horizontal: 0, vertical: 0, phase: .began, momentum: [], timestamp: 1.02), .pass)
        XCTAssertEqual(tracker.handle(horizontal: 0, vertical: 0, phase: .stationary, momentum: [], timestamp: 1.03), .pass)
        XCTAssertEqual(tracker.handle(horizontal: 36, vertical: 0, phase: .changed,
                                      momentum: [], timestamp: 1.04).direction, .next)
    }

    func testPhysicalGestureNavigatesOnceAndMomentumCannotRepeatIt() {
        var tracker = TaskTabSwipeTracker()
        XCTAssertEqual(tracker.handle(horizontal: 0, vertical: 0, phase: .began, momentum: [], timestamp: 1), .pass)
        XCTAssertNil(tracker.handle(horizontal: 18, vertical: 1, phase: .changed, momentum: [], timestamp: 1.01).direction)
        let triggered = tracker.handle(horizontal: 18, vertical: 1, phase: .changed, momentum: [], timestamp: 1.02)
        XCTAssertEqual(triggered.direction, .next)
        XCTAssertTrue(triggered.consumesEvent)
        XCTAssertNil(tracker.handle(horizontal: 100, vertical: 0, phase: .changed, momentum: [], timestamp: 1.03).direction)
        XCTAssertEqual(tracker.handle(horizontal: 0, vertical: 0, phase: .ended, momentum: [], timestamp: 1.04), .pass,
                       "The native scroll view must receive the end of its scrolling phase")
        XCTAssertEqual(tracker.handle(horizontal: 40, vertical: 0, phase: [], momentum: .began, timestamp: 1.05), .pass)
        let inertia = tracker.handle(horizontal: 100, vertical: 0, phase: [], momentum: .changed, timestamp: 1.06)
        XCTAssertNil(inertia.direction)
        XCTAssertTrue(inertia.consumesEvent)
        XCTAssertEqual(tracker.handle(horizontal: 0, vertical: 0, phase: [], momentum: .ended, timestamp: 1.07), .pass)
    }

    func testNewPhysicalGestureCanSwitchAgainWithoutWaitingForTheLegacyTimeout() {
        var tracker = TaskTabSwipeTracker()
        _ = tracker.handle(horizontal: 0, vertical: 0, phase: .began, momentum: [], timestamp: 1)
        XCTAssertEqual(tracker.handle(horizontal: 40, vertical: 0, phase: .changed, momentum: [], timestamp: 1.01).direction, .next)
        _ = tracker.handle(horizontal: 0, vertical: 0, phase: .ended, momentum: [], timestamp: 1.02)
        _ = tracker.handle(horizontal: 0, vertical: 0, phase: .began, momentum: [], timestamp: 1.03)
        XCTAssertEqual(tracker.handle(horizontal: -40, vertical: 0, phase: .changed, momentum: [], timestamp: 1.04).direction, .previous)
    }

    func testVerticalAndDiagonalIntentRemainsNativeScrollingEvenAfterHorizontalDrift() {
        let deltas: [(CGFloat, CGFloat)] = [(2, 20), (20, 12), (20, 10)]
        for delta in deltas {
            var tracker = TaskTabSwipeTracker()
            _ = tracker.handle(horizontal: 0, vertical: 0, phase: .began, momentum: [], timestamp: 1)
            XCTAssertEqual(tracker.handle(horizontal: delta.0, vertical: delta.1, phase: .changed, momentum: [], timestamp: 1.01), .pass)
            XCTAssertEqual(tracker.handle(horizontal: 100, vertical: 0, phase: .changed, momentum: [], timestamp: 1.02), .pass,
                           "A scroll that started vertically or diagonally must not become tab navigation")
        }
    }

    func testSmallOrCancelledGesturesDoNotNavigate() {
        var tracker = TaskTabSwipeTracker()
        _ = tracker.handle(horizontal: 0, vertical: 0, phase: .began, momentum: [], timestamp: 1)
        XCTAssertNil(tracker.handle(horizontal: 20, vertical: 0, phase: .changed, momentum: [], timestamp: 1.01).direction)
        XCTAssertEqual(tracker.handle(horizontal: 100, vertical: 0, phase: .cancelled, momentum: [], timestamp: 1.02), .pass)
        XCTAssertEqual(tracker.handle(horizontal: 100, vertical: 0, phase: .changed, momentum: [], timestamp: 1.03), .pass)
        XCTAssertEqual(tracker.handle(horizontal: 100, vertical: 0, phase: [], momentum: .changed, timestamp: 1.04), .pass)
    }

    func testOrphanMomentumCannotStartNavigation() {
        var tracker = TaskTabSwipeTracker()
        for (index, phase) in [NSEvent.Phase.began, .changed, .changed, .ended].enumerated() {
            XCTAssertEqual(tracker.handle(horizontal: 100, vertical: 0, phase: [], momentum: phase,
                                          timestamp: 1 + Double(index) * 0.01), .pass)
        }
    }

    func testPhaseLessMouseEventsAreGroupedUntilAnIdleGap() {
        var tracker = TaskTabSwipeTracker()
        var navigations: [TaskTabSwipeDirection] = []
        for index in 0..<10 {
            let decision = tracker.handle(horizontal: 12, vertical: 0, phase: [], momentum: [], timestamp: 1 + Double(index) * 0.02)
            if let direction = decision.direction { navigations.append(direction) }
        }
        XCTAssertEqual(navigations, [.next])
        XCTAssertEqual(tracker.handle(horizontal: -36, vertical: 0, phase: [], momentum: [], timestamp: 1.5).direction, .previous)
    }

    func testSuppressedGestureCannotResumeInsideTheBoundaryUntilANewGesture() {
        var tracker = TaskTabSwipeTracker()
        tracker.suppress(at: 1)
        XCTAssertEqual(tracker.handle(horizontal: 100, vertical: 0, phase: .changed, momentum: [], timestamp: 1.01), .pass)
        XCTAssertEqual(tracker.handle(horizontal: 100, vertical: 0, phase: [], momentum: [], timestamp: 1.02), .pass)
        _ = tracker.handle(horizontal: 0, vertical: 0, phase: .began, momentum: [], timestamp: 1.03)
        XCTAssertEqual(tracker.handle(horizontal: 40, vertical: 0, phase: .changed, momentum: [], timestamp: 1.04).direction, .next)
    }

    func testDevicePreferenceAndLineUnitsAreNormalizedBeforeTracking() {
        XCTAssertEqual(TaskTabSwipeTracker.normalizedDelta(1, inverted: false, precise: false), 12)
        XCTAssertEqual(TaskTabSwipeTracker.normalizedDelta(12, inverted: false, precise: true), 12)
        XCTAssertEqual(TaskTabSwipeTracker.normalizedDelta(-12, inverted: true, precise: true), 12,
                       "Physical swipe direction must remain the same when natural scrolling is enabled")
        var tracker = TaskTabSwipeTracker()
        let mouseStep = TaskTabSwipeTracker.normalizedDelta(1, inverted: false, precise: false)
        for index in 0..<2 {
            XCTAssertNil(tracker.handle(horizontal: mouseStep, vertical: 0, phase: [], momentum: [], timestamp: 1 + Double(index) * 0.01).direction)
        }
        XCTAssertEqual(tracker.handle(horizontal: mouseStep, vertical: 0, phase: [], momentum: [], timestamp: 1.02).direction, .next)
    }
}
