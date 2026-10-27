import Foundation
import Combine

@MainActor
public final class WorkStore: ObservableObject {
    @Published public private(set) var data: LedgerData
    @Published public var errorMessage: String?
    public let directory: URL
    private let files = FileManager.default
    private var dataURL: URL { directory.appendingPathComponent("data.json") }
    private var attachmentDirectory: URL { directory.appendingPathComponent("attachments", isDirectory: true) }

    public init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.workledger", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = self.directory.appendingPathComponent("data.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw LedgerError.invalid("数据文件必须是普通文件。") }
            data = try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: url))
            try Self.validate(data)
        } else {
            data = LedgerData()
        }
        let attachments = self.directory.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attachmentInfo = try attachments.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attachmentInfo.isDirectory == true, attachmentInfo.isSymbolicLink != true else { throw LedgerError.invalid("附件目录不能是符号链接。") }
    }

    @discardableResult
    public func addProject(name: String, colorHex: String = "3478F6") throws -> Project {
        let project = Project(name: name.trimmingCharacters(in: .whitespacesAndNewlines), colorHex: colorHex)
        var next = data; next.projects.append(project)
        try commit(next)
        return project
    }

    public func archiveProject(id: UUID) throws {
        guard let index = data.projects.firstIndex(where: { $0.id == id }) else { throw LedgerError.notFound("项目不存在。") }
        var next = data; next.projects[index].isArchived = true
        try commit(next)
    }

    public func unarchiveProject(id: UUID) throws {
        guard let index = data.projects.firstIndex(where: { $0.id == id }) else { throw LedgerError.notFound("项目不存在。") }
        var next = data; next.projects[index].isArchived = false
        try commit(next)
    }

    @discardableResult
    public func updateProject(id: UUID, name: String? = nil, colorHex: String? = nil, isArchived: Bool? = nil) throws -> Project {
        guard let index = data.projects.firstIndex(where: { $0.id == id }) else { throw LedgerError.notFound("项目不存在。") }
        var next = data
        if let name { next.projects[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let colorHex { next.projects[index].colorHex = colorHex }
        if let isArchived { next.projects[index].isArchived = isArchived }
        if next != data { try commit(next) }
        return next.projects[index]
    }

    @discardableResult
    public func deleteProject(id: UUID) throws -> Project {
        guard let project = data.projects.first(where: { $0.id == id }) else { throw LedgerError.notFound("项目不存在。") }
        var next = data
        next.projects.removeAll { $0.id == id }
        for index in next.tasks.indices where next.tasks[index].projectID == id {
            next.tasks[index].projectID = nil
            next.tasks[index].updatedAt = Date()
        }
        try commit(next)
        return project
    }

    @discardableResult
    public func addTag(name: String, colorHex: String = "9462C4") throws -> TaskTag {
        let tag = TaskTag(name: name.trimmingCharacters(in: .whitespacesAndNewlines), colorHex: colorHex)
        var next = data; next.tags.append(tag)
        try commit(next)
        return tag
    }

    @discardableResult
    public func updateTag(id: UUID, name: String? = nil, colorHex: String? = nil) throws -> TaskTag {
        guard let index = data.tags.firstIndex(where: { $0.id == id }) else { throw LedgerError.notFound("标签不存在。") }
        var next = data
        if let name { next.tags[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let colorHex { next.tags[index].colorHex = colorHex }
        if next != data { try commit(next) }
        return next.tags[index]
    }

    @discardableResult
    public func deleteTag(id: UUID) throws -> TaskTag {
        guard let tag = data.tags.first(where: { $0.id == id }) else { throw LedgerError.notFound("标签不存在。") }
        var next = data
        next.tags.removeAll { $0.id == id }
        for index in next.tasks.indices where next.tasks[index].tagIDs.contains(id) {
            next.tasks[index].tagIDs.removeAll { $0 == id }
            next.tasks[index].updatedAt = Date()
        }
        try commit(next)
        return tag
    }

    public func addTagToTask(id: UUID, tagID: UUID) throws {
        guard data.tags.contains(where: { $0.id == tagID }) else { throw LedgerError.notFound("标签不存在。") }
        try updateTask(id: id) { if !$0.tagIDs.contains(tagID) { $0.tagIDs.append(tagID) } }
    }

    public func removeTagFromTask(id: UUID, tagID: UUID) throws {
        guard data.tags.contains(where: { $0.id == tagID }) else { throw LedgerError.notFound("标签不存在。") }
        try updateTask(id: id) { $0.tagIDs.removeAll { $0 == tagID } }
    }

    public func setTaskStarred(id: UUID, isStarred: Bool) throws {
        try updateTask(id: id) { $0.isStarred = isStarred }
    }

    public func validateTask(_ task: WorkTask) throws {
        var next = data
        if let index = next.tasks.firstIndex(where: { $0.id == task.id }) { next.tasks[index] = task }
        else { next.tasks.append(task) }
        try Self.validate(next)
    }

    public func saveTask(_ task: WorkTask) throws {
        var task = task
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = data
        if let index = next.tasks.firstIndex(where: { $0.id == task.id }) {
            task.updatedAt = next.tasks[index].updatedAt
            guard task != next.tasks[index] else { return }
            task.updatedAt = Date()
            next.tasks[index] = task
        } else {
            task.updatedAt = Date()
            next.tasks.append(task)
        }
        try commit(next)
    }

    public func updateTask(id: UUID, _ changes: (inout WorkTask) -> Void) throws {
        guard var task = data.tasks.first(where: { $0.id == id }) else { throw LedgerError.notFound("任务已删除，无法保存修改。") }
        let original = task
        changes(&task)
        guard task.id == id else { throw LedgerError.invalid("更新任务时不能修改任务 ID。") }
        guard task != original else { return }
        try saveTask(task)
    }

    public func moveTask(id: UUID, toProject projectID: UUID?) throws {
        if let projectID {
            guard let project = data.projects.first(where: { $0.id == projectID }) else { throw LedgerError.notFound("目标项目不存在。") }
            guard !project.isArchived else { throw LedgerError.invalid("目标项目已归档，请先恢复项目。") }
        }
        try updateTask(id: id) { $0.projectID = projectID }
    }

    @discardableResult
    public func completeTask(id: UUID, at date: Date = Date(), source: String = "interface") throws -> CompletionResult {
        guard let index = data.tasks.firstIndex(where: { $0.id == id }) else { throw LedgerError.notFound("任务不存在。") }
        if data.tasks[index].completedAt != nil { return existingCompletion(at: index) }
        var next = data
        let result = try complete(at: index, in: &next, date: date, source: source)
        try commit(next)
        return result
    }

    @discardableResult
    public func completeSubtask(taskID: UUID, subtaskID: UUID, at date: Date = Date(), source: String = "interface") throws -> CompletionResult? {
        guard let index = data.tasks.firstIndex(where: { $0.id == taskID }),
              let childIndex = data.tasks[index].subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw LedgerError.notFound("子任务不存在。") }
        if data.tasks[index].completedAt != nil { return existingCompletion(at: index) }
        if data.tasks[index].subtasks[childIndex].completedAt != nil { return nil }
        var next = data
        next.tasks[index].subtasks[childIndex].completedAt = date
        next.tasks[index].updatedAt = Date()
        var result: CompletionResult?
        if next.tasks[index].subtasks.allSatisfy({ $0.completedAt != nil }) {
            let parentDate = next.tasks[index].subtasks.compactMap(\.completedAt).max() ?? date
            result = try complete(at: index, in: &next, date: parentDate, source: source, subtaskSnapshot: data.tasks[index].subtasks)
        }
        try commit(next)
        return result
    }

    public func undoSubtaskCompletion(taskID: UUID, subtaskID: UUID) throws {
        guard let index = data.tasks.firstIndex(where: { $0.id == taskID }),
              let child = data.tasks[index].subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw LedgerError.notFound("子任务不存在。") }
        guard data.tasks[index].completedAt == nil else {
            throw LedgerError.conflict("请先撤销主任务完成，再取消步骤完成。")
        }
        guard data.tasks[index].subtasks[child].completedAt != nil else { return }
        var next = data
        next.tasks[index].subtasks[child].completedAt = nil
        next.tasks[index].updatedAt = Date()
        try commit(next)
    }

    public func undoCompletion(id: UUID) throws {
        let next = try reopeningTask(id: id)
        if next != data { try commit(next) }
    }

    public func validateUndoCompletion(id: UUID) throws {
        try Self.validate(reopeningTask(id: id))
    }

    private func reopeningTask(id: UUID) throws -> LedgerData {
        guard let index = data.tasks.firstIndex(where: { $0.id == id }) else { throw LedgerError.notFound("任务不存在。") }
        let task = data.tasks[index]
        guard task.completedAt != nil else { return data }
        if let nextID = task.nextTaskID, let following = data.tasks.first(where: { $0.id == nextID }) {
            guard following.updatedAt == following.createdAt, following.completedAt == nil,
                  following.nextTaskID == nil, following.subtasks.allSatisfy({ $0.completedAt == nil }) else {
                throw LedgerError.conflict("下一次循环任务已经修改或开始执行。请先处理下一次任务，再撤销本次完成，避免丢失工作。")
            }
        }
        guard task.completionSubtaskSnapshot != nil || task.subtasks.isEmpty else {
            throw LedgerError.conflict("此历史任务没有可恢复的子任务快照，无法安全撤销完成。")
        }
        var next = data
        next.tasks[index].subtasks = task.subtasks.map { child in
            var restored = child
            restored.completedAt = task.completionSubtaskSnapshot?.first(where: { $0.id == child.id })?.completedAt
            return restored
        }
        next.tasks[index].completedAt = nil
        next.tasks[index].completionSource = nil
        next.tasks[index].completionSubtaskSnapshot = nil
        next.tasks[index].nextTaskID = nil
        next.tasks[index].updatedAt = Date()
        if let nextID = task.nextTaskID { next.tasks.removeAll { $0.id == nextID } }
        return next
    }

    public func setCompletionDate(taskID: UUID, at date: Date) throws {
        guard let index = data.tasks.firstIndex(where: { $0.id == taskID }) else { throw LedgerError.notFound("任务不存在。") }
        guard data.tasks[index].completedAt != nil else { throw LedgerError.invalid("请先完成任务，再修改完成日期。") }
        guard data.tasks[index].completedAt != date else { return }
        var next = data
        next.tasks[index].completedAt = date
        next.tasks[index].updatedAt = Date()
        try commit(next)
    }

    public func setSubtaskCompletionDate(taskID: UUID, subtaskID: UUID, at date: Date) throws {
        guard let index = data.tasks.firstIndex(where: { $0.id == taskID }),
              let child = data.tasks[index].subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw LedgerError.notFound("子任务不存在。") }
        guard data.tasks[index].subtasks[child].completedAt != nil else { throw LedgerError.invalid("请先完成子任务，再修改完成日期。") }
        guard data.tasks[index].subtasks[child].completedAt != date else { return }
        var next = data
        next.tasks[index].subtasks[child].completedAt = date
        next.tasks[index].updatedAt = Date()
        try commit(next)
    }

    @discardableResult
    public func deleteTask(id: UUID) throws -> TaskDeletion {
        guard let task = data.tasks.first(where: { $0.id == id }) else { throw LedgerError.notFound("任务不存在。") }
        let deletion = TaskDeletion(task: task, predecessorIDs: data.tasks.filter { $0.nextTaskID == id }.map(\.id))
        var next = data
        if let successorID = task.nextTaskID, let successor = next.tasks.firstIndex(where: { $0.id == successorID }), next.tasks[successor].scheduleAnchor == nil {
            next.tasks[successor].scheduleAnchor = scheduleAnchor(for: next.tasks[successor], in: next)
        }
        next.tasks.removeAll { $0.id == id }
        for index in next.tasks.indices where next.tasks[index].nextTaskID == id { next.tasks[index].nextTaskID = nil }
        try commit(next)
        // Files remain available to history and backups; deleting a record must not delete shared bytes.
        return deletion
    }

    public func restoreDeletedTask(_ snapshot: TaskDeletion) throws {
        try commit(restoringDeletedTask(snapshot))
    }

    public func validateRestoringDeletedTask(_ snapshot: TaskDeletion) throws {
        try Self.validate(restoringDeletedTask(snapshot))
    }

    private func restoringDeletedTask(_ snapshot: TaskDeletion) throws -> LedgerData {
        guard !data.tasks.contains(where: { $0.id == snapshot.task.id }) else { throw LedgerError.conflict("此任务 ID 已存在，无法恢复删除；现有任务保持不变。") }
        var next = data
        var restored = snapshot.task
        if let successorID = restored.nextTaskID, !next.tasks.contains(where: { $0.id == successorID }) { restored.nextTaskID = nil }
        next.tasks.append(restored)
        for index in next.tasks.indices where snapshot.predecessorIDs.contains(next.tasks[index].id) && next.tasks[index].nextTaskID == nil && next.tasks[index].completedAt != nil {
            next.tasks[index].nextTaskID = restored.id
        }
        return next
    }

    public func addAttachments(urls: [URL], to taskID: UUID) throws {
        guard let index = data.tasks.firstIndex(where: { $0.id == taskID }) else { throw LedgerError.notFound("任务不存在。") }
        guard !urls.isEmpty else { return }
        var next = data
        var copied: [URL] = []
        do {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true else { throw LedgerError.invalid("附件必须是文件：\(url.lastPathComponent)") }
                let suffix = url.pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(20)
                let storedName = UUID().uuidString + (suffix.isEmpty ? "" : ".\(suffix)")
                let attachment = Attachment(name: url.lastPathComponent, storedName: storedName, size: Int64(info.fileSize ?? 0))
                let target = attachmentURL(attachment)
                try files.copyItem(at: url, to: target)
                copied.append(target)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                next.tasks[index].attachments.append(attachment)
            }
            next.tasks[index].updatedAt = Date()
            try commit(next)
        } catch {
            for url in copied { try? files.removeItem(at: url) }
            throw error
        }
    }

    public func attachmentURL(_ attachment: Attachment) -> URL {
        attachmentDirectory.appendingPathComponent(attachment.storedName)
    }

    public func removeAttachment(taskID: UUID, attachmentID: UUID) throws {
        guard let index = data.tasks.firstIndex(where: { $0.id == taskID }), data.tasks[index].attachments.contains(where: { $0.id == attachmentID }) else { throw LedgerError.notFound("附件不存在。") }
        var next = data
        next.tasks[index].attachments.removeAll { $0.id == attachmentID }
        next.tasks[index].updatedAt = Date()
        try commit(next)
    }

    public func exportBackup(to url: URL) throws {
        try Self.exportBackup(snapshot: data, directory: directory, to: url)
    }

    public nonisolated static func exportBackup(snapshot: LedgerData, directory: URL, to url: URL) throws {
        try validate(snapshot)
        let files = FileManager.default
        guard !files.fileExists(atPath: url.path) else { throw LedgerError.conflict("备份位置已存在，请选择一个新名称。") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".workledger-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: temporary.appendingPathComponent("attachments"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let jsonURL = temporary.appendingPathComponent("data.json")
            try encoded(snapshot).write(to: jsonURL, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jsonURL.path)
            for attachment in uniqueAttachments(snapshot) {
                let source = directory.appendingPathComponent("attachments").appendingPathComponent(attachment.storedName)
                try verifyAttachment(attachment, at: source)
                try files.copyItem(at: source, to: temporary.appendingPathComponent("attachments").appendingPathComponent(attachment.storedName))
            }
            try files.moveItem(at: temporary, to: url)
        } catch {
            try? files.removeItem(at: temporary)
            throw error
        }
    }

    public func importBackup(from url: URL) throws {
        let backupJSON = url.appendingPathComponent("data.json")
        let backupAttachments = url.appendingPathComponent("attachments")
        guard try backupJSON.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try backupAttachments.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LedgerError.invalid("备份不能包含符号链接。") }
        let next = try JSONDecoder().decode(LedgerData.self, from: Data(contentsOf: backupJSON))
        try Self.validate(next)
        let incoming = Self.uniqueAttachments(next)
        let currentAttachments = Dictionary(uniqueKeysWithValues: Self.uniqueAttachments(data).map { ($0.storedName, $0) })
        var damagedTargets: Set<String> = []
        for attachment in incoming {
            let source = url.appendingPathComponent("attachments").appendingPathComponent(attachment.storedName)
            try Self.verifyAttachment(attachment, at: source)
            let target = attachmentURL(attachment)
            if files.fileExists(atPath: target.path), !files.contentsEqual(atPath: source.path, andPath: target.path) {
                let info = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      let current = currentAttachments[attachment.storedName] else {
                    throw LedgerError.conflict("附件内容冲突，未导入：\(attachment.name)")
                }
                let isDamaged: Bool
                do { try Self.verifyAttachment(current, at: target); isDamaged = false }
                catch { isDamaged = true }
                guard isDamaged else { throw LedgerError.conflict("附件内容冲突，未导入：\(attachment.name)") }
                damagedTargets.insert(attachment.storedName)
            }
        }
        let backups = directory.appendingPathComponent("Backups", isDirectory: true)
        try files.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backupInfo = try backups.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard backupInfo.isDirectory == true, backupInfo.isSymbolicLink != true else { throw LedgerError.invalid("安全副本目录不能是符号链接。") }
        let safetyCopy = try importSafetyCopy(in: backups)
        var copied: [URL] = []
        var displaced: [(original: URL, target: URL)] = []
        do {
            for attachment in incoming {
                let target = attachmentURL(attachment)
                if damagedTargets.contains(attachment.storedName) {
                    let originals = safetyCopy.appendingPathComponent("replaced-originals", isDirectory: true)
                    try files.createDirectory(at: originals, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let original = originals.appendingPathComponent(attachment.storedName)
                    try files.moveItem(at: target, to: original)
                    displaced.append((original, target))
                }
                if !files.fileExists(atPath: target.path) {
                    copied.append(target)
                    try files.copyItem(at: url.appendingPathComponent("attachments").appendingPathComponent(attachment.storedName), to: target)
                    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                }
            }
            try commit(next)
        } catch {
            for target in copied { try? files.removeItem(at: target) }
            var rollbackFailed = false
            for item in displaced.reversed() {
                do { try files.moveItem(at: item.original, to: item.target) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed { throw LedgerError.conflict("恢复未完成，原附件保留在安全副本中，请保留数据目录并检查：\(safetyCopy.path)") }
            throw error
        }
    }

    private func importSafetyCopy(in backups: URL) throws -> URL {
        let id = UUID().uuidString
        let backup = backups.appendingPathComponent("before-import-\(id).workledgerbackup", isDirectory: true)
        do {
            try exportBackup(to: backup)
            return backup
        } catch {
            let rescue = backups.appendingPathComponent("before-import-\(id).workledgerrescue", isDirectory: true)
            let temporary = backups.appendingPathComponent(".workledger-rescue-\(id)", isDirectory: true)
            defer { try? files.removeItem(at: temporary) }
            let attachments = temporary.appendingPathComponent("attachments", isDirectory: true)
            try files.createDirectory(at: attachments, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            func write(_ bytes: Data, named name: String) throws {
                let target = temporary.appendingPathComponent(name)
                try bytes.write(to: target, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
            try write(Self.encoded(data), named: "snapshot.json")
            var issues: [String] = []
            do {
                let info = try dataURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { throw LedgerError.invalid("Original metadata is not a regular file.") }
                try write(Data(contentsOf: dataURL), named: "original-data.json")
            } catch { issues.append("Original metadata unavailable: \(error.localizedDescription)") }
            for attachment in Self.uniqueAttachments(data) {
                let source = attachmentURL(attachment)
                do {
                    let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true else { throw LedgerError.invalid("Not a regular file.") }
                    if Int64(info.fileSize ?? -1) != attachment.size { issues.append("Attachment size mismatch: \(attachment.storedName)") }
                    let target = attachments.appendingPathComponent(attachment.storedName)
                    try files.copyItem(at: source, to: target)
                    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                } catch { issues.append("Attachment unavailable: \(attachment.storedName): \(error.localizedDescription)") }
            }
            let manifest: [String: Any] = ["format": "weekstride-rescue-v1", "completeBackup": false,
                                           "reason": error.localizedDescription, "issues": issues]
            try write(JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]), named: "manifest.json")
            let readme = """
            WeekStride pre-restore rescue copy — NOT a complete, normally restorable backup.

            The current data could not be exported as a valid backup. This rescue copy preserves
            the in-memory ledger (snapshot.json), readable original metadata (original-data.json),
            and readable attachment bytes. See manifest.json for missing or damaged files.
            Replaced original files, if any, are retained under replaced-originals.
            Do not rename these files to data.json or import this folder as a normal backup.
            Keep this folder for manual recovery; use a valid .workledgerbackup for restoration.
            """
            try write(Data(readme.utf8), named: "README.txt")
            try files.moveItem(at: temporary, to: rescue)
            return rescue
        }
    }

    private func existingCompletion(at index: Int) -> CompletionResult {
        let task = data.tasks[index]
        return CompletionResult(task: task, nextTask: data.tasks.first(where: { $0.id == task.nextTaskID }), alreadyCompleted: true)
    }

    private func complete(at index: Int, in next: inout LedgerData, date: Date, source: String, subtaskSnapshot: [Subtask]? = nil) throws -> CompletionResult {
        next.tasks[index].completionSubtaskSnapshot = subtaskSnapshot ?? next.tasks[index].subtasks
        next.tasks[index].completedAt = date
        next.tasks[index].completionSource = source
        next.tasks[index].updatedAt = Date()
        for child in next.tasks[index].subtasks.indices where next.tasks[index].subtasks[child].completedAt == nil {
            next.tasks[index].subtasks[child].completedAt = date
        }
        var following: WorkTask?
        if let rule = next.tasks[index].repeatRule {
            let original = next.tasks[index]
            let calendar = Calendar.current
            var basis = rule.basis == .completion ? calendar.startOfDay(for: date) : (original.dueAt ?? date)
            var intervals = 1
            if let anchor = scheduleAnchor(for: original, in: next) {
                basis = anchor.date
                intervals = anchor.occurrence + 1
            }
            guard let due = calendar.date(byAdding: rule.unit.calendarComponent, value: rule.every * intervals, to: basis) else { throw LedgerError.invalid("无法计算下次任务日期。") }
            let reminder = try Self.nextReminder(previousDue: original.dueAt, previousReminder: original.reminderAt,
                                                 nextDue: due, completedAt: date, calendar: calendar)
            let seriesID = original.seriesID ?? original.id
            let now = Date()
            let persistedAnchor = rule.basis == .schedule ? ScheduleAnchor(date: basis, occurrence: intervals, rule: rule) : nil
            let task = WorkTask(projectID: original.projectID, title: original.title, details: original.details, notes: original.notes, subtasks: original.subtasks.map { Subtask(title: $0.title) }, attachments: original.attachments, dueAt: due, reminderAt: reminder, repeatRule: rule, createdAt: now, updatedAt: now, seriesID: seriesID, scheduleAnchor: persistedAnchor, plannedAt: nil, planGranularity: nil, tagIDs: original.tagIDs, isStarred: original.isStarred)
            next.tasks[index].seriesID = seriesID
            next.tasks[index].nextTaskID = task.id
            next.tasks.append(task)
            following = task
        }
        return CompletionResult(task: next.tasks[index], nextTask: following, alreadyCompleted: false)
    }

    static func nextReminder(previousDue: Date?, previousReminder: Date?, nextDue: Date,
                             completedAt: Date, calendar: Calendar) throws -> Date? {
        guard let previousReminder else { return nil }
        let dayOffset = previousDue.map {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: $0),
                                    to: calendar.startOfDay(for: previousReminder)).day ?? 0
        } ?? 0
        let time = calendar.dateComponents([.hour, .minute, .second], from: previousReminder)
        func atOriginalTime(on day: Date) throws -> Date {
            guard let value = calendar.nextDate(after: calendar.startOfDay(for: day).addingTimeInterval(-1),
                                               matching: time, matchingPolicy: .nextTimePreservingSmallerComponents,
                                               repeatedTimePolicy: .first, direction: .forward) else {
                throw LedgerError.invalid("无法计算下次提醒日期。")
            }
            return value
        }
        guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: nextDue)) else {
            throw LedgerError.invalid("无法计算下次提醒日期。")
        }
        let reminder = try atOriginalTime(on: targetDay)
        guard reminder <= completedAt else { return reminder }
        // Backdated completion must use its recorded time, not rewrite history using the system clock.
        let today = try atOriginalTime(on: completedAt)
        if today > completedAt { return today }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: completedAt)) else {
            throw LedgerError.invalid("无法计算下次提醒日期。")
        }
        return try atOriginalTime(on: tomorrow)
    }

    private func scheduleAnchor(for task: WorkTask, in ledger: LedgerData) -> ScheduleAnchor? {
        guard let rule = task.repeatRule, rule.basis == .schedule, let due = task.dueAt else { return nil }
        let reset = ScheduleAnchor(date: due, occurrence: 0, rule: rule)
        var current = task
        var hops = 0
        var visited: Set<UUID> = [task.id]
        while true {
            if let saved = current.scheduleAnchor {
                let candidate = ScheduleAnchor(date: saved.date, occurrence: saved.occurrence + hops, rule: rule)
                guard saved.rule == rule, Calendar.current.date(byAdding: rule.unit.calendarComponent, value: rule.every * candidate.occurrence, to: candidate.date) == due else { return reset }
                return candidate
            }
            guard let previous = ledger.tasks.first(where: { $0.nextTaskID == current.id && $0.repeatRule == rule }), visited.insert(previous.id).inserted else { break }
            current = previous
            hops += 1
        }
        guard let anchorDate = current.dueAt, Calendar.current.date(byAdding: rule.unit.calendarComponent, value: rule.every * hops, to: anchorDate) == due else { return reset }
        return ScheduleAnchor(date: anchorDate, occurrence: hops, rule: rule)
    }

    private func commit(_ next: LedgerData) throws {
        guard next != data else { return }
        try Self.validate(next)
        let encodedData = try Self.encoded(next)
        let temporary = directory.appendingPathComponent(".data-\(UUID().uuidString).json")
        defer { try? files.removeItem(at: temporary) }
        try encodedData.write(to: temporary, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if files.fileExists(atPath: dataURL.path) {
            let info = try dataURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw LedgerError.invalid("数据文件必须是普通文件。") }
            _ = try files.replaceItemAt(dataURL, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: temporary, to: dataURL)
        }
        data = next
    }

    private nonisolated static func encoded(_ data: LedgerData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(data)
    }

    private nonisolated static func uniqueAttachments(_ ledger: LedgerData) -> [Attachment] {
        var names: Set<String> = []
        return ledger.tasks.flatMap(\.attachments).filter { names.insert($0.storedName).inserted }
    }

    private nonisolated static func verifyAttachment(_ attachment: Attachment, at url: URL) throws {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, Int64(info.fileSize ?? -1) == attachment.size else { throw LedgerError.invalid("附件缺失、已损坏或不是普通文件：\(attachment.name)") }
    }

    private nonisolated static func isValidDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (-62_135_596_800..<253_402_300_800).contains(seconds)
    }

    private nonisolated static func validate(_ ledger: LedgerData) throws {
        guard ledger.schemaVersion == 1 else { throw LedgerError.invalid("不支持此数据版本，请保留原文件并更新应用。") }
        guard Set(ledger.projects.map(\.id)).count == ledger.projects.count,
              Set(ledger.tags.map(\.id)).count == ledger.tags.count,
              Set(ledger.tasks.map(\.id)).count == ledger.tasks.count else { throw LedgerError.invalid("数据包含重复 ID。") }
        let projectIDs = Set(ledger.projects.map(\.id))
        let tagIDs = Set(ledger.tags.map(\.id))
        let taskIDs = Set(ledger.tasks.map(\.id))
        var subtaskIDs: Set<UUID> = []
        var attachmentsByName: [String: Attachment] = [:]
        var successors: [UUID: UUID] = [:]
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        for project in ledger.projects {
            guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LedgerError.invalid("项目名称不能为空。") }
            let color = project.colorHex.hasPrefix("#") ? String(project.colorHex.dropFirst()) : project.colorHex
            guard color.count == 6, color.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw LedgerError.invalid("项目颜色必须为六位十六进制颜色。") }
        }
        for tag in ledger.tags {
            guard !tag.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LedgerError.invalid("标签名称不能为空。") }
            let color = tag.colorHex.hasPrefix("#") ? String(tag.colorHex.dropFirst()) : tag.colorHex
            guard color.count == 6, color.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw LedgerError.invalid("标签颜色必须为六位十六进制颜色。") }
        }
        for task in ledger.tasks {
            if let projectID = task.projectID, !projectIDs.contains(projectID) { throw LedgerError.invalid("任务关联的项目不存在。") }
            guard Set(task.tagIDs).count == task.tagIDs.count,
                  task.tagIDs.allSatisfy(tagIDs.contains) else { throw LedgerError.invalid("任务标签重复或不存在。") }
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LedgerError.invalid("任务标题不能为空。") }
            guard [task.createdAt, task.updatedAt].allSatisfy(Self.isValidDate),
                  [task.dueAt, task.reminderAt, task.completedAt, task.plannedAt].compactMap({ $0 }).allSatisfy(Self.isValidDate) else { throw LedgerError.invalid("任务日期无效。") }
            guard task.planGranularity == nil || task.plannedAt != nil else { throw LedgerError.invalid("请先设置计划日期，再选择按天或按周安排。") }
            if let completed = task.completedAt, completed >= tomorrow { throw LedgerError.invalid("完成日期不能晚于今天。") }
            if let rule = task.repeatRule {
                guard (1...10000).contains(rule.every) else { throw LedgerError.invalid("重复间隔必须在 1 至 10000 之间。") }
                guard rule.basis == .completion || task.dueAt != nil else { throw LedgerError.invalid("按固定日期循环需要设置截止日期。") }
            }
            if let anchor = task.scheduleAnchor {
                guard Self.isValidDate(anchor.date), (0...1_000_000).contains(anchor.occurrence),
                      (1...10000).contains(anchor.rule.every), anchor.rule.basis == .schedule else { throw LedgerError.invalid("循环任务的日期锚点无效。") }
            }
            if let nextID = task.nextTaskID {
                guard task.completedAt != nil, nextID != task.id, taskIDs.contains(nextID) else { throw LedgerError.invalid("循环任务关联无效。") }
                successors[task.id] = nextID
            }
            for subtask in task.subtasks {
                guard subtaskIDs.insert(subtask.id).inserted, !subtask.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LedgerError.invalid("子任务 ID 重复或标题为空。") }
                if let completed = subtask.completedAt, !Self.isValidDate(completed) || completed >= tomorrow { throw LedgerError.invalid("子任务完成日期无效或晚于今天。") }
            }
            if let snapshot = task.completionSubtaskSnapshot {
                guard Set(snapshot.map(\.id)).count == snapshot.count,
                      snapshot.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.completedAt.map { Self.isValidDate($0) && $0 < tomorrow } ?? true) }) else { throw LedgerError.invalid("子任务完成快照无效。") }
            }
            guard Set(task.attachments.map(\.id)).count == task.attachments.count else { throw LedgerError.invalid("任务附件 ID 重复。") }
            for attachment in task.attachments {
                guard !attachment.name.isEmpty, attachment.size >= 0,
                      !attachment.storedName.isEmpty, attachment.storedName != ".", attachment.storedName != "..",
                      !attachment.storedName.contains("/"), !attachment.storedName.contains("\\"), !attachment.storedName.contains("\0") else { throw LedgerError.invalid("附件路径或大小无效。") }
                if let existing = attachmentsByName[attachment.storedName], existing != attachment { throw LedgerError.invalid("附件记录冲突。") }
                attachmentsByName[attachment.storedName] = attachment
            }
        }
        var checked: Set<UUID> = []
        for id in successors.keys where !checked.contains(id) {
            var path: Set<UUID> = []
            var current: UUID? = id
            while let id = current, !checked.contains(id) {
                guard path.insert(id).inserted else { throw LedgerError.invalid("循环任务关联无效。") }
                current = successors[id]
            }
            checked.formUnion(path)
        }
    }
}
