import Foundation
import XCTest
@testable import WorkLedger

final class AppPreferencesTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "WorkLedgerSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testMissingOrInvalidDisplaySettingUsesCurrentDefaultsWithoutWriting() throws {
        let defaults = try isolatedDefaults()
        let preferences = TaskDisplayPreferences(defaults: defaults)
        let fallback = TaskDisplaySetting(columns: .automatic, details: .titles)
        XCTAssertEqual(preferences.setting(for: "all", defaultColumns: .automatic, defaultDetails: .titles), fallback)
        XCTAssertNil(defaults.object(forKey: "taskDisplay.all"))
        for data in [Data("invalid".utf8), Data(#"{"columns":"old","details":"titles"}"#.utf8), Data(#"{"columns":"one"}"#.utf8)] {
            defaults.set(data, forKey: "taskDisplay.all")
            XCTAssertEqual(preferences.setting(for: "all", defaultColumns: .automatic, defaultDetails: .titles), fallback)
            XCTAssertEqual(defaults.data(forKey: "taskDisplay.all"), data)
        }
    }

    func testProjectDisplaySettingsStayIndependentAndSurviveRecreation() throws {
        let defaults = try isolatedDefaults()
        let first = TaskDisplaySetting(columns: .two, details: .titles)
        let second = TaskDisplaySetting(columns: .three, details: .expanded)
        TaskDisplayPreferences(defaults: defaults).save(first, for: "project.first")
        TaskDisplayPreferences(defaults: defaults).save(second, for: "project.second")
        let restored = TaskDisplayPreferences(defaults: defaults)
        XCTAssertEqual(restored.setting(for: "project.first", defaultColumns: .one, defaultDetails: .expanded), first)
        XCTAssertEqual(restored.setting(for: "project.second", defaultColumns: .one, defaultDetails: .titles), second)
        XCTAssertEqual(restored.setting(for: "all", defaultColumns: .one, defaultDetails: .expanded), TaskDisplaySetting())
        let before = defaults.data(forKey: "taskDisplay.project.first")
        restored.save(first, for: "project.first")
        XCTAssertEqual(defaults.data(forKey: "taskDisplay.project.first"), before)
    }

    func testResetOnlyRemovesSelectedScopeAndFollowsNewDefaults() throws {
        let defaults = try isolatedDefaults()
        let preferences = TaskDisplayPreferences(defaults: defaults)
        preferences.save(TaskDisplaySetting(columns: .three, details: .titles), for: "all")
        preferences.save(TaskDisplaySetting(columns: .two, details: .expanded), for: "project.first")
        defaults.set(5, forKey: "weekStart")
        preferences.reset(for: "all")
        XCTAssertNil(defaults.object(forKey: "taskDisplay.all"))
        XCTAssertEqual(preferences.setting(for: "all", defaultColumns: .automatic, defaultDetails: .expanded), TaskDisplaySetting(columns: .automatic, details: .expanded))
        XCTAssertEqual(preferences.setting(for: "project.first", defaultColumns: .one, defaultDetails: .titles), TaskDisplaySetting(columns: .two, details: .expanded))
        XCTAssertEqual(defaults.integer(forKey: "weekStart"), 5)
    }

    func testColumnCountCapsChosenModeAndReducesForNarrowWidthsOrLargeText() {
        XCTAssertEqual(TaskColumnMode.one.columnCount(availableWidth: 2_000, textScale: 1), 1)
        XCTAssertEqual(TaskColumnMode.two.columnCount(availableWidth: 2_000, textScale: 1), 2)
        XCTAssertEqual(TaskColumnMode.three.columnCount(availableWidth: 1_200, textScale: 1), 3)
        XCTAssertEqual(TaskColumnMode.automatic.columnCount(availableWidth: 2_000, textScale: 1), 3)
        XCTAssertEqual(TaskColumnMode.three.columnCount(availableWidth: 600, textScale: 1), 1)
        XCTAssertEqual(TaskColumnMode.automatic.columnCount(availableWidth: 800, textScale: 1), 2)
        XCTAssertEqual(TaskColumnMode.automatic.columnCount(availableWidth: 800, textScale: 1.3), 1)
        for width in [CGFloat.zero, -1, .infinity, .nan] {
            XCTAssertEqual(TaskColumnMode.automatic.columnCount(availableWidth: width, textScale: 1), 1)
        }
        XCTAssertEqual(TaskColumnMode.automatic.columnCount(availableWidth: 800, textScale: .nan), 2)
        XCTAssertEqual(TaskColumnMode.automatic.columnCount(availableWidth: .greatestFiniteMagnitude, textScale: 1), 3)
    }

    func testDisplaySettingsEncodeEverySupportedCombination() throws {
        for columns in TaskColumnMode.allCases {
            for details in TaskDetailsMode.allCases {
                let value = TaskDisplaySetting(columns: columns, details: details)
                XCTAssertEqual(try JSONDecoder().decode(TaskDisplaySetting.self, from: JSONEncoder().encode(value)), value)
            }
        }
    }

    func testTimeFormatOverridesClockWithoutChangingTheDateOrInstant() {
        let date = Date(timeIntervalSince1970: 1_700_053_500)
        let locale = Locale(identifier: "en_US")
        let zone = TimeZone(secondsFromGMT: 0)!
        let twelve = AppTimeFormat.twelveHour.formatted(date, locale: locale, timeZone: zone)
        let twentyFour = AppTimeFormat.twentyFourHour.formatted(date, locale: locale, timeZone: zone)
        XCTAssertTrue(twelve.contains("1:05"), twelve)
        XCTAssertTrue(twelve.lowercased().contains("pm"), twelve)
        XCTAssertTrue(twentyFour.contains("13:05"), twentyFour)
        let withDate = AppTimeFormat.twentyFourHour.formatted(date, includesDate: true, locale: locale, timeZone: zone)
        XCTAssertTrue(withDate.contains("2023"), withDate)
        XCTAssertTrue(withDate.contains("13:05"), withDate)
        let formatter = DateFormatter()
        var components = Locale.Components(locale: locale)
        components.hourCycle = Locale.current.hourCycle
        formatter.locale = Locale(components: components); formatter.timeZone = zone
        formatter.dateStyle = .none; formatter.timeStyle = .short
        XCTAssertEqual(AppTimeFormat.system.formatted(date, locale: locale, timeZone: zone), formatter.string(from: date))
        XCTAssertEqual(date.timeIntervalSince1970, 1_700_053_500)
    }

    func testSystemClockFormatKeepsSystemHourCycleAcrossApplicationLanguages() {
        let date = Date(timeIntervalSince1970: 1_700_053_500)
        let zone = TimeZone(secondsFromGMT: 0)!
        let uses24Hours = [Locale.HourCycle.zeroToTwentyThree, .oneToTwentyFour].contains(Locale.current.hourCycle)
        for identifier in ["en", "zh-Hans"] {
            let locale = Locale(identifier: identifier)
            let system = AppTimeFormat.system.formatted(date, locale: locale, timeZone: zone)
            XCTAssertTrue(system.contains(uses24Hours ? "13:05" : "1:05"), system)
            if !uses24Hours { XCTAssertFalse(system.contains("13:05"), system) }
            XCTAssertTrue(AppTimeFormat.twelveHour.formatted(date, locale: locale, timeZone: zone).contains("1:05"))
            XCTAssertTrue(AppTimeFormat.twentyFourHour.formatted(date, locale: locale, timeZone: zone).contains("13:05"))
        }
    }
}
