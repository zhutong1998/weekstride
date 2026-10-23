import Foundation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppTextSize: String, CaseIterable, Identifiable {
    case small, standard, large, extraLarge
    var id: Self { self }
    var title: String {
        switch self {
        case .small: return L("较小")
        case .standard: return L("标准")
        case .large: return L("较大")
        case .extraLarge: return L("特大")
        }
    }
    var scale: Double {
        switch self {
        case .small: return 0.92
        case .standard: return 1
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    var id: Self { self }
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .simplifiedChinese: return L("简体中文")
        case .english: return "English"
        }
    }
    var localeIdentifier: String { AppLocalization.resolvedLanguageIdentifier(for: rawValue) }
    var locale: Locale { Locale(identifier: localeIdentifier) }
}

enum AppTimeFormat: String, CaseIterable, Identifiable {
    case system
    case twelveHour = "12"
    case twentyFourHour = "24"
    var id: Self { self }
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .twelveHour: return L("12 小时制")
        case .twentyFourHour: return L("24 小时制")
        }
    }

    func formatted(_ date: Date, includesDate: Bool = false, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        var components = Locale.Components(locale: locale)
        components.hourCycle = self == .system ? Locale.current.hourCycle : (self == .twelveHour ? .oneToTwelve : .zeroToTwentyThree)
        formatter.locale = Locale(components: components)
        formatter.timeZone = timeZone
        formatter.dateStyle = includesDate ? .medium : .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

enum TaskColumnMode: String, Codable, CaseIterable, Identifiable {
    case one, two, three, automatic
    var id: Self { self }
    var title: String {
        switch self {
        case .one: return L("每行一个")
        case .two: return L("每行两个")
        case .three: return L("每行三个")
        case .automatic: return L("自适应")
        }
    }

    static let spacing: CGFloat = 12

    func columnCount(availableWidth: CGFloat, textScale: Double) -> Int {
        guard availableWidth.isFinite, availableWidth > 0 else { return 1 }
        let scale = textScale.isFinite && textScale > 0 ? textScale : 1
        let minimumWidth = CGFloat(350 * scale)
        let fitting = Int(min(3, max(1, floor((availableWidth + Self.spacing) / (minimumWidth + Self.spacing)))))
        let maximum = self == .one ? 1 : (self == .two ? 2 : 3)
        return min(maximum, fitting)
    }
}

enum TaskDetailsMode: String, Codable, CaseIterable, Identifiable {
    case expanded, titles
    var id: Self { self }
    var title: String { self == .expanded ? L("完整详情") : L("仅标题") }
}

struct TaskDisplaySetting: Codable, Equatable {
    var columns: TaskColumnMode = .one
    var details: TaskDetailsMode = .expanded
}

struct TaskDisplayPreferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func setting(for scope: String, defaultColumns: TaskColumnMode, defaultDetails: TaskDetailsMode) -> TaskDisplaySetting {
        guard let data = defaults.data(forKey: "taskDisplay.\(scope)"),
              let setting = try? JSONDecoder().decode(TaskDisplaySetting.self, from: data) else {
            return TaskDisplaySetting(columns: defaultColumns, details: defaultDetails)
        }
        return setting
    }

    func save(_ setting: TaskDisplaySetting, for scope: String) {
        let key = "taskDisplay.\(scope)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(setting), defaults.data(forKey: key) != data else { return }
        defaults.set(data, forKey: key)
    }

    func reset(for scope: String) { defaults.removeObject(forKey: "taskDisplay.\(scope)") }
}
