import Foundation
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class LocalAPISettingsRoutesTests: XCTestCase {
    private func fixture(_ test: (UserDefaults, WorkStore) throws -> Void) throws {
        let name = "WeekStride-settings-api-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        try test(defaults, WorkStore(directory: directory))
    }

    private func request(_ path: String = "/v1/settings", method: String = "GET", body: String? = nil) -> LocalAPIRequest {
        let data = Data((body ?? "").utf8)
        return LocalAPIRequest(head: LocalAPIRequestHead(method: method, target: path,
            headers: body == nil ? [:] : ["content-type": "application/json"], bodyLength: data.count, headerLength: 0), body: data)
    }

    private func object(_ request: LocalAPIRequest, defaults: UserDefaults, store: WorkStore, services: AppServices? = nil) throws -> [String: Any] {
        let response = try XCTUnwrap(LocalAPISettingsRoutes.respond(to: request, defaults: defaults, services: services, store: store))
        XCTAssertEqual(response.status, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func reject(_ request: LocalAPIRequest, status: Int = 400, defaults: UserDefaults, store: WorkStore) {
        XCTAssertThrowsError(try LocalAPISettingsRoutes.respond(to: request, defaults: defaults, services: nil, store: store)) {
            XCTAssertEqual(($0 as? LocalAPIHTTPError)?.status, status)
        }
    }

    func testDefaultSettingsAndStatusDoNotExposeSecretsOrWritePreferences() throws {
        try fixture { defaults, store in
            defaults.set("do-not-return-this-token", forKey: "apiToken")
            let before = defaults.dictionaryRepresentation()
            let settings = try object(request(), defaults: defaults, store: store)
            XCTAssertEqual(settings["weekStart"] as? Int, 5)
            for (key, value) in ["appAppearance": "system", "appTextSize": "standard", "appLanguage": "system",
                                 "appTimeFormat": "system", "taskColumns": "one", "taskDetails": "expanded", "taskListEffect": "slide"] {
                XCTAssertEqual(settings[key] as? String, value)
            }
            XCTAssertEqual(settings["remindersEnabled"] as? Bool, true)
            XCTAssertEqual(settings["runInMenuBar"] as? Bool, true)
            XCTAssertEqual(settings["reverseTabSwipe"] as? Bool, false)
            let status = try object(request("/v1/settings/status"), defaults: defaults, store: store)
            XCTAssertEqual(status["servicesAvailable"] as? Bool, false)
            XCTAssertEqual(status["canChangeReminders"] as? Bool, false)
            XCTAssertEqual(status["notificationPermissionRequiresUI"] as? Bool, true)
            XCTAssertEqual(status["runsInMenuBar"] as? Bool, true)
            XCTAssertNil(settings["apiToken"])
            XCTAssertNil(status["apiToken"])
            XCTAssertFalse(String(describing: settings).contains("do-not-return-this-token"))
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
        }
    }

    func testPatchChangesOnlyKnownSettingsAndPreservesTaskDates() throws {
        try fixture { defaults, store in
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let task = WorkTask(title: "Preserve dates", dueAt: date, reminderAt: date, plannedAt: date, planGranularity: .week)
            try store.saveTask(task)
            let before = store.data
            defaults.set("unrelated value", forKey: "unrelated")
            let result = try object(request(method: "PATCH", body: #"{"weekStart":2,"appAppearance":"dark","appTextSize":"extraLarge","appLanguage":"en","appTimeFormat":"24","taskColumns":"automatic","taskDetails":"titles","taskListEffect":"scaleFade"}"#), defaults: defaults, store: store)
            XCTAssertEqual(result["weekStart"] as? Int, 2)
            XCTAssertEqual(result["appLanguage"] as? String, "en")
            XCTAssertEqual(result["taskColumns"] as? String, "automatic")
            XCTAssertEqual(result["taskDetails"] as? String, "titles")
            XCTAssertEqual(defaults.string(forKey: "appAppearance"), "dark")
            XCTAssertEqual(defaults.string(forKey: "appTextSize"), "extraLarge")
            XCTAssertEqual(defaults.string(forKey: "appTimeFormat"), "24")
            XCTAssertEqual(defaults.string(forKey: "taskListEffect"), "scaleFade")
            XCTAssertEqual(defaults.string(forKey: "unrelated"), "unrelated value")
            XCTAssertEqual(store.data, before)
        }
    }

    func testMenuBarVisibilityRoundTripsWithoutChangingWorkOrOtherSettings() throws {
        try fixture { defaults, store in
            let task = WorkTask(title: "Keep my work")
            try store.saveTask(task)
            let before = store.data
            defaults.set("dark", forKey: "appAppearance")
            for visible in [false, true] {
                let result = try object(request(method: "PATCH", body: "{\"runInMenuBar\":\(visible)}"), defaults: defaults, store: store)
                XCTAssertEqual(result["runInMenuBar"] as? Bool, visible)
                XCTAssertEqual(defaults.object(forKey: "runInMenuBar") as? Bool, visible)
                let status = try object(request("/v1/settings/status"), defaults: defaults, store: store)
                XCTAssertEqual(status["runsInMenuBar"] as? Bool, visible)
                XCTAssertEqual(defaults.string(forKey: "appAppearance"), "dark")
                XCTAssertEqual(store.data, before)
            }
        }
    }

    func testInvalidSettingsAndUnavailableServicesRejectWholePatch() throws {
        try fixture { defaults, store in
            defaults.set("zh-Hans", forKey: "appLanguage")
            let before = defaults.dictionaryRepresentation()
            let invalid = ["{}", #"{"weekStart":0}"#, #"{"weekStart":8}"#, #"{"weekStart":true}"#,
                           #"{"weekStart":2.5}"#, #"{"appAppearance":"unknown"}"#, #"{"appLanguage":"fr"}"#,
                           #"{"appTimeFormat":"twelveHour"}"#, #"{"taskColumns":"four"}"#, #"{"taskDetails":null}"#,
                           #"{"taskListEffect":"fade"}"#, #"{"apiEnabled":false}"#, #"{"apiToken":"secret"}"#,
                           #"{"runInMenuBar":"false"}"#, #"{"runInMenuBar":1}"#, #"{"runInMenuBar":null}"#,
                           #"{"runInMenuBar":false,"weekStart":9}"#, #"{"remindersEnabled":1}"#, #"{"launchAtLogin":null}"#,
                           #"{"reverseTabSwipe":"true"}"#, #"{"reverseTabSwipe":1}"#, #"{"reverseTabSwipe":null}"#,
                           #"{"appLanguage":"en","reverseTabSwipe":0}"#, #"{"reverseTabSwipe":true,"weekStart":9}"#,
                           #"{"appLanguage":"en","remindersEnabled":false}"#, #"{"appLanguage":"en","launchAtLogin":true}"#,
                           #"{"appLanguage":"en","weekStart":9}"#, #"{"appLanguage":"en","appLanguage":"system"}"#]
            for body in invalid {
                reject(request(method: "PATCH", body: body), defaults: defaults, store: store)
                XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary, body)
            }
            reject(request("/v1/settings?token=secret"), defaults: defaults, store: store)
            reject(request(method: "GET", body: "{}"), defaults: defaults, store: store)
            reject(request(method: "POST", body: "{}"), status: 405, defaults: defaults, store: store)
            reject(request("/v1/settings/api/disable", method: "POST"), defaults: defaults, store: store)
            reject(request("/v1/settings/api/rotate-token", method: "POST"), defaults: defaults, store: store)
        }
    }

    func testReverseTabSwipeRoundTripsAndSurvivesPartialSettingsPatch() throws {
        try fixture { defaults, store in
            let before = store.data
            defaults.set("dark", forKey: "appAppearance")
            for reversed in [true, false] {
                let result = try object(request(method: "PATCH", body: "{\"reverseTabSwipe\":\(reversed)}"), defaults: defaults, store: store)
                XCTAssertEqual(result["reverseTabSwipe"] as? Bool, reversed)
                XCTAssertEqual(defaults.object(forKey: "reverseTabSwipe") as? Bool, reversed)
                let current = try object(request(), defaults: defaults, store: store)
                XCTAssertEqual(current["reverseTabSwipe"] as? Bool, reversed)
                XCTAssertEqual(defaults.string(forKey: "appAppearance"), "dark")
                XCTAssertEqual(store.data, before)
            }
            defaults.set(true, forKey: "reverseTabSwipe")
            let result = try object(request(method: "PATCH", body: #"{"weekStart":2}"#), defaults: defaults, store: store)
            XCTAssertEqual(result["reverseTabSwipe"] as? Bool, true)
            XCTAssertEqual(defaults.object(forKey: "reverseTabSwipe") as? Bool, true)
        }
    }

    func testProjectViewPreferencesRoundTripAndRemainIndependent() throws {
        try fixture { defaults, store in
            let first = try store.addProject(name: "First"), second = try store.addProject(name: "Second")
            let path = "/v1/projects/\(first.id)/view", otherPath = "/v1/projects/\(second.id)/view"
            defaults.set("two", forKey: "taskColumns")
            defaults.set("titles", forKey: "taskDetails")
            defaults.set(5, forKey: "weekStart")
            let initial = try object(request(path), defaults: defaults, store: store)
            XCTAssertEqual(initial["columns"] as? String, "two")
            XCTAssertEqual(initial["details"] as? String, "titles")
            XCTAssertEqual(initial["planFilter"] as? String, "thisWeek")
            let changed = try object(request(path, method: "PATCH", body: #"{"columns":"three","details":"expanded","planFilter":"week","week":"2030-11-12T15:30:00Z"}"#), defaults: defaults, store: store)
            XCTAssertEqual(changed["columns"] as? String, "three")
            XCTAssertEqual(changed["details"] as? String, "expanded")
            XCTAssertEqual(changed["planFilter"] as? String, "week")
            let selected = try LocalAPIJSON.date("2030-11-12T15:30:00Z", field: "week")
            let anchor = WorkPeriod.range(containing: selected, firstWeekday: 5).start
            XCTAssertEqual(PlanFilterPreferences(defaults: defaults).filter(for: SidebarItem.project(first.id).planFilterPreferenceKey), .week(anchor))
            let other = try object(request(otherPath), defaults: defaults, store: store)
            XCTAssertEqual(other["columns"] as? String, "two")
            XCTAssertEqual(other["planFilter"] as? String, "thisWeek")
            let reset = try object(request(path, method: "PATCH", body: #"{"resetDisplay":true}"#), defaults: defaults, store: store)
            XCTAssertEqual(reset["columns"] as? String, "two")
            XCTAssertEqual(reset["details"] as? String, "titles")
            XCTAssertEqual(reset["planFilter"] as? String, "week")
            XCTAssertEqual(reset["week"] as? String, changed["week"] as? String)
            for filter in ["all", "thisWeek", "nextWeek", "unscheduled"] {
                let value = try object(request(path, method: "PATCH", body: "{\"planFilter\":\"\(filter)\"}"), defaults: defaults, store: store)
                XCTAssertEqual(value["planFilter"] as? String, filter)
                XCTAssertNil(value["week"])
            }
        }
    }

    func testInvalidProjectViewPatchDoesNotPartiallySave() throws {
        try fixture { defaults, store in
            let project = try store.addProject(name: "Project")
            let path = "/v1/projects/\(project.id)/view"
            let before = defaults.dictionaryRepresentation()
            for body in [#"{"columns":"three","details":"invalid"}"#, #"{"columns":"three","planFilter":"week"}"#,
                         #"{"columns":"three","week":"2030-11-12T15:30:00Z"}"#, #"{"planFilter":"week","week":null}"#,
                         #"{"planFilter":"week","week":"2030-02-31T00:00:00Z"}"#, #"{"resetDisplay":true,"columns":"one"}"#,
                         #"{"resetDisplay":1}"#, #"{"planFilter":null}"#, #"{"unknown":true}"#] {
                reject(request(path, method: "PATCH", body: body), defaults: defaults, store: store)
                XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary, body)
            }
            reject(request("/v1/projects/\(UUID())/view"), status: 404, defaults: defaults, store: store)
            reject(request("/v1/projects/not-a-uuid/view"), defaults: defaults, store: store)
            reject(request(path, method: "POST", body: "{}"), status: 405, defaults: defaults, store: store)
        }
    }

    func testFailedPendingEditsBlockSettingsAndViewUpdates() throws {
        try fixture { defaults, store in
            let project = try store.addProject(name: "Project")
            let observer = NotificationCenter.default.addObserver(forName: finishTaskEdits, object: nil, queue: nil) {
                ($0.object as? TaskEditingExitRequest)?.failed = true
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            reject(request(method: "PATCH", body: #"{"appLanguage":"en"}"#), defaults: defaults, store: store)
            reject(request("/v1/projects/\(project.id)/view", method: "PATCH", body: #"{"columns":"two"}"#), defaults: defaults, store: store)
            XCTAssertNil(defaults.object(forKey: "appLanguage"))
            XCTAssertNil(defaults.data(forKey: "taskDisplay.\(SidebarItem.project(project.id).planFilterPreferenceKey)"))
        }
    }

    func testOnlyChangedProjectPreferencesPostScopedRefresh() throws {
        try fixture { defaults, store in
            let project = try store.addProject(name: "Project")
            let path = "/v1/projects/\(project.id)/view"
            var scopes: [String] = []
            let observer = NotificationCenter.default.addObserver(forName: LocalAPISettingsRoutes.viewPreferencesChanged, object: nil, queue: nil) {
                if let scope = $0.object as? String { scopes.append(scope) }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            _ = try object(request(path), defaults: defaults, store: store)
            _ = try object(request(path, method: "PATCH", body: #"{"resetDisplay":true}"#), defaults: defaults, store: store)
            XCTAssertTrue(scopes.isEmpty)
            _ = try object(request(path, method: "PATCH", body: #"{"columns":"two"}"#), defaults: defaults, store: store)
            _ = try object(request(path, method: "PATCH", body: #"{"columns":"two"}"#), defaults: defaults, store: store)
            XCTAssertEqual(scopes, [SidebarItem.project(project.id).planFilterPreferenceKey])
            _ = try object(request(path, method: "PATCH", body: #"{"resetDisplay":true}"#), defaults: defaults, store: store)
            XCTAssertEqual(scopes.count, 2)
        }
    }

    func testAPIActionsAreDeferredAndNeverReturnTheToken() throws {
        try fixture { defaults, store in
            let services = AppServices(store: store, recoveryMode: true)
            services.apiEnabled = true
            services.apiToken = "test-only-secret-never-send"
            for action in ["disable", "rotate-token"] {
                let response = try XCTUnwrap(LocalAPISettingsRoutes.respond(to: request("/v1/settings/api/\(action)", method: "POST", body: "{}"), defaults: defaults, services: services, store: store))
                XCTAssertEqual(response.status, 202)
                XCTAssertNotNil(response.afterSend)
                XCTAssertTrue(services.apiEnabled)
                XCTAssertEqual(services.apiToken, "test-only-secret-never-send")
                XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains(services.apiToken))
            }
            XCTAssertNil(defaults.object(forKey: "apiEnabled"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("api-token").path))
        }
    }
}
