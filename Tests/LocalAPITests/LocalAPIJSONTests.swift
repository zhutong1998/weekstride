import XCTest
@testable import WorkLedger

final class LocalAPIJSONTests: XCTestCase {
    private func request(_ body: String) -> LocalAPIRequest {
        let data = Data(body.utf8)
        return LocalAPIRequest(head: .init(method: "PATCH", target: "/v1/tasks", headers: ["content-type": "application/json"], bodyLength: data.count, headerLength: 0), body: data)
    }

    func testDuplicateKeysAreRejectedIncludingEscapedAndNestedKeys() throws {
        for body in [#"{"title":"one","title":"two"}"#,
                     #"{"title":"one","\u0074itle":"two"}"#,
                     #"{"repeatRule":{"every":1,"every":2}}"#,
                     #"{"items":[{"id":1,"id":2}]}"#] {
            XCTAssertThrowsError(try LocalAPIJSON(request(body), allowed: ["title", "repeatRule", "items"]))
        }
        XCTAssertNoThrow(try LocalAPIJSON(request(#"{"items":[{"id":1},{"id":2}],"title":"escaped \"title\""}"#), allowed: ["items", "title"]))
    }

    func testTypesNullsAndProtectedFieldsDoNotSilentlyConvert() throws {
        let json = try LocalAPIJSON(request(#"{"string":42,"bool":1,"int":true,"date":null,"uuid":null}"#), allowed: ["string", "bool", "int", "date", "uuid"])
        XCTAssertThrowsError(try json.string("string"))
        XCTAssertThrowsError(try json.bool("bool"))
        XCTAssertThrowsError(try json.int("int"))
        XCTAssertNil(try json.date("date"))
        XCTAssertNil(try json.uuid("uuid"))
        XCTAssertThrowsError(try LocalAPIJSON(request(#"{"id":"cannot-change-id"}"#), allowed: ["title"]))
        XCTAssertThrowsError(try LocalAPIJSON(request("{}"), allowed: ["title"], required: ["title"]))
        XCTAssertThrowsError(try LocalAPIJSON(request("[]"), allowed: []))
        let valid = try LocalAPIJSON(request(#"{"bool":true,"int":7,"string":""}"#), allowed: ["bool", "int", "string"])
        XCTAssertEqual(try valid.bool("bool"), true)
        XCTAssertEqual(try valid.int("int"), 7)
        XCTAssertEqual(try valid.string("string"), "")
    }

    func testDateParsingRejectsNormalizationAndPreservesFractionalSeconds() throws {
        for date in ["2026-02-31T09:00:00Z", "2026-10-23T24:00:00Z", "2026-10-23T09:00:00", "2026-10-23T09:00:00Z\n"] {
            XCTAssertThrowsError(try LocalAPIJSON.date(date, field: "date"))
        }
        let a = try LocalAPIJSON.date("2020-10-20T08:30:00.125+08:00", field: "date", allowFuture: false)
        let b = try LocalAPIJSON.date("2020-10-20T00:30:00Z", field: "date")
        XCTAssertEqual(a.timeIntervalSince(b), 0.125, accuracy: 0.000001)
        XCTAssertThrowsError(try LocalAPIJSON.date("2999-01-01T00:00:00Z", field: "date", allowFuture: false))
    }
}
