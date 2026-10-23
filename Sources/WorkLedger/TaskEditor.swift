import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CoreTransferable
import WorkLedgerCore

extension UTType {
    static let workLedgerTask = UTType(exportedAs: "local.workledger.task", conformingTo: .data)
}

struct TaskDragItem: Codable, Transferable {
    let taskID: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .workLedgerTask)
    }
}

private struct TaskHoverEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct TaskPlanningDayKey: EnvironmentKey {
    static var defaultValue: Date { Calendar.current.startOfDay(for: Date()) }
}

extension EnvironmentValues {
    var taskHoverEnabled: Bool {
        get { self[TaskHoverEnabledKey.self] }
        set { self[TaskHoverEnabledKey.self] = newValue }
    }

    var taskPlanningDay: Date {
        get { self[TaskPlanningDayKey.self] }
        set { self[TaskPlanningDayKey.self] = newValue }
    }
}

let flushTaskEdits = Notification.Name("WorkLedger.flushTaskEdits")
let discardTaskEdits = Notification.Name("WorkLedger.discardTaskEdits")
let finishTaskEdits = Notification.Name("WorkLedger.finishTaskEdits")

final class InlineFlushRequest {
    let taskID: UUID
    var failed = false
    let finishEditing: Bool
    let resignFocus: Bool
    init(taskID: UUID, finishEditing: Bool = false, resignFocus: Bool = false) {
        self.taskID = taskID; self.finishEditing = finishEditing; self.resignFocus = resignFocus
    }
}

private struct InlineEditingPreference: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct InlineEditorOpenPreference: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct InlineTextChangedPreference: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension WorkTask {
    var isEmptyDraft: Bool {
        // Project and planning week are filled automatically, so they do not keep an empty draft alive.
        [title, details, notes].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && subtasks.isEmpty && attachments.isEmpty && dueAt == nil && reminderAt == nil && repeatRule == nil
    }

    func hasEditableChanges(comparedTo original: WorkTask) -> Bool {
        var current = self
        current.updatedAt = original.updatedAt
        return current != original
    }
}

struct TaskEditingBoundary: NSViewRepresentable {
    var enabled: Bool
    var onExit: (() -> Void)? = nil
    var onSubmit: (() -> Void)? = nil
    var onNextStep: (() -> Void)? = nil
    var avoidInitialSelection = false
    var onFinish: ((TaskEditingExitRequest) -> Void)? = nil
    var onFlush: ((InlineFlushRequest) -> Void)? = nil
    var onDiscard: ((UUID) -> Void)? = nil

    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }
    func updateNSView(_ view: BoundaryView, context: Context) {
        view.onExit = onExit
        view.onSubmit = onSubmit
        view.onNextStep = onNextStep
        view.onFinish = onFinish; view.onFlush = onFlush; view.onDiscard = onDiscard
        view.setEnabled(enabled)
        view.setAvoidInitialSelection(avoidInitialSelection)
    }
    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) { view.reset() }

    final class BoundaryView: NSView {
        var onExit: (() -> Void)?
        var onSubmit: (() -> Void)?
        var onNextStep: (() -> Void)?
        var onFinish: ((TaskEditingExitRequest) -> Void)?
        var onFlush: ((InlineFlushRequest) -> Void)?
        var onDiscard: ((UUID) -> Void)?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var selectionFocused = false
        private var selectionGeneration = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        // SwiftUI list backgrounds can report a visibleRect larger than their own bounds.
        var interactionRect: NSRect { Self.interactionRect(bounds: bounds, visibleRect: visibleRect) }
        static func interactionRect(bounds: NSRect, visibleRect: NSRect) -> NSRect { bounds.intersection(visibleRect) }

        func reset() {
            setEnabled(false)
            onExit = nil; onFinish = nil; onFlush = nil; onDiscard = nil
            onSubmit = nil; onNextStep = nil
            setAvoidInitialSelection(false)
        }

        static func shouldSubmitReturn(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> Bool {
            (keyCode == 36 || keyCode == 76) && modifiers.intersection([.shift, .option, .control]).isEmpty && !hasMarkedText
        }

        static func shouldAdvanceStep(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> Bool {
            (keyCode == 36 || keyCode == 76) && modifiers.contains(.shift)
                && modifiers.intersection([.option, .control, .command]).isEmpty && !hasMarkedText
        }

        func setAvoidInitialSelection(_ focused: Bool) {
            guard selectionFocused != focused else { return }
            selectionFocused = focused; selectionGeneration += 1
            guard focused else { return }
            let generation = selectionGeneration
            let event = NSApp.currentEvent
            // A click in an already open field owns its insertion point.
            guard event?.type != .leftMouseDown else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionFocused, self.selectionGeneration == generation,
                      NSApp.currentEvent === event,
                      let editor = self.window?.firstResponder as? NSTextView,
                      editor.isFieldEditor, !editor.hasMarkedText(),
                      let field = editor.delegate as? NSTextField, field.currentEditor() === editor,
                      self.interactionRect.intersects(self.convert(field.bounds, from: field)) else { return }
                let length = (editor.string as NSString).length
                if length > 0, editor.selectedRange() == NSRange(location: 0, length: length) {
                    editor.setSelectedRange(NSRange(location: length, length: 0))
                }
            }
        }

        func setEnabled(_ enabled: Bool) {
            if enabled, observers.isEmpty {
                // Save callers need a result before continuing; SwiftUI onReceive defers its action.
                let center = NotificationCenter.default
                observers = [
                    center.addObserver(forName: finishTaskEdits, object: nil, queue: nil) { [weak self] note in
                        if let request = note.object as? TaskEditingExitRequest { self?.onFinish?(request) }
                    },
                    center.addObserver(forName: flushTaskEdits, object: nil, queue: nil) { [weak self] note in
                        if let request = note.object as? InlineFlushRequest { self?.onFlush?(request) }
                    },
                    center.addObserver(forName: discardTaskEdits, object: nil, queue: nil) { [weak self] note in
                        if let id = note.object as? UUID { self?.onDiscard?(id) }
                    }
                ]
            } else if !enabled {
                observers.forEach(NotificationCenter.default.removeObserver)
                observers.removeAll()
            }
            if enabled, onExit != nil || onSubmit != nil || onNextStep != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else { return event }
                    if event.type == .keyDown {
                        guard let editor = window.firstResponder as? NSTextView,
                              self.interactionRect.intersects(self.convert(editor.bounds.intersection(editor.visibleRect), from: editor)) else { return event }
                        if let next = self.onNextStep, Self.shouldAdvanceStep(keyCode: event.keyCode, modifiers: event.modifierFlags, hasMarkedText: editor.hasMarkedText()) {
                            if !event.isARepeat { next() }
                            return nil
                        }
                        if let submit = self.onSubmit, Self.shouldSubmitReturn(keyCode: event.keyCode, modifiers: event.modifierFlags, hasMarkedText: editor.hasMarkedText()) {
                            if !event.isARepeat { submit() }
                            return nil
                        }
                        return event
                    }
                    if !self.interactionRect.contains(self.convert(event.locationInWindow, from: nil)), let exit = self.onExit {
                        if let responder = window.firstResponder as? NSView,
                           self.interactionRect.intersects(self.convert(responder.bounds.intersection(responder.visibleRect), from: responder)) {
                            window.makeFirstResponder(nil)
                        }
                        exit()
                    }
                    return event
                }
            } else if (!enabled || (onExit == nil && onSubmit == nil && onNextStep == nil)), let monitor {
                NSEvent.removeMonitor(monitor); self.monitor = nil
            }
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

struct TaskPlanPicker: View {
    @Binding var date: Date?
    @Binding var granularity: TaskPlanGranularity?
    @Binding var expanded: Bool
    let currentTitle: String
    let detail: String
    let isOverdue: Bool
    var onSelect: ((Date?, TaskPlanGranularity?) -> Void)?
    @Environment(\.taskPlanningDay) private var referenceDate
    @Environment(\.locale) private var locale
    @Environment(\.compactTaskPlan) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("weekStart") private var weekStart = 5
    @State private var calendarDate = Date()
    @State private var calendarPresented = false
    @FocusState private var focusedChoice: String?
    @AccessibilityFocusState private var voiceOverChoice: String?

    init(date: Binding<Date?>, granularity: Binding<TaskPlanGranularity?>, expanded: Binding<Bool>, currentTitle: String, detail: String, isOverdue: Bool, onSelect: ((Date?, TaskPlanGranularity?) -> Void)? = nil) {
        _date = date; _granularity = granularity; _expanded = expanded
        self.currentTitle = currentTitle; self.detail = detail; self.isOverdue = isOverdue; self.onSelect = onSelect
    }

    private var showChoices: Bool { expanded || calendarPresented }

    var body: some View {
        let _ = locale.identifier
        HStack(spacing: 7) {
            choice(currentTitle, selected: true) { expanded.toggle() }
                .help(L("\(detail)；点击展开其他安排"))
                .popover(isPresented: Binding(get: { compact && showChoices }, set: { if !$0 { expanded = false; calendarPresented = false } }), arrowEdge: .bottom) {
                    if calendarPresented { calendar }
                    else {
                        VStack(alignment: .leading, spacing: 9) { choices }
                            .padding(14)
                    }
                }
            if showChoices && !compact {
                HStack(spacing: 7) {
                    choices
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showChoices)
        .preference(key: InlineEditingPreference.self, value: (showChoices && (focusedChoice != nil || voiceOverChoice != nil)) || calendarPresented)
        .onChange(of: showChoices) { _, showing in
            if !showing { focusedChoice = nil }
        }
        .onChange(of: calendarPresented) { _, presented in if !presented { expanded = false } }
    }

    @ViewBuilder private var choices: some View {
        ForEach(0..<2) { offset in
            let title = [L("本周"), L("下周")][offset]
            if title != currentTitle || isOverdue {
                let target = TaskPlanning.weekDate(offset: offset, relativeTo: referenceDate, firstWeekday: weekStart)
                let range = WorkPeriod.range(containing: target, firstWeekday: weekStart)
                choice(title == currentTitle ? L("重新安排\(title)") : title, selected: false) { select(target, precision: .week) }
                    .help(L("\(dayText(range.start)) — \(dayText(range.end.addingTimeInterval(-1)))；按整周安排"))
            }
        }
        choice(L("选择具体时间"), selected: date != nil && granularity != .week, action: openCalendar)
            .help(L("打开日历，选择后点击确定；取消保留原安排"))
            .popover(isPresented: Binding(get: { calendarPresented && !compact }, set: { calendarPresented = $0 }), arrowEdge: .bottom) { calendar }
        if currentTitle != L("未安排") {
            choice(L("未安排"), selected: false) { select(nil, precision: nil) }
                .help(L("清除计划安排，不改变到期日期、提醒和完成记录"))
        }
    }

    private var calendar: some View {
        TaskDatePicker(initialDate: calendarDate, title: L("计划日期"), onConfirm: applyCalendarDate) {
            calendarPresented = false; expanded = false
        }
    }

    private func openCalendar() {
        calendarDate = date ?? referenceDate
        expanded = true
        calendarPresented = true
    }

    private func applyCalendarDate(_ value: Date) {
        calendarDate = value
        select(value, precision: .day)
        calendarPresented = false
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).appFont(.caption.weight(selected ? .semibold : .regular)).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035)))
                .overlay(Capsule().stroke(selected ? Color.accentColor.opacity(0.3) : .clear, lineWidth: 1))
        }
        .buttonStyle(HoverHighlightButtonStyle(cornerRadius: 100))
        .focused($focusedChoice, equals: title).accessibilityFocused($voiceOverChoice, equals: title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ newDate: Date?, precision: TaskPlanGranularity?) {
        let nextPrecision = newDate == nil ? nil : precision
        if let onSelect { onSelect(newDate, nextPrecision) }
        else { date = newDate; granularity = nextPrecision }
        expanded = false
    }
}

