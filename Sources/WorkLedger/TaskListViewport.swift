import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class TaskListViewportState {
    private weak var viewport: NSView?
    private var prepare: (() -> Void)?

    func prepareNavigation() { prepare?() }

    fileprivate func bind<Content: View>(_ view: TaskListViewportView<Content>) {
        viewport = view
        prepare = { [weak view] in view?.prepareNavigation() }
        view.bridge = self
    }

    fileprivate func unbind(_ view: NSView) {
        guard viewport === view else { return }
        viewport = nil; prepare = nil
    }
}

/// Keeps one native list alive; only the departing viewport is temporarily rasterized.
struct TaskListViewport<Content: View>: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let page: TaskListPageID
    let slide: TaskListSlide?
    let effect: TaskListEffect
    let reduceMotion: Bool
    let resetScroll: Bool
    let state: TaskListViewportState
    let content: Content

    init(state: TaskListViewportState, page: TaskListPageID, slide: TaskListSlide?, effect: TaskListEffect, reduceMotion: Bool, resetScroll: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.page = page; self.slide = slide; self.effect = effect; self.reduceMotion = reduceMotion
        self.resetScroll = resetScroll
        self.state = state
        self.content = content()
    }

    func makeNSView(context: Context) -> TaskListViewportView<Content> {
        var environment = context.environment
        environment.colorScheme = colorScheme
        let view = TaskListViewportView(content: content, environment: environment, page: page,
                                        effect: effect, reduceMotion: reduceMotion)
        state.bind(view)
        return view
    }

    func updateNSView(_ view: TaskListViewportView<Content>, context: Context) {
        var environment = context.environment
        environment.colorScheme = colorScheme
        view.update(content: content, environment: environment, page: page,
                    slide: slide, effect: effect, reduceMotion: reduceMotion, resetScroll: resetScroll, transaction: context.transaction)
    }

    static func dismantleNSView(_ view: TaskListViewportView<Content>, coordinator: ()) {
        view.cancelTransition()
        view.bridge?.unbind(view)
    }
}

struct TaskListViewportContent<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues

    var body: some View { content.environment(\.self, environment) }
}

@MainActor
final class TaskListViewportView<Content: View>: NSView {
    let hostingView: NSHostingView<TaskListViewportContent<Content>>
    private(set) var snapshotLayer: CALayer?
    private(set) var isTransitioning = false
    private(set) var transitionGeneration = 0
    fileprivate weak var bridge: TaskListViewportState?
    private var page: TaskListPageID
    private var activeEffect: TaskListEffect
    private var reducesMotion: Bool
    private var preparedSnapshot: CGImage?
    private var pendingStart: DispatchWorkItem?
    private var pendingScrollReset = false
    private var completion: DispatchWorkItem?
    private var viewportSize: CGSize = .zero
    private static var animationKey: String { "WeekStride.pageTransition" }

