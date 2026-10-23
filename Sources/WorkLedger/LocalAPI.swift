import Foundation
import Network
import WorkLedgerCore

@MainActor
final class LocalAPIServer {
    var onStatus: ((String) -> Void)?
    private var listener: NWListener?
    private var retiringListener: NWListener?
    private var listenerStarted = false
    private var connections: [UUID: LocalAPIConnection] = [:]
    private var generation = UUID()

    func start(token: String, store: WorkStore) throws {
        stop()
        guard token.utf8.count == 64, token.allSatisfy({ $0.isHexDigit }) else {
            throw LocalAPIHTTPError(status: 400, message: "访问令牌无效。")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 18743)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let currentGeneration = generation
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener else { return }
                if case .cancelled = state, self.retiringListener === listener {
                    self.retiringListener = nil
                    self.startListenerIfReady()
                }
                guard self.generation == currentGeneration, self.listener === listener else { return }
                switch state {
                case .ready: self.onStatus?("已开启 http://127.0.0.1:18743")
                case .failed:
                    self.stop()
                    self.onStatus?("本地 API 启动失败，请检查端口 18743 是否已被使用。")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak store] connection in
            Task { @MainActor in
                guard let self, let store, self.generation == currentGeneration, self.listener != nil, self.connections.count < 32 else {
                    connection.cancel()
                    return
                }
                let id = UUID()
                let client = LocalAPIConnection(connection: connection, token: token) { [weak self, weak store] request in
                    guard let self, let store, self.generation == currentGeneration, self.listener != nil else { return nil }
                    return self.respond(to: request, store: store)
                } onClose: { [weak self] in self?.connections.removeValue(forKey: id) }
                self.connections[id] = client
                client.start()
            }
        }
        startListenerIfReady()
    }

    private func startListenerIfReady() {
        guard retiringListener == nil, !listenerStarted, let listener else { return }
        listenerStarted = true
        listener.start(queue: .main)
    }

    func stop() {
        generation = UUID()
        // Cancellation releases the port asynchronously; a replacement must wait for .cancelled.
        if listenerStarted { retiringListener = listener }
        listenerStarted = false
        listener?.cancel()
        listener = nil
        let clients = Array(connections.values)
        connections.removeAll()
        clients.forEach { $0.close() }
    }

    private func respond(to request: LocalAPIRequest, store: WorkStore) -> LocalAPIResponse {
        do {
            guard let components = URLComponents(string: request.head.target), components.scheme == nil, components.host == nil else {
                throw LocalAPIHTTPError(status: 400, message: "请求地址无效。")
            }
            let path = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let query = components.queryItems ?? []
            guard Set(query.map(\.name)).count == query.count else {
                throw LocalAPIHTTPError(status: 400, message: "查询参数不能重复。")
            }
            if request.head.method == "GET" {
                guard request.body.isEmpty else { throw LocalAPIHTTPError(status: 400, message: "GET 请求不接受正文。") }
                switch components.path {
                case "/health":
                    guard query.isEmpty else { throw LocalAPIHTTPError(status: 400, message: "不支持此查询参数。") }
                    return try .json(["status": "ok"])
                case "/v1/projects":
                    guard query.isEmpty else { throw LocalAPIHTTPError(status: 400, message: "不支持此查询参数。") }
                    return try .json(store.data.projects)
                case "/v1/tasks":
                    guard query.allSatisfy({ ["status", "projectId"].contains($0.name) }) else {
                        throw LocalAPIHTTPError(status: 400, message: "不支持此查询参数。")
                    }
                    var tasks = store.data.tasks
                    if let item = query.first(where: { $0.name == "status" }) {
                        guard let status = item.value, ["open", "completed"].contains(status) else {
                            throw LocalAPIHTTPError(status: 400, message: "status 必须为 open 或 completed。")
                        }
                        tasks = tasks.filter { status == "open" ? $0.completedAt == nil : $0.completedAt != nil }
                    }
                    if let item = query.first(where: { $0.name == "projectId" }) {
                        guard let value = item.value, let id = UUID(uuidString: value) else {
                            throw LocalAPIHTTPError(status: 400, message: "projectId 必须为 UUID。")
                        }
                        tasks = tasks.filter { $0.projectID == id }
                    }
                    return try .json(tasks)
                default:
                    if path.count == 4, path[1] == "v1", path[2] == "tasks", let id = UUID(uuidString: path[3]), query.isEmpty {
                        guard let task = store.data.tasks.first(where: { $0.id == id }) else { return .error(404, "任务不存在。") }
                        return try .json(task)
                    }
                }
            } else if request.head.method == "POST" {
                guard query.isEmpty else { throw LocalAPIHTTPError(status: 400, message: "不支持此查询参数。") }
                if path.count == 5, path[1] == "v1", path[2] == "tasks", path[4] == "complete", let id = UUID(uuidString: path[3]) {
                    guard let task = store.data.tasks.first(where: { $0.id == id }) else { return .error(404, "任务不存在。") }
                    let date = try Self.completionDate(request)
                    if task.completedAt == nil { try Self.flushEdits(taskID: id) }
                    return try .json(store.completeTask(id: id, at: date, source: "API"))
                }
                if path.count == 7, path[1] == "v1", path[2] == "tasks", path[4] == "subtasks", path[6] == "complete",
                   let taskID = UUID(uuidString: path[3]), let subtaskID = UUID(uuidString: path[5]) {
                    guard let task = store.data.tasks.first(where: { $0.id == taskID }),
                          let subtask = task.subtasks.first(where: { $0.id == subtaskID }) else { return .error(404, "任务或子任务不存在。") }
                    let date = try Self.completionDate(request)
                    if task.completedAt == nil && subtask.completedAt == nil { try Self.flushEdits(taskID: taskID) }
                    let alreadyCompleted = subtask.completedAt != nil
                    if let result = try store.completeSubtask(taskID: taskID, subtaskID: subtaskID, at: date, source: "API") {
                        return try .json(result)
                    }
                    guard let updated = store.data.tasks.first(where: { $0.id == taskID }) else { return .error(404, "任务不存在。") }
                    return try .json(CompletionResult(task: updated, nextTask: nil, alreadyCompleted: alreadyCompleted))
                }
            } else { return .error(405, "仅支持 GET 和 POST。") }
            return .error(404, "接口不存在。")
        } catch let error as LocalAPIHTTPError {
            return .error(error.status, error.message)
        } catch let error as LedgerError {
            switch error {
            case .notFound(let message): return .error(404, message)
            case .invalid(let message), .conflict(let message): return .error(400, message)
            }
        } catch {
            return .error(500, "操作未完成，请在应用中检查任务和存储状态。")
        }
    }

    private static func flushEdits(taskID: UUID) throws {
        let request = InlineFlushRequest(taskID: taskID)
        NotificationCenter.default.post(name: flushTaskEdits, object: request)
        guard !request.failed else { throw LocalAPIHTTPError(status: 400, message: "当前任务的编辑内容未能保存，请先在应用中修正后重试。") }
    }

    private static func completionDate(_ request: LocalAPIRequest) throws -> Date {
        guard !request.body.isEmpty else { return Date() }
        let type = request.head.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard type == "application/json" else { throw LocalAPIHTTPError(status: 400, message: "正文需要使用 application/json。") }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: request.body) }
        catch { throw LocalAPIHTTPError(status: 400, message: "正文必须为 JSON 对象，可包含 completedAt。") }
        guard let payload = object as? [String: Any] else { throw LocalAPIHTTPError(status: 400, message: "正文必须为 JSON 对象，可包含 completedAt。") }
        guard payload.keys.allSatisfy({ $0 == "completedAt" }) else { throw LocalAPIHTTPError(status: 400, message: "仅支持 completedAt 字段，请检查字段拼写。") }
        guard let raw = payload["completedAt"] else { return Date() }
        guard let value = raw as? String else { throw LocalAPIHTTPError(status: 400, message: "completedAt 必须为包含时区的 ISO 8601 日期时间字符串。") }
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"#
        guard let range = value.range(of: pattern, options: .regularExpression), range == value.startIndex..<value.endIndex else {
            throw LocalAPIHTTPError(status: 400, message: "completedAt 必须为完整且包含时区的 ISO 8601 日期时间。")
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        let localTime = String(value.prefix(19)) + "Z"
        // Foundation normalizes dates such as February 31; a round trip must retain every component.
        guard let localDate = formatter.date(from: localTime), formatter.string(from: localDate) == localTime else {
            throw LocalAPIHTTPError(status: 400, message: "completedAt 的日期或时间不存在。")
        }
        if value.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
        guard let date = formatter.date(from: value) else { throw LocalAPIHTTPError(status: 400, message: "completedAt 必须为包含时区的 ISO 8601 日期时间。") }
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())), date < tomorrow else {
            throw LocalAPIHTTPError(status: 400, message: "完成日期不能晚于今天。")
        }
        return date
    }
}