struct InlineEditableText: View {
    @Environment(\.taskHoverEnabled) private var taskHoverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appTextScale) private var textScale
    let text: String
    let placeholder: String
    let help: String
    var multiline = false
    var required = false
    var font: AppFontStyle = .body
    var showsHoverBackground = true
    var taskID: UUID?
    var saveOnBlur = false
    var allowEmpty = false
    var avoidsInitialSelection = false
    var onEmptySave: (() throws -> Void)?
    var onNextStep: (() -> Void)?
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onDraftChange: (String) -> Void = { _ in }
    let onSave: (String) throws -> Void
    var onFailure: (String) -> Void = { _ in }
    @State private var draft: String
    @State private var lastSaved: String
    @State private var originalText: String
    @State private var editing = false
    @State private var autofocusRequested = false
    @State private var hovering = false
    @State private var error: String?
    @State private var pendingSave: Task<Void, Never>?
    @State private var discarded = false
    @State private var hintVisible = false
    @FocusState private var focused: Bool

    init(text: String, placeholder: String, help: String, multiline: Bool = false, required: Bool = false, font: AppFontStyle = .body, showsHoverBackground: Bool = true, taskID: UUID? = nil, saveOnBlur: Bool = false, initiallyEditing: Bool = false, autofocus: Bool = false, allowEmpty: Bool = false, avoidsInitialSelection: Bool = false, onEmptySave: (() throws -> Void)? = nil, onNextStep: (() -> Void)? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in }, onDraftChange: @escaping (String) -> Void = { _ in }, onSave: @escaping (String) throws -> Void, onFailure: @escaping (String) -> Void = { _ in }) {
        self.text = text; self.placeholder = placeholder; self.help = help
        self.multiline = multiline; self.required = required; self.font = font; self.taskID = taskID
        self.showsHoverBackground = showsHoverBackground
        self.saveOnBlur = saveOnBlur; self.allowEmpty = allowEmpty; self.onEditingChanged = onEditingChanged
        self.avoidsInitialSelection = avoidsInitialSelection; self.onNextStep = onNextStep
        self.onEmptySave = onEmptySave
        self.onDraftChange = onDraftChange; self.onSave = onSave; self.onFailure = onFailure
        _draft = State(initialValue: text); _lastSaved = State(initialValue: text); _originalText = State(initialValue: text)
        _editing = State(initialValue: initiallyEditing)
        _autofocusRequested = State(initialValue: initiallyEditing && autofocus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if editing {
                    editor
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(error == nil ? (focused ? Color.accentColor.opacity(0.5) : .clear) : .red.opacity(0.6)))
                } else {
                    Button {
                        withAnimation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.18)) {
                            draft = text; lastSaved = text; originalText = text; autofocusRequested = true; editing = true
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text(text.isEmpty ? placeholder : text)
                                .foregroundStyle(text.isEmpty ? Color.secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "pencil").appFont(.caption).foregroundStyle(.secondary)
                                .opacity(taskHoverEnabled && hovering ? 1 : 0).padding(.top, 3)
                                .animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.12), value: hovering)
                        }.padding(.horizontal, 7).padding(.vertical, 5)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                            .background {
                                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(taskHoverEnabled && hovering && showsHoverBackground ? 0.045 : 0))
                                    .animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.12), value: hovering)
                            }
                    }.buttonStyle(.plain).help(help).accessibilityLabel(help)
                }
            }.appFont(font)
            if editing && hintVisible {
                Text(inputHint).appFont(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(height: 12 * textScale)
                    .padding(.horizontal, 7).allowsHitTesting(false)
                    .transition(reduceMotion ? .identity : .taskSection)
            }
            if let error { Text(error).appFont(.caption).foregroundStyle(.red).padding(.horizontal, 7) }
        }
        .alignmentGuide(VerticalAlignment.center) { dimensions in
            (dimensions.height - (editing && hintVisible ? 12 * textScale + 4 : 0)) / 2
        }
        .onHover { hovering = taskHoverEnabled && $0 }
        .onChange(of: taskHoverEnabled) { _, enabled in if !enabled { hovering = false } }
        .onAppear { onEditingChanged(editing) }
        .task(id: editing) {
            guard editing, autofocusRequested else { return }
            await Task.yield()
            guard !Task.isCancelled, editing, autofocusRequested, !discarded else { return }
            focused = true; autofocusRequested = false
        }
        .onChange(of: editing) { _, value in onEditingChanged(value) }
        .preference(key: InlineEditingPreference.self, value: focused)
        .preference(key: InlineEditorOpenPreference.self, value: editing)
        .preference(key: InlineTextChangedPreference.self, value: editing && textHasChanged)
        .onChange(of: draft) { _, _ in
            guard editing, !discarded else { return }
            onDraftChange(draft)
            pendingSave?.cancel()
            guard !saveOnBlur else { return }
            pendingSave = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                guard !Task.isCancelled else { return }
                _ = flush()
            }
        }
        .onChange(of: focused) { _, value in
            withAnimation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.18)) { hintVisible = value }
            if !value && editing { _ = flush() }
        }
        .onChange(of: text) { _, value in
            if !editing { draft = value; lastSaved = value; originalText = value }
        }
        .background {
            if editing {
                TaskEditingBoundary(enabled: true, onSubmit: focused ? finishEditing : nil,
                                    onNextStep: focused && onNextStep != nil ? advanceStep : nil,
                                    avoidInitialSelection: avoidsInitialSelection && focused, onFlush: { request in
                    guard request.taskID == taskID else { return }
                    if request.resignFocus { autofocusRequested = false; focused = false }
                    if !flush(commitEmpty: request.finishEditing) { request.failed = true }
                    else if request.finishEditing { editing = false; focused = false; draft = lastSaved }
                }, onDiscard: { id in
                    guard id == taskID else { return }
                    discarded = true; pendingSave?.cancel()
                })
            }
        }
        .onDisappear {
            pendingSave?.cancel()
            guard !discarded else { return }
            if !flush(), let error { onFailure(error) }
        }
    }

    private var textHasChanged: Bool {
        if required {
            return draft.trimmingCharacters(in: .whitespacesAndNewlines) != originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return draft != originalText
    }

    private var inputHint: String {
        if onNextStep != nil { return L("↩ 保存任务 · ⇧↩ 下一个步骤") }
        return multiline ? L("↩ 保存任务 · ⇧↩ 换行") : L("↩ 保存任务")
    }

    private func advanceStep() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, flush() else { return }
        onNextStep?()
    }

    @ViewBuilder private var editor: some View {
        if multiline {
            TextEditor(text: $draft)
                .scrollContentBackground(.hidden).focused($focused)
                .frame(height: max(64 * textScale, min(160 * textScale, (CGFloat(draft.components(separatedBy: "\n").count) * 18 + 12) * textScale)))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 1).allowsHitTesting(false)
                    }
                }
                .help(help + L("；回车保存任务，Shift＋回车换行"))
                .accessibilityLabel(help)
                .onExitCommand { finishEditing() }
        } else {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain).focused($focused)
                .help(help + L("；回车保存任务") + (onNextStep == nil ? "" : L("，Shift＋回车下一个步骤"))).accessibilityLabel(help)
                .onExitCommand { finishEditing() }
        }
    }

    static func valueToSave(_ draft: String, required: Bool, allowEmpty: Bool, removesWhenEmpty: Bool, commitEmpty: Bool) throws -> String? {
        let value = required ? draft.trimmingCharacters(in: .whitespacesAndNewlines) : draft
        if required && value.isEmpty {
            if removesWhenEmpty { return commitEmpty ? value : nil }
            if !allowEmpty { throw LedgerError.invalid(L("名称不能为空，请继续输入。")) }
        }
        return value
    }

    @discardableResult private func flush(commitEmpty: Bool = false) -> Bool {
        pendingSave?.cancel()
        guard !discarded else { return true }
        do {
            guard let value = try Self.valueToSave(draft, required: required, allowEmpty: allowEmpty, removesWhenEmpty: onEmptySave != nil, commitEmpty: commitEmpty) else { return true }
            if required && value.isEmpty {
                if let onEmptySave { try onEmptySave() }
                else { onDraftChange(draft) }
                lastSaved = value; error = nil; return true
            }
            guard value != lastSaved else { error = nil; return true }
            try onSave(value); lastSaved = value; error = nil; return true
        }
        catch { self.error = localizedError(error); return false }
    }

    private func finishEditing() {
        guard flush(commitEmpty: true) else { return }
        if let taskID {
            let request = TaskEditingExitRequest(taskID: taskID)
            NotificationCenter.default.post(name: finishTaskEdits, object: request)
            guard !request.failed else { return }
        }
        withAnimation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.18)) {
            focused = false; editing = false
        }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

