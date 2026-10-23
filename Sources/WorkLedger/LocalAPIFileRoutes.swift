import Foundation
import Darwin
import WorkLedgerCore

@MainActor
enum LocalAPIFileRoutes {
    static let maximumBytes = 16 * 1024 * 1024
    private static let backupFormat = "weekstride-backup-v1"
    private static let restoreConfirmation = "replace-current-data"
    private static let files = FileManager.default

    private struct BackupRecord: Encodable {
        let id: UUID
        let createdAt: Date?
    }

    private struct PortableAttachment: Codable {
        let storedName: String
        let contentBase64: String
    }

    private struct PortableBackup: Encodable {
        let format: String
        let data: LedgerData
        let attachments: [PortableAttachment]
    }

    static func respond(to request: LocalAPIRequest, store: WorkStore) throws -> LocalAPIResponse? {
        guard let components = URLComponents(string: request.head.target), components.scheme == nil, components.host == nil else { return nil }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let isAttachments = path.count >= 5 && path[1] == "v1" && path[2] == "tasks" && path[4] == "attachments"
        let isBackups = path.count >= 3 && path[1] == "v1" && path[2] == "backups"
        guard isAttachments || isBackups else { return nil }
        guard components.queryItems?.isEmpty != false else { throw badRequest("This endpoint does not accept query parameters.") }
        if ["GET", "DELETE"].contains(request.head.method), !request.body.isEmpty {
            throw badRequest("This method does not accept a request body.")
        }
        if isAttachments { return try attachments(request, path: path, store: store) }
        return try backups(request, path: path, store: store)
    }

