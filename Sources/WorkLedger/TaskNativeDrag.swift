import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class TaskDragState: ObservableObject {
    static let shared = TaskDragState()
    @Published private(set) var taskID: UUID?

    func begin(_ id: UUID) { if taskID != id { taskID = id } }
    func end(_ id: UUID) { if taskID == id { taskID = nil } }
}

enum TaskDragGeometry {
    static func previewFrame(mouse: NSPoint, size: NSSize) -> NSRect {
        NSRect(x: mouse.x + 16, y: mouse.y - size.height / 2, width: size.width, height: size.height)
    }
}

@MainActor final class TaskDragController: ObservableObject {
    weak var source: TaskNativeDragSource.ProbeView?
    func begin(taskID: UUID, startLocation: CGPoint) { source?.beginDrag(taskID: taskID, startLocation: startLocation) }
}

struct TaskNativeDrag: ViewModifier {
    var taskID: UUID
    var enabled: Bool
    var prepare: () -> Data?
    var preview: () -> NSImage?
    var onDraggingChanged: (Bool) -> Void
    @StateObject private var controller = TaskDragController()

    func body(content: Content) -> some View {
        content
            .background(TaskNativeDragSource(controller: controller, taskID: taskID, enabled: enabled, prepare: prepare, preview: preview, onDraggingChanged: onDraggingChanged))
            // SwiftUI scopes the gesture to this card, including inside a LazyVStack.
            .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { value in
                controller.begin(taskID: taskID, startLocation: value.startLocation)
            })
    }
}

struct TaskNativeDragSource: NSViewRepresentable {
    let controller: TaskDragController
    var taskID: UUID
    var enabled: Bool
    var prepare: () -> Data?
    var preview: () -> NSImage?
    var onDraggingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        controller.source = view
        view.taskID = taskID
        view.enabled = enabled
        view.prepare = prepare
        view.preview = preview
        view.onDraggingChanged = onDraggingChanged
    }

    final class ProbeView: NSView, NSDraggingSource {
        var taskID: UUID?
        var enabled = false
        var prepare: () -> Data? = { nil }
        var preview: () -> NSImage? = { nil }
        var onDraggingChanged: (Bool) -> Void = { _ in }
        private var activeSource: ProbeView?
        private var draggingTaskID: UUID?
        private var activeDraggingChanged: ((Bool) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        static func blocksCardDrag(from hit: NSView?) -> Bool {
            var ancestor = hit
            while let view = ancestor {
                // Native lists are container controls; their text fields and buttons still block dragging.
                if view is NSTextView || (view is NSControl && !(view is NSTableView)) { return true }
                ancestor = view.superview
            }
            return false
        }

        func beginDrag(taskID sourceID: UUID, startLocation: CGPoint) {
            guard enabled, sourceID == taskID, draggingTaskID == nil, TaskDragState.shared.taskID == nil,
                  let host = window?.contentView, let event = NSApp.currentEvent,
                  event.type == .leftMouseDragged, event.window === window else { return }
            let start = NSPoint(x: startLocation.x, y: isFlipped ? startLocation.y : bounds.height - startLocation.y)
            let point = convert(start, to: host.superview)
            guard !Self.blocksCardDrag(from: host.hitTest(point)) else { return }
            guard let data = prepare(), let image = preview() else { return }
            let item = NSPasteboardItem()
            item.setData(data, forType: .init(UTType.workLedgerTask.identifier))
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let mouse = host.convert(event.locationInWindow, from: nil)
            draggingItem.setDraggingFrame(TaskDragGeometry.previewFrame(mouse: mouse, size: image.size), contents: image)
            // A successful drop may remove this card before AppKit sends the final source callback.
            activeSource = self
            draggingTaskID = sourceID
            activeDraggingChanged = onDraggingChanged
            let session = host.beginDraggingSession(with: [draggingItem], event: event, source: self)
            session.draggingFormation = .none
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? [.copy, .move] : []
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            if let draggingTaskID { TaskDragState.shared.begin(draggingTaskID) }
            activeDraggingChanged?(true)
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if let draggingTaskID { TaskDragState.shared.end(draggingTaskID) }
            draggingTaskID = nil
            activeDraggingChanged?(false)
            activeDraggingChanged = nil
            activeSource = nil
        }
    }
}
