import AppKit
import XCTest
@testable import WorkLedger

@MainActor
final class TaskEditingBoundaryTests: XCTestCase {
    func testFinishAndInlineValidationCompleteBeforePostingReturns() {
        let card = TaskEditingBoundary.BoundaryView()
        let input = TaskEditingBoundary.BoundaryView()
        let taskID = UUID()
        var sequence: [String] = []
        input.onFlush = { request in
            guard request.taskID == taskID else { return }
            sequence.append("字段校验")
            request.failed = true
        }
        card.onFinish = { request in
            sequence.append("结束任务")
            let flush = InlineFlushRequest(taskID: taskID)
            NotificationCenter.default.post(name: flushTaskEdits, object: flush)
            request.failed = flush.failed
        }
        card.setEnabled(true); input.setEnabled(true)
        defer { card.setEnabled(false); input.setEnabled(false) }
        let exit = TaskEditingExitRequest()
        NotificationCenter.default.post(name: finishTaskEdits, object: exit)
        sequence.append("决定是否新建")
        XCTAssertTrue(exit.failed, "标题无效必须在新建或跳转前被拦截")
        XCTAssertEqual(sequence, ["结束任务", "字段校验", "决定是否新建"])
    }

    func testDisabledOrDismantledEditorsDoNotReceiveSaveRequests() {
        let view = TaskEditingBoundary.BoundaryView()
        var calls = 0
        view.onFinish = { _ in calls += 1 }
        NotificationCenter.default.post(name: finishTaskEdits, object: TaskEditingExitRequest())
        XCTAssertEqual(calls, 0)
        view.setEnabled(true); view.setEnabled(true)
        NotificationCenter.default.post(name: finishTaskEdits, object: TaskEditingExitRequest())
        XCTAssertEqual(calls, 1, "反复更新视图不能重复注册")
        view.setEnabled(false)
        NotificationCenter.default.post(name: finishTaskEdits, object: TaskEditingExitRequest())
        XCTAssertEqual(calls, 1)
    }

    func testDismantleReleasesObjectsCapturedByAllCallbacks() {
        final class CallbackOwner { var calls = 0 }
        let view = TaskEditingBoundary.BoundaryView()
        var owner: CallbackOwner? = CallbackOwner()
        weak var retainedOwner: CallbackOwner?
        retainedOwner = owner
        view.onExit = { [owner] in owner?.calls += 1 }
        view.onSubmit = { [owner] in owner?.calls += 1 }
        view.onNextStep = { [owner] in owner?.calls += 1 }
        view.onFinish = { [owner] _ in owner?.calls += 1 }
        view.onFlush = { [owner] _ in owner?.calls += 1 }
        view.onDiscard = { [owner] _ in owner?.calls += 1 }
        owner = nil
        XCTAssertNotNil(retainedOwner, "Callbacks retain their captured editing context until dismantled")
        TaskEditingBoundary.dismantleNSView(view, coordinator: ())
        XCTAssertNil(retainedOwner, "A retained NSView must not retain a removed card through its callbacks")
        XCTAssertNil(view.onExit)
        XCTAssertNil(view.onSubmit)
        XCTAssertNil(view.onNextStep)
        XCTAssertNil(view.onFinish)
        XCTAssertNil(view.onFlush)
        XCTAssertNil(view.onDiscard)
    }

    func testDismantleStopsAllNotificationsAndAllowsSafeReuse() {
        let view = TaskEditingBoundary.BoundaryView()
        var calls = 0
        view.onFinish = { _ in calls += 1 }
        view.onFlush = { _ in calls += 1 }
        view.onDiscard = { _ in calls += 1 }
        func postEditingRequests() {
            NotificationCenter.default.post(name: finishTaskEdits, object: TaskEditingExitRequest())
            NotificationCenter.default.post(name: flushTaskEdits, object: InlineFlushRequest(taskID: UUID()))
            NotificationCenter.default.post(name: discardTaskEdits, object: UUID())
        }
        view.setEnabled(true)
        postEditingRequests()
        XCTAssertEqual(calls, 3)
        TaskEditingBoundary.dismantleNSView(view, coordinator: ())
        TaskEditingBoundary.dismantleNSView(view, coordinator: ())
        postEditingRequests()
        XCTAssertEqual(calls, 3, "Repeated dismantling must leave no active observers")
        view.onFinish = { _ in calls += 1 }
        view.setEnabled(true)
        postEditingRequests()
        XCTAssertEqual(calls, 4, "Reusing a bridge cannot restore callbacks from the removed editor")
        TaskEditingBoundary.dismantleNSView(view, coordinator: ())
    }