struct LocalAPIHTTPError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct LocalAPIRequestHead {
    let method: String
    let target: String
    let headers: [String: String]
    let bodyLength: Int
    let headerLength: Int
}

struct LocalAPIRequest {
    let head: LocalAPIRequestHead
    let body: Data
}

enum LocalAPIParser {
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 64 * 1024

    static func head(in data: Data, token: String) throws -> LocalAPIRequestHead? {
        guard let end = data.range(of: Data([13, 10, 13, 10])) else {
            if data.count > maximumHeaderBytes { throw LocalAPIHTTPError(status: 413, message: "请求头过大。") }
            return nil
        }
        let headerLength = end.upperBound
        guard headerLength <= maximumHeaderBytes else { throw LocalAPIHTTPError(status: 413, message: "请求头过大。") }
        let headerData = data[..<end.lowerBound]
        guard headerData.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let header = String(data: headerData, encoding: .ascii) else { throw LocalAPIHTTPError(status: 400, message: "请求头无效。") }
        var lines = header.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, !first[0].isEmpty, first[2] == "HTTP/1.1", first[1].hasPrefix("/"), !first[1].hasPrefix("//"), !first[1].contains("#") else {
            throw LocalAPIHTTPError(status: 400, message: "需要有效的 HTTP/1.1 请求。")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw LocalAPIHTTPError(status: 400, message: "请求头无效。") }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[name] == nil else { throw LocalAPIHTTPError(status: 400, message: "请求头名称无效或重复。") }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.contains("\n"), !value.contains("\r") else { throw LocalAPIHTTPError(status: 400, message: "请求头无效。") }
            headers[name] = value
        }
        guard let host = headers["host"]?.lowercased(), ["127.0.0.1:18743", "localhost:18743"].contains(host) else {
            throw LocalAPIHTTPError(status: 403, message: "只接受本机地址。")
        }
        guard headers["origin"] == nil else { throw LocalAPIHTTPError(status: 403, message: "不接受浏览器跨源请求。") }
        guard secureEqual(headers["authorization"] ?? "", "Bearer \(token)") else {
            throw LocalAPIHTTPError(status: 401, message: "需要有效的 Bearer 访问令牌。")
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else {
            throw LocalAPIHTTPError(status: 400, message: "不支持分块传输或 Expect。")
        }
        var bodyLength = 0
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(value) else {
                throw LocalAPIHTTPError(status: 400, message: "Content-Length 无效。")
            }
            guard length <= maximumBodyBytes else { throw LocalAPIHTTPError(status: 413, message: "正文超过 64 KB。") }
            bodyLength = length
        }
        return LocalAPIRequestHead(method: String(first[0]), target: String(first[1]), headers: headers, bodyLength: bodyLength, headerLength: headerLength)
    }

    private static func secureEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            difference |= Int((index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0))
        }
        return difference == 0
    }
}

