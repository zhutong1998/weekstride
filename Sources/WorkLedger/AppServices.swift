import SwiftUI
import AppKit
import Combine
import Security
import UserNotifications
import ServiceManagement
import WorkLedgerCore

@MainActor
final class AppServices: ObservableObject {
    @Published var apiEnabled = false
    @Published private var apiStatusMessage: String.LocalizationValue = "已关闭"
    @Published var apiToken = ""
    @Published private var apiHealthStatusMessage: String.LocalizationValue = "尚未检测连接"
    @Published private(set) var launchAtLogin = false
    @Published private var launchAtLoginStatusMessage: String.LocalizationValue = "未开启"
    @Published private(set) var remindersEnabled = UserDefaults.standard.object(forKey: "remindersEnabled") as? Bool ?? true
    @Published private var backupProgressMessage: String.LocalizationValue?
    @Published private var lastBackupDate = UserDefaults.standard.object(forKey: "lastBackupDate") as? Date
    @Published private var lastBackupOutcome = UserDefaults.standard.string(forKey: "lastBackupOutcome")
    @Published private var lastBackupError = UserDefaults.standard.string(forKey: "lastBackupError")
    private let legacyBackupStatus = UserDefaults.standard.string(forKey: "lastBackupStatus")
    @Published private(set) var isBackingUp = false
    @Published private var notificationStatusMessage: String.LocalizationValue = "尚未检查通知权限"
    @Published private(set) var notificationAuthorization: UNAuthorizationStatus?
    @Published private var notificationErrorMessage: String.LocalizationValue?
    @Published private(set) var reminderReferenceDate = Date()
    @Published private(set) var reachedReminderCount = 0
    var apiStatus: String { AppLocalization.string(apiStatusMessage) }
    var apiHealthStatus: String { AppLocalization.string(apiHealthStatusMessage) }
    var launchAtLoginStatus: String { AppLocalization.string(launchAtLoginStatusMessage) }
    var notificationStatus: String { AppLocalization.string(notificationStatusMessage) }
    var notificationError: String? { notificationErrorMessage.map { AppLocalization.string($0) } }
    var backupStatus: String {
        if let backupProgressMessage { return AppLocalization.string(backupProgressMessage) }
        guard let lastBackupDate, let lastBackupOutcome else { return legacyBackupStatus ?? L("尚未创建备份") }
        let date = AppTimeFormat(rawValue: UserDefaults.standard.string(forKey: "appTimeFormat") ?? "system") ?? .system
        let timestamp = date.formatted(lastBackupDate, includesDate: true, locale: AppLocalization.locale)
        switch lastBackupOutcome {
        case "exported": return L("备份已导出：\(timestamp)")
        case "restored": return L("备份已恢复：\(timestamp)")
        case "exportFailed": return L("导出失败：\(localizedErrorMessage(lastBackupError ?? ""))")
        case "restoreFailed": return L("恢复失败：\(localizedErrorMessage(lastBackupError ?? ""))")
        default: return legacyBackupStatus ?? L("尚未创建备份")
        }
    }
    private let store: WorkStore
    private let server = LocalAPIServer()
    private lazy var notifications = TaskNotifications()
    private lazy var reminderQueue = ReminderRefreshQueue { [unowned self] tasks -> String.LocalizationValue in
        let revision = self.reminderSettingsRevision
        guard self.remindersEnabled else {
            self.notifications.removeTaskNotifications()
            self.notificationErrorMessage = nil
            return "提醒已暂停；提醒日期仍保留，已到期任务可在待处理提醒中查看。"
        }
        let authorization = await self.notifications.authorization()
        self.notificationAuthorization = authorization
        guard self.remindersEnabled, self.reminderSettingsRevision == revision else {
            self.notifications.removeTaskNotifications()
            self.notificationErrorMessage = nil
            return "提醒已暂停；提醒日期仍保留，已到期任务可在待处理提醒中查看。"
        }
        let allowed = authorization == .authorized || authorization == .provisional
        let status = try await self.notifications.replace(tasks: tasks, canSchedule: allowed, isEnabled: { self.remindersEnabled && self.reminderSettingsRevision == revision })
        self.notificationErrorMessage = nil
        guard allowed else {
            return authorization == .notDetermined ? "尚未允许通知，请点击“允许通知”开启。" : "通知未允许，请在系统设置中开启。"
        }
        return status
    }
    private var changes: AnyCancellable?
    private var activation: AnyCancellable?
    private var nextReminderCheck: Task<Void, Never>?
    private var scheduledReminderDate: Date?
    private let tokenURL: URL
    private var apiHealthCheck: Task<Void, Never>?
    private var reminderSettingsRevision = 0

