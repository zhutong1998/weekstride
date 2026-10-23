import SwiftUI

private struct TaskSectionTransition: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let fraction = min(1, max(0, progress))
        let reveal = Rectangle().scale(x: 1, y: fraction, anchor: .top)
        // Clip instead of shrinking text; the shared transaction animates layout height.
        content.clipShape(reveal).contentShape(reveal).opacity(Double(fraction))
    }
}

extension AnyTransition {
    static var taskSection: AnyTransition {
        .modifier(active: TaskSectionTransition(progress: 0), identity: TaskSectionTransition(progress: 1))
    }
}