struct LocalAPIResponse {
    let status: Int
    let body: Data

    static func json<T: Encodable>(_ value: T) throws -> LocalAPIResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return LocalAPIResponse(status: 200, body: try encoder.encode(value))
    }

    static func error(_ status: Int, _ message: String) -> LocalAPIResponse {
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data("{}".utf8)
        return LocalAPIResponse(status: status, body: body)
    }

    var data: Data {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error"]
        var response = Data("HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        return response
    }
}

@MainActor
private final class LocalAPIConnection {
    private let connection: NWConnection
    private let token: String
    private let handler: (LocalAPIRequest) -> LocalAPIResponse?
    private let onClose: () -> Void
    private var buffer = Data()
    private var head: LocalAPIRequestHead?
    private var timeout: Task<Void, Never>?
    private var closed = false
    private var responded = false

    init(connection: NWConnection, token: String, handler: @escaping (LocalAPIRequest) -> LocalAPIResponse?, onClose: @escaping () -> Void) {
        self.connection = connection
        self.token = token
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.close()
        }
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        timeout = nil
        connection.cancel()
        onClose()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed, !self.responded else { return }
                if let data { self.buffer.append(data) }
                do {
                    if self.head == nil { self.head = try LocalAPIParser.head(in: self.buffer, token: self.token) }
                    if let head = self.head {
                        let expected = head.headerLength + head.bodyLength
                        guard self.buffer.count <= expected else { throw LocalAPIHTTPError(status: 400, message: "不接受多余正文或流水线请求。") }
                        if self.buffer.count == expected {
                            let body = Data(self.buffer[head.headerLength..<expected])
                            guard let response = self.handler(LocalAPIRequest(head: head, body: body)) else { self.close(); return }
                            self.send(response)
                            return
                        }
                    }
                    if complete || error != nil { self.close() } else { self.receive() }
                } catch let error as LocalAPIHTTPError { self.send(.error(error.status, error.message)) }
                catch { self.send(.error(400, "请求无效。")) }
            }
        }
    }

    private func send(_ response: LocalAPIResponse) {
        guard !closed, !responded else { return }
        responded = true
        connection.send(content: response.data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close() }
        })
    }
}
