import AppKit
import SwiftUI
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class TaskGridHeightTests: XCTestCase {
    func testGridCardsShareEachRowsTallestHeightAndShrinkAfterContentRemoval() async throws {
        try await withFixture(columns: 3, fillsRows: false) { natural in
            let heights = try self.heights(in: natural)
            XCTAssertLessThan(heights[0], heights[2])
            XCTAssertLessThan(heights[1], heights[2])

            try await self.withFixture(columns: 3, fillsRows: true) { grid in
                let filled = try self.heights(in: grid)
                for index in 0..<3 { XCTAssertEqual(filled[index], heights[0..<3].max()!, accuracy: 1) }
                for index in 3..<6 { XCTAssertEqual(filled[index], heights[3..<6].max()!, accuracy: 1) }
                XCTAssertGreaterThan(filled[0], filled[3], "Each row must keep its own maximum, not the tallest card in the whole list.")
                let secondRow = Array(filled[3..<6])
                try grid.store.updateTask(id: grid.tasks[2].id) { $0.details = "" }
                await self.settle(grid.host)
                let reduced = try self.heights(in: grid)
                XCTAssertLessThan(reduced[0], filled[0])
                for index in 1..<3 { XCTAssertEqual(reduced[index], reduced[0], accuracy: 1) }
                for index in 3..<6 { XCTAssertEqual(reduced[index], secondRow[index - 3], accuracy: 1) }
                XCTAssertFalse(grid.window.isVisible)
            }
        }
    }

    func testSingleColumnKeepsNaturalTaskHeights() async throws {
        try await withFixture(columns: 1, fillsRows: false) { fixture in
            let heights = try self.heights(in: fixture)
            XCTAssertLessThan(heights[0], heights[2])
            XCTAssertLessThan(heights[3], heights[4])
            XCTAssertFalse(fixture.window.isVisible)
        }
    }

    func testExpandedAndCollapsedCardsAlignTheirActualBordersWithinEachGridRow() async throws {
        let modes: [TaskDetailsMode] = [.titles, .titles, .expanded, .titles, .expanded, .titles]
        try await withFixture(columns: 3, fillsRows: true, detailModes: modes) { fixture in
            let borders = try self.borderHeights(in: fixture)
            for index in 1..<3 { XCTAssertEqual(borders[index], borders[0], accuracy: 1) }
            for index in 4..<6 { XCTAssertEqual(borders[index], borders[3], accuracy: 1) }
            XCTAssertGreaterThan(borders[0], borders[3], "Rows with different expanded content must keep independent heights.")
            XCTAssertGreaterThan(borders[0], 150, "Collapsed siblings must fill the row beside the expanded card.")
        }
    }

    private struct Fixture {
        let store: WorkStore
        let tasks: [WorkTask]
        let host: NSView
        let window: NSWindow
        let measurements: TaskGridHeightMeasurements
    }

    private func withFixture(columns: Int, fillsRows: Bool, detailModes: [TaskDetailsMode]? = nil,
                             _ work: (Fixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WeekStride-grid-height-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let lineCounts = [0, 0, 8, 1, 3, 1]
        let tasks = lineCounts.enumerated().map { index, count in
            WorkTask(title: "Task \(index + 1)", details: Array(repeating: "Review the next step.", count: count).joined(separator: "\n"))
        }
        for task in tasks { try store.saveTask(task) }
        let services = AppServices(store: store, recoveryMode: true)
        let measurements = TaskGridHeightMeasurements()
        let content = List {
            ForEach(Array(stride(from: 0, to: tasks.count, by: columns)), id: \.self) { start in
                TaskColumnLayout(idealWidth: 960) {
                    ForEach(start..<min(start + columns, tasks.count), id: \.self) { index in
                        ObservedTaskCard(store: store, task: tasks[index], project: nil, isHistory: false)
                            .environment(\.taskDetailsMode, detailModes?[index] ?? .expanded)
                            .frame(maxWidth: .infinity, maxHeight: fillsRows ? .infinity : nil, alignment: .top)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: TaskGridHeightFrames.self, value: [index: proxy.frame(in: .global)])
                            })
                    }
                }
                .listRowSeparator(.hidden)
            }
            .environment(\.taskCardFillsGridRow, fillsRows)
        }
        .listStyle(.plain)
        .environmentObject(store).environmentObject(services)
        .environment(\.taskDetailsMode, .expanded)
        .environment(\.compactTaskPlan, true)
        .environment(\.appTextScale, 1)
        .onPreferenceChange(TaskGridHeightFrames.self) { measurements.frames = $0 }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .frame(width: 960, height: 1400)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        await settle(host)
        try await work(Fixture(store: store, tasks: tasks, host: host, window: window, measurements: measurements))
    }

    private func heights(in fixture: Fixture) throws -> [CGFloat] {
        try fixture.tasks.indices.map { index in
            let frame = try XCTUnwrap(fixture.measurements.frames[index], "Every synthetic card must be realized.")
            XCTAssertGreaterThan(frame.width, 250)
            return frame.height
        }
    }

    private func borderHeights(in fixture: Fixture) throws -> [CGFloat] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let probes = descendants(fixture.host).compactMap { $0 as? TaskNativeDragSource.ProbeView }
        return try fixture.tasks.map { task in
            let probe = try XCTUnwrap(probes.first { $0.taskID == task.id })
            return probe.bounds.height
        }
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class TaskGridHeightMeasurements {
    var frames: [Int: CGRect] = [:]
}

private struct TaskGridHeightFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}
