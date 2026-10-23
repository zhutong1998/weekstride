import SwiftUI
import Combine
import AppKit
import WorkLedgerCore

@main
@MainActor
struct WorkLedgerApp: App {
    @NSApplicationDelegateAdaptor(TaskApplicationDelegate.self) private var applicationDelegate
    @State private var store: WorkStore
    @State private var services: AppServices
    @AppStorage("appAppearance") private var appearance: AppAppearance = .system
    @AppStorage("appTextSize") private var textSize: AppTextSize = .standard
    @AppStorage("appLanguage") private var language: AppLanguage = .system
    @AppStorage("runInMenuBar") private var runInMenuBar = true
    @State private var pendingMenuTaskID: UUID?
    private let startupError: String?
    private let originalDirectory: URL

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let dataDirectory = ProcessInfo.processInfo.environment["WORKLEDGER_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        originalDirectory = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.workledger")
        do {
            let loaded = try WorkStore(directory: dataDirectory)
            if ProcessInfo.processInfo.arguments.contains("--add-demo-tasks") {
                do { try loaded.addDemoTasks() }
                catch { loaded.errorMessage = L("添加示例任务失败：\(localizedError(error))") }
            }
            _store = State(initialValue: loaded)
            _services = State(initialValue: AppServices(store: loaded))
            startupError = nil
        } catch {
            // A corrupt store must never be silently replaced with an empty one.
            let recovery = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedger-recovery-\(UUID().uuidString)")
            let loaded = try! WorkStore(directory: recovery)
            _store = State(initialValue: loaded)
            _services = State(initialValue: AppServices(store: loaded, recoveryMode: true))
            startupError = L("无法读取工作清单数据：\(localizedError(error))\n原数据未被覆盖。请保留原文件，从备份恢复后重新启动。")
        }
    }

    var body: some Scene {
        Window(L("工作清单"), id: "main") {
            Group {
                if let startupError {
                    VStack(spacing: 18) {
                        Image(systemName: "externaldrive.badge.exclamationmark").appFont(.system(size: 44)).foregroundStyle(.orange)
                        Text(L("数据需要恢复")).appFont(.title2.bold())
                        Text(startupError).textSelection(.enabled).frame(maxWidth: 540)
                        Button(L("打开原始数据目录")) { NSWorkspace.shared.open(originalDirectory) }
                        Button(L("退出")) { NSApp.terminate(nil) }
                    }.padding(40)
                } else {
                    RootView(store: store).environmentObject(store).environmentObject(services)
                }
            }
            .frame(minWidth: 1000, minHeight: 660)
            .background(TaskWindowCloseBoundary())
            .preferredColorScheme(appearance.colorScheme)
            .environment(\.locale, language.locale)
            .environment(\.appTextScale, textSize.scale)
            .appFont(.body)
            .task(id: pendingMenuTaskID) {
                guard let id = pendingMenuTaskID else { return }
                // Wait until the window's task notification receiver has been mounted.
                await Task.yield()
                guard !Task.isCancelled, pendingMenuTaskID == id else { return }
                NotificationCenter.default.post(name: .init("WorkLedger.openTask"), object: id.uuidString)
                pendingMenuTaskID = nil
            }
            .onChange(of: language) { _, _ in
                guard startupError == nil else { return }
                services.retryNotifications()
            }
        }
        .defaultSize(width: 1220, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("新建任务")) { NotificationCenter.default.post(name: .init("WorkLedger.newTask"), object: nil) }
                    .keyboardShortcut("n")
                Button(L("添加示例任务")) {
                    do {
                        try store.addDemoTasks()
                        NotificationCenter.default.post(name: .init("WorkLedger.showAll"), object: nil)
                    } catch { store.errorMessage = localizedError(error) }
                }
            }
            CommandGroup(after: .textEditing) {
                Button(L("搜索任务")) { NotificationCenter.default.post(name: .init("WorkLedger.focusSearch"), object: nil) }
                    .keyboardShortcut("f")
            }
        }

        Settings {
            Group {
                if startupError == nil {
                    PreferencesView().environmentObject(store).environmentObject(services)
                } else {
                    Text(L("当前处于数据保护模式，暂不能修改设置或导入数据。请保留原始文件，修复后重新启动。"))
                        .padding(30).frame(width: 450)
                }
            }
            .preferredColorScheme(appearance.colorScheme)
            .environment(\.locale, language.locale)
            .environment(\.appTextScale, textSize.scale)
            .appFont(.body)
        }

        MenuBarExtra(L("工作清单"), systemImage: "checklist", isInserted: $runInMenuBar) {
            MenuContent(store: store, onOpenTask: { pendingMenuTaskID = $0 })
                .preferredColorScheme(appearance.colorScheme)
                .environment(\.locale, language.locale)
                .environment(\.appTextScale, textSize.scale)
                .appFont(.body)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .symbolEffectsRemoved()
        }
    }
}

@MainActor
enum TaskCloseValidation {
    static func finishEditing() -> Bool {
        let request = TaskEditingExitRequest()
        NotificationCenter.default.post(name: finishTaskEdits, object: request)
        if let id = request.failedTaskID {
            // Reuse RootView's validation recovery, including revealing a hidden invalid editor.
            NotificationCenter.default.post(name: .init("WorkLedger.openTask"), object: id.uuidString)
        }
        return !request.failed
    }
}

