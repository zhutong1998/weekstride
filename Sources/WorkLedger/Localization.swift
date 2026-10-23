import Foundation
import WorkLedgerCore

enum AppLocalization {
    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    static func resolvedLanguageIdentifier(for preference: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if preference == "en" { return "en" }
        if preference == "zh-Hans" { return "zh-Hans" }
        for language in preferredLanguages {
            if language.lowercased().hasPrefix("en") { return "en" }
            if language.lowercased().hasPrefix("zh") { return "zh-Hans" }
        }
        return "zh-Hans"
    }

    static var languageIdentifier: String {
        resolvedLanguageIdentifier(for: UserDefaults.standard.string(forKey: "appLanguage") ?? "system")
    }

    static var locale: Locale { Locale(identifier: languageIdentifier) }

    private static let englishBundle = localizedBundle("en")
    private static let chineseBundle = localizedBundle("zh-Hans")

    private static func localizedBundle(_ language: String) -> Bundle {
        // SwiftPM's native builder lowercases localization folder names; Xcode preserves them.
        guard let url = resourceBundle.url(forResource: language, withExtension: "lproj")
                ?? resourceBundle.url(forResource: language.lowercased(), withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return resourceBundle }
        return bundle
    }

    static func bundle(for languageIdentifier: String) -> Bundle {
        resolvedLanguageIdentifier(for: languageIdentifier) == "en" ? englishBundle : chineseBundle
    }

    static func string(_ key: String.LocalizationValue, languageIdentifier: String? = nil) -> String {
        let language = resolvedLanguageIdentifier(for: languageIdentifier ?? self.languageIdentifier)
        return String(localized: key, bundle: bundle(for: language), locale: Locale(identifier: language))
    }

    static func label(_ source: String, languageIdentifier: String? = nil) -> String {
        bundle(for: languageIdentifier ?? self.languageIdentifier).localizedString(forKey: source, value: source, table: nil)
    }
}

func L(_ key: String.LocalizationValue) -> String { AppLocalization.string(key) }

// Use only for fixed application labels, never for a task, note, project name, or attachment name.
func localizedLabel(_ source: String) -> String { AppLocalization.label(source) }

func localizedError(_ error: Error) -> String {
    error is LedgerError ? localizedErrorMessage(error.localizedDescription) : error.localizedDescription
}

func localizedErrorMessage(_ message: String) -> String {
    let localized = AppLocalization.label(message)
    guard localized == message else { return localized }
    for prefix in ["附件必须是文件：", "附件内容冲突，未导入：", "附件缺失、已损坏或不是普通文件："] where message.hasPrefix(prefix) {
        let filename = String(message.dropFirst(prefix.count))
        return String(format: AppLocalization.label(prefix + "%@"), locale: AppLocalization.locale, filename)
    }
    return message
}