    init(store: WorkStore, recoveryMode: Bool = false) {
        self.store = store
        let root = ProcessInfo.processInfo.environment["WORKLEDGER_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.workledger")
        tokenURL = root.appendingPathComponent("api-token")
        guard !recoveryMode else { return }
        _ = notifications
        refreshLaunchAtLoginStatus()
        server.onStatus = { [weak self] message in
            guard let self else { return }
            self.apiStatusMessage = String.LocalizationValue(message)
            if message.contains("失败") {
                self.apiEnabled = false
                UserDefaults.standard.set(false, forKey: "apiEnabled")
            }
        }
        do {
            if FileManager.default.fileExists(atPath: tokenURL.path) {
                apiToken = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard apiToken.count == 64, apiToken.allSatisfy({ $0.isHexDigit }) else { throw ServiceError.invalidToken }
            } else {
                apiToken = try newToken()
                try saveToken()
            }
            if UserDefaults.standard.bool(forKey: "apiEnabled") { setAPIEnabled(true) }
        } catch { apiStatusMessage = "API 不可用：\(localizedError(error))" }
        changes = store.$data.debounce(for: .milliseconds(250), scheduler: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshNotifications(self.store.data.tasks)
            }
        }
        let events = [
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange),
            NotificationCenter.default.publisher(for: .NSSystemClockDidChange),
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
        ]
        activation = Publishers.MergeMany(events).receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshLaunchAtLoginStatus()
                await self.refreshNotifications(self.store.data.tasks, force: true)
            }
        }
    }

    func setAPIEnabled(_ enabled: Bool) {
        apiHealthCheck?.cancel()
        apiHealthCheck = nil
        apiHealthStatusMessage = enabled ? "尚未检测连接" : "API 已关闭"
        if enabled {
            do {
                guard !apiToken.isEmpty else { throw ServiceError.invalidToken }
                try server.start(token: apiToken, store: store, services: self)
                apiEnabled = true
                apiStatusMessage = "正在启动 http://127.0.0.1:18743"
                UserDefaults.standard.set(true, forKey: "apiEnabled")
            } catch {
                apiEnabled = false
                apiStatusMessage = "启动失败：\(localizedError(error))"
                UserDefaults.standard.set(false, forKey: "apiEnabled")
            }
        } else {
            server.stop()
            apiEnabled = false
            apiStatusMessage = "已关闭"
            UserDefaults.standard.set(false, forKey: "apiEnabled")
        }
    }

    func checkAPIConnection() {
        apiHealthCheck?.cancel()
        guard apiEnabled else { apiHealthStatusMessage = "请先开启本地 API"; return }
        let token = apiToken
        apiHealthStatusMessage = "正在检测连接…"
        apiHealthCheck = Task {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18743/health")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await session.data(for: request)
                guard !Task.isCancelled, self.apiEnabled, self.apiToken == token else { return }
                self.apiHealthStatusMessage = Self.healthStatusMessage(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                guard !Task.isCancelled, self.apiEnabled, self.apiToken == token else { return }
                self.apiHealthStatusMessage = "连接失败，请确认 API 已开启并检查服务状态。"
            }
        }
    }

    static func healthMessage(data: Data, status: Int) -> String {
        AppLocalization.string(healthStatusMessage(data: data, status: status))
    }

    private static func healthStatusMessage(data: Data, status: Int) -> String.LocalizationValue {
        if status == 401 { return "认证失败，请重置令牌后重试。" }
        guard status == 200, let result = try? JSONDecoder().decode([String: String].self, from: data), result["status"] == "ok" else {
            return "服务响应异常（HTTP \(status)），请检查 API 状态。"
        }
        return "连接正常，可以查询和完成任务。"
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            launchAtLoginStatusMessage = "请在已安装的工作清单应用中设置登录时启动。"
            store.errorMessage = launchAtLoginStatus
            return
        }
        let status = SMAppService.mainApp.status
        if (enabled && status == .enabled) || (!enabled && status == .notRegistered) { refreshLaunchAtLoginStatus(); return }
        if enabled && status == .requiresApproval { refreshLaunchAtLoginStatus(); openLoginItemSettings(); return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginStatusMessage = "无法更改登录启动：\(localizedError(error))"
            store.errorMessage = launchAtLoginStatus
        }
    }

    func openLoginItemSettings() { SMAppService.openSystemSettingsLoginItems() }

    var launchAtLoginRegistrationStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    private func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: launchAtLogin = true; launchAtLoginStatusMessage = "已开启"
        case .requiresApproval: launchAtLogin = false; launchAtLoginStatusMessage = "等待系统批准，请在系统设置的登录项中允许。"
        case .notRegistered: launchAtLogin = false; launchAtLoginStatusMessage = "未开启"
        case .notFound: launchAtLogin = false; launchAtLoginStatusMessage = "当前应用无法注册登录项。"
        @unknown default: launchAtLogin = false; launchAtLoginStatusMessage = "登录项状态暂不可用。"
        }
    }

    func setRemindersEnabled(_ enabled: Bool) {
        guard remindersEnabled != enabled else { return }
        reminderSettingsRevision &+= 1
        remindersEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "remindersEnabled")
        if enabled { notifications.suppressMissedReminders(store.data.tasks, through: Date()) }
        Task { await refreshNotifications(store.data.tasks, force: true) }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"), !NSWorkspace.shared.open(url) {
            notificationStatusMessage = "无法打开系统通知设置，请从系统设置中手动打开通知。"
            store.errorMessage = notificationStatus
        }
    }

    func rotateAPIToken() {
        let restart = apiEnabled
        setAPIEnabled(false)
        let old = apiToken
        do {
            apiToken = try newToken()
            try saveToken()
            if restart { setAPIEnabled(true) }
        } catch {
            apiToken = old
            store.errorMessage = localizedError(error)
        }
    }

    private func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ServiceError.random }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func saveToken() throws {
        try FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(apiToken.utf8).write(to: tokenURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    }

    func requestNotifications() {
        Task {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                await refreshNotifications(store.data.tasks, force: true)
            } catch {
                notificationErrorMessage = "开启通知失败：\(localizedError(error))"
                notificationStatusMessage = notificationErrorMessage!
            }
        }
    }

    func testNotification() {
        guard remindersEnabled else { notificationStatusMessage = "请先开启提醒，再发送测试通知。"; return }
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                guard remindersEnabled else { return }
                guard allowed else {
                    await refreshNotifications(store.data.tasks, force: true)
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = L("工作清单 · 通知测试")
                content.body = L("本地提醒已准备好。请同时检查系统通知和专注模式设置。")
                content.sound = .default
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
                await refreshNotifications(store.data.tasks, force: true)
            } catch {
                notificationErrorMessage = "通知失败：\(localizedError(error))"
                notificationStatusMessage = notificationErrorMessage!
            }
        }
    }

    private func refreshNotifications(_ tasks: [WorkTask], force: Bool = false) async {
        refreshReminderClock(tasks, force: force)
        do {
            if let status = try await reminderQueue.update(tasks, force: force), status != notificationStatusMessage { notificationStatusMessage = status }
        }
        catch {
            notificationErrorMessage = "安排提醒失败：\(localizedError(error))"
            notificationStatusMessage = notificationErrorMessage!
        }
    }

    var canRequestNotifications: Bool { remindersEnabled && (notificationAuthorization == nil || notificationAuthorization == .notDetermined) }

    func retryNotifications() {
        Task { await refreshNotifications(store.data.tasks, force: true) }
    }

    func reminderIssue(for task: WorkTask) -> String? {
        if !remindersEnabled, task.completedAt == nil, task.reminderAt != nil { return L("提醒已暂停，任务中的提醒日期仍保留。") }
        return Self.reminderIssue(for: task, authorization: notificationAuthorization, error: notificationError, now: reminderReferenceDate)
    }

    static func reminderIssue(for task: WorkTask, authorization: UNAuthorizationStatus?, error: String?, now: Date) -> String? {
        guard task.completedAt == nil, let reminder = task.reminderAt else { return nil }
        let reached = reminder <= now ? L("提醒时间已到，请处理或重新安排。") : ""
        if let error { return reached + error }
        guard let authorization else { return reached + L("正在检查通知权限。") }
        switch authorization {
        case .notDetermined: return reached + L("尚未开启通知，此任务不会发送系统提醒。")
        case .authorized, .provisional: return reached.isEmpty ? nil : reached
        default: return reached + L("通知未开启，请到系统设置 → 通知 → 工作清单中允许。")
        }
    }

    private func refreshReminderClock(_ tasks: [WorkTask], force: Bool) {
        let now = Date()
        let dates = tasks.filter { $0.completedAt == nil }.compactMap(\.reminderAt)
        if force || dates.contains(where: { $0 > reminderReferenceDate && $0 <= now }) { reminderReferenceDate = now }
        let reached = dates.filter { $0 <= now }.count
        if reachedReminderCount != reached { reachedReminderCount = reached }
        let next = TaskReminderPlan.nextCheckDate(for: dates, now: now)
        guard scheduledReminderDate != next else { return }
        nextReminderCheck?.cancel()
        nextReminderCheck = nil
        scheduledReminderDate = next
        guard let next else { return }
        nextReminderCheck = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(min(86_400, max(0.05, next.timeIntervalSinceNow)))) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.scheduledReminderDate = nil
            self.nextReminderCheck = nil
            await self.refreshNotifications(self.store.data.tasks, force: true)
        }
    }

    func exportBackup() {
        guard !isBackingUp, finishBackupEdits() else { return }
        let panel = NSSavePanel()
        panel.title = L("导出工作清单备份")
        panel.nameFieldStringValue = "WeekStride-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).workledgerbackup"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard finishBackupEdits() else { return }
        let snapshot = store.data, directory = store.directory
        isBackingUp = true
        backupProgressMessage = "正在导出开始时的任务和附件…"
        Task {
            defer { isBackingUp = false; backupProgressMessage = nil }
            do {
                try await Task.detached(priority: .userInitiated) { try WorkStore.exportBackup(snapshot: snapshot, directory: directory, to: url) }.value
                recordBackupResult("exported")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                recordBackupResult("exportFailed", error: error.localizedDescription)
                store.errorMessage = localizedError(error)
            }
        }
    }

    func importBackup() {
        guard !isBackingUp, finishBackupEdits() else { return }
        let panel = NSOpenPanel()
        panel.title = L("选择工作清单备份文件夹")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let confirm = NSAlert()
        confirm.messageText = L("从备份恢复？")
        confirm.informativeText = L("将以备份内容替换当前项目和任务。恢复前会保留当前数据的安全副本。请确认选择的是可信的工作清单备份。")
        confirm.addButton(withTitle: L("恢复"))
        confirm.addButton(withTitle: L("取消"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        guard finishBackupEdits() else { return }
        do {
            try store.importBackup(from: url)
            recordBackupResult("restored")
        } catch {
            recordBackupResult("restoreFailed", error: error.localizedDescription)
            store.errorMessage = localizedError(error)
        }
    }

    static func finishPendingTaskEdits() -> Bool {
        let request = TaskEditingExitRequest()
        NotificationCenter.default.post(name: finishTaskEdits, object: request)
        return !request.failed
    }

    private func finishBackupEdits() -> Bool {
        guard Self.finishPendingTaskEdits() else {
            store.errorMessage = L("请先修正正在编辑的任务，再进行备份或恢复。")
            return false
        }
        return true
    }

    private func recordBackupResult(_ outcome: String, error: String? = nil) {
        lastBackupDate = Date()
        lastBackupOutcome = outcome
        lastBackupError = error
        UserDefaults.standard.set(lastBackupDate, forKey: "lastBackupDate")
        UserDefaults.standard.set(outcome, forKey: "lastBackupOutcome")
        UserDefaults.standard.set(error, forKey: "lastBackupError")
    }
}

// Serialize system writes, keeping only the latest pending snapshot during an await.
@MainActor
final class ReminderRefreshQueue<Status> {
    private struct Snapshot: Equatable {
        struct Reminder: Equatable {
            let id: UUID
            let title: String
            let body: String
            let date: Date
        }
        let reminders: [Reminder]

        init(_ tasks: [WorkTask]) {
            reminders = tasks.compactMap { task in
                guard task.completedAt == nil, let date = task.reminderAt else { return nil }
                return Reminder(id: task.id, title: task.title, body: String(task.details.prefix(160)), date: date)
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }
    private let apply: ([WorkTask]) async throws -> Status
    private var pending: (tasks: [WorkTask], snapshot: Snapshot, force: Bool)?
    private var applied: Snapshot?
    private var running = false

    init(apply: @escaping ([WorkTask]) async throws -> Status) { self.apply = apply }

    func update(_ tasks: [WorkTask], force: Bool = false) async throws -> Status? {
        pending = (tasks, Snapshot(tasks), force || pending?.force == true)
        guard !running else { return nil }
        running = true
        defer { running = false }
        var result: Result<Status, Error>?
        while let request = pending {
            pending = nil
            guard request.force || request.snapshot != applied else { continue }
            do {
                result = .success(try await apply(request.tasks))
                applied = request.snapshot
            } catch {
                applied = nil
                result = .failure(error)
            }
        }
        return try result?.get()
    }
}

private enum ServiceError: LocalizedError {
    case invalidToken, random
    var errorDescription: String? {
        switch self {
        case .invalidToken: return L("访问令牌无效，请在设置中重置。")
        case .random: return L("无法生成安全随机令牌。")
        }
    }
}

struct TaskReminderPlan {
    static let deliveryGrace: TimeInterval = 60
    struct Addition {
        let request: UNNotificationRequest
        let missedKey: String?
    }
    var additions: [Addition] = []
    var removePending: [String] = []
    var removeDelivered: [String] = []
    var deliveredKeys: Set<String> = []
    var futureCount = 0

    static func key(for task: WorkTask) -> String? {
        task.reminderAt.map { "\(task.id.uuidString)|\($0.timeIntervalSinceReferenceDate)" }
    }

    static func keysToSuppressAfterResuming(_ tasks: [WorkTask], through now: Date) -> Set<String> {
        Set(tasks.compactMap { task in
            guard task.completedAt == nil, let date = task.reminderAt, date <= now else { return nil }
            return key(for: task)
        })
    }

    static func nextCheckDate(for reminderDates: [Date], now: Date) -> Date? {
        reminderDates.map { $0 > now ? $0 : $0.addingTimeInterval(deliveryGrace) }.filter { $0 > now }.min()
    }

    private static func matchesReminder(_ request: UNNotificationRequest, task: WorkTask, calendar: Calendar) -> Bool {
        if let key = request.content.userInfo["reminderKey"] as? String { return key == Self.key(for: task) }
        guard request.content.userInfo["reminderKey"] == nil,
              let when = task.reminderAt, let trigger = request.trigger as? UNCalendarNotificationTrigger,
              !trigger.repeats else { return false }
        var parts = trigger.dateComponents
        guard parts.year != nil, parts.month != nil, parts.day != nil,
              parts.hour != nil, parts.minute != nil, parts.second != nil else { return false }
        if parts.calendar == nil { parts.calendar = calendar }
        if parts.timeZone == nil { parts.timeZone = calendar.timeZone }
        guard let scheduled = calendar.date(from: parts) else { return false }
        return abs(scheduled.timeIntervalSince(when)) < 1
    }

    init(tasks: [WorkTask], pending: [UNNotificationRequest], delivered: [UNNotificationRequest], handledKeys: Set<String>, now: Date, calendar: Calendar) {
        let active = tasks.filter { $0.completedAt == nil && $0.reminderAt != nil }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ("task-\($0.id.uuidString)", $0) })
        let pendingByID = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { _, latest in latest })
        var deliveredIDs: Set<String> = []
        for request in delivered where request.identifier.hasPrefix("task-") {
            guard let task = byID[request.identifier], let key = Self.key(for: task),
                  task.reminderAt! <= now,
                  Self.matchesReminder(request, task: task, calendar: calendar) else {
                removeDelivered.append(request.identifier)
                continue
            }
            deliveredIDs.insert(request.identifier)
            deliveredKeys.insert(key)
        }
        var validPendingIDs: Set<String> = []
        for task in active {
            let when = task.reminderAt!
            let identifier = "task-\(task.id.uuidString)"
            let key = Self.key(for: task)!
            let existing = pendingByID[identifier]
            let missed = when <= now
            if missed && (handledKeys.contains(key) || deliveredKeys.contains(key)) {
                if !deliveredIDs.contains(identifier), existing?.content.userInfo["reminderKey"] as? String == key,
                   existing?.trigger is UNTimeIntervalNotificationTrigger { validPendingIDs.insert(identifier) }
                continue
            }
            if missed, now.timeIntervalSince(when) < Self.deliveryGrace,
               existing?.content.userInfo["reminderKey"] as? String == key,
               existing?.trigger is UNCalendarNotificationTrigger {
                validPendingIDs.insert(identifier)
                continue
            }
            validPendingIDs.insert(identifier)
            let content = UNMutableNotificationContent()
            content.title = task.title
            content.body = task.details.isEmpty ? L("这项工作需要处理了，打开工作清单查看详情。") : String(task.details.prefix(160))
            content.sound = .default
            content.userInfo = ["taskID": task.id.uuidString, "reminderKey": key]
            let trigger: UNNotificationTrigger
            if missed {
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            } else {
                futureCount += 1
                var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
                parts.calendar = calendar
                parts.timeZone = calendar.timeZone
                trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            }
            if let existing, existing.content.isEqual(content), existing.trigger?.isEqual(trigger) == true { continue }
            additions.append(Addition(request: UNNotificationRequest(identifier: identifier, content: content, trigger: trigger), missedKey: missed ? key : nil))
        }
        removePending = pending.filter { request in
            guard request.identifier.hasPrefix("task-") else { return false }
            guard validPendingIDs.contains(request.identifier), let task = byID[request.identifier] else { return true }
            return !Self.matchesReminder(request, task: task, calendar: calendar)
        }.map(\.identifier)
    }
}