@MainActor
final class TaskApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TaskCloseValidation.finishEditing() ? .terminateNow : .terminateCancel
    }
}

@MainActor
final class TaskWindowCloseProxy: NSObject, NSWindowDelegate {
    // NSObject's selector forwarding is nonisolated; this weak reference is otherwise used on the UI thread.
    nonisolated(unsafe) weak var originalDelegate: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard TaskCloseValidation.finishEditing() else { return false }
        return originalDelegate?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let originalDelegate, originalDelegate.responds(to: selector) { return originalDelegate }
        return super.forwardingTarget(for: selector)
    }
}

struct TaskWindowCloseBoundary: NSViewRepresentable {
    func makeNSView(context: Context) -> BridgeView { BridgeView(frame: .zero) }
    func updateNSView(_ view: BridgeView, context: Context) { view.installIfNeeded() }
    static func dismantleNSView(_ view: BridgeView, coordinator: ()) { view.uninstall() }

    final class BridgeView: NSView {
        let proxy = TaskWindowCloseProxy()
        private weak var protectedWindow: NSWindow?
        private var generation = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installIfNeeded()
            let expectedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                // SwiftUI can finish installing its window delegate later in the same turn.
                self.installIfNeeded()
            }
        }

        func installIfNeeded() {
            guard let window else { uninstall(); return }
            if protectedWindow !== window { uninstall(); protectedWindow = window }
            guard window.delegate !== proxy else { return }
            if let existing = window.delegate as? TaskWindowCloseProxy { proxy.originalDelegate = existing.originalDelegate }
            else { proxy.originalDelegate = window.delegate }
            window.delegate = proxy
        }

        func uninstall() {
            generation &+= 1
            if let window = protectedWindow, window.delegate === proxy { window.delegate = proxy.originalDelegate }
            protectedWindow = nil
            proxy.originalDelegate = nil
        }
    }
}

struct MenuBarTask: Identifiable, Equatable {
    let id: UUID
    let title: String

    var menuTitle: String {
        let singleLine = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return singleLine.count > 36 ? String(singleLine.prefix(35)) + "…" : singleLine
    }

    static func items(in data: LedgerData, relativeTo today: Date, firstWeekday: Int, calendar: Calendar = .current) -> [Self] {
        let tasks = TaskListPolicy.tasks(in: .thisWeek, data: data, relativeTo: today, firstWeekday: firstWeekday, calendar: calendar)
        return TaskListPolicy.visibleTasks(tasks, projects: data.projects, scope: .thisWeek, filter: .thisWeek,
                                          search: "", relativeTo: today, firstWeekday: firstWeekday, calendar: calendar)
            .map { Self(id: $0.id, title: $0.title) }
    }
}

private struct MenuContent: View {
    let store: WorkStore
    let onOpenTask: (UUID) -> Void
    @AppStorage("appLanguage") private var language: AppLanguage = .system
    @AppStorage("weekStart") private var weekStart = 5
    @AppStorage("runInMenuBar") private var runInMenuBar = true
    @State private var today = Calendar.current.startOfDay(for: Date())
    @State private var tasks: [MenuBarTask]
    @Environment(\.openWindow) var openWindow

    init(store: WorkStore, onOpenTask: @escaping (UUID) -> Void) {
        self.store = store; self.onOpenTask = onOpenTask
        _tasks = State(initialValue: MenuBarTask.items(in: store.data, relativeTo: Date(), firstWeekday: UserDefaults.standard.object(forKey: "weekStart") as? Int ?? 5))
    }

    var body: some View {
        Group {
            Button(L("打开工作清单"), action: openMainWindow)
            Divider()
            Text(L("本周待办 \(tasks.count) 项"))
            if tasks.isEmpty {
                Text(L("本周没有待办任务"))
            } else {
                ForEach(tasks) { task in
                    Button {
                        onOpenTask(task.id)
                        openMainWindow()
                    } label: {
                        Text(verbatim: task.menuTitle).lineLimit(1).truncationMode(.tail)
                    }
                    .help(task.title)
                    .accessibilityLabel(task.title)
                }
            }
            Divider()
            SettingsLink { Text(L("设置…")) }
            Button(L("隐藏菜单栏图标")) { runInMenuBar = false }
            Button(L("退出工作清单")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .environment(\.locale, language.locale)
        .onReceive(store.$data.map { MenuBarTask.items(in: $0, relativeTo: today, firstWeekday: weekStart) }.removeDuplicates()) { next in
            if tasks != next { tasks = next }
        }
        .onChange(of: weekStart) { _, _ in refreshTasks() }
        .onAppear { refreshTasks() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in refreshTasks() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: RunLoop.main)) { _ in refreshTasks() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshTasks() }
    }

    private func refreshTasks() {
        today = Calendar.current.startOfDay(for: Date())
        let next = MenuBarTask.items(in: store.data, relativeTo: today, firstWeekday: weekStart)
        if tasks != next { tasks = next }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
