import XCTest
import WorkLedgerCore
@testable import WorkLedger

final class PlanFilterPreferencesTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "WorkLedgerPlanFilterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testMissingAndInvalidPreferencesDefaultToThisWeekWithoutRewriting() throws {
        let defaults = try isolatedDefaults()
        let preferences = PlanFilterPreferences(defaults: defaults)
        let key = "taskPlanFilter.all"
        XCTAssertEqual(preferences.filter(for: "all"), .thisWeek)
        XCTAssertNil(defaults.object(forKey: key))
        for data in [Data("broken JSON".utf8), Data("{\"obsoleteCase\":{}}".utf8)] {
            defaults.set(data, forKey: key)
            XCTAssertEqual(preferences.filter(for: "all"), .thisWeek)
            XCTAssertEqual(defaults.data(forKey: key), data)
        }
        defaults.set("wrong value type", forKey: key)
        XCTAssertEqual(preferences.filter(for: "all"), .thisWeek)
        XCTAssertEqual(defaults.string(forKey: key), "wrong value type")
    }

    func testProjectScopesRemainIndependentAndSavingReplacesOnlyThatScope() throws {
        let defaults = try isolatedDefaults()
        let preferences = PlanFilterPreferences(defaults: defaults)
        let firstProject = UUID().uuidString
        let secondProject = UUID().uuidString
        preferences.save(.all, for: firstProject)
        preferences.save(.unscheduled, for: secondProject)
        preferences.save(.nextWeek, for: "all")
        preferences.save(.thisWeek, for: firstProject)
        let restored = PlanFilterPreferences(defaults: defaults)
        XCTAssertEqual(restored.filter(for: firstProject), .thisWeek)
        XCTAssertEqual(restored.filter(for: secondProject), .unscheduled)
        XCTAssertEqual(restored.filter(for: "all"), .nextWeek)
        XCTAssertNotNil(defaults.data(forKey: "taskPlanFilter.\(firstProject)"))
        XCTAssertNil(defaults.object(forKey: firstProject))
    }

    func testEveryFilterIncludingWeekDateSurvivesRecreatingPreferences() throws {
        let defaults = try isolatedDefaults()
        let date = Date(timeIntervalSince1970: 1_793_232_000.125)
        let filters: [TaskPlanFilter] = [.all, .thisWeek, .nextWeek, .week(date), .unscheduled]
        for (index, filter) in filters.enumerated() {
            let scope = "scope-\(index)"
            PlanFilterPreferences(defaults: defaults).save(filter, for: scope)
            XCTAssertEqual(PlanFilterPreferences(defaults: defaults).filter(for: scope), filter)
            let stored = try XCTUnwrap(defaults.data(forKey: "taskPlanFilter.\(scope)"))
            XCTAssertEqual(try JSONDecoder().decode(TaskPlanFilter.self, from: stored), filter)
            PlanFilterPreferences(defaults: defaults).save(filter, for: scope)
            XCTAssertEqual(defaults.data(forKey: "taskPlanFilter.\(scope)"), stored)
        }
    }
}
