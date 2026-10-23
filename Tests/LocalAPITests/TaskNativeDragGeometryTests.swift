import AppKit
import Combine
import SwiftUI
import XCTest
@testable import WorkLedger

final class TaskNativeDragGeometryTests: XCTestCase {
    @MainActor func testNativeListContainersAllowCardDragButTheirEditingControlsBlockIt() {
        let lists: [NSTableView] = [NSTableView(), NSOutlineView()]
        for list in lists {
            let card = NSView(), content = NSView()
            list.addSubview(card)
            card.addSubview(content)
            XCTAssertFalse(TaskNativeDragSource.ProbeView.blocksCardDrag(from: list))
            XCTAssertFalse(TaskNativeDragSource.ProbeView.blocksCardDrag(from: content),
                           "A task card inside a native list must remain draggable.")

            let controls: [NSControl] = [NSButton(), NSTextField(), NSSlider(), NSControl(frame: .zero)]
            for control in controls {
                let child = NSView()
                card.addSubview(control)
                control.addSubview(child)
                XCTAssertTrue(TaskNativeDragSource.ProbeView.blocksCardDrag(from: control))
                XCTAssertTrue(TaskNativeDragSource.ProbeView.blocksCardDrag(from: child),
                              "The list exception must not allow dragging from a real control's content.")
            }
            let editor = NSTextView(frame: .zero)
            card.addSubview(editor)
            XCTAssertTrue(TaskNativeDragSource.ProbeView.blocksCardDrag(from: editor))
        }
        XCTAssertFalse(TaskNativeDragSource.ProbeView.blocksCardDrag(from: NSView()))
        XCTAssertFalse(TaskNativeDragSource.ProbeView.blocksCardDrag(from: nil))
    }

    @MainActor func testLazyStackDragSourcesKeepTheirOwnTask() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let taskIDs = (0..<3).map { _ in UUID() }
        let host = NSHostingView(rootView: ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { index in
                    Text("Task \(index)").frame(maxWidth: .infinity, minHeight: 100)
                        .modifier(TaskNativeDrag(taskID: taskIDs[index], enabled: true, prepare: { try? JSONEncoder().encode(TaskDragItem(taskID: taskIDs[index])) }, preview: { nil }, onDraggingChanged: { _ in }))
                }
            }.padding(28)
        })
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let probes = descendants(host).compactMap { $0 as? TaskNativeDragSource.ProbeView }
        XCTAssertEqual(probes.count, taskIDs.count)
        XCTAssertEqual(Set(probes.compactMap(\.taskID)), Set(taskIDs))
        var frames: [NSRect] = []
        for probe in probes {
            let id = try XCTUnwrap(probe.taskID)
            let payload = try JSONDecoder().decode(TaskDragItem.self, from: XCTUnwrap(probe.prepare()))
            XCTAssertEqual(payload.taskID, id)
            frames.append(probe.convert(probe.bounds, to: host))
            var ancestor: NSView? = probe
            while let view = ancestor {
                XCTAssertFalse(view.gestureRecognizers.contains { $0 is NSPanGestureRecognizer && $0.target is TaskNativeDragSource.ProbeView }, "Cards must not install competing ancestor/window gestures")
                ancestor = view.superview
            }
        }
        XCTAssertEqual(Set(frames.map(\.midY)).count, 3)
        XCTAssertTrue(frames.allSatisfy { abs($0.height - 100) < 1 })
    }

    @MainActor func testEndingAnOlderDragDoesNotRestoreHoverDuringAnotherDrag() {
        let state = TaskDragState()
        let first = UUID(), second = UUID()
        state.begin(first)
        XCTAssertEqual(state.taskID, first)
        state.begin(second)
        state.end(first)
        XCTAssertEqual(state.taskID, second)
        state.end(second)
        XCTAssertNil(state.taskID)
    }

    @MainActor func testUnchangedDragStateDoesNotPublish() {
        let state = TaskDragState()
        let id = UUID()
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }
        state.begin(id)
        state.begin(id)
        state.end(UUID())
        XCTAssertEqual(changes, 1)
        state.end(id)
        state.end(id)
        XCTAssertEqual(changes, 2)
        withExtendedLifetime(subscription) {}
    }

    func testPreviewKeepsPointSizeAndStaysRightOfCursor() {
        for mouse in [NSPoint.zero, NSPoint(x: 640, y: 480), NSPoint(x: -200, y: -50)] {
            for size in [NSSize(width: 270, height: 80), NSSize(width: 270, height: 240)] {
                let frame = TaskDragGeometry.previewFrame(mouse: mouse, size: size)
                XCTAssertEqual(frame.minX, mouse.x + 16)
                XCTAssertEqual(frame.midY, mouse.y)
                XCTAssertEqual(frame.size, size)
            }
        }
    }
}
