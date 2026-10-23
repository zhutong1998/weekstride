import Foundation
import WorkLedgerCore

@MainActor
enum LocalAPISettingsRoutes {
    static let viewPreferencesChanged = Notification.Name("WorkLedger.viewPreferencesChanged")
    private static var enumValues: [String: Set<String>] {
        ["appAppearance": Set(AppAppearance.allCases.map(\.rawValue)),
         "appTextSize": Set(AppTextSize.allCases.map(\.rawValue)),
         "appLanguage": Set(AppLanguage.allCases.map(\.rawValue)),
         "appTimeFormat": Set(AppTimeFormat.allCases.map(\.rawValue)),
         "taskColumns": Set(TaskColumnMode.allCases.map(\.rawValue)),
         "taskDetails": Set(TaskDetailsMode.allCases.map(\.rawValue)),
         "taskListEffect": Set(TaskListEffect.allCases.map(\.rawValue))]
    }

    static func respond(to request: LocalAPIRequest, defaults: UserDefaults, services: AppServices?, store: WorkStore) throws -> LocalAPIResponse? {
        guard let url = URLComponents(string: request.head.target) else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        let isSettings = path.starts(with: ["v1", "settings"])
        let isProjectView = path.count == 4 && path[0] == "v1" && path[1] == "projects" && path[3] == "view"
        guard isSettings || isProjectView else { return nil }
        guard url.queryItems?.isEmpty ?? true else { throw invalid("Settings routes do not accept query parameters.") }

        if isProjectView {
            guard let id = UUID(uuidString: path[2]) else { throw invalid("The project ID must be a UUID.") }
            guard store.data.projects.contains(where: { $0.id == id }) else { throw LocalAPIHTTPError(status: 404, message: "Project not found.") }
            return try projectView(request, id: id, defaults: defaults)
        }
        switch url.path {
        case "/v1/settings":
            switch request.head.method {
            case "GET":
                try requireEmptyBody(request)
                return try .json(Settings(defaults: defaults, services: services))
            case "PATCH":
                try updateSettings(request, defaults: defaults, services: services)
                return try .json(Settings(defaults: defaults, services: services))
            default: throw methodNotAllowed()
            }
        case "/v1/settings/status":
            guard request.head.method == "GET" else { throw methodNotAllowed() }
            try requireEmptyBody(request)
            return try .json(Status(defaults: defaults, services: services))
        case "/v1/settings/api/disable", "/v1/settings/api/rotate-token":
            guard request.head.method == "POST" else { throw methodNotAllowed() }
            _ = try LocalAPIJSON(request, allowed: [], allowEmpty: true)
            guard let services else { throw invalid("Application services are unavailable in this context.") }
            let rotate = url.path.hasSuffix("/rotate-token")
            let message = rotate
                ? "The token will be rotated after this response is sent. Copy the new token from the app; it is never returned by the API."
                : "The API will stop after this response is sent. Enable it again manually in the app."
            return try .json(["status": "accepted", "message": message], status: 202, afterSend: { [weak services] in
                if rotate { services?.rotateAPIToken() } else { services?.setAPIEnabled(false) }
            })
        default: return nil
        }
    }

    private static func updateSettings(_ request: LocalAPIRequest, defaults: UserDefaults, services: AppServices?) throws {
        let allowed = Set(enumValues.keys).union(["weekStart", "remindersEnabled", "launchAtLogin", "runInMenuBar"])
        let json = try LocalAPIJSON(request, allowed: allowed)
        guard !json.raw.isEmpty else { throw invalid("Include at least one setting to change.") }
        var changes: [String: Any] = [:]
        for (key, values) in enumValues {
            if let value = try json.string(key) {
                guard values.contains(value) else { throw invalid("\(key) must be one of: \(values.sorted().joined(separator: ", ")).") }
                changes[key] = value
            }
        }
        if let value = try json.int("weekStart") {
            guard (1...7).contains(value) else { throw invalid("weekStart must be an integer from 1 (Sunday) to 7 (Saturday).") }
            changes["weekStart"] = value
        }
        let reminders = try json.bool("remindersEnabled")
        let login = try json.bool("launchAtLogin")
        if let value = try json.bool("runInMenuBar") { changes["runInMenuBar"] = value }
        if reminders != nil || login != nil {
            guard services != nil else { throw invalid("Changing reminders or login items requires the running application services.") }
        }
        if login != nil, Bundle.main.bundleURL.pathExtension != "app" {
            throw invalid("Launch at login can only be changed from the installed application.")
        }
        try LocalAPIJSON.flushEdits()
        if let login, let services {
            services.setLaunchAtLogin(login)
            let state = services.launchAtLoginRegistrationStatus
            guard (state == "enabled") == login || (login && state == "requiresApproval") else {
                throw invalid("The login item could not be changed. Check the app and macOS Login Items settings.")
            }
        }
        for (key, value) in changes { defaults.set(value, forKey: key) }
        if let reminders { services?.setRemindersEnabled(reminders) }
    }

