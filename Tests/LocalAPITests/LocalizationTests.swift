import Foundation
import XCTest
@testable import WorkLedger

final class LocalizationTests: XCTestCase {
    func testExplicitLanguageOverridesSystemAndUsesSupportedFallback() {
        XCTAssertEqual(AppLocalization.resolvedLanguageIdentifier(for: "en", preferredLanguages: ["zh-Hans-CN"]), "en")
        XCTAssertEqual(AppLocalization.resolvedLanguageIdentifier(for: "zh-Hans", preferredLanguages: ["en-US"]), "zh-Hans")
        XCTAssertEqual(AppLocalization.resolvedLanguageIdentifier(for: "system", preferredLanguages: ["fr-FR", "en-GB"]), "en")
        XCTAssertEqual(AppLocalization.resolvedLanguageIdentifier(for: "system", preferredLanguages: ["de-DE"]), "zh-Hans")
    }

    func testBothLanguagesResolveUsingTheirOwnBundle() {
        XCTAssertEqual(AppLocalization.bundle(for: "zh-Hans").bundleURL.lastPathComponent.lowercased(), "zh-hans.lproj")
        XCTAssertEqual(AppLocalization.bundle(for: "en").bundleURL.lastPathComponent, "en.lproj")
        XCTAssertEqual(AppLocalization.string("本周任务", languageIdentifier: "en"), "This week")
        XCTAssertEqual(AppLocalization.string("本周任务", languageIdentifier: "zh-Hans"), "本周任务")
        XCTAssertEqual(AppLocalization.string("共 \(3) 项任务", languageIdentifier: "en"), "3 tasks")
        XCTAssertEqual(AppLocalization.string("共 \(3) 项任务", languageIdentifier: "zh-Hans"), "共 3 项任务")
    }

    func testBrandUsesCurrentNameWithStableLocalizationKeys() {
        XCTAssertEqual(AppLocalization.string("工作清单", languageIdentifier: "en"), "WeekStride")
        XCTAssertEqual(AppLocalization.string("工作清单", languageIdentifier: "zh-Hans"), "WeekStride · 周程")
        XCTAssertEqual(AppLocalization.string("打开工作清单", languageIdentifier: "en"), "Open WeekStride")
        XCTAssertEqual(AppLocalization.string("工作清单-\("2026-10-23").workledgerbackup", languageIdentifier: "zh-Hans"), "WeekStride-2026-10-23.workledgerbackup")
    }

    func testUnknownTextKeepsItsOriginalContents() {
        let userText = "Project A：客户备注 with English and 中文"
        XCTAssertEqual(AppLocalization.label(userText, languageIdentifier: "en"), userText)
        XCTAssertEqual(AppLocalization.label(userText, languageIdentifier: "zh-Hans"), userText)
    }

    func testTaskDisplayOptionTitlesFollowLanguageChanges() {
        withAppLanguage("zh-Hans") {
            XCTAssertEqual(TaskColumnMode.allCases.map(\.title), ["每行一个", "每行两个", "每行三个", "自适应"])
            XCTAssertEqual(TaskDetailsMode.allCases.map(\.title), ["完整详情", "仅标题"])
        }
        withAppLanguage("en") {
            XCTAssertEqual(TaskColumnMode.allCases.map(\.title), ["One per row", "Two per row", "Three per row", "Automatic"])
            XCTAssertEqual(TaskDetailsMode.allCases.map(\.title), ["Full details", "Titles only"])
        }
        withAppLanguage("zh-Hans") { XCTAssertEqual(TaskColumnMode.two.title, "每行两个") }
    }

    func testAllSettingsChoiceTitlesResolveToEnglish() {
        withAppLanguage("en") {
            XCTAssertEqual(AppAppearance.allCases.map(\.title), ["Follow system", "Light", "Dark"])
            XCTAssertEqual(AppTextSize.allCases.map(\.title), ["Small", "Standard", "Large", "Extra large"])
            XCTAssertEqual(AppLanguage.allCases.map(\.title), ["Follow system", "Simplified Chinese", "English"])
            XCTAssertEqual(AppTimeFormat.allCases.map(\.title), ["Follow system", "12-hour", "24-hour"])
            XCTAssertEqual(TaskListEffect.allCases.map(\.title), ["Slide", "Slide & fade", "Scale & fade", "Off"])
            let history = HistoryRange.allCases.map { localizedLabel($0.rawValue) }
            XCTAssertEqual(history, ["Work period", "Custom dates", "All history"])
            let shortcuts = TaskDateShortcut.allCases.map { localizedLabel($0.rawValue) }
            XCTAssertEqual(shortcuts, ["Today", "Tomorrow", "Next week", "Next month"])
        }
    }

    private func withAppLanguage(_ language: String, _ check: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(previous.merging(["appLanguage": language]) { _, value in value }, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        check()
    }

    func testTwelveHourClockRoundTripsMidnightNoonAndAfternoon() {
        for hour in 0..<24 {
            let displayed = TaskCalendarGrid.displayHour(hour, twelveHour: true)
            XCTAssertTrue((1...12).contains(displayed))
            XCTAssertEqual(TaskCalendarGrid.hour24(displayed, afternoon: hour >= 12), hour)
            XCTAssertEqual(TaskCalendarGrid.displayHour(hour, twelveHour: false), hour)
        }
        XCTAssertEqual(TaskCalendarGrid.hour24(12, afternoon: false), 0)
        XCTAssertEqual(TaskCalendarGrid.hour24(12, afternoon: true), 12)
    }
}
