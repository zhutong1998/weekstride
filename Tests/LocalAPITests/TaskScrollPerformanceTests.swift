import AppKit
import Darwin
import QuartzCore
import SwiftUI
import XCTest
import WorkLedgerCore
@testable import WorkLedger

final class TaskScrollPerformanceTests: XCTestCase {
    @MainActor
    func testScrollLayoutBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["WORKLEDGER_SCROLL_BENCHMARK"] else {
            throw XCTSkip("Set WORKLEDGER_SCROLL_BENCHMARK to an output directory to measure isolated scrolling.")
        }
        guard let details = TaskDetailsMode(rawValue: environment["WORKLEDGER_SCROLL_DETAILS"] ?? "expanded"),
              let columns = TaskColumnMode(rawValue: environment["WORKLEDGER_SCROLL_COLUMNS"] ?? "one"),
              [TaskColumnMode.one, .two, .three].contains(columns) else {
            throw LedgerError.invalid("Benchmark details must be expanded/titles and columns must be one/two/three.")
        }
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let allFilter = try JSONEncoder().encode(TaskPlanFilter.all)
        let display = try JSONEncoder().encode(TaskDisplaySetting(columns: columns, details: details))
        defaults.setVolatileDomain(arguments.merging([
            "appLanguage": "en", "appTextSize": "standard", "appTimeFormat": "24",
            "taskColumns": columns.rawValue, "taskDetails": details.rawValue, "taskListEffect": "none",
            "taskPlanFilter.all": allFilter, "taskDisplay.all": display, "weekStart": 6,
            "apiEnabled": false, "remindersEnabled": false
        ]) { _, fixture in fixture }, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }

        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("WeekStride-scroll-\(UUID())")
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let dataURL = directory.appendingPathComponent("data.json")
        var sourceURL: URL?
        let bytes: Data
        if let path = environment["WORKLEDGER_SCROLL_DATA_DIR"] {
            let source = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            let live = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("local.workledger").resolvingSymlinksInPath().standardizedFileURL
            guard source.path != live.path else { throw LedgerError.invalid("Point WORKLEDGER_SCROLL_DATA_DIR at a data copy, never the live app directory.") }
            let url = source.appendingPathComponent("data.json")
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw LedgerError.invalid("Benchmark input must be a regular copied data.json file.") }
            sourceURL = url
            bytes = try Data(contentsOf: url)
        } else {
            bytes = try JSONEncoder().encode(Self.syntheticData())
        }
        // Only task metadata is copied; this benchmark never opens attachment contents.
        try bytes.write(to: dataURL, options: .atomic)
        let store = try WorkStore(directory: directory)
        let original = store.data
        let services = AppServices(store: store, recoveryMode: true)

        _ = NSApplication.shared
        let size = NSSize(width: 1520, height: 1100)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = RootView(store: store).environmentObject(store).environmentObject(services)
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.appTextScale, 1).environment(\.colorScheme, .light).appFont(.body)
        let host = ScrollBenchmarkHostingView(rootView: root)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(Self.descendants(host).compactMap { $0 as? NSScrollView }
            .filter { $0.contentView.bounds.width > 500 && ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1 }
            .max { $0.contentView.bounds.width < $1.contentView.bounds.width }, "Expected a scrollable task area in the isolated RootView.")
        let initialOffset = scroll.contentView.bounds.origin.y
        let initialProbes = Self.visibleProbes(in: host)
        var ticks: [[String: Any]] = []
        var durations: [Double] = []
        var elapsedDurations: [Double] = []
        var cpuDurations: [Double] = []
        var furthestOffset = initialOffset
        let totalStart = CACurrentMediaTime()
        let totalCPUStart = Self.threadCPUTime()
        for index in 0..<160 {
            let clip = scroll.contentView
            let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height)
            let requested = min(maximum, max(0, clip.bounds.origin.y + (index < 80 ? 90 : -90)))
            let calls = host.layoutCalls
            let start = CACurrentMediaTime()
            let cpuStart = Self.threadCPUTime()
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: requested))
            scroll.reflectScrolledClipView(clip)
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            let immediateMS = (CACurrentMediaTime() - start) * 1000
            // Let pending SwiftUI graph work run before the second layout flush.
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
            let settleStart = CACurrentMediaTime()
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            let settleMS = (CACurrentMediaTime() - settleStart) * 1000
            let measuredMS = immediateMS + settleMS
            durations.append(measuredMS)
            let tickElapsedMS = (CACurrentMediaTime() - start) * 1000
            elapsedDurations.append(tickElapsedMS)
            let cpuMS = (Self.threadCPUTime() - cpuStart) * 1000
            cpuDurations.append(cpuMS)
            let actual = clip.bounds.origin.y
            furthestOffset = max(furthestOffset, actual)
            ticks.append([
                "tick": index, "requestedY": requested, "actualY": actual,
                "layoutFlushMS": measuredMS, "immediateMS": immediateMS, "settleMS": settleMS,
                "elapsedMS": tickElapsedMS, "threadCPUMS": cpuMS,
                "hostingLayoutCalls": host.layoutCalls - calls,
                "visibleProbes": Self.visibleProbes(in: host)
            ])
            XCTAssertFalse(window.isVisible)
        }
        let elapsedMS = (CACurrentMediaTime() - totalStart) * 1000
        let totalCPUMS = (Self.threadCPUTime() - totalCPUStart) * 1000
        let finalProbes = Self.visibleProbes(in: host)
        window.close()
        await Task.yield()
        XCTAssertGreaterThan(furthestOffset - initialOffset, 100, "The benchmark must actually move the task viewport.")
        XCTAssertGreaterThan(initialProbes + finalProbes, 0, "The fixture must realize actual task cards.")
        XCTAssertEqual(store.data, original, "Scrolling must not mutate task data.")
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes, "Scrolling must not save the copied task file.")
        if let sourceURL { XCTAssertEqual(try Data(contentsOf: sourceURL), bytes, "The benchmark input copy must remain unchanged.") }
        XCTAssertFalse(files.fileExists(atPath: directory.appendingPathComponent("api-token").path))
        XCTAssertFalse(window.isVisible)

        let sorted = durations.sorted()
        let elapsedSorted = elapsedDurations.sorted()
        let cpuSorted = cpuDurations.sorted()
        let report: [String: Any] = [
            "dataset": sourceURL == nil ? "synthetic" : "copied", "taskCount": original.tasks.count,
            "detailsMode": details.rawValue, "columnMode": columns.rawValue,
            "stepCount": original.tasks.reduce(0) { $0 + $1.subtasks.count }, "projectCount": original.projects.count,
            "viewportWidth": size.width, "viewportHeight": size.height, "ticks": ticks,
            "medianLayoutFlushMS": sorted[sorted.count / 2],
            "p95LayoutFlushMS": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
            "maxLayoutFlushMS": sorted.last ?? 0, "totalElapsedMS": elapsedMS,
            "medianTickElapsedMS": elapsedSorted[elapsedSorted.count / 2],
            "p95TickElapsedMS": elapsedSorted[Int(ceil(Double(elapsedSorted.count) * 0.95)) - 1],
            "maxTickElapsedMS": elapsedSorted.last ?? 0,
            "medianThreadCPUMS": cpuSorted[cpuSorted.count / 2],
            "p95ThreadCPUMS": cpuSorted[Int(ceil(Double(cpuSorted.count) * 0.95)) - 1],
            "maxThreadCPUMS": cpuSorted.last ?? 0, "totalThreadCPUMS": totalCPUMS,
            "initialOffsetY": initialOffset, "furthestOffsetY": furthestOffset,
            "initialVisibleProbes": initialProbes, "finalVisibleProbes": finalProbes,
            "hostingLayoutCalls": host.layoutCalls, "storeUnchanged": store.data == original,
            "windowVisible": window.isVisible,
            "measurement": "Synchronous programmatic scroll/layout flush plus a fixed 1ms yield; elapsed includes pending graph work. Thread CPU includes main-thread work during that yield, excluding scheduler waits. Hidden fixture, not display-frame timing or FPS."
        ]
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try files.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("scroll-layout.json"), options: .atomic)
        print("Scroll layout benchmark: \(original.tasks.count) tasks; median \(report["medianLayoutFlushMS"]!), p95 \(report["p95LayoutFlushMS"]!), max \(report["maxLayoutFlushMS"]!) ms. Not FPS.")
    }

    private static func threadCPUTime() -> Double {
        precondition(Thread.isMainThread, "The benchmark CPU clock must measure the main thread, including after suspension.")
        var time = timespec()
        precondition(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func visibleProbes(in host: NSView) -> Int {
        descendants(host).compactMap { $0 as? TaskNativeDragSource.ProbeView }
            .filter { !$0.isHidden && !$0.visibleRect.isEmpty }.count
    }

    private static func syntheticData() -> LedgerData {
        let today = Calendar.current.startOfDay(for: Date())
        let projects = (0..<3).map { Project(name: "Operations \($0 + 1)", colorHex: ["168C83", "3478F6", "9462C4"][$0]) }
        let tasks: [WorkTask] = (0..<27).map { index in
            let subtasks: [Subtask] = (0..<(index < 22 ? 2 : 1)).map { step in
                Subtask(title: "Complete verification step \(step + 1)")
            }
            return WorkTask(projectID: projects[index % projects.count].id, title: "Review work item \(index + 1)",
                     details: String(repeating: "Review the deployment, verify its outcome, and document the next action.\n", count: 1 + index % 4),
                     notes: index.isMultiple(of: 3) ? "Confirm the owner and retain a rollback plan." : "",
                     subtasks: subtasks,
                     dueAt: index.isMultiple(of: 2) ? today.addingTimeInterval(Double(index + 1) * 86400) : nil,
                     reminderAt: index.isMultiple(of: 4) ? today.addingTimeInterval(18 * 3600) : nil,
                     repeatRule: index.isMultiple(of: 5) ? RepeatRule(every: 6, unit: .month) : nil,
                     plannedAt: index.isMultiple(of: 3) ? nil : today, planGranularity: index.isMultiple(of: 3) ? nil : .week)
        }
        return LedgerData(projects: projects, tasks: tasks)
    }
}

@MainActor
private final class ScrollBenchmarkHostingView<Content: View>: NSHostingView<Content> {
    var layoutCalls = 0
    override func layout() {
        layoutCalls += 1
        super.layout()
    }
}
