import AppKit
import SwiftUI

enum TaskTabSwipeDirection: Equatable {
    case previous, next
    var reversed: Self { self == .next ? .previous : .next }
}

struct TaskTabSwipeDecision: Equatable {
    var direction: TaskTabSwipeDirection?
    var consumesEvent: Bool
    static let pass = Self(direction: nil, consumesEvent: false)
}

/// Scroll deltas are normalized to physical swipe direction before entering this tracker.
struct TaskTabSwipeTracker {
    private enum Axis: Equatable { case undecided, horizontal, vertical }
    private enum Mode: Equatable { case idle, phased, legacy }
    private var axis = Axis.undecided
    private var mode = Mode.idle
    private var active = false
    private var switched = false
    private var horizontal: CGFloat = 0
    private var verticalTravel: CGFloat = 0
    private var lastTimestamp: TimeInterval?
    private var lastPhysicalTimestamp: TimeInterval?
    static let threshold: CGFloat = 36
    static let groupInterval: TimeInterval = 0.24
    private static let dominance: CGFloat = 2.2

    static func normalizedDelta(_ delta: CGFloat, inverted: Bool, precise: Bool) -> CGFloat {
        delta * (inverted ? -1 : 1) * (precise ? 1 : 12)
    }

    mutating func reset() { self = Self() }

    mutating func suppress(at timestamp: TimeInterval) {
        mode = .phased; active = false; axis = .vertical; switched = false
        horizontal = 0; verticalTravel = 0; lastTimestamp = timestamp
    }

    mutating func handleSwipe(horizontal x: CGFloat, vertical y: CGFloat, timestamp: TimeInterval) -> TaskTabSwipeDecision {
        guard x.isFinite, y.isFinite, timestamp.isFinite,
              abs(x) > 0, abs(x) >= Self.dominance * abs(y) else { return .pass }
        let elapsed = lastPhysicalTimestamp.map { timestamp - $0 } ?? .infinity
        let alreadySwitched = switched && elapsed >= 0 && elapsed <= Self.groupInterval
        reset()
        return TaskTabSwipeDecision(direction: alreadySwitched ? nil : (x > 0 ? .next : .previous), consumesEvent: true)
    }

    mutating func handle(horizontal x: CGFloat, vertical y: CGFloat, phase: NSEvent.Phase,
                         momentum: NSEvent.Phase, timestamp: TimeInterval) -> TaskTabSwipeDecision {
        guard x.isFinite, y.isFinite, timestamp.isFinite else { return .pass }
        let terminal = phase.contains(.ended) || phase.contains(.cancelled)
        let phaseBoundary = phase.contains(.began) || terminal || momentum.contains(.began)
            || momentum.contains(.ended) || momentum.contains(.cancelled)
        let horizontalEvent = abs(x) > 0 && abs(x) >= Self.dominance * abs(y)
        if !momentum.isEmpty {
            lastTimestamp = timestamp
            return TaskTabSwipeDecision(direction: nil, consumesEvent: switched && horizontalEvent && !phaseBoundary)
        }

        let gap = lastTimestamp.map { timestamp - $0 } ?? .infinity
        if phase.contains(.began) {
            begin(.phased)
        } else if !phase.isEmpty {
            guard mode == .phased, active else { lastTimestamp = timestamp; return .pass }
        } else if mode == .idle || gap > Self.groupInterval || gap < 0 {
            begin(.legacy)
        } else if mode != .legacy {
            lastTimestamp = timestamp
            return .pass
        }
        lastTimestamp = timestamp
        lastPhysicalTimestamp = timestamp
        if phase.contains(.cancelled) { active = false; axis = .vertical; return .pass }
        horizontal += x
        verticalTravel += abs(y)
        if axis == .undecided, max(abs(horizontal), verticalTravel) >= 8 {
            axis = abs(horizontal) >= Self.dominance * verticalTravel ? .horizontal : .vertical
        }
        if !switched, axis == .horizontal, verticalTravel >= 8,
           abs(horizontal) < Self.dominance * verticalTravel { axis = .vertical }
        var direction: TaskTabSwipeDirection?
        if axis == .horizontal, !switched, abs(horizontal) >= Self.threshold {
            switched = true
            direction = horizontal > 0 ? .next : .previous
        }
        if terminal { active = false }
        // Preserve native begin/end delivery so the underlying scroll view never stays in a scrolling phase.
        return TaskTabSwipeDecision(direction: direction, consumesEvent: axis == .horizontal && horizontalEvent && !phaseBoundary)
    }

    private mutating func begin(_ mode: Mode) {
        self.mode = mode; axis = .undecided; active = true; switched = false
        horizontal = 0; verticalTravel = 0
    }
}

struct TaskTabSwipeBoundary: NSViewRepresentable {
    let enabled: Bool
    var reverseDirection = false
    let onSwipe: (TaskTabSwipeDirection) -> Void

    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }

    func updateNSView(_ view: BoundaryView, context: Context) {
        view.onSwipe = onSwipe
        view.reverseDirection = reverseDirection
        view.setEnabled(enabled)
    }

    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) {
        view.setEnabled(false); view.onSwipe = nil
    }

    final class BoundaryView: NSView {
        var onSwipe: ((TaskTabSwipeDirection) -> Void)?
        var reverseDirection = false
        private var monitor: Any?
        private var tracker = TaskTabSwipeTracker()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setEnabled(_ enabled: Bool) {
            if enabled, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
                    guard let self else { return event }
                    return self.process(event)
                }
            } else if !enabled {
                if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
                tracker.reset()
            }
        }

        func process(_ event: NSEvent) -> NSEvent? {
            guard event.type == .scrollWheel || event.type == .swipe else { return event }
            guard accepts(event) else { tracker.suppress(at: event.timestamp); return event }
            let decision: TaskTabSwipeDecision
            if event.type == .swipe {
                decision = tracker.handleSwipe(horizontal: event.deltaX, vertical: event.deltaY, timestamp: event.timestamp)
            } else {
                let inverted = event.isDirectionInvertedFromDevice
                decision = tracker.handle(
                    horizontal: TaskTabSwipeTracker.normalizedDelta(event.scrollingDeltaX, inverted: inverted, precise: event.hasPreciseScrollingDeltas),
                    vertical: TaskTabSwipeTracker.normalizedDelta(event.scrollingDeltaY, inverted: inverted, precise: event.hasPreciseScrollingDeltas),
                    phase: event.phase, momentum: event.momentumPhase, timestamp: event.timestamp)
            }
            if let direction = decision.direction { onSwipe?(reverseDirection ? direction.reversed : direction) }
            return decision.consumesEvent ? nil : event
        }

        private func accepts(_ event: NSEvent) -> Bool {
            // Scroll events target the window under the pointer, including non-key windows with system sharing controls.
            guard let window, event.window === window,
                  !isHiddenOrHasHiddenAncestor, NSEvent.pressedMouseButtons == 0,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)) else { return false }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
            if let field = window.firstResponder as? NSTextField, field.isEditable { return false }
            return true
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