private struct InlineMetadataButton<Content: View>: View {
    @Environment(\.taskHoverEnabled) private var taskHoverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let action: () -> Void
    let content: Content
    @State private var hovering = false
    @FocusState private var focused: Bool
    @AccessibilityFocusState private var voiceOverFocused: Bool

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Content) {
        self.action = action; content = label()
    }

    var body: some View {
        Button(action: action) {
            content.padding(.horizontal, 5).padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(taskHoverEnabled && (hovering || focused || voiceOverFocused) ? 0.055 : 0))
                        .animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.12), value: hovering || focused || voiceOverFocused)
                }
        }.buttonStyle(.plain).focused($focused).accessibilityFocused($voiceOverFocused)
            .onHover { hovering = taskHoverEnabled && $0 }
            .onChange(of: taskHoverEnabled) { _, enabled in if !enabled { hovering = false } }
            .preference(key: InlineEditingPreference.self, value: focused || voiceOverFocused)
    }
}

private struct TaskMetadataRow: View {
    @Environment(\.taskHoverEnabled) private var taskHoverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let symbol: String
    let tint: Color
    let editHelp: String
    let removeHelp: String
    let removeLabel: String
    let onEdit: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false
    @FocusState private var removeFocused: Bool
    @AccessibilityFocusState private var removeVoiceOverFocused: Bool

    private var showRemove: Bool { taskHoverEnabled && (hovering || removeFocused || removeVoiceOverFocused) }

    var body: some View {
        HStack(spacing: 4) {
            InlineMetadataButton(action: onEdit) { Label(title, systemImage: symbol) }
                .help(editHelp)
            Button(role: .destructive, action: onRemove) { Image(systemName: "xmark.circle").frame(width: 20, height: 20) }
                .buttonStyle(HoverHighlightButtonStyle(cornerRadius: 10)).help(removeHelp).accessibilityLabel(removeLabel)
                .focused($removeFocused).accessibilityFocused($removeVoiceOverFocused)
                .opacity(showRemove ? 1 : 0).allowsHitTesting(showRemove)
                .animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.12), value: showRemove)
                .accessibilityHidden(false)
                .preference(key: InlineEditingPreference.self, value: removeFocused || removeVoiceOverFocused)
        }
        .appFont(.caption).foregroundStyle(tint)
        .contentShape(Rectangle())
        .onHover { hovering = taskHoverEnabled && $0 }
        .onChange(of: taskHoverEnabled) { _, enabled in if !enabled { hovering = false } }
    }
}

private struct TaskSubtaskRow: View {
    @Environment(\.taskHoverEnabled) private var taskHoverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let taskID: UUID
    let child: Subtask
    let parentCompleted: Bool
    let isDraft: Bool
    let onComplete: () -> Void
    let onDraftChange: (String) -> Void
    let onSave: (String) throws -> Void
    let onEmptySave: () throws -> Void
    let onNextStep: () -> Void
    let onFailure: (String) -> Void
    let onRemove: () -> Void
    let completionDate: () -> Date?
    let onSetCompletionDate: (Date) -> Void
    @State private var hovering = false
    @State private var editingCompletionDate = false
    @FocusState private var removeFocused: Bool
    @AccessibilityFocusState private var removeVoiceOverFocused: Bool

    private var active: Bool { taskHoverEnabled && (hovering || removeFocused || removeVoiceOverFocused) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 0) {
                HoverGlassButton(size: 24, action: onComplete) {
                    Image(systemName: child.completedAt == nil ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(child.completedAt == nil ? Color.secondary : .teal)
                        .symbolEffect(.bounce, options: .speed(2), value: child.completedAt != nil)
                        .symbolEffectsRemoved(reduceMotion)
                }
                .frame(width: 36)
                .disabled(parentCompleted)
                .help(parentCompleted ? L("请先撤销主任务完成，再调整步骤状态") : (child.completedAt == nil ? L("完成步骤，默认记录今天") : L("点击恢复为未完成；右键可修改完成日期")))
                .accessibilityLabel(L("\(child.completedAt == nil ? L("完成步骤") : L("取消步骤完成")) \(child.title)"))
                InlineEditableText(text: child.title, placeholder: L("步骤名称"), help: L("点击修改步骤名称；清空后回车移除步骤"), required: true, showsHoverBackground: false, taskID: taskID, saveOnBlur: isDraft, onEmptySave: onEmptySave, onNextStep: onNextStep, onDraftChange: onDraftChange, onSave: onSave, onFailure: onFailure)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(HoverHighlightButtonStyle(cornerRadius: 12)).foregroundStyle(.secondary)
                .opacity(active ? 1 : 0)
                .animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.12), value: active)
                .focused($removeFocused).accessibilityFocused($removeVoiceOverFocused)
                .accessibilityHidden(false)
                .help(L("移除此步骤")).accessibilityLabel(L("移除步骤 \(child.title)"))
                .preference(key: InlineEditingPreference.self, value: removeFocused || removeVoiceOverFocused || (editingCompletionDate && child.completedAt != nil))
            }
            if editingCompletionDate, let completed = child.completedAt {
                HStack {
                    DatePicker(L("完成日期"), selection: Binding(get: { completionDate() ?? completed }, set: onSetCompletionDate), in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.field).help(L("修改此步骤的完成日期，平时不显示时间"))
                    Button { editingCompletionDate = false } label: { Image(systemName: "xmark") }
                        .nativeActionButton().controlSize(.mini).help(L("收起步骤完成日期")).accessibilityLabel(L("收起步骤完成日期"))
                    Spacer()
                }.appFont(.caption).padding(.leading, 36)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .background {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(active ? 0.045 : 0))
                .animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.12), value: active)
        }
        .onHover { hovering = taskHoverEnabled && $0 }
        .onChange(of: taskHoverEnabled) { _, enabled in if !enabled { hovering = false } }
        .contextMenu {
            if child.completedAt != nil {
                if !parentCompleted { Button(L("恢复未完成"), action: onComplete) }
                Button(L("修改完成日期")) { editingCompletionDate = true }.help(L("在步骤下方展开完成日期"))
            }
        }
    }
}

private struct FooterActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.taskHoverEnabled) private var taskHoverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            configuration.label.fixedSize(horizontal: true, vertical: false)
            configuration.label.labelStyle(.iconOnly).fixedSize(horizontal: true, vertical: false)
        }
            .appFont(.system(size: 11, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? Color.red : (prominent ? Color.accentColor : .primary))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(minWidth: 28, minHeight: 24)
            .contentShape(Capsule())
            .background((prominent ? Color.accentColor : Color.primary).opacity(prominent ? 0.1 : (taskHoverEnabled && hovering ? 0.06 : 0)), in: Capsule())
            .animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.12), value: hovering)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .scaleEffect(reduceMotion || !isEnabled || !configuration.isPressed ? 1 : 0.97)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering = taskHoverEnabled && $0 }
            .onChange(of: taskHoverEnabled) { _, enabled in if !enabled { hovering = false } }
    }
}

private struct TaskBorderBackground: View {
    var body: some View {
        Capsule().fill(Color(nsColor: .controlBackgroundColor))
            .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            .allowsHitTesting(false)
    }
}

private struct DraftAttachment: Identifiable {
    let url: URL
    let size: Int64
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

extension TaskDraftStorage {
    @discardableResult
    func update(taskID: UUID, _ changes: (inout WorkTask) -> Void) -> WorkTask? {
        guard var candidate = task, candidate.id == taskID else { return nil }
        changes(&candidate)
        task = candidate
        return candidate
    }
}

@MainActor
final class TaskCardState: ObservableObject {
    @Published private(set) var task: WorkTask
    private var snapshot: Snapshot
    private var subscription: AnyCancellable?
    private var draftSubscription: AnyCancellable?

    private struct Snapshot: Equatable {
        let task: WorkTask
        let nextTaskID: UUID?
        let nextTaskDueAt: Date?

        init(task: WorkTask, data: LedgerData) {
            self.task = task
            let next = task.nextTaskID.flatMap { id in data.tasks.first { $0.id == id } }
            nextTaskID = next?.id
            nextTaskDueAt = next?.dueAt
        }
    }

    init(store: WorkStore, task: WorkTask, draft: TaskDraftStorage? = nil) {
        let current = store.data.tasks.first { $0.id == task.id } ?? task
        let initial = Snapshot(task: current, data: store.data)
        self.task = current
        snapshot = initial
        let taskID = task.id
        subscription = store.$data
            .dropFirst()
            .compactMap { data -> Snapshot? in
                guard let task = data.tasks.first(where: { $0.id == taskID }) else { return nil }
                return Snapshot(task: task, data: data)
            }
            .removeDuplicates()
            .sink { [weak self] value in self?.update(value) }
        draftSubscription = draft?.changes.sink { [weak self, weak store] candidate in
            guard let self, let store, let candidate, candidate.id == taskID,
                  !store.data.tasks.contains(where: { $0.id == taskID }) else { return }
            self.update(Snapshot(task: candidate, data: store.data))
        }
    }

    private func update(_ value: Snapshot) {
        guard snapshot != value else { return }
        snapshot = value
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || TaskDragState.shared.taskID != nil ? nil : .easeOut(duration: 0.18)) {
            task = value.task
        }
    }
}

struct ObservedTaskCard: View {
    let store: WorkStore
    let project: Project?
    let isHistory: Bool
    let isNavigationTarget: Bool
    let initiallyExpanded: Bool
    let draft: TaskDraftStorage?
    let onCreated: () -> Void
    let onCancel: () -> Void
    let onInitialExpansionConsumed: () -> Void
    @AppStorage("appLanguage") private var language: AppLanguage = .system
    @AppStorage("appTimeFormat") private var timeFormat: AppTimeFormat = .system
    @StateObject private var state: TaskCardState