    private static func projectView(_ request: LocalAPIRequest, id: UUID, defaults: UserDefaults) throws -> LocalAPIResponse {
        let scope = SidebarItem.project(id).planFilterPreferenceKey
        let displays = TaskDisplayPreferences(defaults: defaults)
        let plans = PlanFilterPreferences(defaults: defaults)
        var display = displays.setting(for: scope,
            defaultColumns: TaskColumnMode(rawValue: defaults.string(forKey: "taskColumns") ?? "") ?? .one,
            defaultDetails: TaskDetailsMode(rawValue: defaults.string(forKey: "taskDetails") ?? "") ?? .expanded)
        var filter = plans.filter(for: scope)
        if request.head.method == "PATCH" {
            let json = try LocalAPIJSON(request, allowed: ["columns", "details", "planFilter", "week", "resetDisplay"])
            guard !json.raw.isEmpty else { throw invalid("Include at least one view preference to change.") }
            let reset = try json.bool("resetDisplay") ?? false
            guard !reset || (!json.contains("columns") && !json.contains("details")) else { throw invalid("resetDisplay cannot be combined with columns or details.") }
            if let value = try json.string("columns") {
                guard let columns = TaskColumnMode(rawValue: value) else { throw invalid("columns must be one, two, three, or automatic.") }
                display.columns = columns
            }
            if let value = try json.string("details") {
                guard let details = TaskDetailsMode(rawValue: value) else { throw invalid("details must be expanded or titles.") }
                display.details = details
            }
            let name = try json.string("planFilter")
            let week = try json.date("week")
            guard !json.contains("week") || name == "week" else { throw invalid("week is only accepted together with planFilter: week.") }
            if let name {
                switch name {
                case "all": filter = .all
                case "thisWeek": filter = .thisWeek
                case "nextWeek": filter = .nextWeek
                case "unscheduled": filter = .unscheduled
                case "week":
                    guard let week else { throw invalid("planFilter: week requires a non-null ISO 8601 week date-time.") }
                    let firstWeekday = validWeekStart(defaults)
                    filter = .week(WorkPeriod.range(containing: week, firstWeekday: firstWeekday).start)
                default: throw invalid("planFilter must be all, thisWeek, nextWeek, week, or unscheduled.")
                }
            }
            try LocalAPIJSON.flushEdits()
            let previousDisplay = defaults.data(forKey: "taskDisplay.\(scope)")
            let previousPlan = defaults.data(forKey: "taskPlanFilter.\(scope)")
            if reset { displays.reset(for: scope) }
            else if json.contains("columns") || json.contains("details") { displays.save(display, for: scope) }
            if name != nil { plans.save(filter, for: scope) }
            if reset {
                display = displays.setting(for: scope,
                    defaultColumns: TaskColumnMode(rawValue: defaults.string(forKey: "taskColumns") ?? "") ?? .one,
                    defaultDetails: TaskDetailsMode(rawValue: defaults.string(forKey: "taskDetails") ?? "") ?? .expanded)
            }
            if previousDisplay != defaults.data(forKey: "taskDisplay.\(scope)") || previousPlan != defaults.data(forKey: "taskPlanFilter.\(scope)") {
                NotificationCenter.default.post(name: viewPreferencesChanged, object: scope)
            }
        } else if request.head.method == "GET" { try requireEmptyBody(request) }
        else { throw methodNotAllowed() }
        return try .json(ProjectView(id: id, display: display, filter: filter))
    }

    private static func validWeekStart(_ defaults: UserDefaults) -> Int {
        let value = defaults.object(forKey: "weekStart") as? Int ?? 5
        return (1...7).contains(value) ? value : 5
    }