    private static func attachments(_ request: LocalAPIRequest, path: [String], store: WorkStore) throws -> LocalAPIResponse {
        guard let taskID = UUID(uuidString: path[3]) else { throw badRequest("taskId must be a UUID.") }
        guard let task = store.data.tasks.first(where: { $0.id == taskID }) else { throw notFound("Task not found.") }
        let method = request.head.method
        if path.count == 5 {
            if method == "GET" { return try boundedJSON(task.attachments) }
            guard method == "POST" else { throw methodNotAllowed() }
            let payload = try LocalAPIJSON(request, allowed: ["name", "contentBase64"], required: ["name", "contentBase64"])
            guard let name = try payload.string("name", allowEmpty: false), let encoded = try payload.string("contentBase64") else {
                throw badRequest("name and contentBase64 are required.")
            }
            try validateComponent(name)
            let content = try decodeBase64(encoded, remaining: maximumBytes)
            try LocalAPIJSON.flushEdits(taskID: taskID)
            return try withTemporaryDirectory { directory in
                let source = directory.appendingPathComponent(name)
                try content.write(to: source, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
                let previousIDs = Set(store.data.tasks.first(where: { $0.id == taskID })?.attachments.map(\.id) ?? [])
                try store.addAttachments(urls: [source], to: taskID)
                guard let attachment = store.data.tasks.first(where: { $0.id == taskID })?.attachments.first(where: { !previousIDs.contains($0.id) }) else {
                    throw badRequest("The attachment could not be added.")
                }
                return try boundedJSON(attachment, status: 201)
            }
        }
        guard path.count == 6 || (path.count == 7 && path[6] == "content"), let attachmentID = UUID(uuidString: path[5]) else {
            throw notFound("Attachment endpoint not found.")
        }
        guard let attachment = task.attachments.first(where: { $0.id == attachmentID }) else { throw notFound("Attachment not found.") }
        if path.count == 7 {
            guard method == "GET" else { throw methodNotAllowed() }
            let url = store.attachmentURL(attachment)
            let content = try readFile(in: url.deletingLastPathComponent(), named: attachment.storedName, expectedSize: attachment.size)
            return LocalAPIResponse(status: 200, body: content, contentType: "application/octet-stream")
        }
        if method == "GET" { return try boundedJSON(attachment) }
        guard method == "DELETE" else { throw methodNotAllowed() }
        try LocalAPIJSON.flushEdits(taskID: taskID)
        try store.removeAttachment(taskID: taskID, attachmentID: attachmentID)
        return try .json(["deleted": true])
    }

    private static func backups(_ request: LocalAPIRequest, path: [String], store: WorkStore) throws -> LocalAPIResponse {
        let method = request.head.method
        if path.count == 3 {
            if method == "GET" {
                let directory = try backupDirectory(store, create: false)
                guard files.fileExists(atPath: directory.path) else { return try .json([BackupRecord]()) }
                let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey])
                let records = try entries.compactMap { url -> BackupRecord? in
                    guard url.pathExtension == "workledgerbackup", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                          url.lastPathComponent == "\(id.uuidString).workledgerbackup" else { return nil }
                    let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey])
                    guard info.isDirectory == true, info.isSymbolicLink != true else { return nil }
                    return BackupRecord(id: id, createdAt: info.creationDate)
                }.sorted { $0.id.uuidString < $1.id.uuidString }
                return try boundedJSON(records)
            }
            guard method == "POST" else { throw methodNotAllowed() }
            _ = try LocalAPIJSON(request, allowed: [], allowEmpty: true)
            try LocalAPIJSON.flushEdits()
            // Bound copying and validate every referenced file before starting a managed snapshot.
            _ = try portableAttachments(for: store.data, in: store.directory)
            let directory = try backupDirectory(store, create: true)
            let id = UUID()
            let destination = directory.appendingPathComponent("\(id.uuidString).workledgerbackup", isDirectory: true)
            try store.exportBackup(to: destination)
            let info = try destination.resourceValues(forKeys: [.creationDateKey])
            return try boundedJSON(BackupRecord(id: id, createdAt: info.creationDate), status: 201)
        }
        if path.count == 4 && path[3] == "import" {
            guard method == "POST" else { throw methodNotAllowed() }
            let payload = try LocalAPIJSON(request, allowed: ["format", "data", "attachments", "confirm"], required: ["format", "data", "attachments", "confirm"])
            try requireConfirmation(payload)
            guard try payload.string("format") == backupFormat else { throw badRequest("Unsupported backup format.") }
            guard let object = payload.raw["data"] as? [String: Any], let entries = payload.raw["attachments"] as? [[String: Any]] else {
                throw badRequest("data must be a ledger object and attachments must be an array.")
            }
            let nativeJSON = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard nativeJSON.count <= maximumBytes else { throw tooLarge() }
            let ledger: LedgerData
            do { ledger = try JSONDecoder().decode(LedgerData.self, from: nativeJSON) }
            catch { throw badRequest("Invalid native backup ledger data.") }
            let references = try attachmentRecords(ledger)
            var contents: [String: Data] = [:]
            var remaining = maximumBytes - nativeJSON.count
            for entry in entries {
                guard Set(entry.keys) == ["storedName", "contentBase64"], let name = entry["storedName"] as? String,
                      let encoded = entry["contentBase64"] as? String else { throw badRequest("Each backup attachment requires only storedName and contentBase64 strings.") }
                try validateComponent(name)
                guard contents[name] == nil else { throw badRequest("Duplicate backup attachment storedName.") }
                guard let reference = references[name] else { throw badRequest("A backup attachment has no ledger reference.") }
                let bytes = try decodeBase64(encoded, remaining: remaining)
                guard Int64(bytes.count) == reference.size else { throw badRequest("Backup attachment size does not match its ledger record.") }
                remaining -= bytes.count
                contents[name] = bytes
            }
            guard Set(contents.keys) == Set(references.keys) else { throw badRequest("A referenced backup attachment is missing.") }
            return try withTemporaryDirectory { directory in
                let attachments = directory.appendingPathComponent("attachments", isDirectory: true)
                try files.createDirectory(at: attachments, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try nativeJSON.write(to: directory.appendingPathComponent("data.json"), options: .atomic)
                for (name, content) in contents {
                    let target = attachments.appendingPathComponent(name)
                    guard !files.fileExists(atPath: target.path) else {
                        throw badRequest("Backup file names collide on this file system.")
                    }
                    try content.write(to: target, options: .atomic)
                    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                }
                // Reject invalid graph data before an API request can commit any user's pending edits.
                _ = try WorkStore(directory: directory)
                try LocalAPIJSON.flushEdits()
                // WorkStore validates the complete graph and files before making its safety copy or replacing data.
                try store.importBackup(from: directory)
                return try .json(["restored": true])
            }
        }
        guard path.count == 4 || (path.count == 5 && path[4] == "restore"), let id = UUID(uuidString: path[3]) else {
            throw notFound("Backup endpoint not found.")
        }
        let directory = try managedBackup(id, store: store)
        if path.count == 5 {
            guard method == "POST" else { throw methodNotAllowed() }
            let payload = try LocalAPIJSON(request, allowed: ["confirm"], required: ["confirm"])
            try requireConfirmation(payload)
            let ledger = try readLedger(in: directory)
            _ = try portableAttachments(for: ledger, in: directory)
            try LocalAPIJSON.flushEdits()
            try store.importBackup(from: directory)
            return try .json(["restored": true])
        }
        if method == "GET" {
            let ledger = try readLedger(in: directory)
            let attachments = try portableAttachments(for: ledger, in: directory)
            // Native backup dates are seconds since 2001, preserving exact Double values used by recurrence undo.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(PortableBackup(format: backupFormat, data: ledger, attachments: attachments))
            guard body.count <= maximumBytes else { throw tooLarge() }
            return LocalAPIResponse(status: 200, body: body)
        }
        guard method == "DELETE" else { throw methodNotAllowed() }
        try files.removeItem(at: directory)
        return try .json(["deleted": true])
    }

    private static func requireConfirmation(_ payload: LocalAPIJSON) throws {
        guard try payload.string("confirm") == restoreConfirmation else {
            throw badRequest("Restore replaces current data. Set confirm to replace-current-data; a safety copy is created first.")
        }
    }

    private static func readLedger(in directory: URL) throws -> LedgerData {
        let bytes = try readFile(in: directory, named: "data.json")
        let ledger: LedgerData
        do { ledger = try JSONDecoder().decode(LedgerData.self, from: bytes) }
        catch { throw badRequest("The managed backup ledger is invalid.") }
        try withTemporaryDirectory { validationDirectory in
            try bytes.write(to: validationDirectory.appendingPathComponent("data.json"), options: .atomic)
            _ = try WorkStore(directory: validationDirectory)
        }
        return ledger
    }

    private static func portableAttachments(for ledger: LedgerData, in directory: URL) throws -> [PortableAttachment] {
        let nativeJSON = try JSONEncoder().encode(ledger)
        guard nativeJSON.count <= maximumBytes else { throw tooLarge() }
        var remaining = maximumBytes - nativeJSON.count
        let references = try attachmentRecords(ledger)
        let attachmentDirectory = directory.appendingPathComponent("attachments", isDirectory: true)
        try checkDirectory(attachmentDirectory)
        return try references.keys.sorted().map { name in
            let attachment = references[name]!
            guard attachment.size <= Int64(remaining) else { throw tooLarge() }
            let bytes = try readFile(in: attachmentDirectory, named: name, expectedSize: attachment.size)
            remaining -= bytes.count
            return PortableAttachment(storedName: name, contentBase64: bytes.base64EncodedString())
        }
    }

    private static func attachmentRecords(_ ledger: LedgerData) throws -> [String: Attachment] {
        var result: [String: Attachment] = [:]
        for attachment in ledger.tasks.flatMap(\.attachments) {
            try validateComponent(attachment.storedName)
            guard attachment.size >= 0 else { throw badRequest("Attachment sizes cannot be negative.") }
            if let previous = result[attachment.storedName], previous != attachment { throw badRequest("Conflicting attachment records share a storedName.") }
            result[attachment.storedName] = attachment
        }
        return result
    }

    private static func backupDirectory(_ store: WorkStore, create: Bool) throws -> URL {
        let directory = store.directory.appendingPathComponent("APIBackups", isDirectory: true)
        if !files.fileExists(atPath: directory.path), create {
            try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        if files.fileExists(atPath: directory.path) { try checkDirectory(directory) }
        return directory
    }

    private static func managedBackup(_ id: UUID, store: WorkStore) throws -> URL {
        let directory = try backupDirectory(store, create: false).appendingPathComponent("\(id.uuidString).workledgerbackup", isDirectory: true)
        guard files.fileExists(atPath: directory.path) else { throw notFound("Managed backup not found.") }
        try checkDirectory(directory)
        return directory
    }

    private static func checkDirectory(_ url: URL) throws {
        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw badRequest("Backup and attachment directories must be real directories, not symbolic links.") }
    }

    private static func validateComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), name.utf8.count <= 255,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
            throw badRequest("File names must be basenames without paths or control characters, up to 255 UTF-8 bytes.")
        }
    }

    private static func decodeBase64(_ value: String, remaining: Int) throws -> Data {
        guard remaining >= 0, value.utf8.count <= ((remaining + 2) / 3) * 4 else { throw tooLarge() }
        guard let bytes = Data(base64Encoded: value), bytes.base64EncodedString() == value else { throw badRequest("contentBase64 must use canonical padded Base64 without whitespace.") }
        guard bytes.count <= remaining else { throw tooLarge() }
        return bytes
    }

    private static func readFile(in directory: URL, named name: String, expectedSize: Int64? = nil) throws -> Data {
        try validateComponent(name)
        // openat + O_NOFOLLOW prevents a stored file or its immediate directory from redirecting reads outside the ledger.
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw badRequest("The file directory is missing or is a symbolic link.") }
        defer { close(directoryFD) }
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw badRequest("The file is missing, unreadable, or is a symbolic link.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw badRequest("Content must be a regular file.") }
        guard info.st_size <= Int64(maximumBytes) else { throw tooLarge() }
        guard expectedSize == nil || expectedSize == info.st_size else { throw badRequest("Attachment content size does not match its record.") }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes + 1 - bytes.count)), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= maximumBytes else { throw tooLarge() }
        }
        guard bytes.count == Int(info.st_size) else { throw badRequest("The file changed while it was being read.") }
        return bytes
    }

    private static func withTemporaryDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
        let directory = files.temporaryDirectory.appendingPathComponent("WeekStride-API-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        return try operation(directory)
    }

    private static func boundedJSON<T: Encodable>(_ value: T, status: Int = 200) throws -> LocalAPIResponse {
        let response = try LocalAPIResponse.json(value, status: status)
        guard response.body.count <= maximumBytes else { throw tooLarge() }
        return response
    }

    private static func badRequest(_ message: String) -> LocalAPIHTTPError { LocalAPIHTTPError(status: 400, message: message) }
    private static func notFound(_ message: String) -> LocalAPIHTTPError { LocalAPIHTTPError(status: 404, message: message) }
    private static func methodNotAllowed() -> LocalAPIHTTPError { LocalAPIHTTPError(status: 405, message: "Method not supported for this endpoint.") }
    private static func tooLarge() -> LocalAPIHTTPError { LocalAPIHTTPError(status: 413, message: "The API limit is 16 MiB of decoded backup/file data and 16 MiB per response. Use the app backup interface for larger files or ledgers.") }
}