private final class TaskNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let handledKey = "handledTaskReminders"
    override init() { super.init(); UNUserNotificationCenter.current().delegate = self }

    @MainActor
    func authorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @MainActor
    func replace(tasks: [WorkTask], canSchedule: Bool, isEnabled: () -> Bool = { true }) async throws -> String.LocalizationValue {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications().map(\.request)
        let previousKeys = Set(UserDefaults.standard.stringArray(forKey: handledKey) ?? [])
        var handled = previousKeys
        let plan = TaskReminderPlan(tasks: tasks, pending: pending, delivered: delivered, handledKeys: handled, now: Date(), calendar: .current)
        handled.formUnion(plan.deliveredKeys)
        defer {
            handled.formUnion(UserDefaults.standard.stringArray(forKey: handledKey) ?? [])
            if handled != previousKeys { UserDefaults.standard.set(handled.sorted(), forKey: handledKey) }
        }
        center.removePendingNotificationRequests(withIdentifiers: plan.removePending)
        center.removeDeliveredNotifications(withIdentifiers: plan.removeDelivered)
        guard isEnabled() else { removeTaskNotifications(); return "提醒已暂停，提醒日期仍保留。" }
        guard canSchedule else { return "" }
        var firstFailure: Error?
        var missed = 0
        for addition in plan.additions {
            guard isEnabled() else { removeTaskNotifications(); return "提醒已暂停，提醒日期仍保留。" }
            do {
                try await center.add(addition.request)
                if let key = addition.missedKey { handled.insert(key); missed += 1 }
                guard isEnabled() else { removeTaskNotifications(); return "提醒已暂停，提醒日期仍保留。" }
            } catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
        return "通知已允许，已安排 \(plan.futureCount) 项未来提醒；本次补发 \(missed) 项已到提醒。"
    }

    @MainActor
    func removeTaskNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    @MainActor
    func suppressMissedReminders(_ tasks: [WorkTask], through now: Date) {
        var handled = Set(UserDefaults.standard.stringArray(forKey: handledKey) ?? [])
        handled.formUnion(TaskReminderPlan.keysToSuppressAfterResuming(tasks, through: now))
        UserDefaults.standard.set(handled.sorted(), forKey: handledKey)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        remember(notification.request)
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        remember(response.notification.request)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain && !$0.title.isEmpty }?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .init("WorkLedger.openTask"), object: response.notification.request.content.userInfo["taskID"])
            completionHandler()
        }
    }

    private func remember(_ request: UNNotificationRequest) {
        guard let key = request.content.userInfo["reminderKey"] as? String else { return }
        DispatchQueue.main.async { [self] in
            var handled = Set(UserDefaults.standard.stringArray(forKey: handledKey) ?? [])
            if handled.insert(key).inserted { UserDefaults.standard.set(handled.sorted(), forKey: handledKey) }
        }
    }
}
