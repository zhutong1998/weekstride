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
