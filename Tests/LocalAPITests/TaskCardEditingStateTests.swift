import Foundation
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class TaskCardEditingStateTests: XCTestCase {
    func testDeletedStepSessionCannotBlockOtherEditsFromFinishing() {
        let deletedID = UUID(), retainedID = UUID()
        let owner = TaskCardEditingState(task: WorkTask(title: "Task"), isDraft: false)
        var deletedSaves = 0
        var retainedValue: String?
        let deleted = field(key: "step:\(deletedID)") { _ in
            deletedSaves += 1
            throw LedgerError.notFound("Step was removed externally")
        }
        let retained = field(key: "step:\(retainedID)") { retainedValue = $0 }
        deleted.draft = "Pending deleted step"
        retained.draft = "Updated retained step"
        owner.fields = ["step:\(deletedID)": deleted, "step:\(retainedID)": retained]

        owner.discardMissingStepFields(existingIDs: [retainedID])

        XCTAssertTrue(deleted.discarded)
        XCTAssertNil(owner.fields["step:\(deletedID)"])
        XCTAssertTrue(retained.active)
        XCTAssertTrue(owner.flushFields(finish: true))
        XCTAssertEqual(retainedValue, "Updated retained step")
        XCTAssertEqual(deletedSaves, 0)
    }

    func testMissingStepReconciliationPreservesCurrentUnsavedChildAndOtherFields() {
        let owner = TaskCardEditingState(task: WorkTask(title: ""), isDraft: true)
        let childKey = "step:\(owner.childInputID)"
        var childValue: String?
        var titleValue: String?
        let child = field(key: childKey) { childValue = $0 }
        let title = field(key: "title") { titleValue = $0 }
        child.draft = "Unsaved new child"
        title.draft = "Unsaved task title"
        owner.fields = [childKey: child, "title": title]

        owner.discardMissingStepFields(existingIDs: [])

        XCTAssertTrue(owner.fields[childKey] === child)
        XCTAssertTrue(owner.fields["title"] === title)
        XCTAssertTrue(child.active)
        XCTAssertTrue(title.active)
        XCTAssertTrue(owner.flushFields())
        XCTAssertEqual(childValue, "Unsaved new child")
        XCTAssertEqual(titleValue, "Unsaved task title")
    }

    private func field(key: String, onSave: @escaping (String) throws -> Void) -> InlineTextEditingState {
        let input = InlineEditableText.Input(text: "Original", placeholder: "Name", help: "Edit name", multiline: false,
                                            required: true, font: .body, showsHoverBackground: true, taskID: UUID(), sessionID: key,
                                            saveOnBlur: true, allowEmpty: false, avoidsInitialSelection: false,
                                            onEmptySave: nil, onNextStep: nil, onEditingChanged: { _ in }, onDraftChange: { _ in },
                                            onSave: onSave, onFailure: { _ in })
        return InlineTextEditingState(input: input)
    }
}
