import CoreGraphics
import XCTest
@testable import WorkLedger

final class TaskFlowLayoutTests: XCTestCase {
    func testItemsKeepNaturalWidthsOnOneRow() {
        let result = TaskFlowLayout.arrange([
            CGSize(width: 100, height: 20), CGSize(width: 80, height: 30), CGSize(width: 60, height: 15)
        ], width: 300)
        XCTAssertEqual(result.frames, [
            CGRect(x: 0, y: 0, width: 100, height: 20),
            CGRect(x: 110, y: 0, width: 80, height: 30),
            CGRect(x: 200, y: 0, width: 60, height: 15)
        ])
        XCTAssertEqual(result.size, CGSize(width: 260, height: 30))
    }

    func testOverflowWrapsAfterTheTallestItemInTheRow() {
        let result = TaskFlowLayout.arrange([
            CGSize(width: 80, height: 20), CGSize(width: 60, height: 30), CGSize(width: 70, height: 12)
        ], width: 150)
        XCTAssertEqual(result.frames[1], CGRect(x: 90, y: 0, width: 60, height: 30))
        XCTAssertEqual(result.frames[2], CGRect(x: 0, y: 34, width: 70, height: 12))
        XCTAssertEqual(result.size, CGSize(width: 150, height: 46))
    }

    func testOversizedItemIsConstrainedWithoutAnEmptyFirstRow() {
        let result = TaskFlowLayout.arrange([
            CGSize(width: 240, height: 20), CGSize(width: 40, height: 10)
        ], width: 100, spacing: 12, rowSpacing: 6)
        XCTAssertEqual(result.frames, [
            CGRect(x: 0, y: 0, width: 100, height: 20),
            CGRect(x: 0, y: 26, width: 40, height: 10)
        ])
        XCTAssertEqual(result.size, CGSize(width: 100, height: 36))
    }

    func testEmptyAndUnspecifiedWidth() {
        let empty = TaskFlowLayout.arrange([], width: 100)
        XCTAssertTrue(empty.frames.isEmpty)
        XCTAssertEqual(empty.size, .zero)
        let natural = TaskFlowLayout.arrange([CGSize(width: 80, height: 20), CGSize(width: 100, height: 15)], width: nil)
        XCTAssertEqual(natural.frames[1], CGRect(x: 90, y: 0, width: 100, height: 15))
        XCTAssertEqual(natural.size, CGSize(width: 190, height: 20))
    }

    func testMinimumAndUnboundedWidthProposalsStayFinite() {
        let sizes = [CGSize(width: 80, height: 20), CGSize(width: 100, height: 15)]
        let minimum = TaskFlowLayout.arrange(sizes, width: 0)
        XCTAssertEqual(minimum.frames, [
            CGRect(x: 0, y: 0, width: 0, height: 20),
            CGRect(x: 0, y: 24, width: 0, height: 15)
        ])
        XCTAssertEqual(minimum.size, CGSize(width: 0, height: 39))
        let unbounded = TaskFlowLayout.arrange(sizes, width: .infinity)
        XCTAssertEqual(unbounded.size, CGSize(width: 190, height: 20))
    }
}
