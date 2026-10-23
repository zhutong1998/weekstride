import Foundation
import CoreFoundation

struct LocalAPIJSON {
    let raw: [String: Any]

    init(_ request: LocalAPIRequest, allowed: Set<String>, required: Set<String> = [], allowEmpty: Bool = false) throws {
        if request.body.isEmpty, allowEmpty { raw = [:]; return }
        let type = request.head.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard type == "application/json" else { throw LocalAPIHTTPError(status: 400, message: "A JSON body with Content-Type: application/json is required.") }
        guard String(data: request.body, encoding: .utf8) != nil, !request.body.contains(0) else {
            throw LocalAPIHTTPError(status: 400, message: "JSON must use UTF-8 encoding.")
        }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: request.body) }
        catch { throw LocalAPIHTTPError(status: 400, message: "The body must be a valid JSON object.") }
        guard let object = value as? [String: Any] else { throw LocalAPIHTTPError(status: 400, message: "The body must be a JSON object.") }
        try Self.rejectDuplicateKeys(request.body)
        guard Set(object.keys).isSubset(of: allowed), required.isSubset(of: Set(object.keys)) else {
            throw LocalAPIHTTPError(status: 400, message: "Unknown or missing fields. Allowed: \(allowed.sorted().joined(separator: ", ")). Required: \(required.sorted().joined(separator: ", ")).")
        }
        raw = object
    }

    func contains(_ field: String) -> Bool { raw[field] != nil }

    func string(_ field: String, allowEmpty: Bool = true) throws -> String? {
        guard let value = raw[field] else { return nil }
        guard let text = value as? String, allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAPIHTTPError(status: 400, message: "\(field) must be \(allowEmpty ? "a string" : "a nonempty string").")
        }
        return text
    }

    func uuid(_ field: String) throws -> UUID? {
        guard let value = raw[field], !(value is NSNull) else { return nil }
        guard let text = value as? String, let id = UUID(uuidString: text) else {
            throw LocalAPIHTTPError(status: 400, message: "\(field) must be a UUID or null.")
        }
        return id
    }

    func bool(_ field: String) throws -> Bool? {
        guard let value = raw[field] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw LocalAPIHTTPError(status: 400, message: "\(field) must be a boolean.")
        }
        return number.boolValue
    }

    func int(_ field: String) throws -> Int? {
        guard let value = raw[field] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let integer = Int(number.stringValue) else {
            throw LocalAPIHTTPError(status: 400, message: "\(field) must be an integer.")
        }
        return integer
    }

    func date(_ field: String) throws -> Date? {
        guard let value = raw[field], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw LocalAPIHTTPError(status: 400, message: "\(field) must be an ISO 8601 date-time string or null.") }
        return try Self.date(text, field: field)
    }

    func decode<T: Decodable>(_ field: String, as type: T.Type) throws -> T? {
        guard let value = raw[field], !(value is NSNull) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                return try Self.date(value, field: decoder.codingPath.map(\.stringValue).joined(separator: "."))
            }
            return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
        } catch let error as LocalAPIHTTPError { throw error }
        catch { throw LocalAPIHTTPError(status: 400, message: "Invalid \(field): \(error.localizedDescription)") }
    }

    static func date(_ value: String, field: String, allowFuture: Bool = true) throws -> Date {
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"#
        guard let range = value.range(of: pattern, options: .regularExpression), range == value.startIndex..<value.endIndex else {
            throw LocalAPIHTTPError(status: 400, message: "\(field) requires a complete ISO 8601 date-time with a time zone.")
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        let localTime = String(value.prefix(19)) + "Z"
        guard let localDate = formatter.date(from: localTime), formatter.string(from: localDate) == localTime else {
            throw LocalAPIHTTPError(status: 400, message: "\(field) contains an impossible date or time.")
        }
        if value.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
        guard let date = formatter.date(from: value) else { throw LocalAPIHTTPError(status: 400, message: "Invalid \(field) date-time.") }
        if !allowFuture {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
            guard date < tomorrow else { throw LocalAPIHTTPError(status: 400, message: "\(field) cannot be later than today.") }
        }
        return date
    }

    @MainActor static func flushEdits(taskID: UUID? = nil) throws {
        let failed: Bool
        if let taskID {
            let request = InlineFlushRequest(taskID: taskID)
            NotificationCenter.default.post(name: flushTaskEdits, object: request)
            failed = request.failed
        } else {
            let request = TaskEditingExitRequest()
            NotificationCenter.default.post(name: finishTaskEdits, object: request)
            failed = request.failed
        }
        guard !failed else { throw LocalAPIHTTPError(status: 400, message: "Pending edits could not be saved. Correct them in the app before retrying.") }
    }

    private static func rejectDuplicateKeys(_ data: Data) throws {
        let bytes = Array(data)
        var stack: [(object: Bool, keys: Set<String>, expectsKey: Bool)] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123: stack.append((true, [], true))
            case 91: stack.append((false, [], false))
            case 125, 93: _ = stack.popLast()
            case 44:
                if !stack.isEmpty, stack[stack.count - 1].object { stack[stack.count - 1].expectsKey = true }
            case 34:
                let start = index
                index += 1
                while index < bytes.count, bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                if !stack.isEmpty, stack[stack.count - 1].object, stack[stack.count - 1].expectsKey {
                    let key = try JSONSerialization.jsonObject(with: Data(bytes[start...index]), options: [.fragmentsAllowed]) as! String
                    guard stack[stack.count - 1].keys.insert(key).inserted else {
                        throw LocalAPIHTTPError(status: 400, message: "Duplicate JSON field: \(key).")
                    }
                    stack[stack.count - 1].expectsKey = false
                }
            default: break
            }
            index += 1
        }
    }
}
