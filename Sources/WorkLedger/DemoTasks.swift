import Foundation
import WorkLedgerCore

@MainActor
extension WorkStore {
    func addDemoTasks() throws {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let period = WorkPeriod.range(containing: now, firstWeekday: 5, calendar: calendar)
        let earlierThisPeriod = min(now, period.start.addingTimeInterval(10 * 3600))
        let previousPeriod = calendar.date(byAdding: .day, value: -2, to: period.start)!
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

        func project(_ name: String, color: String) throws -> Project {
            if let existing = data.projects.first(where: { $0.name == "示例 · \(name)" }) { return existing }
            return try addProject(name: "示例 · \(name)", colorHex: color)
        }

        let operations = try project("网站运维", color: "168C83")
        let product = try project("产品开发", color: "397CC6")
        let daily = try project("日常工作", color: "9866C7")
        let staging = directory.appendingPathComponent(".demo-staging-\(UUID().uuidString)", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let documents: [(String, String)] = [
            ("证书更新操作说明.md", """
            # 证书更新操作说明（示例）

            演示域名：example.com。此文档没有真实服务器地址、证书或密码。

            1. 在测试环境申请证书并核对域名。
            2. 按实际部署流程替换证书，保留上一版本以便回退。
            3. 检查 HTTPS、证书链与失效日期，再登记本次完成记录。

            提醒应根据真实证书有效期提前安排；半年循环仅用于演示。
            """),
            ("域名解析记录示例.json", """
            {
              "purpose": "示例数据，没有真实网络配置",
              "domain": "example.com",
              "records": [
                {"type": "A", "name": "www", "value": "192.0.2.10", "ttl": 300},
                {"type": "TXT", "name": "_demo", "value": "weekstride-demo"}
              ]
            }
            """),
            ("首版验收记录.txt", """
            WeekStride · 周程首版验收记录（示例）

            [通过] 按项目分组，直接展示明细和备注。
            [通过] 完成任务后保留历史，循环任务创建下一次任务。
            [通过] 附件保存在本机，导出备份包含附件。
            [待实测] 睡眠、重启后的系统通知表现。

            此文件仅用于演示附件功能，不代表真实测试结论。
            """)
        ]
        for (name, content) in documents {
            try Data(content.utf8).write(to: staging.appendingPathComponent(name), options: .atomic)
        }

        func add(_ project: Project, _ title: String, details: String, notes: String,
                 children: [String], due: Date?, rule: RepeatRule? = nil,
                 attachment: String? = nil, completedAt: Date? = nil,
                 completedChildren: Int = 0) throws {
            // Existing sample tasks may have been edited; never reset their work on another import.
            let previousTitle = title == "完成周程交互走查" ? "完成工作清单交互走查" : title
            guard !data.tasks.contains(where: { $0.projectID == project.id && ($0.title == title || $0.title == previousTitle) }) else { return }
            let task = WorkTask(projectID: project.id, title: title, details: details,
                                notes: notes, subtasks: children.map { Subtask(title: $0) },
                                dueAt: due, repeatRule: rule)
            try saveTask(task)
            do {
                if let attachment { try addAttachments(urls: [staging.appendingPathComponent(attachment)], to: task.id) }
                for child in task.subtasks.prefix(completedChildren) {
                    _ = try completeSubtask(taskID: task.id, subtaskID: child.id, at: now, source: "示例")
                }
                if let completedAt { _ = try completeTask(id: task.id, at: completedAt, source: "示例") }
            } catch {
                _ = try? deleteTask(id: task.id)
                throw error
            }
        }

        try add(operations, "更新网站域名证书", details: "核对 example.com 与 www.example.com 的证书覆盖范围。\n完成申请、部署与 HTTPS 验证，并登记实际失效日期。", notes: "示例循环：实际完成后 6 个月创建新任务。正式使用时，请按证书的真实失效日期提前提醒。附件为本地示例文档。", children: ["核对域名和证书有效期", "部署证书并保留回退版本", "验证 HTTPS 与证书链"], due: day(-2), rule: RepeatRule(every: 6, unit: .month, basis: .completion), attachment: "证书更新操作说明.md", completedAt: earlierThisPeriod)

        try add(operations, "检查网站备份与恢复", details: "确认数据库备份、静态资源和配置文件均有副本。\n抽取一份备份，在隔离的测试环境验证恢复流程。", notes: "这是一项逾期示例。备份文件不要只看是否存在，也要确认可以恢复。", children: ["检查最近一次备份时间", "执行恢复演练", "记录恢复耗时与问题"], due: day(-1), completedChildren: 1)

        try add(operations, "排查首页图片加载延迟", details: "记录首页首屏图片的大小与加载顺序。\n比较压缩前后的资源体积，确认不同屏幕下的展示效果。", notes: "优先处理首屏大图；测试完成后保留前后对比，暂时不改线上配置。", children: ["整理待优化图片清单", "生成适当尺寸的图片", "复查首屏与移动端布局"], due: day(0))

        try add(operations, "整理域名解析记录", details: "将现有解析按用途分类，核对过期记录与 TTL。\n先整理和确认，再决定是否需要变更。", notes: "附件中的 example.com 和 192.0.2.10 均为示例值。没有真实账号、密码或证书。", children: ["梳理 A / CNAME / TXT 记录", "标注每条记录的用途", "保存本地解析记录说明"], due: day(3), attachment: "域名解析记录示例.json")

        try add(product, "完成周程交互走查", details: "按新建项目 → 新建任务 → 添加子任务 → 完成 → 查看历史的流程走查。\n重点观察列表切换、完成反馈与卡片增删的动态效果。", notes: "前两项已完成，用来观察子任务进度。可以继续完成剩余子任务，查看主任务自动完成。", children: ["检查项目筛选与搜索", "检查明细和备注同屏展示", "检查子任务完成反馈", "检查已完成视图和周期切换"], due: day(1), completedChildren: 2)

        try add(product, "整理首版需求与验收标准", details: "将已确认的需求整理为可验收的条目。\n明确项目、子任务、完成日期、循环任务与本地附件的行为。", notes: "已完成示例：完成日期默认今天。可在卡片上点击完成日期补记，观察工作周期归属变化。", children: ["整理核心使用流程", "列出边界情况", "登记后续实测事项"], due: day(0), attachment: "首版验收记录.txt", completedAt: now)

        try add(product, "验证任务搜索边界", details: "分别使用项目名、任务名、子任务名、备注和附件名搜索。\n检查空关键词、中文和没有结果时的提示。", notes: "可搜索“证书”“解析”“验收”试试。任务内容较长时，也应完整保留可复制的文字。", children: ["验证不同内容字段", "检查中文与大小写", "检查无结果状态"], due: day(2))

        try add(product, "验证循环任务日期计算", details: "分别检查完成后重复和固定日期重复。\n验证月底、跨年和手动修改完成日期时，历史记录及下一次任务是否符合预期。", notes: "这项任务没有自动提醒，适合先体验界面。重复点击完成不能生成多份下一次任务。", children: ["检查完成后 6 个月", "检查固定每周循环", "检查月末与闰年日期", "检查重复请求幂等性"], due: day(5))

        try add(daily, "每周工作回顾", details: "按周四至周三汇总各项目的完成记录。\n记录本周期成果、遗留问题以及下一周期的重点。", notes: "上一周期的已完成示例，并已生成固定每周的下一次任务。可在“已完成”中切换上一周期查看。", children: ["回顾各项目完成事项", "整理阻塞与待办", "安排下一周期重点"], due: previousPeriod, rule: RepeatRule(every: 1, unit: .week, basis: .schedule), completedAt: previousPeriod)

        try add(daily, "核对设备与软件清单", details: "记录常用设备、软件版本和维护事项。\n确认重要资料有备份，保留必要的安装与恢复说明。", notes: "示例只用于记录维护工作。不要在任务备注或附件中存放真实密码、访问令牌和私钥。", children: ["整理设备清单", "核对常用软件版本", "检查重要资料备份"], due: day(7))

        try add(daily, "清理下载目录并归档资料", details: "按项目整理近期下载的文档与截图。\n先确认是否仍有用途，再将需要保留的资料归档。", notes: "这是待办清单，不会自动扫描或删除任何文件。可以先用无关紧要的副本体验附件功能。", children: ["识别需要保留的文件", "按项目整理资料", "确认备份后再清理"], due: day(0))

        try add(daily, "整理知识库与操作手册", details: "把本周重复处理的问题整理为简短步骤。\n每份说明包含前提、操作方法与验证方式，方便下一次直接使用。", notes: "这项任务没有到期日期，用来演示无需排期的常规待办。长备注、链接和资料可以直接放在主任务中。", children: ["选择一个常见问题", "整理处理步骤", "补充验证与回退方法"], due: nil)
    }
}