    func testReturnAndKeypadEnterSubmitButOtherKeysDoNot() {
        for keyCode in [UInt16(36), 76] {
            XCTAssertTrue(TaskEditingBoundary.BoundaryView.shouldSubmitReturn(keyCode: keyCode, modifiers: [], hasMarkedText: false))
            XCTAssertTrue(TaskEditingBoundary.BoundaryView.shouldSubmitReturn(keyCode: keyCode, modifiers: .command, hasMarkedText: false), "原有 ⌘Return 仍然可以保存")
        }
        for keyCode in [UInt16(0), 48, 49, 53, 123, 125] {
            XCTAssertFalse(TaskEditingBoundary.BoundaryView.shouldSubmitReturn(keyCode: keyCode, modifiers: [], hasMarkedText: false), "普通输入、Tab、Esc 和方向键不能保存")
        }
    }

    func testShiftReturnAndNativeModifiedReturnRemainWithEditor() {
        let modifiers: [NSEvent.ModifierFlags] = [
            .shift, .option, .control, [.shift, .command], [.option, .command], [.control, .command],
            [.shift, .option, .control, .command]
        ]
        for keyCode in [UInt16(36), 76] {
            for flags in modifiers {
                XCTAssertFalse(TaskEditingBoundary.BoundaryView.shouldSubmitReturn(keyCode: keyCode, modifiers: flags, hasMarkedText: false), "换行和原生编辑快捷键必须继续由编辑器处理")
            }
        }
        let deviceFlags: [NSEvent.ModifierFlags] = [.capsLock, .numericPad, .function, [.command, .capsLock]]
        for flags in deviceFlags {
            XCTAssertTrue(TaskEditingBoundary.BoundaryView.shouldSubmitReturn(keyCode: 36, modifiers: flags, hasMarkedText: false), "大小写及设备标记不应阻止 Return 保存")
        }
    }

    func testIMEConfirmationNeverSubmitsTask() {
        let modifiers: [NSEvent.ModifierFlags] = [[], .shift, .command]
        for keyCode in [UInt16(36), 76] {
            for flags in modifiers {
                XCTAssertFalse(TaskEditingBoundary.BoundaryView.shouldSubmitReturn(keyCode: keyCode, modifiers: flags, hasMarkedText: true), "中文输入法确认候选时的回车不能提交任务")
            }
        }
    }

    func testShiftReturnAndKeypadEnterAdvanceStepWithDeviceFlags() {
        let modifiers: [NSEvent.ModifierFlags] = [
            .shift, [.shift, .capsLock], [.shift, .numericPad], [.shift, .function],
            [.shift, .capsLock, .numericPad, .function]
        ]
        for keyCode in [UInt16(36), 76] {
            for flags in modifiers {
                XCTAssertTrue(TaskEditingBoundary.BoundaryView.shouldAdvanceStep(keyCode: keyCode, modifiers: flags, hasMarkedText: false), "Shift＋回车保存当前步骤并继续，设备标记不应阻止操作")
                XCTAssertFalse(TaskEditingBoundary.BoundaryView.shouldSubmitReturn(keyCode: keyCode, modifiers: flags, hasMarkedText: false), "继续步骤不能同时触发普通回车保存")
            }
        }
    }

    func testStepAdvanceRejectsOtherKeysModifiersAndIMEConfirmation() {
        let blockedModifiers: [NSEvent.ModifierFlags] = [
            [], .command, .option, .control, [.shift, .command], [.shift, .option], [.shift, .control],
            [.shift, .command, .capsLock], [.shift, .option, .numericPad], [.shift, .control, .function],
            [.shift, .option, .control, .command]
        ]
        let composingModifiers: [NSEvent.ModifierFlags] = [.shift, [.shift, .capsLock, .numericPad, .function]]
        for keyCode in [UInt16(36), 76] {
            for flags in blockedModifiers {
                XCTAssertFalse(TaskEditingBoundary.BoundaryView.shouldAdvanceStep(keyCode: keyCode, modifiers: flags, hasMarkedText: false), "只有不带其他操作修饰键的Shift＋回车可以继续步骤")
            }
            for flags in composingModifiers {
                XCTAssertFalse(TaskEditingBoundary.BoundaryView.shouldAdvanceStep(keyCode: keyCode, modifiers: flags, hasMarkedText: true), "输入法确认候选不能保存或新增步骤")
            }
        }
        for keyCode in [UInt16(0), 48, 49, 53, 123, 125] {
            XCTAssertFalse(TaskEditingBoundary.BoundaryView.shouldAdvanceStep(keyCode: keyCode, modifiers: .shift, hasMarkedText: false), "Shift配合其他按键不能继续步骤")
        }
    }

