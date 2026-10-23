import AppKit
import Darwin
import QuartzCore
import SwiftUI
import XCTest
import WorkLedgerCore
@testable import WorkLedger

final class TaskNavigationPerformanceTests: XCTestCase {
    @MainActor
    func testNavigationLayoutBenchmark() async throws {
        #if !WORKLEDGER_PERFORMANCE_TESTS
        throw XCTSkip("Rebuild with -Xswiftc -DWORKLEDGER_PERFORMANCE_TESTS to enable the shared navigation-action benchmark receivers.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["WORKLEDGER_NAVIGATION_BENCHMARK"] else {
            throw XCTSkip("Set WORKLEDGER_NAVIGATION_BENCHMARK to measure isolated RootView navigation.")
        }
        guard let effect = TaskListEffect(rawValue: environment["WORKLEDGER_NAVIGATION_EFFECT"] ?? "none") else {
            throw LedgerError.invalid("Navigation effect must be none/slide/slideFade/scaleFade.")
        }
        guard let tickCount = Int(environment["WORKLEDGER_NAVIGATION_TICKS"] ?? "160"), (32...1000).contains(tickCount) else {
            throw LedgerError.invalid("Navigation ticks must be an integer from 32 through 1000.")
        }
        let columnScenario = environment["WORKLEDGER_NAVIGATION_COLUMNS"] ?? "mixed"
        guard ["one", "mixed"].contains(columnScenario) else {
            throw LedgerError.invalid("Navigation columns must be one/mixed.")
        }
        let savedColumns: [TaskColumnMode] = columnScenario == "one" ? [.one, .one] : [.two, .one]
        let files = FileManager.default
        let copiedData = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../work/scroll-fix-20261023/test-data", isDirectory: true).standardizedFileURL
        let source = environment["WORKLEDGER_NAVIGATION_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? copiedData
        let sourceDirectory = source.resolvingSymlinksInPath().standardizedFileURL
        let live = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.workledger").resolvingSymlinksInPath().standardizedFileURL
        guard sourceDirectory.path != live.path else {
            throw LedgerError.invalid("Navigation benchmarks require a fixed data copy, never the live app directory.")
        }
        let sourceURL = sourceDirectory.appendingPathComponent("data.json")
        let info = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else {
            throw LedgerError.invalid("Navigation input must be a regular copied data.json file.")
        }
        let bytes = try Data(contentsOf: sourceURL)
        let directory = files.temporaryDirectory.appendingPathComponent("WeekStride-navigation-\(UUID())")
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let dataURL = directory.appendingPathComponent("data.json")
        // Copy metadata only; attachment contents and the formal store are never opened.
        try bytes.write(to: dataURL, options: .atomic)
        let store = try WorkStore(directory: directory)
        let original = store.data
        let today = Calendar.current.startOfDay(for: Date())
        let routes = original.projects.filter { !$0.isArchived }.compactMap { project -> NavigationRoute? in
            let scope = SidebarItem.project(project.id)
            let pending = TaskListPolicy.visibleTasks(
                TaskListPolicy.tasks(in: scope, data: original, relativeTo: today, firstWeekday: 6),
                projects: original.projects, scope: scope, filter: .all, search: "", relativeTo: today, firstWeekday: 6)
            guard let first = pending.first else { return nil }
            let tasks = pending + TaskListPolicy.completedTasks(in: scope, data: original, relativeTo: today, firstWeekday: 6)
            return NavigationRoute(scope: scope, tasks: tasks,
                                   filter: TaskPlanFilter(task: first, relativeTo: today, firstWeekday: 6))
        }.sorted { $0.tasks.count > $1.tasks.count }.prefix(2)
        guard routes.count == 2 else { throw LedgerError.invalid("Navigation data must contain two active projects with pending tasks.") }
        let projects = Array(routes)
        let allTasks = TaskListPolicy.tasks(in: .all, data: original, relativeTo: today, firstWeekday: 6)
            + TaskListPolicy.completedTasks(in: .all, data: original, relativeTo: today, firstWeekday: 6)
        let allIDs = Set(allTasks.map(\.id))

        guard let defaultsDomain = Bundle.main.bundleIdentifier,
              !["local.workledger", "local.weekstride.refactor"].contains(defaultsDomain) else {
            throw LedgerError.invalid("Navigation preference writes require a test-process bundle domain, never a formal app domain.")
        }
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let fixture: [String: Any] = [
            "appLanguage": "en", "appTextSize": "standard", "appTimeFormat": "24", "weekStart": 6,
            "taskColumns": "one", "taskDetails": "expanded", "taskListEffect": effect.rawValue,
            "apiEnabled": false, "remindersEnabled": false
        ]
        let scopes = [SidebarItem.all] + projects.map(\.scope)
        let preferenceKeys = Set(scopes.flatMap { ["taskPlanFilter.\($0.planFilterPreferenceKey)", "taskDisplay.\($0.planFilterPreferenceKey)"] })
        let originalPreferences = defaults.persistentDomain(forName: defaultsDomain) ?? [:]
        defer {
            for key in preferenceKeys {
                if let value = originalPreferences[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        let globalArguments = arguments.filter { !$0.key.hasPrefix("taskPlanFilter.") && !$0.key.hasPrefix("taskDisplay.") }
        defaults.setVolatileDomain(globalArguments.merging(fixture) { _, value in value }, forName: UserDefaults.argumentDomain)
        let filters = PlanFilterPreferences(defaults: defaults)
        let displays = TaskDisplayPreferences(defaults: defaults)
        filters.save(.all, for: "all")
        displays.save(TaskDisplaySetting(columns: .one, details: .expanded), for: "all")
        for (index, route) in projects.enumerated() {
            let key = route.scope.planFilterPreferenceKey
            filters.save(route.filter, for: key)
            // Compare the all-one-column setup with different saved destination layouts.
            displays.save(TaskDisplaySetting(columns: savedColumns[index], details: .expanded), for: key)
        }
        let services = AppServices(store: store, recoveryMode: true)

        _ = NSApplication.shared
        let size = NSSize(width: 1520, height: 1100)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = RootView(store: store).environmentObject(store).environmentObject(services)
            .environment(\.locale, Locale(identifier: "en")).environment(\.appTextScale, 1)
            .environment(\.colorScheme, .light).appFont(.body)
        let host = NavigationBenchmarkHostingView(rootView: root)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(220))
        host.layoutSubtreeIfNeeded()
        var previousVisible = Self.visibleTaskIDs(in: host)
        XCTAssertFalse(previousVisible.isEmpty, "The fixture must realize actual task cards.")
        var observedTaskLists = Self.taskListIdentities(in: host)
        var changedViewports = 0
        var ticks: [[String: Any]] = []
        let settlingSeconds = TaskListEffect.duration + 0.04
        let totalStart = CACurrentMediaTime()
        let totalCPUStart = Self.threadCPUTime()
        for index in 0..<tickCount {
            let routeIndex = (index / 4) % projects.count
            let route = projects[routeIndex]
            let phase = index % 4
            let expectedIDs: Set<UUID>
            let kind: String
            switch phase {
            case 0:
                kind = "project-sidebar-action"
                expectedIDs = Set(route.tasks.filter { route.filter.includes($0, relativeTo: today, firstWeekday: 6) }.map(\.id))
            case 1:
                kind = "project-filter-all"; expectedIDs = Set(route.tasks.map(\.id))
            case 2:
                kind = "project-filter-bucket"
                expectedIDs = Set(route.tasks.filter { route.filter.includes($0, relativeTo: today, firstWeekday: 6) }.map(\.id))
            default:
                kind = "global-sidebar-action"; expectedIDs = allIDs
            }
            let calls = host.layoutCalls
            let start = CACurrentMediaTime()
            let cpuStart = Self.threadCPUTime()
            if phase == 0 || phase == 3 {
                NotificationCenter.default.post(name: .init("WorkLedger.testSelectScope"), object: phase == 0 ? route.scope : SidebarItem.all)
            } else {
                NotificationCenter.default.post(name: .init("WorkLedger.testSelectPlanFilter"), object: phase == 1 ? TaskPlanFilter.all : route.filter)
            }
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            let immediateMS = (CACurrentMediaTime() - start) * 1000
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
            let firstSettleStart = CACurrentMediaTime()
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            var layoutMS = immediateMS + (CACurrentMediaTime() - firstSettleStart) * 1000
            let settlingStart = CACurrentMediaTime()
            let firstLayoutElapsedMS = (settlingStart - start) * 1000
            // Allow a full transition window after initial layout, even when that layout is slow.
            while CACurrentMediaTime() - settlingStart < settlingSeconds {
                try await Task.sleep(for: .milliseconds(16))
                let flushStart = CACurrentMediaTime()
                host.layoutSubtreeIfNeeded()
                CATransaction.flush()
                layoutMS += (CACurrentMediaTime() - flushStart) * 1000
            }
            let elapsedMS = (CACurrentMediaTime() - start) * 1000
            let cpuMS = (Self.threadCPUTime() - cpuStart) * 1000
            let visible = Self.visibleTaskIDs(in: host)
            let taskLists = Self.taskListIdentities(in: host)
            observedTaskLists.formUnion(taskLists)
            if visible != previousVisible { changedViewports += 1 }
            previousVisible = visible
            XCTAssertFalse(visible.isEmpty, "Every destination must realize task cards (tick \(index)).")
            XCTAssertTrue(visible.isSubset(of: expectedIDs), "The settled viewport must contain destination tasks (tick \(index)).")
            XCTAssertFalse(window.isVisible)
            ticks.append([
                "tick": index, "kind": kind, "projectIndex": routeIndex,
                "layoutFlushMS": layoutMS, "immediateMS": immediateMS,
                "firstLayoutElapsedMS": firstLayoutElapsedMS, "elapsedMS": elapsedMS, "threadCPUMS": cpuMS,
                "hostingLayoutCalls": host.layoutCalls - calls, "visibleTaskCount": visible.count,
                "expectedTaskCount": expectedIDs.count, "taskListObjectIdentifiers": taskLists.sorted()
            ])
        }
        let loopElapsedMS = (CACurrentMediaTime() - totalStart) * 1000
        let loopCPUMS = (Self.threadCPUTime() - totalCPUStart) * 1000
        let totalElapsedMS = ticks.compactMap { $0["elapsedMS"] as? Double }.reduce(0, +)
        let totalCPUMS = ticks.compactMap { $0["threadCPUMS"] as? Double }.reduce(0, +)
        window.close()
        await Task.yield()
        XCTAssertGreaterThan(changedViewports, tickCount / 3, "Navigation must change actual visible task UUIDs.")
        XCTAssertTrue(store.data == original, "Navigation must not mutate task data.")
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes, "Navigation must not save the isolated task file.")
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes, "The fixed input copy must remain unchanged.")
        XCTAssertFalse(files.fileExists(atPath: directory.appendingPathComponent("api-token").path))
        let finalPreferences = defaults.persistentDomain(forName: defaultsDomain) ?? [:]
        let preferencesConfined = NSDictionary(dictionary: originalPreferences.filter { !preferenceKeys.contains($0.key) })
            .isEqual(to: finalPreferences.filter { !preferenceKeys.contains($0.key) })
        XCTAssertTrue(preferencesConfined, "Navigation must write only the isolated fixture's scoped preferences.")
        var byKind: [String: Any] = [:]
        for kind in Set(ticks.compactMap { $0["kind"] as? String }) {
            byKind[kind] = Self.statistics(ticks.filter { $0["kind"] as? String == kind })
        }
        let report: [String: Any] = [
            "dataset": "copied", "taskCount": original.tasks.count, "projectCount": original.projects.count,
            "stepCount": original.tasks.reduce(0) { $0 + $1.subtasks.count }, "effect": effect.rawValue,
            "columnScenario": columnScenario, "savedColumnModes": savedColumns.map(\.rawValue), "globalColumnMode": "one", "detailsMode": "expanded",
            "viewportWidth": size.width, "viewportHeight": size.height, "settlingWindowMS": settlingSeconds * 1000,
            "tickCount": tickCount, "ticks": ticks, "statistics": Self.statistics(ticks), "statisticsByKind": byKind,
            "totalElapsedMS": totalElapsedMS, "totalThreadCPUMS": totalCPUMS,
            "wholeLoopElapsedMS": loopElapsedMS, "wholeLoopThreadCPUMS": loopCPUMS,
            "changedViewports": changedViewports, "hostingLayoutCalls": host.layoutCalls,
            "observedTaskListObjectIdentifiers": observedTaskLists.sorted(), "observedTaskListIdentityCount": observedTaskLists.count,
            "storeUnchanged": store.data == original, "windowVisible": window.isVisible,
            "defaultsDomain": defaultsDomain, "fixturePreferenceKeys": preferenceKeys.sorted(),
            "preferenceWritesConfinedToFixtureKeys": preferencesConfined, "fixturePreferencesRestoredAtExit": true,
            "systemReduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "trigger": "Compile-time WORKLEDGER_PERFORMANCE_TESTS receivers dispatch typed SidebarItem/TaskPlanFilter values directly to the same selectScope/selectPlanFilter actions as sidebar and plan buttons. Scoped preferences are configured once in the guarded test-process defaults domain and restored at exit. Real plan actions save normally; no per-tick harness defaults preparation occurs.",
            "measurement": "Hidden RootView shared-navigation-action-to-layout timing, not literal mouse clicks or FPS. First layout includes a 1ms yield; all effects then use a full 220ms settling window with 16ms layout flushes. Tick metrics and totalElapsedMS/totalThreadCPUMS include normal action preference saves; wholeLoop metrics also include harness inspection overhead. Main-thread CPU excludes scheduler waits. Task-list identities are native table ancestors of task probes, excluding the sidebar; address reuse can undercount rebuilt instances."
        ]
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try files.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("navigation-layout-\(effect.rawValue).json"), options: .atomic)
        print("Navigation benchmark: effect=\(effect.rawValue), ticks=\(ticks.count), main-thread CPU=\(totalCPUMS)ms. Hidden shared-action/layout timing, not FPS.")
        #endif
    }

