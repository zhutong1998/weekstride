import Foundation
import XCTest
import WorkLedgerCore
@testable import WorkLedger

@MainActor
final class TaskEditChangesTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testBlankDraftIgnoresDefaultProjectAndPlanningWeek() {
        XCTAssertTrue(WorkTask(projectID: UUID(), title: " \n", details: "\t", plannedAt: date, planGranularity: .week).isEmptyDraft)
    }

    func testUntitledDraftWithAnyUserContentIsNotEmpty() {
        let fields: [(inout WorkTask) -> Void] = [
            { $0.details = "需要保留的明细" }, { $0.notes = "需要保留的备注" },
            { $0.subtasks = [Subtask(title: "步骤")] },
            { $0.attachments = [Attachment(name: "文件.txt", storedName: "file.txt", size: 1)] },
            { $0.dueAt = self.date }, { $0.reminderAt = self.date }, { $0.repeatRule = RepeatRule() }
        ]
        for edit in fields {
            var draft = WorkTask(title: "")
            edit(&draft)
            XCTAssertFalse(draft.isEmptyDraft)
        }
        XCTAssertFalse(WorkTask(title: "有标题").isEmptyDraft)
    }

    func testAutosaveTimestampAloneDoesNotMakeTaskDirty() {
        let original = WorkTask(title: "检查证书", createdAt: date, updatedAt: date)
        var current = original
        current.updatedAt = date.addingTimeInterval(60)

        XCTAssertFalse(current.hasEditableChanges(comparedTo: original))
        XCTAssertEqual(current.updatedAt, date.addingTimeInterval(60))
    }

    func testTextChangesRemainDirtyAfterAutosaveAndClearWhenReverted() {
        let original = WorkTask(title: "检查证书", details: "检查部署状态", notes: "保留原备注", updatedAt: date)
        var current = original
        current.details = "确认部署及续期状态"
        current.updatedAt = date.addingTimeInterval(60)
        XCTAssertTrue(current.hasEditableChanges(comparedTo: original))

        current.details = original.details
        current.notes = "已联系维护人员"
        XCTAssertTrue(current.hasEditableChanges(comparedTo: original))

        current.notes = original.notes
        XCTAssertFalse(current.hasEditableChanges(comparedTo: original))
    }

    func testSubtaskRenameAdditionAndRemovalCountAsChanges() {
        let original = WorkTask(title: "检查证书", subtasks: [Subtask(title: "验证证书链")])
        var current = original
        current.subtasks[0].title = "验证完整证书链"
        XCTAssertTrue(current.hasEditableChanges(comparedTo: original))

        current = original
        current.subtasks.append(Subtask(title: "验证 HTTPS"))
        XCTAssertTrue(current.hasEditableChanges(comparedTo: original))

        current = original
        current.subtasks.removeAll()
        XCTAssertTrue(current.hasEditableChanges(comparedTo: original))
    }

    func testAttachmentAdditionAndRemovalCountAsChanges() {
        let original = WorkTask(title: "检查证书", attachments: [Attachment(name: "部署说明.txt", storedName: "first.txt", size: 24)])
        var current = original
        current.attachments.append(Attachment(name: "验证结果.txt", storedName: "second.txt", size: 16))
        XCTAssertTrue(current.hasEditableChanges(comparedTo: original))

        current = original
        current.attachments.removeAll()
        XCTAssertTrue(current.hasEditableChanges(comparedTo: original))
    }

    func testPlanningReminderAndDueDateChangesAreIndependent() {
        let original = WorkTask(title: "检查证书", dueAt: date, reminderAt: date, plannedAt: date)
        let fields: [(String, WritableKeyPath<WorkTask, Date?>)] = [
            ("计划日期", \.plannedAt), ("提醒日期", \.reminderAt), ("截止日期", \.dueAt)
        ]
        for (name, field) in fields {
            var current = original
            current[keyPath: field] = date.addingTimeInterval(86_400)
            XCTAssertTrue(current.hasEditableChanges(comparedTo: original), name)
            current[keyPath: field] = nil
            XCTAssertTrue(current.hasEditableChanges(comparedTo: original), name)
            current[keyPath: field] = original[keyPath: field]
            current.updatedAt = date.addingTimeInterval(60)
            XCTAssertFalse(current.hasEditableChanges(comparedTo: original), name)
        }
    }

    func testEmptyStepWaitsForExplicitSaveBeforeRemoval() throws {
        for draft in ["", " ", "\t\n", "\u{2003}\n "] {
            XCTAssertNil(try InlineEditableText.valueToSave(draft, required: true, allowEmpty: false,
                                                          removesWhenEmpty: true, commitEmpty: false),
                         "自动保存和失焦保留空步骤输入框，不提交删除")
            XCTAssertEqual(try InlineEditableText.valueToSave(draft, required: true, allowEmpty: false,
                                                            removesWhenEmpty: true, commitEmpty: true), "",
                           "只有明确保存才把空步骤交给移除回调")
        }
    }

    func testStepNamesTrimWhitespaceBeforeSaving() throws {
        for commitEmpty in [false, true] {
            XCTAssertEqual(try InlineEditableText.valueToSave(" \n验证证书链\t ", required: true, allowEmpty: false,
                                                            removesWhenEmpty: true, commitEmpty: commitEmpty), "验证证书链")
        }
    }

    func testExistingTaskTitleStillRejectsEmptyInput() {
        for draft in ["", " \t\n"] {
            for commitEmpty in [false, true] {
                XCTAssertThrowsError(try InlineEditableText.valueToSave(draft, required: true, allowEmpty: false,
                                                                     removesWhenEmpty: false, commitEmpty: commitEmpty)) { error in
                    XCTAssertTrue(error.localizedDescription == L("名称不能为空，请继续输入。"))
                }
            }
        }
    }

    func testNewTaskCanKeepItsEmptyTitleWhileBeingEdited() throws {
        for commitEmpty in [false, true] {
            XCTAssertEqual(try InlineEditableText.valueToSave(" \t\n", required: true, allowEmpty: true,
                                                            removesWhenEmpty: false, commitEmpty: commitEmpty), "")
        }
    }

    func testDetailsAndNotesPreserveTheirWhitespaceAndNewlines() throws {
        for draft in ["", " \t\n", " 第一行明细\n第二行备注  \n"] {
            for commitEmpty in [false, true] {
                XCTAssertEqual(try InlineEditableText.valueToSave(draft, required: false, allowEmpty: false,
                                                                removesWhenEmpty: false, commitEmpty: commitEmpty), draft)
            }
        }
    }
}
