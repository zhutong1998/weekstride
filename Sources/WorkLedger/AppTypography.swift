import SwiftUI

private struct AppTextScaleKey: EnvironmentKey {
    static let defaultValue = 1.0
}
private struct TaskDetailsModeKey: EnvironmentKey {
    static let defaultValue = TaskDetailsMode.expanded
}
private struct CompactTaskPlanKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var appTextScale: Double {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
    var taskDetailsMode: TaskDetailsMode {
        get { self[TaskDetailsModeKey.self] }
        set { self[TaskDetailsModeKey.self] = newValue }
    }
    var compactTaskPlan: Bool {
        get { self[CompactTaskPlanKey.self] }
        set { self[CompactTaskPlanKey.self] = newValue }
    }
}

struct AppFontStyle {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    var numeric = false
    static let body = Self(size: 13)
    static let callout = Self(size: 12)
    static let caption = Self(size: 11)
    static let caption2 = Self(size: 10)
    static let headline = Self(size: 13, weight: .semibold)
    static let title3 = Self(size: 15)
    static let title2 = Self(size: 17)
    static let title = Self(size: 22)
    static let largeTitle = Self(size: 26)
    static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Self {
        Self(size: size, weight: weight, design: design)
    }
    static func system(_ style: Self, design: Font.Design) -> Self {
        var result = style; result.design = design; return result
    }
    func weight(_ value: Font.Weight) -> Self { var result = self; result.weight = value; return result }
    func bold() -> Self { weight(.bold) }
    func monospacedDigit() -> Self { var result = self; result.numeric = true; return result }
    func font(scale: Double) -> Font {
        let font = Font.system(size: size * scale, weight: weight, design: design)
        return numeric ? font.monospacedDigit() : font
    }
}
private struct AppFontModifier: ViewModifier {
    @Environment(\.appTextScale) private var scale
    let style: AppFontStyle
    func body(content: Content) -> some View { content.font(style.font(scale: scale)) }
}
extension View {
    func appFont(_ style: AppFontStyle) -> some View { modifier(AppFontModifier(style: style)) }
}
