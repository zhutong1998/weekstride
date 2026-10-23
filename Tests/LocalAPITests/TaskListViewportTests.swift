import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import WorkLedger

@MainActor
final class TaskListViewportTests: XCTestCase {
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private struct Fixture: View {
        let marker: String
        let rows: [Int]

        var body: some View {
            VStack(spacing: 0) {
                EnvironmentProbe(marker: marker).frame(height: 1)
                List(rows, id: \.self) { Text("Synthetic row \($0)").padding(.vertical, 8) }
                    .listStyle(.plain)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private struct EnvironmentProbe: NSViewRepresentable {
        @Environment(\.locale) private var locale
        @Environment(\.appTextScale) private var textScale
        @Environment(\.taskPlanningDay) private var planningDay
        @Environment(\.colorScheme) private var colorScheme
        let marker: String

        func makeNSView(context: Context) -> ProbeView { ProbeView() }
        func updateNSView(_ view: ProbeView, context: Context) {
            view.marker = marker; view.locale = locale.identifier
            view.textScale = textScale; view.planningDay = planningDay
            view.colorScheme = colorScheme
        }

        final class ProbeView: NSView {
            var marker = ""
            var locale = ""
            var textScale: Double = 0
            var planningDay = Date.distantPast
            var colorScheme = ColorScheme.light
        }
    }

    private struct AppearanceFixture: View {
        @State private var draft = "Unfinished theme draft"
        var body: some View {
            VStack(spacing: 0) {
                EnvironmentProbe(marker: "Unchanged theme content").frame(height: 1)
                TextField("Theme editor", text: $draft).textFieldStyle(.plain).padding(6)
                List(0..<40, id: \.self) { Text("Theme row \($0)").padding(.vertical, 8) }.listStyle(.plain)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private final class AppearanceModel: ObservableObject {
        @Published var scheme = ColorScheme.light
    }

    private struct AppearanceEnvironment<Content: View>: View {
        @ObservedObject var model: AppearanceModel
        let content: Content
        var body: some View { content.preferredColorScheme(model.scheme) }
    }

    func testPageChangesPreserveHostingViewAndNativeListIdentity() async throws {
        try await withFixture { view in
            let host = view.hostingView
            let nativeList = try XCTUnwrap(self.nativeList(in: view))
            let scroll = try XCTUnwrap(self.descendants(view).compactMap { $0 as? NSScrollView }.first)
            let destinations = [TaskListPageID(scope: .all, filter: .nextWeek),
                                TaskListPageID(scope: .thisWeek, filter: .thisWeek)]
            for (index, page) in destinations.enumerated() {
                view.update(content: Fixture(marker: "Destination \(index)", rows: Array(20..<50)),
                            environment: EnvironmentValues(), page: page,
                            slide: .horizontal(forward: true), effect: .none, reduceMotion: false)
                await self.settle(view)
                XCTAssertTrue(view.hostingView === host)
                XCTAssertTrue(self.nativeList(in: view) === nativeList, "Navigation must update the existing native list")
                XCTAssertTrue(self.descendants(view).contains { $0 === scroll })
                XCTAssertEqual(self.probe(in: view)?.marker, "Destination \(index)")
                XCTAssertNil(view.snapshotLayer)
                XCTAssertFalse(view.isTransitioning)
            }
        }
    }

    func testSlideUsesFullViewportAndReleasesTheOutgoingImage() async throws {
        try await withFixture { view in
            let nativeList = try XCTUnwrap(self.nativeList(in: view))
            view.prepareNavigation()
            view.update(content: Fixture(marker: "Incoming", rows: Array(20..<50)),
                        environment: EnvironmentValues(), page: TaskListPageID(scope: .all, filter: .nextWeek),
                        slide: .horizontal(forward: true), effect: .slide, reduceMotion: false)
            let snapshot = try XCTUnwrap(view.snapshotLayer)
            XCTAssertNotNil(snapshot.contents)
            XCTAssertTrue(view.isTransitioning)
            XCTAssertNil(view.hitTest(NSPoint(x: 100, y: 100)), "Moving controls must not receive clicks at stale logical positions")
            XCTAssertNil(view.hostingView.layer?.animation(forKey: "WeekStride.pageTransition"), "The animation must wait until updateNSView has returned")
            await self.settle(view)
            let incoming = try XCTUnwrap(self.transformAnimation(on: view.hostingView.layer))
            let outgoing = try XCTUnwrap(self.transformAnimation(on: snapshot))
            XCTAssertEqual(try XCTUnwrap(incoming.fromValue as? NSValue).caTransform3DValue.m41, view.bounds.width, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(outgoing.toValue as? NSValue).caTransform3DValue.m41, -view.bounds.width, accuracy: 0.01)
            XCTAssertEqual(view.hostingView.layer?.animation(forKey: "WeekStride.pageTransition")?.duration,
                           TaskListEffect.duration)
            await self.finishAnimation(view)
            XCTAssertNil(view.snapshotLayer)
            XCTAssertFalse(view.isTransitioning)
            XCTAssertNil(snapshot.superlayer)
            XCTAssertTrue(self.nativeList(in: view) === nativeList)
        }
    }

    func testRapidNavigationKeepsOnlyOneImageAndCanBeCancelled() async throws {
        try await withFixture { view in
            view.prepareNavigation()
            view.update(content: Fixture(marker: "Second", rows: Array(20..<50)), environment: EnvironmentValues(),
                        page: TaskListPageID(scope: .all, filter: .nextWeek),
                        slide: .horizontal(forward: true), effect: .slideFade, reduceMotion: false)
            let first = try XCTUnwrap(view.snapshotLayer)
            let generation = view.transitionGeneration
            view.prepareNavigation()
            view.update(content: Fixture(marker: "Third", rows: Array(50..<80)), environment: EnvironmentValues(),
                        page: TaskListPageID(scope: .thisWeek, filter: .thisWeek),
                        slide: .vertical(forward: true), effect: .scaleFade, reduceMotion: false)
            let latest = try XCTUnwrap(view.snapshotLayer)
            XCTAssertFalse(first === latest)
            XCTAssertNil(first.superlayer)
            XCTAssertGreaterThan(view.transitionGeneration, generation)
            XCTAssertEqual(view.layer?.sublayers?.filter { $0 === latest }.count, 1)
            await self.settle(view)
            let scaleAnimation = try XCTUnwrap(self.transformAnimation(on: view.hostingView.layer))
            XCTAssertEqual(try XCTUnwrap(scaleAnimation.fromValue as? NSValue).caTransform3DValue.m11, 0.92, accuracy: 0.001)
            view.cancelTransition()
            XCTAssertFalse(view.isTransitioning)
            XCTAssertNil(view.snapshotLayer)
            XCTAssertNil(latest.superlayer)
            XCTAssertNil(view.hostingView.layer?.animation(forKey: "WeekStride.pageTransition"))
            await self.finishAnimation(view)
            XCTAssertNil(view.snapshotLayer, "Cancelled completions must not restore stale presentation state")
        }
    }

    func testCancellingBeforeDeferredStartCannotRestoreTheSnapshotOrAnimation() async throws {
        try await withFixture { view in
            view.prepareNavigation()
            view.update(content: Fixture(marker: "Pending destination", rows: Array(20..<50)),
                        environment: EnvironmentValues(), page: TaskListPageID(scope: .all, filter: .nextWeek),
                        slide: .horizontal(forward: true), effect: .slide, reduceMotion: false)
            let snapshot = try XCTUnwrap(view.snapshotLayer)
            XCTAssertNil(view.hostingView.layer?.animation(forKey: "WeekStride.pageTransition"))
            view.cancelTransition()
            await self.settle(view)
            XCTAssertNil(view.snapshotLayer)
            XCTAssertNil(snapshot.contents)
            XCTAssertNil(snapshot.superlayer)
            XCTAssertFalse(view.isTransitioning)
            XCTAssertNil(view.hostingView.layer?.animation(forKey: "WeekStride.pageTransition"))
        }
    }

    func testUnpreparedPageChangeDoesNotCaptureDuringViewUpdate() async throws {
        try await withFixture { view in
            view.update(content: Fixture(marker: "Unprepared destination", rows: Array(20..<50)),
                        environment: EnvironmentValues(), page: TaskListPageID(scope: .all, filter: .nextWeek),
                        slide: .horizontal(forward: true), effect: .slide, reduceMotion: false)
            await self.settle(view)
            XCTAssertEqual(self.probe(in: view)?.marker, "Unprepared destination")
            XCTAssertNil(view.snapshotLayer)
            XCTAssertFalse(view.isTransitioning)
            XCTAssertNil(view.hostingView.layer?.animation(forKey: "WeekStride.pageTransition"))
        }
    }

    func testReduceMotionAndDisabledEffectNeverRetainSnapshots() async throws {
        try await withFixture { view in
            for (index, mode) in [(false, TaskListEffect.none), (true, .slide)].enumerated() {
                view.update(content: Fixture(marker: "Immediate \(index)", rows: Array(20..<50)),
                            environment: EnvironmentValues(),
                            page: TaskListPageID(scope: .project(UUID()), filter: .all),
                            slide: .vertical(forward: true), effect: mode.1, reduceMotion: mode.0)
                XCTAssertNil(view.snapshotLayer)
                XCTAssertFalse(view.isTransitioning)
                XCTAssertNil(view.hostingView.layer?.animation(forKey: "WeekStride.pageTransition"))
            }
        }
    }

    func testHostedContentReceivesUpdatedEnvironmentValues() async throws {
        try await withFixture { view in
            var environment = EnvironmentValues()
            environment.locale = Locale(identifier: "en_GB")
            environment.appTextScale = 1.3
            let day = Date(timeIntervalSinceReferenceDate: 1_000_000)
            environment.taskPlanningDay = day
            view.update(content: Fixture(marker: "Environment", rows: Array(0..<20)), environment: environment,
                        page: TaskListPageID(scope: .all, filter: .all),
                        slide: nil, effect: .none, reduceMotion: false)
            await self.settle(view)
            let probe = try XCTUnwrap(self.probe(in: view))
            XCTAssertEqual(probe.locale, "en_GB")
            XCTAssertEqual(probe.textScale, 1.3)
            XCTAssertEqual(probe.planningDay, day)
        }
    }

    func testRepeatedThemeUpdatesKeepNativeListScrollAndEditingIdentity() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let page = TaskListPageID(scope: .all, filter: .all)
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        let view = TaskListViewportView(content: AppearanceFixture(), environment: environment, page: page, effect: .none)
        window.contentView = view
        await settle(view)
        let host = view.hostingView
        let list = try XCTUnwrap(nativeList(in: view))
        let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first)
        self.scroll(scroll, to: 180)
        await settle(view)
        let offset = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(offset, 100)
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Retained theme draft", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.setSelectedRange(NSRange(location: 3, length: 4))

        for scheme in [ColorScheme.light, .dark, .light, .dark, .light] {
            environment.colorScheme = scheme
            view.update(content: AppearanceFixture(), environment: environment, page: page,
                        slide: nil, effect: .none, reduceMotion: false)
            await settle(view)
            XCTAssertEqual(probe(in: view)?.colorScheme, scheme)
            XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), scheme == .dark ? .darkAqua : .aqua,
                           "Native controls and SwiftUI must resolve the same theme, independently of the outer window.")
            XCTAssertTrue(view.hostingView === host)
            XCTAssertTrue(nativeList(in: view) === list)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 0.5)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(field.currentEditor() === editor)
            XCTAssertEqual(editor.string, "Retained theme draft")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))
        }
        XCTAssertFalse(window.isVisible)
    }

    func testThemeChangeDiscardsActiveAndPreparedNavigationSnapshots() async throws {
        try await withFixture { view in
            let initialPage = TaskListPageID(scope: .all, filter: .all)
            let destination = TaskListPageID(scope: .all, filter: .nextWeek)
            var environment = EnvironmentValues()
            environment.colorScheme = .light
            view.update(content: Fixture(marker: "Light", rows: Array(0..<30)), environment: environment,
                        page: initialPage, slide: nil, effect: .slide, reduceMotion: false)
            await self.settle(view)
            view.prepareNavigation()
            view.update(content: Fixture(marker: "Destination", rows: Array(0..<30)), environment: environment,
                        page: destination, slide: .horizontal(forward: true), effect: .slide, reduceMotion: false)
            let outgoing = try XCTUnwrap(view.snapshotLayer)
            environment.colorScheme = .dark
            view.update(content: Fixture(marker: "Destination", rows: Array(0..<30)), environment: environment,
                        page: destination, slide: nil, effect: .slide, reduceMotion: false)
            XCTAssertNil(view.snapshotLayer, "A same-page theme change must immediately remove old-theme pixels.")
            XCTAssertNil(outgoing.contents)
            XCTAssertNil(outgoing.superlayer)
            await self.settle(view)
            XCTAssertFalse(view.isTransitioning)

            view.prepareNavigation()
            environment.colorScheme = .light
            view.update(content: Fixture(marker: "Destination", rows: Array(0..<30)), environment: environment,
                        page: destination, slide: nil, effect: .slide, reduceMotion: false)
            view.update(content: Fixture(marker: "Next page", rows: Array(10..<40)), environment: environment,
                        page: TaskListPageID(scope: .thisWeek, filter: .thisWeek),
                        slide: .vertical(forward: true), effect: .slide, reduceMotion: false)
            XCTAssertNil(view.snapshotLayer, "A screenshot prepared before the theme change cannot be reused on the next page.")
            await self.settle(view)
            XCTAssertFalse(view.isTransitioning)
        }
    }

    func testThemeAndAnimationSettingChangesPreserveAPendingNavigationScrollReset() async throws {
        for (effect, reduceMotion) in [(TaskListEffect.none, false), (.slide, true)] {
            try await withFixture { view in
                let initialPage = TaskListPageID(scope: .all, filter: .all)
                let destination = TaskListPageID(scope: .all, filter: .nextWeek)
                var environment = EnvironmentValues()
                environment.colorScheme = .light
                view.update(content: Fixture(marker: "Light", rows: Array(0..<30)), environment: environment,
                            page: initialPage, slide: nil, effect: .slide, reduceMotion: false)
                await self.settle(view)
                let scroll = try XCTUnwrap(self.descendants(view).compactMap { $0 as? NSScrollView }.first)
                self.scroll(scroll, to: 180)
                await self.settle(view)
                XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 100)
                view.prepareNavigation()
                view.update(content: Fixture(marker: "Destination", rows: Array(0..<30)), environment: environment,
                            page: destination, slide: .horizontal(forward: true), effect: .slide, reduceMotion: false)
                XCTAssertNotNil(view.snapshotLayer)

                // Both updates occur before the deferred navigation gets a main-queue turn.
                environment.colorScheme = .dark
                view.update(content: Fixture(marker: "Destination", rows: Array(0..<30)), environment: environment,
                            page: destination, slide: nil, effect: effect, reduceMotion: reduceMotion)
                XCTAssertNil(view.snapshotLayer)
                XCTAssertFalse(view.isTransitioning)
                await self.settle(view)
                XCTAssertEqual(self.probe(in: view)?.colorScheme, .dark)
                XCTAssertFalse(TaskListViewportView<Fixture>.resetScrollToTopIfNeeded(scroll),
                               "A same-page theme and animation-setting change must preserve the queued navigation reset.")
            }
        }
    }

    func testRepresentableReceivesThemeOnlyEnvironmentChangesWithoutReplacingContent() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let model = AppearanceModel()
        let content = TaskListViewport(state: TaskListViewportState(), page: TaskListPageID(scope: .all, filter: .all),
                                       slide: nil, effect: .none, reduceMotion: false) { AppearanceFixture() }
        let host = NSHostingView(rootView: AppearanceEnvironment(model: model, content: content))
        window.contentView = host
        // Start deterministically in Aqua, then let SwiftUI's preferred-color-scheme
        // preference control the window just as it does in the application.
        window.appearance = nil
        await settle(host)
        let viewport = try XCTUnwrap(descendants(host).compactMap { $0 as? TaskListViewportView<AppearanceFixture> }.first)
        let innerHost = viewport.hostingView
        let list = try XCTUnwrap(nativeList(in: viewport))
        for scheme in [ColorScheme.light, .dark, .light] {
            model.scheme = scheme
            await settle(host)
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), scheme == .dark ? .darkAqua : .aqua,
                           "The outer presentation must apply the preferred theme before checking its native viewport.")
            XCTAssertEqual(probe(in: viewport)?.marker, "Unchanged theme content")
            XCTAssertEqual(probe(in: viewport)?.colorScheme, scheme, "Only the outer preferred theme changes; the representable content value stays constant.")
            XCTAssertEqual(innerHost.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), scheme == .dark ? .darkAqua : .aqua)
            XCTAssertTrue(viewport.hostingView === innerHost)
            XCTAssertTrue(nativeList(in: viewport) === list)
        }
        XCTAssertFalse(window.isVisible)
    }

    func testPageChangeResetsAnAlreadyScrolledNativeListWithoutReplacingIt() async throws {
        try await withFixture { view in
            let scroll = try XCTUnwrap(self.descendants(view).compactMap { $0 as? NSScrollView }.first)
            self.scroll(scroll, to: 180)
            await self.settle(view)
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 100)
            view.update(content: Fixture(marker: "Reset destination", rows: Array(0..<30)), environment: EnvironmentValues(),
                        page: TaskListPageID(scope: .all, filter: .nextWeek),
                        slide: nil, effect: .none, reduceMotion: false)
            await self.settle(view)
            XCTAssertTrue(self.descendants(view).contains { $0 === scroll })
            XCTAssertFalse(TaskListViewportView<Fixture>.resetScrollToTopIfNeeded(scroll), "The deferred navigation must already have returned the native clip view to its top")
        }
    }

    func testPageChangeCanPreserveTheScrollPositionForAnExplicitReveal() async throws {
        try await withFixture { view in
            let scroll = try XCTUnwrap(self.descendants(view).compactMap { $0 as? NSScrollView }.first)
            view.update(content: Fixture(marker: "Revealed destination", rows: Array(0..<30)), environment: EnvironmentValues(),
                        page: TaskListPageID(scope: .all, filter: .nextWeek),
                        slide: nil, effect: .none, reduceMotion: false, resetScroll: false)
            self.scroll(scroll, to: 200)
            let revealedOffset = scroll.contentView.bounds.origin.y
            XCTAssertGreaterThan(revealedOffset, 100)
            await self.settle(view)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, revealedOffset, accuracy: 0.5,
                           "A pending native reset must not override the destination's explicit task reveal")
        }
    }

    func testResizingAfterPageChangeCancelsPixelsButKeepsThePendingNativeReset() async throws {
        try await withFixture { view in
            let scroll = try XCTUnwrap(self.descendants(view).compactMap { $0 as? NSScrollView }.first)
            self.scroll(scroll, to: 180)
            await self.settle(view)
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 100)
            view.prepareNavigation()
            view.update(content: Fixture(marker: "Resized destination", rows: Array(0..<30)), environment: EnvironmentValues(),
                        page: TaskListPageID(scope: .thisWeek, filter: .thisWeek),
                        slide: .vertical(forward: true), effect: .slide, reduceMotion: false)
            XCTAssertNotNil(view.snapshotLayer)
            view.setFrameSize(NSSize(width: view.bounds.width, height: view.bounds.height + 40))
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            XCTAssertNil(view.snapshotLayer, "A changed viewport must discard the old-sized pixel snapshot")
            XCTAssertFalse(view.isTransitioning)
            await self.settle(view)
            XCTAssertFalse(TaskListViewportView<Fixture>.resetScrollToTopIfNeeded(scroll),
                           "Resizing the control strip must not cancel the destination's pending scroll reset")
        }
    }

    func testSamePageRevealCancelsAnEarlierPendingNavigationReset() async throws {
        try await withFixture { view in
            let scroll = try XCTUnwrap(self.descendants(view).compactMap { $0 as? NSScrollView }.first)
            let destination = TaskListPageID(scope: .all, filter: .nextWeek)
            view.update(content: Fixture(marker: "Pending top reset", rows: Array(0..<30)), environment: EnvironmentValues(),
                        page: destination, slide: nil, effect: .none, reduceMotion: false)
            view.update(content: Fixture(marker: "Later explicit reveal", rows: Array(0..<30)), environment: EnvironmentValues(),
                        page: destination, slide: nil, effect: .none, reduceMotion: false, resetScroll: false)
            self.scroll(scroll, to: 200)
            let revealedOffset = scroll.contentView.bounds.origin.y
            XCTAssertGreaterThan(revealedOffset, 100)
            await self.settle(view)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, revealedOffset, accuracy: 0.5,
                           "A later reveal must override an earlier reset queued for the same page")
        }
    }

    func testNativeResetHandlesBothDocumentCoordinateSystemsAndSkipsAnUnchangedTop() {
        _ = NSApplication.shared
        let documents: [NSView] = [NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200)),
                                   FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))]
        for document in documents {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 280))
            scroll.documentView = document
            scroll.layoutSubtreeIfNeeded()
            self.scroll(scroll, to: 500)
            XCTAssertTrue(TaskListViewportView<Fixture>.resetScrollToTopIfNeeded(scroll))
            let expectedTop = document.isFlipped ? document.bounds.minY : max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, expectedTop, accuracy: 0.5)
            XCTAssertFalse(TaskListViewportView<Fixture>.resetScrollToTopIfNeeded(scroll), "Being at the top must not trigger another native scroll")
        }
    }

    func testIgnoredNativeContainerForwardsTheHostingAccessibilityRootsWithoutDuplication() async throws {
        try await withFixture { view in
            var environment = EnvironmentValues()
            environment.accessibilityEnabled = true
            view.update(content: Fixture(marker: "Accessible viewport", rows: Array(0..<30)), environment: environment,
                        page: TaskListPageID(scope: .all, filter: .all),
                        slide: nil, effect: .none, reduceMotion: false)
            var hostedRoots: [Any] = []
            var exposedRoots: [Any] = []
            for _ in 0..<3 {
                await self.settle(view)
                hostedRoots = view.hostingView.accessibilityChildren() ?? []
                exposedRoots = view.accessibilityChildren() ?? []
                if !hostedRoots.isEmpty && !exposedRoots.isEmpty { break }
            }
            XCTAssertFalse(hostedRoots.isEmpty, "The explicitly enabled hosting accessibility graph must expose its roots")
            XCTAssertFalse(exposedRoots.isEmpty, "The native wrapper must not hide its hosting accessibility graph")
            // SwiftUI's virtual accessibility nodes need not conform to NSAccessibilityProtocol.
            // AppKit may return the hosting view itself or flatten its ignored native container.
            var hostedIdentities = Set(hostedRoots.map { ObjectIdentifier($0 as AnyObject) })
            hostedIdentities.insert(ObjectIdentifier(view.hostingView))
            let exposedIdentities = Set(exposedRoots.map { ObjectIdentifier($0 as AnyObject) })
            XCTAssertFalse(hostedIdentities.isDisjoint(with: exposedIdentities), "The wrapper must forward its live hosting roots")
            XCTAssertEqual(exposedIdentities.count, exposedRoots.count, "The wrapper must not duplicate accessibility roots")
        }
    }

    private func withFixture(_ test: (TaskListViewportView<Fixture>) async throws -> Void) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TaskListViewportView(content: Fixture(marker: "Initial", rows: Array(0..<30)),
                                        environment: EnvironmentValues(), page: TaskListPageID(scope: .all, filter: .all))
        window.contentView = view
        defer { view.cancelTransition(); window.close() }
        await settle(view)
        try await test(view)
        XCTAssertFalse(window.isVisible)
    }

    private func transformAnimation(on layer: CALayer?) -> CABasicAnimation? {
        (layer?.animation(forKey: "WeekStride.pageTransition") as? CAAnimationGroup)?
            .animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "transform" }
    }

    private func nativeList(in view: NSView) -> NSView? {
        descendants(view).first { $0 is NSTableView || $0 is NSCollectionView }
    }

    private func probe(in view: NSView) -> EnvironmentProbe.ProbeView? {
        descendants(view).compactMap { $0 as? EnvironmentProbe.ProbeView }.first
    }

    private func finishAnimation(_ view: NSView) async {
        try? await Task.sleep(for: .milliseconds(240))
        await settle(view)
    }

    private func settle(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        view.layoutSubtreeIfNeeded()
    }

    private func scroll(_ scroll: NSScrollView, to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