    init(store: WorkStore, task: WorkTask, project: Project?, isHistory: Bool, isNavigationTarget: Bool = false, initiallyExpanded: Bool = false, draft: TaskDraftStorage? = nil, onCreated: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}, onInitialExpansionConsumed: @escaping () -> Void = {}) {
        self.store = store; self.project = project; self.isHistory = isHistory; self.draft = draft
        self.isNavigationTarget = isNavigationTarget
        self.initiallyExpanded = initiallyExpanded
        self.onCreated = onCreated; self.onCancel = onCancel
        self.onInitialExpansionConsumed = onInitialExpansionConsumed
        _state = StateObject(wrappedValue: TaskCardState(store: store, task: task, draft: draft))
    }

    var body: some View {
        TaskCard(store: store, task: state.task, project: project, isHistory: isHistory,
                 isNavigationTarget: isNavigationTarget, initiallyExpanded: initiallyExpanded, languageIdentifier: language.localeIdentifier, timeFormat: timeFormat, draft: draft, onCreated: onCreated, onCancel: onCancel, onInitialExpansionConsumed: onInitialExpansionConsumed)
            .equatable()
    }
}

struct TaskCard: View, Equatable {
    let store: WorkStore
    @EnvironmentObject private var services: AppServices
    @ObservedObject private var taskDragState = TaskDragState.shared
    @Environment(\.undoManager) private var undoManager
    @Environment(\.taskPlanningDay) private var planningReferenceDate
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.taskDetailsMode) private var detailsMode
    @Environment(\.appTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("weekStart") private var weekStart = 5
    let task: WorkTask
    let project: Project?
    let isHistory: Bool
    let isNavigationTarget: Bool
    let initiallyExpanded: Bool
    let languageIdentifier: String
    let timeFormat: AppTimeFormat
    let draft: TaskDraftStorage?
    let onCreated: () -> Void
    let onCancel: () -> Void
    let onInitialExpansionConsumed: () -> Void
    @State private var hovered = false
    @State private var expandedOverride: Bool?
    @State private var textEditingFocused = false
    @State private var importingFiles = false
    @State private var dropTargeted = false
    @State private var dateEditor: DateField?
    @State private var releaseFocusAfterDate = false
    @State private var dateCloseEvent: NSEvent?
    @State private var selectedDate = Date()
    @State private var editingRepeat = false
    @State private var customRepeat = false
    @State private var repeatDraft = RepeatRule()
    @State private var planningExpanded = false
    @State private var addingChild = false
    @State private var childInputID = UUID()
    @State private var detailsEditing = false
    @State private var focusDetailsOnAppear = false
    @State private var notesEditing = false
    @State private var focusNotesOnAppear = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var discardedDraft = false
    @State private var editorsOpen = false
    @State private var editingBaseline: WorkTask?
    @State private var textHasChanges = false
    @State private var focusChildOnAppear = false
    @State private var stagedAttachments: [DraftAttachment] = []
    @FocusState private var cardFocused: Bool
    @FocusState private var focusedAction: Action?
    @FocusState private var focusedAttachment: UUID?
    @AccessibilityFocusState private var voiceOverAction: Action?
    @AccessibilityFocusState private var voiceOverAttachment: UUID?

    private enum Action: Hashable { case addDetails, addNotes, addChild, attachment, reminder, due, recurrence, delete, completionDate }
    private enum DateField: String, Identifiable {
        case reminder, due
        var id: Self { self }
        var title: String { self == .reminder ? L("提醒日期") : L("截止日期") }
        var symbol: String { self == .reminder ? "bell" : "calendar" }
    }
    private let repeatPresets: [(String, Int, RepeatUnit)] = [(L("每天"), 1, .day), (L("每周"), 1, .week), (L("每月"), 1, .month), (L("每半年"), 6, .month), (L("每年"), 1, .year)]
    private var taskHoverEnabled: Bool { taskDragState.taskID == nil }
    private var sectionTransition: AnyTransition { reduceMotion ? .identity : .taskSection }
    private var showActions: Bool {
        showsDetails && taskHoverEnabled && (hovered || taskFocused || dateEditor != nil || importingFiles)
    }
    private var showsDetails: Bool {
        isDraft || editingSessionActive || editingRepeat || dateEditor != nil || importingFiles || (expandedOverride ?? (detailsMode == .expanded))
    }
    private var taskFocused: Bool { cardFocused || textEditingFocused || focusedAction != nil || voiceOverAction != nil || focusedAttachment != nil || voiceOverAttachment != nil }
    private var hasTaskChanges: Bool {
        textHasChanges || editingBaseline.map { task.hasEditableChanges(comparedTo: $0) } == true
    }
    private var editingSessionActive: Bool { editorsOpen || isDraft || editingBaseline != nil || planningExpanded }
    private var latestTask: WorkTask { store.data.tasks.first { $0.id == task.id } ?? draft?.task ?? task }
    private var hasAttachments: Bool { !task.attachments.isEmpty || !stagedAttachments.isEmpty }
    private var isDraft: Bool { !discardedDraft && draft?.task?.id == task.id && !store.data.tasks.contains { $0.id == task.id } }
    private var projectColor: Color { project.map { Color(hex: $0.colorHex) } ?? .teal }
    private var hoverBorderColor: Color { project.map { Color(hex: $0.colorHex) } ?? .accentColor }

    private let draftID: UUID?
    private let nextTask: WorkTask?

    init(store: WorkStore, task: WorkTask, project: Project?, isHistory: Bool, isNavigationTarget: Bool = false, initiallyExpanded: Bool = false, languageIdentifier: String = AppLocalization.languageIdentifier, timeFormat: AppTimeFormat = .system, draft: TaskDraftStorage? = nil, onCreated: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}, onInitialExpansionConsumed: @escaping () -> Void = {}) {
        self.store = store; self.task = task; self.project = project; self.isHistory = isHistory; self.draft = draft
        self.isNavigationTarget = isNavigationTarget; self.languageIdentifier = languageIdentifier; self.timeFormat = timeFormat
        self.initiallyExpanded = initiallyExpanded
        self.onCreated = onCreated; self.onCancel = onCancel
        self.onInitialExpansionConsumed = onInitialExpansionConsumed
        draftID = draft?.task?.id
        nextTask = task.nextTaskID.flatMap { id in store.data.tasks.first { $0.id == id } }
        _detailsEditing = State(initialValue: draftID == task.id)
        _notesEditing = State(initialValue: draftID == task.id)
        _addingChild = State(initialValue: draftID == task.id)
        _editorsOpen = State(initialValue: draftID == task.id)
        _expandedOverride = State(initialValue: initiallyExpanded ? true : nil)
    }

    static func == (lhs: TaskCard, rhs: TaskCard) -> Bool {
        lhs.store === rhs.store && lhs.draft === rhs.draft && lhs.task == rhs.task && lhs.project == rhs.project
            && lhs.isHistory == rhs.isHistory && lhs.draftID == rhs.draftID
            && lhs.isNavigationTarget == rhs.isNavigationTarget && lhs.languageIdentifier == rhs.languageIdentifier
            && lhs.initiallyExpanded == rhs.initiallyExpanded
            && lhs.timeFormat == rhs.timeFormat
            && lhs.nextTask?.id == rhs.nextTask?.id && lhs.nextTask?.dueAt == rhs.nextTask?.dueAt
    }
    private var completedChildren: Int { task.subtasks.filter { $0.completedAt != nil }.count }
    private var planTitle: String {
        guard task.plannedAt != nil else { return L("未安排") }
        if isHistory, task.completedAt != nil { return task.planGranularity == .week ? L("按周") : L("具体日期") }
        return localizedLabel(task.planBucket(relativeTo: planningReferenceDate, firstWeekday: weekStart).title)
    }
    private var planOverdue: Bool { task.isPlanOverdue(relativeTo: planningReferenceDate, firstWeekday: weekStart) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                heading
                if showsDetails {
                if isHistory, task.completedAt != nil || task.completionSource?.lowercased() == "api" {
                    metadata.padding(.top, 6).transition(sectionTransition)
                }
                if detailsEditing || !task.details.isEmpty {
                    detailsEditor.padding(.top, 6).transition(sectionTransition)
                }
                if !task.subtasks.isEmpty || addingChild {
                    subtasks.padding(.top, 6).transition(sectionTransition)
                }
                if notesEditing || !task.notes.isEmpty {
                    notesEditor.padding(.vertical, 3)
                        .background(projectColor.opacity(notesEditing ? 0 : 0.035), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 6).transition(sectionTransition)
                }
                if isDraft || hasAttachments {
                    attachments.padding(.top, 6).transition(sectionTransition)
                }
                if let error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.circle").appFont(.caption).foregroundStyle(.red)
                        Spacer()
                        Button { self.error = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help(L("关闭错误提示")).accessibilityLabel(L("关闭错误提示"))
                    }.padding(.top, 6).transition(sectionTransition)
                }
                if isHistory, let nextID = task.nextTaskID, let next = nextTask {
                    Button {
                        guard flushEdits() else { return }
                        NotificationCenter.default.post(name: .init("WorkLedger.openTask"), object: nextID.uuidString)
                    } label: {
                        Label(L("下一次任务\(next.dueAt.map { " · " + dayText($0) } ?? "")"), systemImage: "arrow.right.circle")
                    }.buttonStyle(.link).appFont(.caption).help(L("跳转到下一次循环任务"))
                        .padding(.top, 6).transition(sectionTransition)
                }
                if task.reminderAt != nil || task.repeatRule != nil || task.dueAt != nil {
                    dateSummary.padding(.top, 8).transition(sectionTransition)
                }
                if let issue = services.reminderIssue(for: task) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(issue, systemImage: "bell.badge").appFont(.caption).foregroundStyle(.orange)
                        if services.canRequestNotifications {
                            Button(L("开启通知"), action: services.requestNotifications).buttonStyle(.link).appFont(.caption)
                                .help(L("允许 macOS 发送提醒；系统通知仍受专注模式影响"))
                        } else if services.notificationError != nil {
                            Button(L("重试"), action: services.retryNotifications).buttonStyle(.link).appFont(.caption)
                                .help(L("重新检查通知权限并安排提醒"))
                        }
                    }.padding(.horizontal, 7).padding(.top, 6).transition(sectionTransition)
                }
                if editingRepeat { repeatControls.padding(.top, 6).transition(sectionTransition) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor))
                    .onTapGesture { if !showsDetails { animateLayout { expandedOverride = true } } }
            }
            .overlay {
                let fileDropActive = taskHoverEnabled && dropTargeted
                let hoverActive = taskHoverEnabled && hovered && !isDraft
                let navigationActive = taskHoverEnabled && isNavigationTarget
                let editingActive = taskHoverEnabled && taskFocused
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(fileDropActive ? Color.teal : (navigationActive || editingActive ? hoverBorderColor : (hoverActive ? hoverBorderColor.opacity(0.7) : Color.primary.opacity(0.08))), lineWidth: fileDropActive || navigationActive ? 2 : (hoverActive || editingActive ? 1.5 : 1))
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.teal.opacity(fileDropActive ? 0.06 : 0)))
                    .overlay {
                        if fileDropActive {
                            Label(L("松开以添加附件"), systemImage: "paperclip")
                                .appFont(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                        }
                    }
                    .allowsHitTesting(false)
            }
            .modifier(TaskNativeDrag(taskID: task.id, enabled: !isDraft, prepare: prepareDrag, preview: renderDragPreview, onDraggingChanged: { _ in }))
            .scaleEffect(reduceMotion || taskDragState.taskID != task.id ? 1 : 0.985)
            .opacity(taskDragState.taskID == task.id ? 0.48 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: taskDragState.taskID == task.id)
            .overlay(alignment: .bottom) {
                if showsDetails {
                    footer.fixedSize(horizontal: false, vertical: true)
                        .frame(height: 0, alignment: .center)
                }
            }
            Color.clear
                .frame(height: showActions ? 20 : 4)
                .allowsHitTesting(false)
        }
        .background {
            if editingSessionActive || taskFocused {
                TaskEditingBoundary(enabled: true, onExit: {
                    persistTaskEditing()
                    releaseTaskFocus()
                }, onFinish: { request in
                    guard request.targets(task.id) else { return }
                    if !finishTaskEditing() { request.failed = true }
                })
            }
        }
        .onHover { hovering in animateLayout { hovered = taskHoverEnabled && hovering } }
        .onChange(of: taskHoverEnabled) { _, enabled in
            if !enabled { hovered = false }
        }
        .focusable(interactions: .activate).focused($cardFocused).focusEffectDisabled()
        .onPreferenceChange(InlineEditorOpenPreference.self) { open in
            if open { beginTaskEditing() }
            editorsOpen = open
        }
        .onPreferenceChange(InlineTextChangedPreference.self) { textHasChanges = $0 }
        .onPreferenceChange(InlineEditingPreference.self) { focused in
            textEditingFocused = focused
            if !focused, NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.keyCode == 48 {
                Task { @MainActor in
                    await Task.yield()
                    if !textEditingFocused && !cardFocused && focusedAction == nil && focusedAttachment == nil {
                        persistTaskEditing()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            if editingSessionActive && !importingFiles { persistTaskEditing() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if editingSessionActive { finishTaskEditing() }
        }
        .onDisappear { if editingSessionActive && !discardedDraft { finishTaskEditing() } }
        .onAppear {
            loadStagedAttachments()
            if isNavigationTarget { expandedOverride = true }
            if initiallyExpanded && !isDraft { onInitialExpansionConsumed() }
        }
        .onChange(of: isNavigationTarget) { _, target in if target { animateLayout { expandedOverride = true } } }
        .onChange(of: detailsMode) { _, _ in
            if finishTaskEditing() { animateLayout { expandedOverride = nil } }
        }
        .confirmationDialog(L("删除这项任务？"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("删除任务"), role: .destructive, action: deleteTask)
            Button(L("取消"), role: .cancel) {}
        } message: { Text(L("「\(task.title)」会被删除，之后可通过编辑菜单撤销。")) }
        .accessibilityElement(children: .contain)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            return addFiles(files)
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): addFiles(urls)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .contextMenu {
            Button(L("修改计划时间"), action: togglePlanning).help(L("在卡片内选择本周、下周，或打开日历选择具体时间"))
            Button(L("添加本地附件")) { importingFiles = true }.help(L("选择本地文件并复制到任务中"))
            Button(L("提醒日期")) { openDate(.reminder) }.help(L("添加或修改提醒日期"))
            Button(L("截止日期")) { openDate(.due) }.help(L("添加或修改截止日期"))
            Button(L("循环")) { openRepeat() }.help(L("选择循环周期或自定义周期"))
            if task.completedAt != nil {
                Button(L("撤销完成"), action: undoCompletion).help(L("撤销本次完成，并移除尚未被操作的下一次任务"))
            }
            Divider()
            Button(L("删除任务"), role: .destructive, action: requestDelete).help(L("删除任务，可通过编辑菜单撤销"))
        }
        .environment(\.taskHoverEnabled, taskHoverEnabled)
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: 0) {
            HoverGlassButton(size: 36, action: toggleCompletion) {
                Image(systemName: task.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .appFont(.system(size: 24, weight: .light))
                    .foregroundStyle(task.completedAt == nil ? Color.secondary : .teal)
                    .symbolEffect(.bounce, options: .speed(2), value: task.completedAt != nil)
                    .symbolEffectsRemoved(reduceMotion)
            }
                .help(task.completedAt == nil ? L("完成任务，默认记录今天；完成日期可直接修改") : L("撤销完成"))
                .accessibilityLabel(task.completedAt == nil ? L("完成任务 \(task.title)") : L("撤销完成 \(task.title)"))
            if showsDetails {
            planningRow
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 4)
                .padding(.trailing, 6)
            InlineEditableText(text: task.title, placeholder: L("任务名称"), help: L("点击修改任务名称，回车保存任务"), required: true, font: .system(size: 15, weight: .semibold), taskID: task.id, saveOnBlur: isDraft, initiallyEditing: isDraft, autofocus: isDraft, allowEmpty: isDraft, avoidsInitialSelection: true, onDraftChange: { value in stageTask { $0.title = value } }) { value in
                try updateTask { $0.title = value }
            } onFailure: { store.errorMessage = $0 }
            } else {
                Button { animateLayout { expandedOverride = true } } label: {
                    Text(task.title).appFont(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                }.buttonStyle(HoverHighlightButtonStyle())
                    .help(L("展开任务详情"))
                if task.completedAt == nil, let due = task.dueAt, due < Calendar.current.startOfDay(for: Date()) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .help(L("截止日期已过：\(dayText(due))"))
                }
            }
            if !isDraft {
                Image(systemName: "line.3.horizontal").appFont(.caption)
                    .foregroundStyle(.secondary).frame(width: 18, height: 24)
                    .opacity(hovered ? 0.7 : 0)
                    .help(L("拖动调整项目或周计划"))
                HoverGlassButton(size: 24, action: toggleDetails) {
                    Image(systemName: "chevron.right").appFont(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                }
                .help(showsDetails ? L("收起任务详情，先保存当前编辑") : L("展开任务详情"))
                .accessibilityLabel(showsDetails ? L("收起任务详情") : L("展开任务详情"))
            }

        }
    }

    private var dragPreview: some View {
        let current = latestTask
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: current.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .appFont(.system(size: 20, weight: .light))
                    .foregroundStyle(current.completedAt == nil ? Color.secondary : .teal)
                Text(current.title).appFont(.headline).lineLimit(2)
            }
            Text(planTitle).appFont(.caption).foregroundStyle(.secondary)
            if !current.details.isEmpty {
                Text(current.details).appFont(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if !current.subtasks.isEmpty {
                Label(L("步骤 \(current.subtasks.filter { $0.completedAt != nil }.count)/\(current.subtasks.count)"), systemImage: "checklist")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            if !current.notes.isEmpty {
                Text(current.notes).appFont(.caption).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                    .background(hoverBorderColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(14).frame(width: 270, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hoverBorderColor.opacity(0.85), lineWidth: 1.5))
    }

    private var planningRow: some View {
        HStack(spacing: 10) {
            TaskPlanPicker(date: .constant(task.plannedAt), granularity: .constant(task.planGranularity), expanded: $planningExpanded, currentTitle: planTitle, detail: task.plannedAt.map(planDateDescription) ?? L("尚未安排"), isOverdue: planOverdue, onSelect: updatePlan)
            if planOverdue {
                Text(L("已超时")).appFont(.caption.weight(.semibold)).foregroundStyle(.red)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.red.opacity(0.08), in: Capsule())
                    .help(L("原计划时间已经过去，未完成任务归入本周继续处理"))
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            if task.completionSource?.lowercased() == "api" {
                Label(L("API 完成"), systemImage: "terminal").appFont(.caption).foregroundStyle(.secondary).help(L("此任务通过本地 API 完成"))
            }
            if let completed = task.completedAt {
                HStack(spacing: 8) {
                    Label(L("完成日期"), systemImage: "checkmark").foregroundStyle(.secondary)
                    DatePicker(L("完成日期"), selection: Binding(get: { latestTask.completedAt ?? completed }, set: { date in
                        perform { try store.setCompletionDate(taskID: task.id, at: date) }
                    }), in: ...Date(), displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.field).help(L("直接修改主任务完成日期，工作周期会同步调整"))
                        .focused($focusedAction, equals: .completionDate).accessibilityFocused($voiceOverAction, equals: .completionDate)
                    if task.nextTaskID != nil {
                        Text(L("不改变下一次任务日期")).foregroundStyle(.secondary).help(L("若需调整下一次日期，请点击下方“下一次任务”后修改"))
                    }
                    Spacer()
                }.appFont(.caption)
            }
        }
    }

    private func planDateDescription(_ date: Date) -> String {
        guard task.planGranularity == .week else { return dayText(date) }
        let range = WorkPeriod.range(containing: date, firstWeekday: weekStart)
        return "\(dayText(range.start)) — \(dayText(range.end.addingTimeInterval(-1)))"
    }

    private func togglePlanning() {
        guard flushEdits() else { return }
        planningExpanded.toggle()
    }

    private func updatePlan(_ date: Date?, _ precision: TaskPlanGranularity?) {
        guard flushEdits() else { return }
        let before = latestTask
        let editingDraft = draft?.task?.id == task.id
        perform {
            try updateTask {
                $0.plannedAt = date
                $0.planGranularity = date == nil ? nil : precision
            }
            if !editingDraft, let after = store.data.tasks.first(where: { $0.id == task.id }),
               before.plannedAt != after.plannedAt || before.planGranularity != after.planGranularity {
                TaskOperationEvent.planned(before: before, after: after).post()
            }
            releaseTaskFocus()
        }
    }

    private var detailsEditor: some View {
        InlineEditableText(text: task.details, placeholder: L("填写任务明细"), help: L("点击修改任务明细"), multiline: true, taskID: task.id, saveOnBlur: isDraft, initiallyEditing: detailsEditing, autofocus: focusDetailsOnAppear, onEditingChanged: { editing in animateLayout { detailsEditing = editing; focusDetailsOnAppear = false } }, onDraftChange: { value in stageTask { $0.details = value } }) { value in
            try updateTask { $0.details = value }
        } onFailure: { store.errorMessage = $0 }
    }

    private var notesEditor: some View {
        InlineEditableText(text: task.notes, placeholder: L("填写备注"), help: L("点击修改备注"), multiline: true, taskID: task.id, saveOnBlur: isDraft, initiallyEditing: notesEditing, autofocus: focusNotesOnAppear, onEditingChanged: { editing in animateLayout { notesEditing = editing; focusNotesOnAppear = false } }, onDraftChange: { value in stageTask { $0.notes = value } }) { value in
            try updateTask { $0.notes = value }
        } onFailure: { store.errorMessage = $0 }
    }

    private var subtasks: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(L("执行步骤 · 已完成 \(completedChildren)/\(task.subtasks.count)"))
                    .appFont(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .help(L("全部步骤完成后，主任务会自动完成"))
                if !task.subtasks.isEmpty {
                    HoverGlassButton(size: 24, action: beginAddingChild) {
                        Text(Image(systemName: "plus")).appFont(.caption.weight(.semibold))
                    }
                        .help(L("添加步骤并开始编辑")).accessibilityLabel(L("添加步骤"))
                        .focused($focusedAction, equals: .addChild).accessibilityFocused($voiceOverAction, equals: .addChild)
                        .opacity(showActions ? 1 : 0)
                }
            }.padding(.horizontal, 7)
            ForEach(task.subtasks.filter { !addingChild || $0.id != childInputID }) { child in
                TaskSubtaskRow(taskID: task.id, child: child, parentCompleted: task.completedAt != nil, isDraft: isDraft, onComplete: {
                    guard flushEdits() else { return }
                    if draft?.task?.id == task.id {
                        do { try commitDraft() }
                        catch { self.error = localizedError(error); return }
                    }
                    toggleSubtask(child.id)
                }, onDraftChange: { value in
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    stageTask { latest in
                        if let index = latest.subtasks.firstIndex(where: { $0.id == child.id }) { latest.subtasks[index].title = value }
                    }
                }, onSave: { value in
                    guard latestTask.subtasks.contains(where: { $0.id == child.id }) else { throw LedgerError.notFound(L("此步骤已被移除。")) }
                    try updateTask { latest in
                        if let index = latest.subtasks.firstIndex(where: { $0.id == child.id }) { latest.subtasks[index].title = value }
                    }
                }, onEmptySave: { try removeChild(child.id) }, onNextStep: beginAddingChild, onFailure: { store.errorMessage = $0 }, onRemove: {
                    guard flushEdits() else { return }
                    perform { try removeChild(child.id) }
                }, completionDate: { latestTask.subtasks.first { $0.id == child.id }?.completedAt }, onSetCompletionDate: { date in
                    perform { try store.setSubtaskCompletionDate(taskID: task.id, subtaskID: child.id, at: date) }
                }).padding(.top, 4).transition(sectionTransition)
            }
            if addingChild {
                let inputID = childInputID
                HStack(alignment: .center, spacing: 0) {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).frame(width: 36).accessibilityHidden(true)
                    InlineEditableText(text: task.subtasks.first { $0.id == inputID }?.title ?? "", placeholder: L("步骤名称"), help: L("新步骤名称"), taskID: task.id, saveOnBlur: true, initiallyEditing: true, autofocus: focusChildOnAppear, onNextStep: {
                        animateLayout { childInputID = UUID(); focusChildOnAppear = true }
                    }, onEditingChanged: { editing in
                        guard childInputID == inputID else { return }
                        animateLayout {
                            focusChildOnAppear = false
                            if !editing { addingChild = false }
                        }
                    }, onSave: { try saveChild($0, id: inputID) }) { store.errorMessage = $0 }
                }.id(inputID).padding(.top, 7).transition(sectionTransition)
            }
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(L("附件 · \(task.attachments.count + stagedAttachments.count)"))
                    .appFont(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                if hasAttachments {
                    HoverGlassButton(size: 24, action: { importingFiles = true }) {
                        Text(Image(systemName: "plus")).appFont(.caption.weight(.semibold))
                    }
                        .help(L("添加本地附件，也可以直接拖入文件")).accessibilityLabel(L("添加附件"))
                        .focused($focusedAction, equals: .attachment).accessibilityFocused($voiceOverAction, equals: .attachment)
                        .opacity(showActions ? 1 : 0)
                }
            }.padding(.horizontal, 7)
            if !hasAttachments {
                Text(L("将文件拖入这里，或点击下方“附件”添加本地文件。"))
                    .appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 7)
            }
            if hasAttachments {
                TaskFlowLayout(spacing: 8, rowSpacing: 6) {
                    ForEach(task.attachments) { attachment in
                        HStack(spacing: 9) {
                            Image(systemName: "doc").foregroundStyle(projectColor)
                            Button(attachment.name) { openAttachment(attachment) }.buttonStyle(.link)
                                .appFont(.system(size: 12, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                                .help(L("打开 \(attachment.name)\n\(attachmentSize(attachment.size))\n\(store.attachmentURL(attachment).path)"))
                            Text(attachmentSize(attachment.size)).appFont(.caption).foregroundStyle(.secondary)
                            Menu {
                                Button(L("打开")) { openAttachment(attachment) }.help(L("使用默认应用打开附件"))
                                Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([store.attachmentURL(attachment)]) }.help(L("在 Finder 中定位本地附件"))
                                Button(L("另存为…")) { saveAttachment(attachment) }.help(L("将附件复制到选择的位置"))
                                Divider()
                                Button(L("从此任务移除"), role: .destructive) {
                                    guard flushEdits() else { return }
                                    perform {
                                        guard let index = latestTask.attachments.firstIndex(where: { $0.id == attachment.id }) else { return }
                                        try store.removeAttachment(taskID: task.id, attachmentID: attachment.id)
                                        announceUndo(.removedAttachment(taskID: task.id, attachment: attachment, index: index),
                                                     message: L("已移除附件「\(attachment.name)」"), symbol: "paperclip", name: L("移除附件"))
                                    }
                                }.help(L("仅移除此任务的引用，文件保留；可在底部撤销或按 ⌘Z 恢复"))
                            } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("附件操作：打开、定位、另存为或移除"))
                                .accessibilityLabel(L("附件 \(attachment.name) 的操作"))
                                .focused($focusedAttachment, equals: attachment.id)
                                .accessibilityFocused($voiceOverAttachment, equals: attachment.id)
                                .opacity(showActions ? 1 : 0)
                                .accessibilityHidden(false)
                        }.padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                    }
                    ForEach(stagedAttachments) { attachment in
                        HStack(spacing: 9) {
                            Image(systemName: "doc").foregroundStyle(projectColor)
                            Button(attachment.name) {
                                if !NSWorkspace.shared.open(attachment.url) { error = L("无法打开草稿附件。") }
                            }.buttonStyle(.link).appFont(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).help(L("打开本地草稿附件：\(attachment.name)"))
                            Text(attachmentSize(attachment.size)).appFont(.caption).foregroundStyle(.secondary)
                            Text(L("待保存")).appFont(.caption).foregroundStyle(.secondary)
                            Button {
                                perform {
                                    try FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
                                    stagedAttachments.removeAll { $0.id == attachment.id }
                                }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(HoverHighlightButtonStyle()).help(L("移除此草稿附件")).accessibilityLabel(L("移除草稿附件 \(attachment.name)"))
                        }.padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
            if !isDraft && !stagedAttachments.isEmpty {
                Button(L("重试保存附件")) { perform { try importStagedAttachments() } }
                    .buttonStyle(.link).appFont(.caption).help(L("重新将保留的草稿附件保存到任务中"))
            }
        }
    }

    private func attachmentSize(_ size: Int64) -> String {
        size.formatted(.byteCount(style: .file).locale(Locale(identifier: languageIdentifier)))
    }

    private var footer: some View {
        footerActions
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background { if showActions { TaskBorderBackground() } }
        .padding(.horizontal, 16)
        .opacity(showActions ? 1 : 0)
        .animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.18), value: showActions)
        .allowsHitTesting(showActions)
        .accessibilityHidden(false)
    }

    private var footerActions: some View {
        HStack(spacing: 4) {
            if task.details.isEmpty && !detailsEditing {
                Button { animateLayout { focusDetailsOnAppear = true; detailsEditing = true } } label: { Label(L("任务明细"), systemImage: "text.alignleft") }
                    .buttonStyle(FooterActionButtonStyle()).controlSize(.small)
                    .help(L("添加任务明细并开始编辑")).accessibilityLabel(L("添加任务明细"))
                    .focused($focusedAction, equals: .addDetails).accessibilityFocused($voiceOverAction, equals: .addDetails)
            }
            if task.notes.isEmpty && !notesEditing {
                Button { animateLayout { focusNotesOnAppear = true; notesEditing = true } } label: { Label(L("备注"), systemImage: "note.text") }
                    .buttonStyle(FooterActionButtonStyle()).controlSize(.small)
                    .help(L("添加备注并开始编辑")).accessibilityLabel(L("添加备注"))
                    .focused($focusedAction, equals: .addNotes).accessibilityFocused($voiceOverAction, equals: .addNotes)
            }
            if task.subtasks.isEmpty && !addingChild {
                Button(action: beginAddingChild) { Label(L("步骤"), systemImage: "checklist") }
                    .buttonStyle(FooterActionButtonStyle()).controlSize(.small)
                    .help(L("添加步骤并开始编辑")).accessibilityLabel(L("添加步骤"))
                    .focused($focusedAction, equals: .addChild).accessibilityFocused($voiceOverAction, equals: .addChild)
            }
            if !hasAttachments {
                Button { importingFiles = true } label: { Label(L("附件"), systemImage: "paperclip") }
                    .buttonStyle(FooterActionButtonStyle()).controlSize(.small).help(L("添加本地附件，也可以直接拖入文件")).accessibilityLabel(L("添加附件"))
                    .focused($focusedAction, equals: .attachment).accessibilityFocused($voiceOverAction, equals: .attachment)
            }
            if task.reminderAt == nil {
                Button { openDate(.reminder) } label: { Label(L("提醒日期"), systemImage: "bell.badge") }
                    .buttonStyle(FooterActionButtonStyle()).controlSize(.small).help(L("添加提醒日期与时间"))
                    .focused($focusedAction, equals: .reminder).accessibilityFocused($voiceOverAction, equals: .reminder)
                    .popover(isPresented: datePresented(.reminder), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { datePicker(.reminder) }
            }
            if task.dueAt == nil {
                Button { openDate(.due) } label: { Label(L("截止日期"), systemImage: "calendar.badge.plus") }
                    .buttonStyle(FooterActionButtonStyle()).controlSize(.small).help(L("添加截止日期"))
                    .focused($focusedAction, equals: .due).accessibilityFocused($voiceOverAction, equals: .due)
                    .popover(isPresented: datePresented(.due), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { datePicker(.due) }
            }
            if task.repeatRule == nil {
                Button(action: openRepeat) { Label(L("循环"), systemImage: "repeat") }
                    .buttonStyle(FooterActionButtonStyle()).controlSize(.small).help(L("选择常用循环周期或自定义周期"))
                    .focused($focusedAction, equals: .recurrence).accessibilityFocused($voiceOverAction, equals: .recurrence)
            }
            Button(role: .destructive, action: requestDelete) { Image(systemName: "trash") }
                .buttonStyle(FooterActionButtonStyle()).controlSize(.small).help(draft?.task?.id == task.id ? L("取消新增任务") : L("删除任务，确认后可撤销（⌘Z）")).accessibilityLabel(draft?.task?.id == task.id ? L("取消新增任务") : L("删除任务"))
                .focused($focusedAction, equals: .delete).accessibilityFocused($voiceOverAction, equals: .delete)
        }
        .lineLimit(1)
    }

    private var dateSummary: some View {
        TaskFlowLayout(spacing: 12, rowSpacing: 4) {
            if let reminder = task.reminderAt {
                dateRow(.reminder, text: timeFormat.formatted(reminder, includesDate: true, locale: AppLocalization.locale))
            }
            if let rule = task.repeatRule {
                TaskMetadataRow(title: repeatText(rule), symbol: "repeat", tint: .secondary,
                                editHelp: L("点击修改循环周期"), removeHelp: L("移除循环，保留已有日期和历史记录"), removeLabel: L("移除循环"),
                                onEdit: openRepeat, onRemove: removeRepeat)
            }
            if let due = task.dueAt { dateRow(.due, text: dayText(due)) }
        }
    }

    private func dateRow(_ field: DateField, text: String) -> some View {
        TaskMetadataRow(title: "\(field.title) \(text)", symbol: field.symbol,
                        tint: field == .due && task.completedAt == nil && task.dueAt.map { $0 < Calendar.current.startOfDay(for: Date()) } == true ? .orange : .secondary,
                        editHelp: L("点击修改\(field.title)"),
                        removeHelp: field == .due && task.repeatRule?.basis == .schedule ? L("移除截止日期，循环改为从完成日计算") : L("移除\(field.title)"),
                        removeLabel: L("移除\(field.title)"), onEdit: { openDate(field) }, onRemove: { removeDate(field) })
            .popover(isPresented: datePresented(field), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { datePicker(field) }
    }

    private func datePresented(_ field: DateField) -> Binding<Bool> {
        Binding(get: { dateEditor == field }, set: { presented in
            if !presented && dateEditor == field { dateEditor = nil }
        })
    }

    private func datePicker(_ field: DateField) -> some View {
        TaskDatePicker(initialDate: selectedDate, includesTime: field == .reminder, title: field.title,
                       onConfirm: { updateDate(field, to: $0) }, onCancel: { closeDateEditor() })
            .onDisappear {
                guard releaseFocusAfterDate else { return }
                releaseFocusAfterDate = false
                let event = dateCloseEvent
                dateCloseEvent = nil
                // Popovers restore the previous field after closing; clear that restored focus once.
                DispatchQueue.main.async {
                    guard dateEditor == nil, NSApp.currentEvent === event else { return }
                    releaseTaskFocus()
                }
            }
    }

    private var repeatControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("循环周期")).appFont(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { animateLayout { editingRepeat = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(HoverHighlightButtonStyle()).help(L("收起循环选择")).accessibilityLabel(L("收起循环选择"))
            }
            HStack(spacing: 6) {
                ForEach(repeatPresets.indices, id: \.self) { index in
                    let preset = repeatPresets[index]
                    Button(preset.0) {
                        saveRepeat(RepeatRule(every: preset.1, unit: preset.2, basis: repeatDraft.basis), close: true)
                    }.nativeActionButton().controlSize(.small).help(L("设为\(preset.0)循环"))
                }
                Button(L("自定义…")) { animateLayout { customRepeat = true } }
                    .nativeActionButton().controlSize(.small).help(L("自定义间隔、单位与循环依据"))
            }
            if customRepeat {
                HStack {
                    Stepper(L("每隔 \(repeatDraft.every)"), value: Binding(get: { repeatDraft.every }, set: { value in
                        var rule = repeatDraft; rule.every = value; saveRepeat(rule)
                    }), in: 1...10000).fixedSize().help(L("调整自定义循环间隔"))
                    Picker(L("循环单位"), selection: Binding(get: { repeatDraft.unit }, set: { value in
                        var rule = repeatDraft; rule.unit = value; saveRepeat(rule)
                    })) {
                        Text(L("天")).tag(RepeatUnit.day); Text(L("周")).tag(RepeatUnit.week)
                        Text(L("个月")).tag(RepeatUnit.month); Text(L("年")).tag(RepeatUnit.year)
                    }.labelsHidden().frame(width: 90).help(L("选择循环单位"))
                    Picker(L("循环依据"), selection: Binding(get: { repeatDraft.basis }, set: { value in
                        var rule = repeatDraft; rule.basis = value; saveRepeat(rule)
                    })) {
                        Text(L("实际完成日")).tag(RepeatBasis.completion)
                        Text(L("截止日期")).tag(RepeatBasis.schedule).disabled(latestTask.dueAt == nil)
                    }.labelsHidden().frame(width: 145).help(L("没有截止日期时，按实际完成日循环"))
                }
            }
            Text(latestTask.dueAt == nil ? L("从完成日计算下一次任务的截止日期。") : L("完成后保留本次记录，并创建下一次任务。"))
                .appFont(.caption).foregroundStyle(.secondary)
            if latestTask.reminderAt != nil {
                Text(L("下次提醒保留原时刻。有截止日期时保留提前天数；无截止日期时在下次任务当天提醒。若已早于完成时间，则顺延到最近一次该时刻。"))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
    }

    private func openDate(_ field: DateField) {
        guard flushEdits() else { return }
        if dateEditor == field { dateEditor = nil; return }
        releaseTaskFocus()
        releaseFocusAfterDate = false
        dateCloseEvent = nil
        selectedDate = (field == .reminder ? latestTask.reminderAt : latestTask.dueAt) ?? shortcutDate(field, offset: field == .reminder ? 1 : 0)
        editingRepeat = false
        dateEditor = field
    }

    private func shortcutDate(_ field: DateField, offset: Int) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        return field == .reminder ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day : Calendar.current.startOfDay(for: day)
    }

    private func updateDate(_ field: DateField, to date: Date) {
        perform {
            try updateTask { if field == .reminder { $0.reminderAt = date } else { $0.dueAt = date } }
            selectedDate = date; closeDateEditor()
            releaseTaskFocus()
        }
    }

    private func removeDate(_ field: DateField) {
        guard flushEdits() else { return }
        perform {
            try updateTask {
                if field == .reminder { $0.reminderAt = nil }
                else {
                    $0.dueAt = nil; $0.scheduleAnchor = nil
                    if $0.repeatRule?.basis == .schedule { $0.repeatRule?.basis = .completion }
                }
            }
            if dateEditor == field { dateEditor = nil }
            if let rule = latestTask.repeatRule { repeatDraft = rule }
            releaseTaskFocus()
        }
    }

    private func closeDateEditor() {
        dateCloseEvent = NSApp.currentEvent
        releaseFocusAfterDate = true
        dateEditor = nil
    }

    private func openRepeat() {
        guard flushEdits() else { return }
        animateLayout {
            if editingRepeat { editingRepeat = false; return }
            repeatDraft = latestTask.repeatRule ?? RepeatRule()
            customRepeat = latestTask.repeatRule != nil
            dateEditor = nil; editingRepeat = true
        }
    }

    private func saveRepeat(_ rule: RepeatRule, close: Bool = false) {
        perform {
            try updateTask {
                if $0.repeatRule != rule { $0.scheduleAnchor = nil }
                $0.repeatRule = rule
            }
            repeatDraft = rule
            if close { editingRepeat = false; releaseTaskFocus() }
        }
    }

    private func removeRepeat() {
        guard flushEdits() else { return }
        perform {
            try updateTask { $0.repeatRule = nil; $0.scheduleAnchor = nil }
            editingRepeat = false
            releaseTaskFocus()
        }
    }

    private func prepareDrag() -> Data? {
        guard !isDraft, !discardedDraft, store.data.tasks.contains(where: { $0.id == task.id }) else {
            return nil
        }
        guard flushEdits() else { return nil }
        do {
            return try JSONEncoder().encode(TaskDragItem(taskID: task.id))
        } catch {
            self.error = localizedError(error)
            return nil
        }
    }

    private func renderDragPreview() -> NSImage? {
        let renderer = ImageRenderer(content: dragPreview.environment(\.colorScheme, colorScheme).environment(\.appTextScale, textScale))
        renderer.scale = NSApp.keyWindow?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    @discardableResult private func flushEdits() -> Bool {
        let request = InlineFlushRequest(taskID: task.id)
        NotificationCenter.default.post(name: flushTaskEdits, object: request)
        if request.failed { error = L("请先修正正在编辑的内容，再继续操作。") }
        return !request.failed
    }

    private func releaseTaskFocus() {
        let request = InlineFlushRequest(taskID: task.id, resignFocus: true)
        NotificationCenter.default.post(name: flushTaskEdits, object: request)
        animateLayout {
            cardFocused = false; textEditingFocused = false; focusedAction = nil; focusedAttachment = nil
            hovered = false
        }
    }

    private func toggleDetails() {
        if showsDetails {
            guard finishTaskEditing() else { return }
            animateLayout { expandedOverride = false }
        } else { animateLayout { expandedOverride = true } }
    }

    private func beginTaskEditing() {
        expandedOverride = true
        if editingBaseline == nil { editingBaseline = latestTask }
    }

    private func animateLayout<Result>(_ changes: () throws -> Result) rethrows -> Result {
        // The shared transaction also animates following cards in the parent list.
        try withAnimation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.18), changes)
    }

    private func perform(_ work: () throws -> Void) {
        animateLayout {
            beginTaskEditing()
            do { try work(); error = nil }
            catch { self.error = localizedError(error) }
        }
    }

    private func stageTask(_ changes: (inout WorkTask) -> Void) {
        guard isDraft else { return }
        draft?.update(taskID: task.id, changes)
    }

    private func updateTask(_ changes: (inout WorkTask) -> Void) throws {
        guard !discardedDraft else { return }
        try animateLayout {
            beginTaskEditing()
            if isDraft {
                stageTask(changes)
            } else {
                try store.updateTask(id: task.id, changes)
            }
        }
    }

    @discardableResult private func persistTaskEditing() -> Bool {
        guard !discardedDraft, isDraft || store.data.tasks.contains(where: { $0.id == task.id }) else { return true }
        guard flushEdits() else { return false }
        if isDraft, latestTask.isEmptyDraft, stagedAttachments.isEmpty { return true }
        do {
            if draft?.task?.id == task.id { try commitDraft(finishCreation: false) }
            error = nil
            return true
        } catch { self.error = localizedError(error); return false }
    }

    @discardableResult private func finishTaskEditing() -> Bool {
        animateLayout {
            guard !discardedDraft, isDraft || store.data.tasks.contains(where: { $0.id == task.id }) else { return true }
            guard persistTaskEditing() else { return false }
            if isDraft, latestTask.isEmptyDraft, stagedAttachments.isEmpty {
                requestDelete()
                return true
            }
            let finishingCreation = draft?.task?.id == task.id
            let request = InlineFlushRequest(taskID: task.id, finishEditing: true)
            NotificationCenter.default.post(name: flushTaskEdits, object: request)
            guard !request.failed else { return false }
            detailsEditing = false; notesEditing = false; addingChild = false; editorsOpen = false
            dateEditor = nil; editingRepeat = false; planningExpanded = false
            cardFocused = false; focusedAction = nil; focusedAttachment = nil
            editingBaseline = nil; textHasChanges = false
            error = nil
            if finishingCreation { onCreated() }
            return true
        }
    }

    private func commitDraft(finishCreation: Bool = true) throws {
        guard var candidate = draft?.task, candidate.id == task.id else { return }
        if isDraft {
            candidate.title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.title.isEmpty else { throw LedgerError.invalid(L("请先填写任务名称。")) }
            try store.saveTask(candidate)
        }
        try importStagedAttachments()
        if finishCreation { onCreated() }
    }

    private func requestDelete() {
        if draft?.task?.id == task.id {
            do {
                if store.data.tasks.contains(where: { $0.id == task.id }) { _ = try store.deleteTask(id: task.id) }
                discardDraft()
            } catch { self.error = localizedError(error) }
        } else if flushEdits() { confirmDelete = true }
    }

    private func discardDraft() {
        discardedDraft = true
        NotificationCenter.default.post(name: discardTaskEdits, object: task.id)
        onCancel()
        if FileManager.default.fileExists(atPath: draftAttachmentDirectory.path) {
            do { try FileManager.default.removeItem(at: draftAttachmentDirectory) }
            catch { store.errorMessage = L("草稿已取消，但临时附件未能清理：\(localizedError(error))") }
        }
    }

    private func toggleCompletion() {
        guard flushEdits() else { return }
        if draft?.task?.id == task.id {
            do { try commitDraft() }
            catch { self.error = localizedError(error); return }
        }
        if latestTask.completedAt == nil {
            perform {
                let result = try store.completeTask(id: task.id, at: Date(), source: "interface")
                if !result.alreadyCompleted { TaskOperationEvent.completed(result).post() }
            }
        } else { undoCompletion() }
    }

    private func undoCompletion() {
        guard flushEdits() else { return }
        perform {
            try store.undoCompletion(id: task.id)
            if let restored = store.data.tasks.first(where: { $0.id == task.id }) { TaskOperationEvent.restored(restored).post() }
        }
    }

    private func toggleSubtask(_ id: UUID) {
        guard let before = latestTask.subtasks.first(where: { $0.id == id }) else { return }
        perform {
            if before.completedAt != nil {
                try store.undoSubtaskCompletion(taskID: task.id, subtaskID: id)
            } else if let result = try store.completeSubtask(taskID: task.id, subtaskID: id, source: "interface"), !result.alreadyCompleted {
                TaskOperationEvent.completed(result).post()
                return
            }
            guard let after = latestTask.subtasks.first(where: { $0.id == id }), before.completedAt != after.completedAt else { return }
            announceUndo(.subtaskCompletion(taskID: task.id, subtaskID: id, before: before.completedAt, after: after.completedAt),
                         message: after.completedAt == nil ? L("步骤已恢复未完成") : L("步骤已完成"), symbol: "checkmark.circle", name: L("步骤完成状态"))
        }
    }

    private func announceUndo(_ operation: TaskOperationUndo, message: String, symbol: String, name: String) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let undo = TaskUndoRecord(operation)
        undo.register(in: NSApp.keyWindow?.undoManager ?? undoManager, store: store, name: name)
        TaskOperationEvent.edited(task: latestTask, message: message, symbol: symbol, undo: undo).post()
    }

    private func beginAddingChild() {
        guard flushEdits() else { return }
        animateLayout { childInputID = UUID(); focusChildOnAppear = true; addingChild = true }
    }

    private func removeChild(_ id: UUID) throws {
        let before = latestTask
        guard let index = before.subtasks.firstIndex(where: { $0.id == id }) else { return }
        try updateTask { $0.subtasks.removeAll { $0.id == id } }
        if !isDraft {
            announceUndo(.removedSubtask(taskID: task.id, child: before.subtasks[index], index: index, parentCompletedAt: before.completedAt),
                         message: L("已移除步骤「\(before.subtasks[index].title)」"), symbol: "checklist", name: L("移除步骤"))
        }
    }

    private func saveChild(_ title: String, id: UUID) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || latestTask.subtasks.contains(where: { $0.id == id }) else { return }
        try animateLayout {
            try updateTask { latest in
                if name.isEmpty { latest.subtasks.removeAll { $0.id == id } }
                else if let index = latest.subtasks.firstIndex(where: { $0.id == id }) { latest.subtasks[index].title = name }
                else { latest.subtasks.append(Subtask(id: id, title: name, completedAt: latest.completedAt)) }
            }
            error = nil
        }
    }

    private func deleteTask() {
        guard flushEdits() else { return }
        do {
            let deleted = try store.deleteTask(id: task.id)
            // Attachment import can fail after the task is saved; do not leave a draft that can recreate it.
            if draft?.task?.id == task.id { discardDraft() }
            undoManager?.registerUndo(withTarget: store) { target in
                do { try target.restoreDeletedTask(deleted) }
                catch { target.errorMessage = L("无法撤销删除：\(localizedError(error))") }
            }
            undoManager?.setActionName(L("删除任务"))
        } catch { self.error = localizedError(error) }
    }

    @discardableResult private func addFiles(_ urls: [URL]) -> Bool {
        beginTaskEditing()
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try animateLayout {
                if isDraft { try stageAttachments(urls) }
                else { try store.addAttachments(urls: urls, to: task.id) }
            }
            error = nil
            return true
        } catch {
            self.error = localizedError(error)
            return false
        }
    }

    private var draftAttachmentDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerDraft-\(task.id.uuidString)", isDirectory: true)
    }

    private func stageAttachments(_ urls: [URL]) throws {
        let files = FileManager.default
        var copied: [DraftAttachment] = []
        do {
            for source in urls {
                let info = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true else { throw LedgerError.invalid(L("附件必须是文件：\(source.lastPathComponent)")) }
                let folder = draftAttachmentDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let destination = folder.appendingPathComponent(source.lastPathComponent)
                do {
                    try files.copyItem(at: source, to: destination)
                    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                } catch { try? files.removeItem(at: folder); throw error }
                copied.append(DraftAttachment(url: destination, size: Int64(info.fileSize ?? 0)))
            }
            stagedAttachments.append(contentsOf: copied)
        } catch {
            for attachment in copied { try? files.removeItem(at: attachment.url.deletingLastPathComponent()) }
            throw error
        }
    }

    private func loadStagedAttachments() {
        let files = FileManager.default
        guard files.fileExists(atPath: draftAttachmentDirectory.path) else { return }
        perform {
            var pending: [DraftAttachment] = []
            for folder in try files.contentsOfDirectory(at: draftAttachmentDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true else { continue }
                for file in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
                    let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { continue }
                    pending.append(DraftAttachment(url: file, size: Int64(metadata.fileSize ?? 0)))
                }
            }
            stagedAttachments = pending.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func importStagedAttachments() throws {
        guard !stagedAttachments.isEmpty else { return }
        try store.addAttachments(urls: stagedAttachments.map(\.url), to: task.id)
        stagedAttachments = []
        try? FileManager.default.removeItem(at: draftAttachmentDirectory)
    }

    private func openAttachment(_ attachment: Attachment) {
        if !NSWorkspace.shared.open(store.attachmentURL(attachment)) { error = L("无法打开附件，请检查文件是否存在，以及是否安装了对应的应用。") }
    }

    private func saveAttachment(_ attachment: Attachment) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = attachment.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform {
            let source = store.attachmentURL(attachment)
            guard source.standardizedFileURL != destination.standardizedFileURL else { return }
            let files = FileManager.default
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".workledger-export-\(UUID().uuidString)")
            defer { try? files.removeItem(at: temporary) }
            try files.copyItem(at: source, to: temporary)
            if files.fileExists(atPath: destination.path) { _ = try files.replaceItemAt(destination, withItemAt: temporary) }
            else { try files.moveItem(at: temporary, to: destination) }
        }
    }
}