    private static func statistics(_ ticks: [[String: Any]]) -> [String: Any] {
        var result: [String: Any] = ["count": ticks.count]
        for key in ["layoutFlushMS", "firstLayoutElapsedMS", "elapsedMS", "threadCPUMS"] {
            let sorted = ticks.compactMap { $0[key] as? Double }.sorted()
            guard !sorted.isEmpty else { continue }
            result[key] = ["median": sorted[sorted.count / 2], "p95": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
                           "max": sorted.last!, "total": sorted.reduce(0, +)]
        }
        return result
    }

    private static func threadCPUTime() -> Double {
        precondition(Thread.isMainThread)
        var time = timespec()
        precondition(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func visibleTaskIDs(in host: NSView) -> Set<UUID> {
        Set(descendants(host).compactMap { view -> UUID? in
            guard let probe = view as? TaskNativeDragSource.ProbeView, !probe.isHiddenOrHasHiddenAncestor,
                  !probe.bounds.intersection(probe.visibleRect).isEmpty else { return nil }
            return probe.taskID
        })
    }

    @MainActor private static func taskListIdentities(in host: NSView) -> Set<String> {
        var identities: Set<String> = []
        for probe in descendants(host).compactMap({ $0 as? TaskNativeDragSource.ProbeView }) {
            var ancestor = probe.superview
            while let view = ancestor {
                if view is NSTableView { identities.insert(String(describing: ObjectIdentifier(view))) }
                ancestor = view.superview
            }
        }
        return identities
    }

}

private struct NavigationRoute {
    let scope: SidebarItem
    let tasks: [WorkTask]
    let filter: TaskPlanFilter
}

@MainActor
private final class NavigationBenchmarkHostingView<Content: View>: NSHostingView<Content> {
    var layoutCalls = 0
    override func layout() {
        layoutCalls += 1
        super.layout()
    }
}
