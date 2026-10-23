import Foundation
import WorkLedgerCore

struct PlanFilterPreferences {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func filter(for scope: String) -> TaskPlanFilter {
        guard let data = defaults.data(forKey: "taskPlanFilter.\(scope)"),
              let filter = try? JSONDecoder().decode(TaskPlanFilter.self, from: data) else { return .thisWeek }
        return filter
    }

    func save(_ filter: TaskPlanFilter, for scope: String) {
        let key = "taskPlanFilter.\(scope)"
        guard let data = try? JSONEncoder().encode(filter), defaults.data(forKey: key) != data else { return }
        defaults.set(data, forKey: key)
    }
}