    init(content: Content, environment: EnvironmentValues, page: TaskListPageID,
         effect: TaskListEffect = .slide, reduceMotion: Bool = false) {
        self.page = page
        activeEffect = effect; reducesMotion = reduceMotion
        hostingView = NSHostingView(rootView: TaskListViewportContent(content: content, environment: environment))
        super.init(frame: .zero)
        appearance = NSAppearance(named: Self.appearanceName(for: environment))
        wantsLayer = true
        layer?.masksToBounds = true
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func layout() {
        super.layout()
        if viewportSize != bounds.size {
            cancelTransition(preservingScrollReset: true)
            viewportSize = bounds.size
        }
        if hostingView.frame != bounds { hostingView.frame = bounds }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Core Animation moves pixels independently of AppKit's control hit regions.
        isTransitioning ? nil : super.hitTest(point)
    }

    func update(content: Content, environment: EnvironmentValues, page: TaskListPageID,
                slide: TaskListSlide?, effect: TaskListEffect, reduceMotion: Bool, resetScroll: Bool = true, transaction: Transaction = Transaction()) {
        if !resetScroll { pendingScrollReset = false }
        let appearanceName = Self.appearanceName(for: environment)
        if appearance?.name != appearanceName {
            cancelTransition(preservingScrollReset: true)
            appearance = NSAppearance(named: appearanceName)
        }
        let changedPage = page != self.page
        let snapshot = changedPage && !reduceMotion && effect != .none && slide != nil ? preparedSnapshot : nil
        if changedPage || reduceMotion || effect != activeEffect { cancelTransition(preservingScrollReset: !changedPage) }
        self.page = page
        activeEffect = effect; reducesMotion = reduceMotion
        let outgoingLayer = snapshot.flatMap(installSnapshot)
        var updateTransaction = transaction
        if changedPage { updateTransaction.animation = nil; updateTransaction.disablesAnimations = true }
        withTransaction(updateTransaction) {
            hostingView.rootView = TaskListViewportContent(content: content, environment: environment)
        }
        if changedPage && (resetScroll || outgoingLayer != nil) {
            scheduleNavigation(outgoingLayer: outgoingLayer, slide: slide, effect: effect, resetScroll: resetScroll)
        }
    }

    private static func appearanceName(for environment: EnvironmentValues) -> NSAppearance.Name {
        if environment.colorSchemeContrast == .increased {
            return environment.colorScheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua
        }
        return environment.colorScheme == .dark ? .darkAqua : .aqua
    }

    func prepareNavigation() {
        cancelTransition()
        guard activeEffect != .none, !reducesMotion else { return }
        preparedSnapshot = captureViewport()
    }

    func cancelTransition(preservingScrollReset: Bool = false) {
        let resetAfterResize = preservingScrollReset && pendingScrollReset
        transitionGeneration &+= 1
        preparedSnapshot = nil
        pendingStart?.cancel(); pendingStart = nil
        pendingScrollReset = false
        completion?.cancel(); completion = nil
        hostingView.layer?.removeAnimation(forKey: Self.animationKey)
        snapshotLayer?.removeAllAnimations()
        snapshotLayer?.contents = nil
        snapshotLayer?.removeFromSuperlayer(); snapshotLayer = nil
        isTransitioning = false
        if resetAfterResize {
            scheduleNavigation(outgoingLayer: nil, slide: nil, effect: .none, resetScroll: true)
        }
    }

    private func captureViewport() -> CGImage? {
        guard window != nil, bounds.width > 0, bounds.height > 0,
              let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap.cgImage
    }

    private func installSnapshot(_ snapshot: CGImage) -> CALayer? {
        guard let layer else { return nil }
        let outgoingLayer = CALayer()
        outgoingLayer.frame = bounds
        outgoingLayer.contents = snapshot
        outgoingLayer.contentsScale = window?.backingScaleFactor ?? 1
        outgoingLayer.contentsGravity = .resize
        layer.addSublayer(outgoingLayer)
        snapshotLayer = outgoingLayer
        isTransitioning = true
        return outgoingLayer
    }

    private func scheduleNavigation(outgoingLayer: CALayer?, slide: TaskListSlide?, effect: TaskListEffect, resetScroll: Bool) {
        let generation = transitionGeneration
        pendingScrollReset = resetScroll
        // Updating a hosting view synchronously from updateNSView can reenter the native list's layout.
        // Keep the outgoing pixels visible until the destination has its own normal main-queue turn.
        let start = DispatchWorkItem { [weak self, weak outgoingLayer] in
            guard let self, self.transitionGeneration == generation,
                  outgoingLayer == nil || self.snapshotLayer === outgoingLayer else { return }
            self.pendingStart = nil
            let shouldResetScroll = self.pendingScrollReset
            self.pendingScrollReset = false
            if shouldResetScroll, let scroll = self.outerScrollView(in: self.hostingView) {
                Self.resetScrollToTopIfNeeded(scroll)
            }
            guard let outgoingLayer else { return }
            self.hostingView.layoutSubtreeIfNeeded()
            guard self.transitionGeneration == generation, self.snapshotLayer === outgoingLayer else { return }
            self.animate(outgoingLayer: outgoingLayer, slide: slide, effect: effect)
        }
        pendingStart = start
        DispatchQueue.main.async(execute: start)
    }

    private func outerScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = outerScrollView(in: child) { return scroll }
        }
        return nil
    }

    @discardableResult
    static func resetScrollToTopIfNeeded(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        var proposed = clip.bounds
        proposed.origin.y = document.isFlipped ? document.bounds.minY - clip.bounds.height : document.bounds.maxY
        let top = clip.constrainBoundsRect(proposed).origin.y
        guard abs(clip.bounds.origin.y - top) > 0.5 else { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: top))
        scroll.reflectScrolledClipView(clip)
        return true
    }

    private func animate(outgoingLayer: CALayer, slide: TaskListSlide?, effect: TaskListEffect) {
        guard let incomingLayer = hostingView.layer else { cancelTransition(); return }
        let generation = transitionGeneration
        let incoming = effect.presentation(at: 1, slide: slide, viewport: bounds.size)
        let outgoing = effect.presentation(at: -1, slide: slide, viewport: bounds.size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoingLayer.transform = transform(offset: outgoing.offset, scale: outgoing.scale)
        outgoingLayer.opacity = Float(outgoing.opacity)
        incomingLayer.add(animation(fromOffset: incoming.offset, fromScale: incoming.scale, fromOpacity: incoming.opacity,
                                    toOffset: .zero, toScale: 1, toOpacity: 1), forKey: Self.animationKey)
        outgoingLayer.add(animation(fromOffset: .zero, fromScale: 1, fromOpacity: 1,
                                    toOffset: outgoing.offset, toScale: outgoing.scale, toOpacity: outgoing.opacity), forKey: Self.animationKey)
        CATransaction.commit()

        let finish = DispatchWorkItem { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.cancelTransition()
        }
        completion = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + TaskListEffect.duration, execute: finish)
    }

    private func transform(offset: CGSize, scale: CGFloat) -> CATransform3D {
        var value = CATransform3DMakeScale(scale, scale, 1)
        value.m41 = offset.width; value.m42 = offset.height
        return value
    }

    private func animation(fromOffset: CGSize, fromScale: CGFloat, fromOpacity: Double,
                           toOffset: CGSize, toScale: CGFloat, toOpacity: Double) -> CAAnimationGroup {
        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = NSValue(caTransform3D: transform(offset: fromOffset, scale: fromScale))
        transformAnimation.toValue = NSValue(caTransform3D: transform(offset: toOffset, scale: toScale))
        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = fromOpacity; opacityAnimation.toValue = toOpacity
        let group = CAAnimationGroup()
        group.animations = [transformAnimation, opacityAnimation]
        group.duration = TaskListEffect.duration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return group
    }
}