    func testInteractionRectRejectsOutsidePointsWhenVisibleRectExceedsBounds() {
        let bounds = NSRect(x: 0, y: 0, width: 160, height: 80)
        let oversizedVisible = NSRect(x: -1_000, y: -2_000, width: 4_000, height: 5_000)
        let rect = TaskEditingBoundary.BoundaryView.interactionRect(bounds: bounds, visibleRect: oversizedVisible)

        XCTAssertEqual(rect, bounds)
        XCTAssertTrue(rect.contains(NSPoint(x: 40, y: 30)))
        for point in [NSPoint(x: -1, y: 30), NSPoint(x: 161, y: 30), NSPoint(x: 40, y: -1), NSPoint(x: 40, y: 200)] {
            XCTAssertTrue(oversizedVisible.contains(point), "回归条件：SwiftUI返回的visibleRect会覆盖其他任务")
            XCTAssertFalse(rect.contains(point), "任务bounds之外的点击不能算作任务内部")
        }
    }

    func testInteractionRectRespectsClippingAndNonzeroBoundsOrigin() {
        let bounds = NSRect(x: 20, y: 30, width: 160, height: 80)
        let clippedVisible = NSRect(x: 0, y: 50, width: 100, height: 100)
        let rect = TaskEditingBoundary.BoundaryView.interactionRect(bounds: bounds, visibleRect: clippedVisible)

        XCTAssertEqual(rect, NSRect(x: 20, y: 50, width: 80, height: 60))
        XCTAssertTrue(rect.contains(NSPoint(x: 40, y: 60)))
        XCTAssertFalse(rect.contains(NSPoint(x: 40, y: 40)), "自身bounds中已经被裁掉的部分不能交互")
        XCTAssertFalse(rect.contains(NSPoint(x: 10, y: 60)), "visibleRect超出自身bounds的部分也不能交互")
        let hidden = TaskEditingBoundary.BoundaryView.interactionRect(bounds: bounds, visibleRect: NSRect(x: 200, y: 200, width: 40, height: 40))
        XCTAssertTrue(hidden.isEmpty, "完全离开视口的任务不能拥有点击或当前编辑器")
    }

    func testFinishRequestsTargetOneTaskOrAllTasks() {
        let first = UUID(), second = UUID()
        let all = TaskEditingExitRequest()
        XCTAssertTrue(all.targets(first))
        XCTAssertTrue(all.targets(second))
        let onlyFirst = TaskEditingExitRequest(taskID: first)
        XCTAssertTrue(onlyFirst.targets(first))
        XCTAssertFalse(onlyFirst.targets(second), "当前字段回车只结束所属任务")
        let explicitAll = TaskEditingExitRequest(taskID: nil)
        XCTAssertTrue(explicitAll.targets(first))
        XCTAssertTrue(explicitAll.targets(second), "列表导航仍可结束全部任务编辑")
    }

    func testInlineFlushSeparatesResigningFocusFromFinishingEditing() {
        let taskID = UUID()
        let defaults = InlineFlushRequest(taskID: taskID)
        XCTAssertEqual(defaults.taskID, taskID)
        XCTAssertFalse(defaults.finishEditing)
        XCTAssertFalse(defaults.resignFocus)

        let resignOnly = InlineFlushRequest(taskID: taskID, resignFocus: true)
        XCTAssertEqual(resignOnly.taskID, taskID)
        XCTAssertTrue(resignOnly.resignFocus)
        XCTAssertFalse(resignOnly.finishEditing, "任务外点击只失焦，不能关闭仍在编辑的文本框")

        let finishOnly = InlineFlushRequest(taskID: taskID, finishEditing: true)
        XCTAssertEqual(finishOnly.taskID, taskID)
        XCTAssertTrue(finishOnly.finishEditing)
        XCTAssertFalse(finishOnly.resignFocus, "结束编辑不应隐式修改独立的失焦标记")
    }
}
