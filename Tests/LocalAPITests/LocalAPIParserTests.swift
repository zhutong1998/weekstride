import XCTest
@testable import WorkLedger

final class LocalAPIParserTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)

    private func request(_ extra: String = "", authorization: Bool = true, host: String = "127.0.0.1:18743") -> Data {
        Data(("POST /v1/tasks/00000000-0000-0000-0000-000000000001/complete HTTP/1.1\r\nHost: \(host)\r\n"
              + (authorization ? "Authorization: Bearer \(token)\r\n" : "") + extra + "\r\n").utf8)
    }

    private func assertStatus(_ status: Int, _ input: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try LocalAPIParser.head(in: input, token: token), file: file, line: line) { error in
            XCTAssertEqual((error as? LocalAPIHTTPError)?.status, status, file: file, line: line)
        }
    }

    func testAuthenticatedHeadCanBeParsedBeforeBodyArrives() throws {
        let input = request("Content-Type: application/json\r\nContent-Length: 37\r\n")
        let head = try XCTUnwrap(LocalAPIParser.head(in: input, token: token))
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.bodyLength, 37)
        XCTAssertEqual(head.headerLength, input.count)
        XCTAssertNil(try LocalAPIParser.head(in: Data("GET /health HTTP/1.1\r\n".utf8), token: token))
    }

    func testRequiresTokenBeforeReceivingBody() {
        assertStatus(401, request("Content-Length: 65536\r\n", authorization: false))
        assertStatus(401, request("", authorization: false))
        let wrongToken = String(data: request(), encoding: .utf8)!.replacingOccurrences(of: token, with: String(repeating: "b", count: 64))
        assertStatus(401, Data(wrongToken.utf8))
    }

    func testRejectsOriginAndNonlocalHost() throws {
        assertStatus(403, request("Origin: http://malicious.example\r\n"))
        assertStatus(403, request("Origin: \r\n"))
        assertStatus(403, request(host: "malicious.example:18743"))
        assertStatus(403, request(host: "127.0.0.1"))
        XCTAssertNotNil(try LocalAPIParser.head(in: request(host: "localhost:18743"), token: token))
    }

    func testRejectsAmbiguousFraming() {
        assertStatus(400, request("Content-Length: 1\r\ncontent-length: 1\r\n"))
        assertStatus(400, request("Content-Length: 1, 1\r\n"))
        assertStatus(400, request("Content-Length: -1\r\n"))
        assertStatus(400, request("Transfer-Encoding: chunked\r\n"))
        assertStatus(400, request("Content-Length: 1\r\nTransfer-Encoding: identity\r\n"))
        assertStatus(400, request("Expect: 100-continue\r\n"))
        assertStatus(400, request("Host: localhost:18743\r\n"))
        assertStatus(400, request("X-Test: value\r\n continuation\r\n"))
    }

    func testEnforcesHeaderAndBodyLimits() throws {
        assertStatus(413, request("Content-Length: 65537\r\n"))
        assertStatus(413, Data(repeating: 65, count: 16385))
        assertStatus(413, request("X-Large: \(String(repeating: "a", count: 16384))\r\n"))
        XCTAssertEqual(try LocalAPIParser.head(in: request("Content-Length: 65536\r\n"), token: token)?.bodyLength, 65536)
    }
}