    private static func requireEmptyBody(_ request: LocalAPIRequest) throws {
        guard request.body.isEmpty else { throw invalid("GET requests do not accept a body.") }
    }
    private static func invalid(_ message: String) -> LocalAPIHTTPError { LocalAPIHTTPError(status: 400, message: message) }
    private static func methodNotAllowed() -> LocalAPIHTTPError { LocalAPIHTTPError(status: 405, message: "This method is not supported for this settings route.") }

    private struct Settings: Encodable {
        let weekStart: Int
        let appAppearance: String
        let appTextSize: String
        let appLanguage: String
        let appTimeFormat: String
        let taskColumns: String
        let taskDetails: String
        let taskListEffect: String
        let remindersEnabled: Bool
        let runInMenuBar: Bool
        let status: Status

        @MainActor init(defaults: UserDefaults, services: AppServices?) {
            weekStart = validWeekStart(defaults)
            appAppearance = (AppAppearance(rawValue: defaults.string(forKey: "appAppearance") ?? "") ?? .system).rawValue
            appTextSize = (AppTextSize(rawValue: defaults.string(forKey: "appTextSize") ?? "") ?? .standard).rawValue
            appLanguage = (AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system).rawValue
            appTimeFormat = (AppTimeFormat(rawValue: defaults.string(forKey: "appTimeFormat") ?? "") ?? .system).rawValue
            taskColumns = (TaskColumnMode(rawValue: defaults.string(forKey: "taskColumns") ?? "") ?? .one).rawValue
            taskDetails = (TaskDetailsMode(rawValue: defaults.string(forKey: "taskDetails") ?? "") ?? .expanded).rawValue
            taskListEffect = (TaskListEffect(rawValue: defaults.string(forKey: "taskListEffect") ?? "") ?? .slide).rawValue
            remindersEnabled = services?.remindersEnabled ?? (defaults.object(forKey: "remindersEnabled") as? Bool ?? true)
            runInMenuBar = defaults.object(forKey: "runInMenuBar") as? Bool ?? true
            status = Status(defaults: defaults, services: services)
        }
    }

    private struct Status: Encodable {
        let servicesAvailable: Bool
        let apiEnabled: Bool?
        let launchAtLogin: Bool?
        let launchAtLoginStatus: String?
        let notificationAuthorization: String
        let isBackingUp: Bool?
        let runsInMenuBar: Bool
        let notificationPermissionRequiresUI = true
        let testNotificationRequiresUI = true
        let canChangeReminders: Bool
        let canChangeLaunchAtLogin: Bool
        let canDisableAPI: Bool
        let canRotateAPIToken: Bool

        @MainActor init(defaults: UserDefaults, services: AppServices?) {
            runsInMenuBar = defaults.object(forKey: "runInMenuBar") as? Bool ?? true
            servicesAvailable = services != nil
            apiEnabled = services?.apiEnabled
            launchAtLoginStatus = services?.launchAtLoginRegistrationStatus
            launchAtLogin = launchAtLoginStatus.map { $0 == "enabled" }
            isBackingUp = services?.isBackingUp
            canChangeReminders = services != nil
            canChangeLaunchAtLogin = services != nil && Bundle.main.bundleURL.pathExtension == "app"
            canDisableAPI = services != nil
            canRotateAPIToken = services != nil
            switch services?.notificationAuthorization {
            case .notDetermined?: notificationAuthorization = "notDetermined"
            case .denied?: notificationAuthorization = "denied"
            case .authorized?: notificationAuthorization = "authorized"
            case .provisional?: notificationAuthorization = "provisional"
            default: notificationAuthorization = "unknown"
            }
        }
    }

    private struct ProjectView: Encodable {
        let id: UUID
        let columns: String
        let details: String
        let planFilter: String
        let week: Date?
        init(id: UUID, display: TaskDisplaySetting, filter: TaskPlanFilter) {
            self.id = id; columns = display.columns.rawValue; details = display.details.rawValue
            switch filter {
            case .all: planFilter = "all"; week = nil
            case .thisWeek: planFilter = "thisWeek"; week = nil
            case .nextWeek: planFilter = "nextWeek"; week = nil
            case .unscheduled: planFilter = "unscheduled"; week = nil
            case .week(let date): planFilter = "week"; week = date
            }
        }
    }
}
