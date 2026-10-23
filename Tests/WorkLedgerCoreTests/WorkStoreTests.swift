import XCTest
@testable import WorkLedgerCore

@MainActor
final class WorkStoreTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func testRecurringCompletionPreservesOriginalAndIsIdempotent() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "网站")
        let due = date("2024-01-31T12:00:00Z")
        let task = WorkTask(projectID: project.id, title: "更新证书", details: "部署后验证", notes: "保留记录", subtasks: [Subtask(title: "申请"), Subtask(title: "部署")], dueAt: due, reminderAt: due.addingTimeInterval(-86400), repeatRule: RepeatRule(every: 1, unit: .month, basis: .completion))
        try store.saveTask(task)
        let result = try store.completeTask(id: task.id, at: due, source: "api")
        let following = try XCTUnwrap(result.nextTask)
        XCTAssertEqual(result.task.completedAt, due)
        XCTAssertEqual(result.task.completionSource, "api")
        XCTAssertTrue(result.task.subtasks.allSatisfy { $0.completedAt == due })
        XCTAssertNil(following.completedAt)
        XCTAssertTrue(following.subtasks.allSatisfy { $0.completedAt == nil })
        XCTAssertTrue(Set(task.subtasks.map(\.id)).isDisjoint(with: following.subtasks.map(\.id)))
        XCTAssertEqual(following.details, task.details)
        XCTAssertEqual(following.notes, task.notes)
        let nextDue = try XCTUnwrap(following.dueAt)
        let nextReminder = try XCTUnwrap(following.reminderAt)
        XCTAssertEqual(Calendar.current.component(.day, from: nextDue), 29)
        XCTAssertEqual(nextDue, Calendar.current.startOfDay(for: nextDue))
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: nextReminder), to: nextDue).day, 1)
        XCTAssertEqual(Calendar.current.dateComponents([.hour, .minute, .second], from: nextReminder),
                       Calendar.current.dateComponents([.hour, .minute, .second], from: try XCTUnwrap(task.reminderAt)))
        XCTAssertEqual(following.seriesID, task.id)
        XCTAssertEqual(result.task.nextTaskID, following.id)
        let repeated = try store.completeTask(id: task.id, at: due.addingTimeInterval(3600))
        XCTAssertTrue(repeated.alreadyCompleted)
        XCTAssertEqual(repeated.nextTask?.id, following.id)
        XCTAssertEqual(store.data.tasks.count, 2)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("data.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testSubtasksCompleteParentOnlyAfterAllAreDone() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "工作")
        let first = Subtask(title: "一")
        let second = Subtask(title: "二")
        let task = WorkTask(projectID: project.id, title: "父任务", subtasks: [first, second])
        try store.saveTask(task)
        let firstDate = date("2024-01-01T12:00:00Z")
        let secondDate = date("2024-01-02T12:00:00Z")
        XCTAssertNil(try store.completeSubtask(taskID: task.id, subtaskID: first.id, at: firstDate))
        XCTAssertNil(store.data.tasks[0].completedAt)
        let result = try XCTUnwrap(store.completeSubtask(taskID: task.id, subtaskID: second.id, at: secondDate))
        XCTAssertEqual(result.task.completedAt, secondDate)
        XCTAssertEqual(result.task.subtasks[0].completedAt, firstDate)
        XCTAssertEqual(result.task.subtasks[1].completedAt, secondDate)
        try store.setCompletionDate(taskID: task.id, at: firstDate)
        XCTAssertEqual(store.data.tasks[0].completedAt, firstDate)
        XCTAssertEqual(store.data.tasks[0].subtasks[1].completedAt, secondDate)
        try store.setSubtaskCompletionDate(taskID: task.id, subtaskID: second.id, at: firstDate)
        XCTAssertEqual(store.data.tasks[0].subtasks[1].completedAt, firstDate)
    }

    func testFixedScheduleAndBackdatedCompletion() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "维护")
        let due = date("2024-01-01T12:00:00Z")
        let task = WorkTask(projectID: project.id, title: "固定日期", dueAt: due, repeatRule: RepeatRule(every: 6, unit: .month, basis: .schedule))
        try store.saveTask(task)
        let result = try store.completeTask(id: task.id, at: date("2024-02-01T12:00:00Z"))
        XCTAssertEqual(result.nextTask?.dueAt, Calendar.current.date(byAdding: .month, value: 6, to: due))
        try store.setCompletionDate(taskID: task.id, at: date("2024-01-15T12:00:00Z"))
        XCTAssertEqual(store.data.tasks.first(where: { $0.id == result.nextTask?.id })?.dueAt, result.nextTask?.dueAt)
        let count = store.data.tasks.count
        XCTAssertThrowsError(try store.setCompletionDate(taskID: task.id, at: Date().addingTimeInterval(3 * 86400)))
        XCTAssertEqual(store.data.tasks.count, count)
    }

    func testWorkPeriodIsThursdayToWednesdayAndEndExclusive() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let interval = WorkPeriod.range(containing: date("2026-10-20T04:00:00Z"), firstWeekday: 5, calendar: calendar)
        XCTAssertEqual(interval.start, date("2026-10-14T16:00:00Z"))
        XCTAssertEqual(interval.end, date("2026-10-21T16:00:00Z"))
        XCTAssertTrue(WorkPeriod.contains(interval.start, in: interval))
        XCTAssertTrue(WorkPeriod.contains(interval.end.addingTimeInterval(-1), in: interval))
        XCTAssertFalse(WorkPeriod.contains(interval.end, in: interval))
        XCTAssertEqual(WorkPeriod.range(containing: interval.end, firstWeekday: 5, calendar: calendar).start, interval.end)
    }

    func testFixedMonthlyScheduleKeepsOriginalMonthEndAnchor() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "月末")
        let task = WorkTask(projectID: project.id, title: "月末维护", dueAt: date("2024-01-31T12:00:00Z"), repeatRule: RepeatRule(every: 1, unit: .month, basis: .schedule))
        try store.saveTask(task)
        let february = try XCTUnwrap(store.completeTask(id: task.id, at: date("2024-01-31T12:00:00Z")).nextTask)
        let march = try XCTUnwrap(store.completeTask(id: february.id, at: date("2024-02-29T12:00:00Z")).nextTask)
        XCTAssertEqual(Calendar.current.component(.day, from: try XCTUnwrap(february.dueAt)), 29)
        XCTAssertEqual(Calendar.current.component(.day, from: try XCTUnwrap(march.dueAt)), 31)
    }

    func testMonthEndAnchorSurvivesDeletingOriginalAndReloading() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "持久化月末")
        let january = date("2024-01-31T12:00:00Z")
        let task = WorkTask(projectID: project.id, title: "月末维护", dueAt: january, repeatRule: RepeatRule(every: 1, unit: .month, basis: .schedule))
        try store.saveTask(task)
        let february = try XCTUnwrap(store.completeTask(id: task.id, at: january).nextTask)
        XCTAssertEqual(february.scheduleAnchor?.date, january)
        XCTAssertEqual(february.scheduleAnchor?.occurrence, 1)
        try store.deleteTask(id: task.id)
        let reloaded = try WorkStore(directory: directory)
        let march = try XCTUnwrap(reloaded.completeTask(id: february.id, at: try XCTUnwrap(february.dueAt)).nextTask)
        XCTAssertEqual(march.dueAt, Calendar.current.date(byAdding: .month, value: 2, to: january))
        XCTAssertEqual(Calendar.current.component(.day, from: try XCTUnwrap(march.dueAt)), 31)
        XCTAssertEqual(march.scheduleAnchor?.occurrence, 2)
    }

    func testDeletingLegacyAncestorPreservesSuccessorAnchor() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "旧数据")
        let january = date("2024-01-31T12:00:00Z")
        let task = WorkTask(projectID: project.id, title: "月末维护", dueAt: january, repeatRule: RepeatRule(every: 1, unit: .month, basis: .schedule))
        try store.saveTask(task)
        let february = try XCTUnwrap(store.completeTask(id: task.id, at: january).nextTask)
        try store.updateTask(id: february.id) { $0.scheduleAnchor = nil }
        try store.deleteTask(id: task.id)
        let preserved = try XCTUnwrap(store.data.tasks.first(where: { $0.id == february.id }))
        XCTAssertEqual(preserved.scheduleAnchor?.date, january)
        let march = try XCTUnwrap(store.completeTask(id: february.id, at: try XCTUnwrap(february.dueAt)).nextTask)
        XCTAssertEqual(march.dueAt, Calendar.current.date(byAdding: .month, value: 2, to: january))
    }

    func testEditingDueDateOrRuleStartsANewFixedScheduleAnchor() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "修改计划")
        let january = date("2024-01-31T12:00:00Z")
        let task = WorkTask(projectID: project.id, title: "维护", dueAt: january, repeatRule: RepeatRule(every: 1, unit: .month, basis: .schedule))
        try store.saveTask(task)
        let february = try XCTUnwrap(store.completeTask(id: task.id, at: january).nextTask)
        let editedDue = date("2024-02-20T12:00:00Z")
        try store.updateTask(id: february.id) { $0.dueAt = editedDue }
        let march = try XCTUnwrap(store.completeTask(id: february.id, at: editedDue).nextTask)
        XCTAssertEqual(march.dueAt, Calendar.current.date(byAdding: .month, value: 1, to: editedDue))
        XCTAssertEqual(march.scheduleAnchor?.date, editedDue)
        try store.updateTask(id: march.id) { $0.repeatRule = RepeatRule(every: 2, unit: .month, basis: .schedule) }
        let may = try XCTUnwrap(store.completeTask(id: march.id, at: try XCTUnwrap(march.dueAt)).nextTask)
        XCTAssertEqual(may.dueAt, Calendar.current.date(byAdding: .month, value: 2, to: try XCTUnwrap(march.dueAt)))
        XCTAssertEqual(may.scheduleAnchor?.date, march.dueAt)
    }

    func testAttachmentsBackupAndSharedHistory() async throws {
        let directory = location()
        let destination = location()
        let backup = location()
        let source = location().appendingPathExtension("txt")
        defer {
            for item in [directory, destination, backup, source] { try? FileManager.default.removeItem(at: item) }
        }
        try Data("部署说明".utf8).write(to: source)
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "项目")
        let task = WorkTask(projectID: project.id, title: "附件任务", dueAt: date("2024-01-01T12:00:00Z"), repeatRule: RepeatRule(every: 6, unit: .month))
        try store.saveTask(task)
        try store.addAttachments(urls: [source], to: task.id)
        let attachment = try XCTUnwrap(store.data.tasks[0].attachments.first)
        XCTAssertEqual(store.attachmentURL(attachment).pathExtension, "txt")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(attachment)), Data("部署说明".utf8))
        let result = try store.completeTask(id: task.id, at: date("2024-01-01T12:00:00Z"))
        XCTAssertEqual(result.nextTask?.attachments, [attachment])
        try store.removeAttachment(taskID: try XCTUnwrap(result.nextTask).id, attachmentID: attachment.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.attachmentURL(attachment).path))
        try store.exportBackup(to: backup)
        let restored = try WorkStore(directory: destination)
        try restored.importBackup(from: backup)
        XCTAssertEqual(restored.data, store.data)
        XCTAssertEqual(try Data(contentsOf: restored.attachmentURL(attachment)), Data("部署说明".utf8))
        try restored.importBackup(from: backup)
        XCTAssertEqual(restored.data.tasks.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Backups").path))
        var edited = restored.data.tasks[0]; edited.notes = "本机新内容"
        try restored.saveTask(edited)
        try restored.importBackup(from: backup)
        XCTAssertEqual(restored.data, store.data)
        let safetyBackups = try FileManager.default.contentsOfDirectory(at: destination.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        let snapshots = try safetyBackups.map { try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: $0.appendingPathComponent("data.json"))) }
        XCTAssertTrue(snapshots.contains(where: { $0.tasks.first?.notes == "本机新内容" }))
    }

    func testInvalidInputCorruptDataAndWriteFailureDoNotResetOrMutate() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        XCTAssertThrowsError(try store.addProject(name: "  "))
        XCTAssertTrue(store.data.projects.isEmpty)
        let project = try store.addProject(name: "有效项目")
        XCTAssertThrowsError(try store.saveTask(WorkTask(projectID: UUID(), title: "项目不存在")))
        let unsafe = Attachment(name: "文件", storedName: "../outside", size: 0)
        XCTAssertThrowsError(try store.saveTask(WorkTask(projectID: project.id, title: "路径错误", attachments: [unsafe])))
        let original = store.data
        let dataURL = directory.appendingPathComponent("data.json")
        try FileManager.default.removeItem(at: dataURL)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.addProject(name: "不能写入"))
        XCTAssertEqual(store.data, original)
        try FileManager.default.removeItem(at: dataURL)
        let corrupt = Data("{broken json".utf8)
        try corrupt.write(to: dataURL)
        XCTAssertThrowsError(try WorkStore(directory: directory))
        XCTAssertEqual(try Data(contentsOf: dataURL), corrupt)
    }

    func testUndoCompletionRemovesPristineSuccessorAndRestoresPartialChildren() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "撤销")
        let firstDate = date("2024-01-01T12:00:00Z")
        let secondDate = date("2024-01-02T12:00:00Z")
        let first = Subtask(title: "已做", completedAt: firstDate)
        let last = Subtask(title: "尚未做")
        let task = WorkTask(projectID: project.id, title: "循环任务", subtasks: [first, last], dueAt: firstDate, repeatRule: RepeatRule())
        try store.saveTask(task)
        let completed = try store.completeTask(id: task.id, at: secondDate)
        let following = try XCTUnwrap(completed.nextTask)
        XCTAssertEqual(following.createdAt, following.updatedAt)
        try store.undoCompletion(id: task.id)
        XCTAssertEqual(store.data.tasks.count, 1)
        XCTAssertNil(store.data.tasks[0].completedAt)
        XCTAssertNil(store.data.tasks[0].completionSource)
        XCTAssertNil(store.data.tasks[0].completionSubtaskSnapshot)
        XCTAssertNil(store.data.tasks[0].nextTaskID)
        XCTAssertEqual(store.data.tasks[0].subtasks, [first, last])

        let automatic = try XCTUnwrap(store.completeSubtask(taskID: task.id, subtaskID: last.id, at: secondDate))
        XCTAssertNotNil(automatic.nextTask)
        try store.undoCompletion(id: task.id)
        XCTAssertEqual(store.data.tasks[0].subtasks, [first, last])
        XCTAssertEqual(store.data.tasks.count, 1)
    }

    func testUndoRefusesModifiedSuccessorAndPreservesData() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "撤销保护")
        let completedDate = date("2024-01-01T12:00:00Z")
        let task = WorkTask(projectID: project.id, title: "循环任务", dueAt: completedDate, repeatRule: RepeatRule())
        try store.saveTask(task)
        var following = try XCTUnwrap(store.completeTask(id: task.id, at: completedDate).nextTask)
        following.notes = "下一次已经开始工作"
        try store.saveTask(following)
        let before = store.data
        XCTAssertThrowsError(try store.undoCompletion(id: task.id))
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try WorkStore(directory: directory).data, before)
    }

    func testFieldUpdateUsesLatestTaskAndPreservesAPICompletion() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "自动保存")
        let completedDate = date("2024-01-01T12:00:00Z")
        let staleTask = WorkTask(projectID: project.id, title: "编辑前", subtasks: [Subtask(title: "步骤")], dueAt: completedDate, repeatRule: RepeatRule())
        try store.saveTask(staleTask)
        let completed = try store.completeTask(id: staleTask.id, at: completedDate, source: "api")
        try store.updateTask(id: staleTask.id) { $0.title = "界面修改后的标题" }
        let latest = try XCTUnwrap(store.data.tasks.first(where: { $0.id == staleTask.id }))
        XCTAssertEqual(latest.title, "界面修改后的标题")
        XCTAssertEqual(latest.completedAt, completed.task.completedAt)
        XCTAssertEqual(latest.completionSource, "api")
        XCTAssertEqual(latest.nextTaskID, completed.nextTask?.id)
        XCTAssertEqual(latest.subtasks, completed.task.subtasks)
        XCTAssertEqual(latest.repeatRule, completed.task.repeatRule)
        XCTAssertEqual(latest.completionSubtaskSnapshot, completed.task.completionSubtaskSnapshot)
        XCTAssertEqual(store.data.tasks.first(where: { $0.id == completed.nextTask?.id }), completed.nextTask)
        if let nextID = completed.nextTask?.id {
            try store.updateTask(id: nextID) { $0.title = staleTask.title }
            XCTAssertEqual(store.data.tasks.first(where: { $0.id == nextID }), completed.nextTask)
        }

        let before = store.data
        XCTAssertThrowsError(try store.updateTask(id: staleTask.id) { $0.id = UUID() })
        XCTAssertEqual(store.data, before)
        try store.deleteTask(id: staleTask.id)
        let afterDeletion = store.data
        XCTAssertThrowsError(try store.updateTask(id: staleTask.id) { $0.title = "延迟自动保存" })
        XCTAssertEqual(store.data, afterDeletion)
        XCTAssertFalse(store.data.tasks.contains(where: { $0.id == staleTask.id }))
    }

    func testCompletedHistoryRequiresParentCompletionAndUsesExclusiveWeekEnd() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let interval = WorkPeriod.range(containing: date("2024-01-02T04:00:00Z"), firstWeekday: 5, calendar: calendar)
        var task = WorkTask(projectID: UUID(), title: "主任务", subtasks: [Subtask(title: "已完成子任务", completedAt: interval.start), Subtask(title: "未完成子任务")])
        XCTAssertFalse(task.matchesCompletedHistory(in: interval))
        XCTAssertFalse(task.matchesCompletedHistory(in: nil))
        task.completedAt = interval.start
        XCTAssertTrue(task.matchesCompletedHistory(in: interval))
        XCTAssertTrue(task.matchesCompletedHistory(in: nil))
        task.completedAt = interval.end.addingTimeInterval(-1)
        XCTAssertTrue(task.matchesCompletedHistory(in: interval))
        task.completedAt = interval.end
        XCTAssertFalse(task.matchesCompletedHistory(in: interval))
        XCTAssertTrue(task.matchesCompletedHistory(in: nil))
        task.completedAt = interval.start.addingTimeInterval(-1)
        XCTAssertFalse(task.matchesCompletedHistory(in: interval))
    }

    func testDeleteAndRestoreRelinksPredecessorAndPreservesOtherCurrentData() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "删除恢复")
        let completedDate = date("2024-01-01T12:00:00Z")
        let task = WorkTask(projectID: project.id, title: "循环任务", dueAt: completedDate, repeatRule: RepeatRule())
        try store.saveTask(task)
        let following = try XCTUnwrap(store.completeTask(id: task.id, at: completedDate).nextTask)
        let before = store.data
        let deletion = try store.deleteTask(id: following.id)
        XCTAssertEqual(deletion.task, following)
        XCTAssertEqual(deletion.predecessorIDs, [task.id])
        XCTAssertNil(store.data.tasks[0].nextTaskID)
        try store.restoreDeletedTask(deletion)
        XCTAssertEqual(store.data, before)

        let secondDeletion = try store.deleteTask(id: following.id)
        let newProject = try store.addProject(name: "删除后新项目")
        try store.updateTask(id: task.id) { $0.notes = "删除后新增备注" }
        try store.restoreDeletedTask(secondDeletion)
        XCTAssertTrue(store.data.projects.contains(where: { $0.id == newProject.id }))
        XCTAssertEqual(store.data.tasks.first(where: { $0.id == task.id })?.notes, "删除后新增备注")
        XCTAssertEqual(store.data.tasks.first(where: { $0.id == task.id })?.nextTaskID, following.id)
    }

    func testRestoreDeletedTaskRefusesOccupiedIDAndDoesNotOverwriteNewLinks() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "恢复保护")
        let completedDate = date("2024-01-01T12:00:00Z")
        let task = WorkTask(projectID: project.id, title: "循环任务", dueAt: completedDate, repeatRule: RepeatRule())
        try store.saveTask(task)
        let following = try XCTUnwrap(store.completeTask(id: task.id, at: completedDate).nextTask)
        let deletion = try store.deleteTask(id: following.id)
        let newer = WorkTask(id: following.id, projectID: project.id, title: "相同 ID 的新任务")
        try store.saveTask(newer)
        let before = store.data
        XCTAssertThrowsError(try store.restoreDeletedTask(deletion))
        XCTAssertEqual(store.data, before)

        try store.deleteTask(id: newer.id)
        let replacement = WorkTask(projectID: project.id, title: "新的后继任务")
        try store.saveTask(replacement)
        try store.updateTask(id: task.id) { $0.nextTaskID = replacement.id }
        try store.restoreDeletedTask(deletion)
        XCTAssertEqual(store.data.tasks.first(where: { $0.id == task.id })?.nextTaskID, replacement.id)
        XCTAssertEqual(store.data.tasks.first(where: { $0.id == following.id }), following)
    }

    func testCompletionRepeatWithoutDeadlineSavesReloadsAndUsesActualCompletionDate() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let task = WorkTask(title: "完成后半年再处理", details: "本次没有截止日期", repeatRule: RepeatRule(every: 6, unit: .month, basis: .completion))
        try store.saveTask(task)
        let reloaded = try WorkStore(directory: directory)
        XCTAssertNil(reloaded.data.tasks[0].dueAt)
        XCTAssertNil(reloaded.data.tasks[0].reminderAt)
        XCTAssertEqual(reloaded.data.tasks[0].repeatRule, task.repeatRule)
        let completed = date("2024-01-31T12:00:00Z")
        let result = try reloaded.completeTask(id: task.id, at: completed, source: "API")
        let next = try XCTUnwrap(result.nextTask)
        XCTAssertNil(result.task.dueAt)
        XCTAssertNil(result.task.reminderAt)
        XCTAssertEqual(result.task.completedAt, completed)
        XCTAssertEqual(next.dueAt, Calendar.current.date(byAdding: .month, value: 6, to: Calendar.current.startOfDay(for: completed)))
        XCTAssertEqual(next.repeatRule, task.repeatRule)
        XCTAssertNil(next.reminderAt)
        XCTAssertNil(next.scheduleAnchor)
        let repeated = try reloaded.completeTask(id: task.id, at: completed.addingTimeInterval(86400))
        XCTAssertTrue(repeated.alreadyCompleted)
        XCTAssertEqual(repeated.nextTask?.id, next.id)
        XCTAssertEqual(reloaded.data.tasks.count, 2)
        XCTAssertEqual(try WorkStore(directory: directory).data, reloaded.data)
    }

    func testSubtasksCompleteRepeatWithoutDeadlineAndPreserveReminderClock() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let firstDate = date("2024-01-30T12:00:00Z")
        let completed = date("2024-01-31T12:00:00Z")
        let first = Subtask(title: "第一步")
        let last = Subtask(title: "最后一步")
        let task = WorkTask(title: "无截止日期的月度工作", subtasks: [first, last], reminderAt: firstDate, repeatRule: RepeatRule(every: 1, unit: .month, basis: .completion))
        try store.saveTask(task)
        XCTAssertNil(try store.completeSubtask(taskID: task.id, subtaskID: first.id, at: firstDate))
        XCTAssertNil(store.data.tasks[0].dueAt)
        XCTAssertNil(store.data.tasks[0].completedAt)
        let result = try XCTUnwrap(store.completeSubtask(taskID: task.id, subtaskID: last.id, at: completed))
        let next = try XCTUnwrap(result.nextTask)
        let nextDue = try XCTUnwrap(Calendar.current.date(byAdding: .month, value: 1, to: Calendar.current.startOfDay(for: completed)))
        XCTAssertNil(result.task.dueAt)
        XCTAssertEqual(result.task.reminderAt, firstDate)
        XCTAssertEqual(result.task.completedAt, completed)
        XCTAssertEqual(result.task.subtasks.map(\.completedAt), [firstDate, completed])
        XCTAssertEqual(next.dueAt, nextDue)
        let reminderTime = Calendar.current.dateComponents([.hour, .minute, .second], from: firstDate)
        XCTAssertEqual(next.reminderAt, Calendar.current.date(bySettingHour: reminderTime.hour!, minute: reminderTime.minute!, second: reminderTime.second!, of: nextDue))
        XCTAssertTrue(next.subtasks.allSatisfy { $0.completedAt == nil })
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }

    func testFixedRepeatWithoutDeadlineAndInvalidIntervalsAreRejectedWithoutMutation() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let rule = RepeatRule(every: 1, unit: .month, basis: .schedule)
        let task = WorkTask(title: "已有固定循环", dueAt: date("2024-01-31T12:00:00Z"), repeatRule: rule)
        try store.saveTask(task)
        let before = store.data
        let dataURL = directory.appendingPathComponent("data.json")
        let bytes = try Data(contentsOf: dataURL)
        XCTAssertThrowsError(try store.saveTask(WorkTask(title: "缺少固定截止", repeatRule: rule)))
        XCTAssertThrowsError(try store.updateTask(id: task.id) { $0.dueAt = nil })
        for every in [0, 10001] {
            XCTAssertThrowsError(try store.saveTask(WorkTask(title: "无效完成后循环", repeatRule: RepeatRule(every: every, unit: .month, basis: .completion))))
        }
        XCTAssertEqual(store.data, before)
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        XCTAssertEqual(try WorkStore(directory: directory).data, before)
        try store.updateTask(id: task.id) {
            $0.dueAt = nil
            $0.repeatRule?.basis = .completion
            $0.scheduleAnchor = nil
        }
        XCTAssertNil(store.data.tasks[0].dueAt)
        XCTAssertEqual(store.data.tasks[0].repeatRule?.basis, .completion)
        XCTAssertEqual(try WorkStore(directory: directory).data, store.data)
    }
}
