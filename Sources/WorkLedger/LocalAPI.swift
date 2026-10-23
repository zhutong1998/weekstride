import Foundation
import Network
import WorkLedgerCore

@MainActor
final class LocalAPIServer {
    var onStatus: ((String) -> Void)?
    private(set) var boundPort: UInt16?
    private var listener: NWListener?
    private var retiringListener: NWListener?
    private var listenerStarted = false
    private var connections: [UUID: LocalAPIConnection] = [:]
    private var generation = UUID()

    func start(token: String, store: WorkStore, port: NWEndpoint.Port = 18743, defaults: UserDefaults = .standard, services: AppServices? = nil) throws {
        stop()
        guard token.utf8.count == 64, token.allSatisfy({ $0.isHexDigit }) else {
            throw LocalAPIHTTPError(status: 400, message: "访问令牌无效。")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
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
                case .ready:
                    self.boundPort = listener.port?.rawValue
                    self.onStatus?("已开启 http://127.0.0.1:\(self.boundPort ?? port.rawValue)")
                case .failed:
                    self.stop()
                    self.onStatus?("本地 API 启动失败，请检查端口 \(port.rawValue) 是否已被使用。")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak store, weak services] connection in
            Task { @MainActor in
                guard let self, let store, self.generation == currentGeneration, self.listener != nil,
                      let boundPort = self.boundPort, self.connections.count < 8 else {
                    connection.cancel()
                    return
                }
                let id = UUID()
                let client = LocalAPIConnection(connection: connection, token: token, port: boundPort) { [weak self, weak store, weak services] request in
                    guard let self, let store, self.generation == currentGeneration, self.listener != nil else { return nil }
                    return self.respond(to: request, store: store, defaults: defaults, services: services)
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
        boundPort = nil
        let clients = Array(connections.values)
        connections.removeAll()
        clients.forEach { $0.close() }
    }

    func respond(to request: LocalAPIRequest, store: WorkStore, defaults: UserDefaults = .standard, services: AppServices? = nil) -> LocalAPIResponse {
        do {
            guard let components = URLComponents(string: request.head.target), components.scheme == nil, components.host == nil else {
                throw LocalAPIHTTPError(status: 400, message: "请求地址无效。")
            }
            let path = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let query = components.queryItems ?? []
            guard Set(query.map(\.name)).count == query.count else {
                throw LocalAPIHTTPError(status: 400, message: "查询参数不能重复。")
            }
            guard ["GET", "POST", "PATCH", "DELETE"].contains(request.head.method) else {
                return .error(405, "Supported methods: GET, POST, PATCH, DELETE.")
            }
            if request.head.method == "GET", !request.body.isEmpty {
                throw LocalAPIHTTPError(status: 400, message: "GET requests cannot contain a body.")
            }
            if request.head.method == "GET", components.path == "/health", query.isEmpty {
                return try .json(["status": "ok"])
            }
            if request.head.method == "GET", ["/v1", "/v1/capabilities"].contains(components.path), query.isEmpty {
                return try .json(LocalAPICapabilities())
            }
            let firstWeekday = defaults.object(forKey: "weekStart") == nil ? 5 : defaults.integer(forKey: "weekStart")
            if let response = try LocalAPISettingsRoutes.respond(to: request, defaults: defaults, services: services, store: store) { return response }
            if let response = try LocalAPIFileRoutes.respond(to: request, store: store) { return response }
            if let response = try LocalAPIWorkRoutes.respond(to: request, store: store, firstWeekday: firstWeekday) { return response }
            if request.head.method == "POST" {
                guard query.isEmpty else { throw LocalAPIHTTPError(status: 400, message: "不支持此查询参数。") }
                if path.count == 5, path[1] == "v1", path[2] == "tasks", path[4] == "complete", let id = UUID(uuidString: path[3]) {
                    guard let task = store.data.tasks.first(where: { $0.id == id }) else { return .error(404, "任务不存在。") }
                    let date = try Self.completionDate(request)
                    if task.completedAt == nil { try LocalAPIJSON.flushEdits(taskID: id) }
                    return try .json(store.completeTask(id: id, at: date, source: "API"))
                }
                if path.count == 7, path[1] == "v1", path[2] == "tasks", path[4] == "subtasks", path[6] == "complete",
                   let taskID = UUID(uuidString: path[3]), let subtaskID = UUID(uuidString: path[5]) {
                    guard let task = store.data.tasks.first(where: { $0.id == taskID }),
                          let subtask = task.subtasks.first(where: { $0.id == subtaskID }) else { return .error(404, "任务或子任务不存在。") }
                    let date = try Self.completionDate(request)
                    if task.completedAt == nil && subtask.completedAt == nil { try LocalAPIJSON.flushEdits(taskID: taskID) }
                    let alreadyCompleted = subtask.completedAt != nil
                    if let result = try store.completeSubtask(taskID: taskID, subtaskID: subtaskID, at: date, source: "API") {
                        return try .json(result)
                    }
                    guard let updated = store.data.tasks.first(where: { $0.id == taskID }) else { return .error(404, "任务不存在。") }
                    return try .json(CompletionResult(task: updated, nextTask: nil, alreadyCompleted: alreadyCompleted))
                }
            }
            return .error(404, "接口不存在。")
        } catch let error as LocalAPIHTTPError {
            return .error(error.status, error.message)
        } catch let error as LedgerError {
            switch error {
            case .notFound(let message): return .error(404, message)
            case .invalid(let message): return .error(400, message)
            case .conflict(let message): return .error(409, message)
            }
        } catch {
            return .error(500, "操作未完成，请在应用中检查任务和存储状态。")
        }
    }

    private static func completionDate(_ request: LocalAPIRequest) throws -> Date {
        let json = try LocalAPIJSON(request, allowed: ["completedAt"], allowEmpty: true)
        guard let value = try json.string("completedAt") else { return Date() }
        return try LocalAPIJSON.date(value, field: "completedAt", allowFuture: false)
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
    static let maximumFileBodyBytes = 32 * 1024 * 1024

    static func head(in data: Data, token: String, port: UInt16 = 18743) throws -> LocalAPIRequestHead? {
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
        guard let host = headers["host"]?.lowercased(), ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host) else {
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
            let path = URLComponents(string: String(first[1]))?.path ?? ""
            let isFileUpload = String(first[0]) == "POST" && (path == "/v1/backups/import" || path.range(of: #"^/v1/tasks/[0-9A-Fa-f-]{36}/attachments$"#, options: .regularExpression) != nil)
            let limit = isFileUpload ? maximumFileBodyBytes : maximumBodyBytes
            guard length <= limit else { throw LocalAPIHTTPError(status: 413, message: "Request body exceeds the endpoint limit of \(limit) bytes.") }
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
    var contentType: String = "application/json; charset=utf-8"
    var headers: [String: String] = [:]
    var afterSend: (() -> Void)? = nil

    static func json<T: Encodable>(_ value: T, status: Int = 200, afterSend: (() -> Void)? = nil, dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .iso8601) throws -> LocalAPIResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateEncodingStrategy
        encoder.outputFormatting = [.sortedKeys]
        return LocalAPIResponse(status: status, body: try encoder.encode(value), afterSend: afterSend)
    }

    static func error(_ status: Int, _ message: String) -> LocalAPIResponse {
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data("{}".utf8)
        return LocalAPIResponse(status: status, body: body)
    }

    var data: Data {
        let reasons = [200: "OK", 201: "Created", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error"]
        let extraHeaders = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
        var response = Data("HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\(extraHeaders)Connection: close\r\n\r\n".utf8)
        response.append(body)
        return response
    }
}

@MainActor
private final class LocalAPIConnection {
    private let connection: NWConnection
    private let token: String
    private let port: UInt16
    private let handler: (LocalAPIRequest) -> LocalAPIResponse?
    private let onClose: () -> Void
    private var buffer = Data()
    private var head: LocalAPIRequestHead?
    private var timeout: Task<Void, Never>?
    private var closed = false
    private var responded = false

    init(connection: NWConnection, token: String, port: UInt16, handler: @escaping (LocalAPIRequest) -> LocalAPIResponse?, onClose: @escaping () -> Void) {
        self.connection = connection
        self.token = token
        self.port = port
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
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
                    if self.head == nil { self.head = try LocalAPIParser.head(in: self.buffer, token: self.token, port: self.port) }
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
        connection.send(content: response.data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.close()
                if error == nil { response.afterSend?() }
            }
        })
    }
}
