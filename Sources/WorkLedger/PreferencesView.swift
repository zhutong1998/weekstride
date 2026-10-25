import SwiftUI
import AppKit
import WorkLedgerCore

struct PreferencesView: View {
    @EnvironmentObject private var store: WorkStore
    @EnvironmentObject private var services: AppServices
    @AppStorage("weekStart") private var weekStart = 5
    @AppStorage("taskListEffect") private var listEffect: TaskListEffect = .slide
    @AppStorage("reverseTabSwipe") private var reverseTabSwipe = false
    @AppStorage("appAppearance") private var appearance: AppAppearance = .system
    @AppStorage("appTextSize") private var textSize: AppTextSize = .standard
    @AppStorage("appLanguage") private var language: AppLanguage = .system
    @AppStorage("appTimeFormat") private var timeFormat: AppTimeFormat = .system
    @AppStorage("taskColumns") private var columns: TaskColumnMode = .one
    @AppStorage("taskDetails") private var details: TaskDetailsMode = .expanded
    @AppStorage("runInMenuBar") private var runInMenuBar = true
    @State private var selection: Page? = .general
    @State private var showToken = false
    @State private var confirmRotate = false
    @State private var showAPIHelp = false

    private enum Page: String, CaseIterable, Identifiable {
        case general, appearance, reminders, api, data, about
        var id: Self { self }
        var title: String {
            switch self {
            case .general: return L("通用")
            case .appearance: return L("外观与动效")
            case .reminders: return L("提醒")
            case .api: return L("本地 API")
            case .data: return L("数据与备份")
            case .about: return L("关于与帮助")
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "textformat.size"
            case .reminders: return "bell"
            case .api: return "network"
            case .data: return "externaldrive"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $selection) { page in
                Label { Text(page.title).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: page.symbol) }
                    .tag(page)
                    .padding(.vertical, 4)
            }
            .listStyle(.sidebar)
            .id(language.localeIdentifier)
            .navigationSplitViewColumnWidth(min: 160, ideal: 175, max: 210)
        } detail: {
            Form {
                switch selection ?? .general {
                case .general: general
                case .appearance: appearanceSettings
                case .reminders: reminderSettings
                case .api: apiSettings
                case .data: dataSettings
                case .about: about
                }
            }
            .formStyle(.grouped)
            .navigationTitle((selection ?? .general).title)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 570, idealHeight: 640)
        .preferredColorScheme(appearance.colorScheme)
        .environment(\.locale, language.locale)
        .alert(L("重置访问令牌？"), isPresented: $confirmRotate) {
            Button(L("取消"), role: .cancel) {}
            Button(L("重置")) { services.rotateAPIToken() }
        } message: {
            Text(L("已有脚本和 AI 工具需要更新令牌后才能继续连接。"))
        }
    }

    private var general: some View {
        Group {
            Section(L("语言与时间")) {
                Picker(L("语言"), selection: $language) {
                    ForEach(AppLanguage.allCases) { item in Text(item.title).tag(item) }
                }.id("language.\(language.localeIdentifier)")
                Picker(L("时间格式"), selection: $timeFormat) {
                    ForEach(AppTimeFormat.allCases) { item in Text(item.title).tag(item) }
                }.id("timeFormat.\(language.localeIdentifier)")
                Text(L("语言只改变界面和日期显示，任务内容与工作周期保持原样。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            Section(L("启动")) {
                Toggle(L("登录时启动"), isOn: Binding(get: { services.launchAtLogin }, set: { services.setLaunchAtLogin($0) }))
                if !services.launchAtLoginStatus.isEmpty {
                    Text(services.launchAtLoginStatus).appFont(.caption).foregroundStyle(.secondary)
                }
                Button(L("打开系统登录项")) { services.openLoginItemSettings() }
                Toggle(L("显示菜单栏图标"), isOn: $runInMenuBar)
                Text(L("菜单栏显示本周待办任务。隐藏图标后，仍可从 Dock 打开应用并在此重新开启。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            Section(L("工作周期")) {
                Picker(L("每周开始日"), selection: $weekStart) {
                    ForEach(weekdayChoices, id: \.0) { value, title in Text(title).tag(value) }
                }.id("weekStart.\(language.localeIdentifier)")
                let range = WorkPeriod.range(containing: Date(), firstWeekday: weekStart)
                Text(L("当前周期：\(dateText(range.start)) — \(dateText(range.end.addingTimeInterval(-1)))"))
                    .appFont(.caption).foregroundStyle(.secondary)
                Text(L("计划分组、本周数量和完成历史会同步重算，原有计划、截止、提醒和完成日期保持不变。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSettings: some View {
        Group {
            Section(L("外观与阅读")) {
                Picker(L("颜色模式"), selection: $appearance) {
                    ForEach(AppAppearance.allCases) { item in Text(item.title).tag(item) }
                }.id("appearance.\(language.localeIdentifier)")
                Picker(L("字体大小"), selection: $textSize) {
                    ForEach(AppTextSize.allCases) { item in Text(item.title).tag(item) }
                }.id("textSize.\(language.localeIdentifier)")
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("检查域名证书"), systemImage: "circle")
                        .appFont(.system(size: 15, weight: .semibold))
                    Text(L("确认更新结果，并记录本次处理情况。"))
                        .appFont(.system(size: 13))
                    Text(L("提醒日期 · \(timeFormat.formatted(Date(), includesDate: true, locale: language.locale))"))
                        .appFont(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .environment(\.appTextScale, textSize.scale)
                .accessibilityLabel(L("字体大小预览"))
            }
            Section(L("任务显示默认值")) {
                Picker(L("列数"), selection: $columns) {
                    ForEach(TaskColumnMode.allCases) { item in Text(item.title).tag(item) }
                }.id("columns.\(language.localeIdentifier)")
                Picker(L("默认内容"), selection: $details) {
                    ForEach(TaskDetailsMode.allCases) { item in Text(item.title).tag(item) }
                }.id("details.\(language.localeIdentifier)")
                Text(L("各项目可单独记住显示方式。空间不足或字体较大时会减少列数，保持任务可读。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            Section(L("列表切换效果")) {
                Toggle(L("反转左右滑动方向"), isOn: $reverseTabSwipe)
                Text(L("反转触控板双指和鼠标横向滑动切换周标签的方向，立即生效。"))
                    .appFont(.caption).foregroundStyle(.secondary)
                Picker(L("切换效果"), selection: $listEffect) {
                    ForEach(TaskListEffect.allCases) { effect in Text(effect.title).tag(effect) }
                }.id("listEffect.\(language.localeIdentifier)")
                Text(listEffect.summary).appFont(.caption).foregroundStyle(.secondary)
                Text(L("项目上下切换，周标签左右切换；时长为 0.18 秒，并遵循系统的“减少动态效果”。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var reminderSettings: some View {
        Group {
            Section(L("任务提醒")) {
                Toggle(L("启用任务提醒"), isOn: Binding(get: { services.remindersEnabled }, set: { services.setRemindersEnabled($0) }))
                Text(L("关闭后保留任务里的提醒日期；重新开启时安排未来提醒，已到时间的任务仍可在“待处理提醒”查看。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            Section(L("系统通知")) {
                LabeledContent(L("通知状态"), value: services.notificationStatus)
                ViewThatFits(in: .horizontal) {
                    HStack { notificationActions }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { notificationActions }
                }
                Text(L("通知呈现由 macOS 管理，也会受专注模式和系统设置影响。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var notificationActions: some View {
        Button(L("允许通知")) { services.requestNotifications() }
        Button(L("发送测试通知")) { services.testNotification() }
            .disabled(!services.remindersEnabled)
        Button(L("打开系统通知设置")) { services.openNotificationSettings() }
    }

    private var apiSettings: some View {
        Group {
            Section(L("本地 API")) {
                Toggle(L("开启本地 API"), isOn: Binding(get: { services.apiEnabled }, set: { services.setAPIEnabled($0) }))
                LabeledContent(L("状态"), value: services.apiStatus)
                LabeledContent(L("接口地址")) {
                    HStack {
                        Text("http://127.0.0.1:18743").appFont(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Button(L("复制")) { copy("http://127.0.0.1:18743") }
                    }
                }
                HStack {
                    Button(L("连接自检")) { services.checkAPIConnection() }.disabled(!services.apiEnabled)
                    if !services.apiHealthStatus.isEmpty { Text(services.apiHealthStatus).appFont(.caption).foregroundStyle(.secondary) }
                }
                Text(L("仅允许本机连接，必须提供 Bearer 令牌。完全退出应用后，接口停止服务。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            Section(L("访问令牌")) {
                HStack {
                    if showToken {
                        Text(services.apiToken).appFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    } else {
                        Text("••••••••••••••••••••••••").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(showToken ? L("隐藏") : L("显示")) { showToken.toggle() }
                    Button(L("复制")) { copy(services.apiToken) }
                }
                Button(L("重置令牌…")) { confirmRotate = true }
                Text(L("只把令牌提供给可信工具。重置后旧令牌立即失效；令牌不随任务备份导出。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            Section(L("使用说明")) {
                Link(L("打开本地使用说明"), destination: URL(string: "http://127.0.0.1:18743/")!)
                    .disabled(!services.apiEnabled)
                Text(L("先开启服务并复制令牌，再查询任务 ID，最后调用完成接口。主任务和步骤都支持指定完成日期，重复请求不会重复生成循环任务。"))
                Button(showAPIHelp ? L("收起接口说明") : L("查看接口说明")) { showAPIHelp.toggle() }
                if showAPIHelp {
                    Text("GET /v1/capabilities\nGET, POST /v1/projects\nGET, POST /v1/tasks\nPATCH, DELETE /v1/tasks/TASK_UUID\nPOST /v1/tasks/TASK_UUID/complete\nGET, PATCH /v1/settings\nGET, POST /v1/backups")
                        .appFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(L("调用示例中的 YOUR_TOKEN 和 TASK_UUID 需要替换成自己的令牌和任务 ID。"))
                        .appFont(.caption).foregroundStyle(.secondary)
                    Text(apiExample).appFont(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button(L("复制调用示例")) { copy(apiExample) }
                    Text(L("接口可读取任务文本和附件元数据，不提供文件内容下载。云端 AI 读取的任务文本可能发送到其服务端。"))
                        .appFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dataSettings: some View {
        Group {
            Section(L("工作数据备份")) {
                Text(L("备份包含项目、任务、完成记录及任务引用的本地附件。外观、语言、筛选偏好和 API 令牌不包含在任务备份中。"))
                HStack {
                    Button(L("导出完整备份…")) { services.exportBackup() }
                    Button(L("从备份恢复…")) { services.importBackup() }
                }.disabled(services.isBackingUp)
                if services.isBackingUp { ProgressView().controlSize(.small) }
                if !services.backupStatus.isEmpty { Text(services.backupStatus).appFont(.caption).foregroundStyle(.secondary) }
                Text(L("恢复会替换当前项目和任务；操作前自动保留当前数据的安全副本。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            Section(L("本地存储")) {
                Text(store.directory.path).appFont(.caption).textSelection(.enabled)
                Button(L("在 Finder 中显示数据目录")) { NSWorkspace.shared.open(store.directory) }
                Text(L("任务和附件保存在这台 Mac。卸载应用或迁移电脑前，请先导出备份。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var about: some View {
        Group {
            Section(L("工作清单")) {
                LabeledContent(L("版本"), value: version)
                LabeledContent(L("开源许可证"), value: "MIT License")
                Text("Copyright © 2026 WeekStride contributors")
                    .appFont(.caption).foregroundStyle(.secondary)
                Text(L("离线使用，无需账号。任务内容保存在本机，是否开启本地 API 由你决定。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            Section(L("键盘与编辑")) {
                LabeledContent(L("新增任务"), value: "⌘N")
                LabeledContent(L("搜索任务"), value: "⌘F")
                LabeledContent(L("保存当前任务"), value: "↩")
                LabeledContent(L("明细、备注换行"), value: "⇧↩")
                LabeledContent(L("保存并添加下一步骤"), value: "⇧↩")
                LabeledContent(L("撤销上次操作"), value: "⌘Z")
                Text(L("点击任务外部会保留输入框；空步骤清空后按回车移除，任务删除和移除操作可撤销。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var weekdayChoices: [(Int, String)] {
        var calendar = Calendar.current
        calendar.locale = language.locale
        return [2, 3, 4, 5, 6, 7, 1].map { ($0, calendar.weekdaySymbols[$0 - 1]) }
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).locale(language.locale))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var apiExample: String {
        "curl --header 'Authorization: Bearer YOUR_TOKEN' 'http://127.0.0.1:18743/v1/tasks?status=open'\n\ncurl --request POST --header 'Authorization: Bearer YOUR_TOKEN' --header 'Content-Type: application/json' --data '{}' 'http://127.0.0.1:18743/v1/tasks/TASK_UUID/complete'"
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
}
