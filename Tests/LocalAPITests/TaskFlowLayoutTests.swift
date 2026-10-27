import AppKit
import SwiftUI
import XCTest
@testable import WorkLedger

final class TaskFlowLayoutTests: XCTestCase {
    func testItemsKeepNaturalWidthsOnOneRow() {
        let result = TaskFlowLayout.arrange([
            CGSize(width: 100, height: 20), CGSize(width: 80, height: 30), CGSize(width: 60, height: 15)
        ], width: 300)
        XCTAssertEqual(result.frames, [
            CGRect(x: 0, y: 0, width: 100, height: 20),
            CGRect(x: 110, y: 0, width: 80, height: 30),
            CGRect(x: 200, y: 0, width: 60, height: 15)
        ])
        XCTAssertEqual(result.size, CGSize(width: 260, height: 30))
    }

    func testOverflowWrapsAfterTheTallestItemInTheRow() {
        let result = TaskFlowLayout.arrange([
            CGSize(width: 80, height: 20), CGSize(width: 60, height: 30), CGSize(width: 70, height: 12)
        ], width: 150)
        XCTAssertEqual(result.frames[1], CGRect(x: 90, y: 0, width: 60, height: 30))
        XCTAssertEqual(result.frames[2], CGRect(x: 0, y: 34, width: 70, height: 12))
        XCTAssertEqual(result.size, CGSize(width: 150, height: 46))
    }

    func testOversizedItemIsConstrainedWithoutAnEmptyFirstRow() {
        let result = TaskFlowLayout.arrange([
            CGSize(width: 240, height: 20), CGSize(width: 40, height: 10)
        ], width: 100, spacing: 12, rowSpacing: 6)
        XCTAssertEqual(result.frames, [
            CGRect(x: 0, y: 0, width: 100, height: 20),
            CGRect(x: 0, y: 26, width: 40, height: 10)
        ])
        XCTAssertEqual(result.size, CGSize(width: 100, height: 36))
    }

    func testEmptyAndUnspecifiedWidth() {
        let empty = TaskFlowLayout.arrange([], width: 100)
        XCTAssertTrue(empty.frames.isEmpty)
        XCTAssertEqual(empty.size, .zero)
        let natural = TaskFlowLayout.arrange([CGSize(width: 80, height: 20), CGSize(width: 100, height: 15)], width: nil)
        XCTAssertEqual(natural.frames[1], CGRect(x: 90, y: 0, width: 100, height: 15))
        XCTAssertEqual(natural.size, CGSize(width: 190, height: 20))
    }

    func testMinimumAndUnboundedWidthProposalsStayFinite() {
        let sizes = [CGSize(width: 80, height: 20), CGSize(width: 100, height: 15)]
        let minimum = TaskFlowLayout.arrange(sizes, width: 0)
        XCTAssertEqual(minimum.frames, [
            CGRect(x: 0, y: 0, width: 0, height: 20),
            CGRect(x: 0, y: 24, width: 0, height: 15)
        ])
        XCTAssertEqual(minimum.size, CGSize(width: 0, height: 39))
        let unbounded = TaskFlowLayout.arrange(sizes, width: .infinity)
        XCTAssertEqual(unbounded.size, CGSize(width: 190, height: 20))
    }

    @MainActor
    func testPlacementCacheDoesNotKeepOldTextOrFontMeasurements() async throws {
        try await withNativeFixture(usesText: true) { state, measurements, host in
            let shortHeight = measurements.size.height
            XCTAssertGreaterThan(shortHeight, 0)
            state.text = String(repeating: "Read the deployment notes and verify the attachment. ", count: 12)
            await self.settle(host)
            let wrappedHeight = measurements.size.height
            XCTAssertGreaterThan(wrappedHeight, shortHeight * 3)

            state.scale = 1.5
            await self.settle(host)
            XCTAssertGreaterThan(measurements.size.height, wrappedHeight)

            state.text = "Short"
            await self.settle(host)
            XCTAssertLessThan(measurements.size.height, wrappedHeight)
        }
    }

    @MainActor
    func testPlacementCacheTracksContainerWidthAndInsertedRemovedItems() async throws {
        try await withNativeFixture(usesText: false) { state, measurements, host in
            XCTAssertEqual(measurements.size.height, 20, accuracy: 1)
            state.width = 150
            await self.settle(host)
            XCTAssertEqual(measurements.size.height, 68, accuracy: 1)

            state.count = 4
            await self.settle(host)
            XCTAssertEqual(measurements.size.height, 92, accuracy: 1)

            state.scale = 1.5
            await self.settle(host)
            XCTAssertEqual(measurements.size.height, 132, accuracy: 1)

            state.count = 1
            await self.settle(host)
            XCTAssertEqual(measurements.size.height, 30, accuracy: 1)
        }
    }

    @MainActor
    private func withNativeFixture(usesText: Bool,
                                   _ work: (FlowState, FlowMeasurements, NSView) async throws -> Void) async throws {
        _ = NSApplication.shared
        let state = FlowState()
        if usesText { state.count = 1 }
        let measurements = FlowMeasurements()
        let host = NSHostingView(rootView: FlowFixture(state: state, measurements: measurements, usesText: usesText)
            .frame(width: 640, height: 1600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.layoutIfNeeded()
        await settle(host)
        _ = try XCTUnwrap(measurements.view, "The fixture must realize the flow's native measurement probe.")
        try await work(state, measurements, host)
        XCTAssertFalse(window.isVisible, "Layout checks must not open a desktop window.")
    }

    @MainActor
    private func settle(_ host: NSView) async {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(15))
        }
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class FlowState: ObservableObject {
    @Published var text = "Short attachment"
    @Published var width: CGFloat = 320
    @Published var scale: CGFloat = 1
    @Published var count = 3
}

@MainActor
private final class FlowMeasurements {
    weak var view: NSView?
    var size: CGSize { view?.bounds.size ?? .zero }
}

@MainActor
private struct FlowFixture: View {
    @ObservedObject var state: FlowState
    let measurements: FlowMeasurements
    let usesText: Bool

    var body: some View {
        TaskFlowLayout(spacing: 8, rowSpacing: 4) {
            ForEach(0..<state.count, id: \.self) { _ in
                if usesText {
                    Text(state.text).font(.system(size: 13 * state.scale))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Color.clear.frame(width: 80 * state.scale, height: 20 * state.scale)
                }
            }
        }
        .background(FlowSizeProbe(measurements: measurements))
        .frame(width: state.width, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
private struct FlowSizeProbe: NSViewRepresentable {
    let measurements: FlowMeasurements
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        measurements.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { measurements.view = view }
}
