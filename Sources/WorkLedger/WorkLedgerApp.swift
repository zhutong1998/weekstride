import SwiftUI
import Combine
import WorkLedgerCore

@main
@MainActor
struct WorkLedgerApp: App {
    @State private var store: WorkStore
    @State private var services: AppServices
    @AppStorage("appAppearance") private var appearance: AppAppearance = .system
    @AppStorage("appTextSize") private var textSize: AppTextSize = .standard
    @AppStorage("appLanguage") private var language: AppLanguage = .system
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
            .preferredColorScheme(appearance.colorScheme)
            .environment(\.locale, language.locale)
            .environment(\.appTextScale, textSize.scale)
            .appFont(.body)
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

        MenuBarExtra(L("工作清单"), systemImage: "checklist") {
            MenuContent(store: store)
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

private struct MenuContent: View {
    let store: WorkStore
    @AppStorage("appLanguage") private var language: AppLanguage = .system
    @State private var pendingCount: Int
    @Environment(\.openWindow) var openWindow

    init(store: WorkStore) {
        self.store = store
        _pendingCount = State(initialValue: store.data.tasks.filter { $0.completedAt == nil }.count)
    }

    var body: some View {
        Group {
            Button(L("打开工作清单")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Text(L("待办 \(pendingCount) 项"))
            Divider()
            SettingsLink { Text(L("设置…")) }
            Button(L("退出工作清单")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .environment(\.locale, language.locale)
        .onReceive(store.$data.map { $0.tasks.filter { $0.completedAt == nil }.count }.removeDuplicates()) { count in
            if pendingCount != count { pendingCount = count }
        }
    }
}
