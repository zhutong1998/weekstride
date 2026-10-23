import AppKit
import SwiftUI
import XCTest
import WorkLedgerCore
@testable import WorkLedger

final class TaskDisplayRenderingTests: XCTestCase {
    @MainActor
    func testEnglishLargeCardsAndSettingsRenderWithoutRealData() async throws {
        guard let output = ProcessInfo.processInfo.environment["WORKLEDGER_RENDER_DIR"] else {
            throw XCTSkip("Set WORKLEDGER_RENDER_DIR to render synthetic interface fixtures.")
        }
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(arguments.merging([
            "appLanguage": "en", "appTextSize": "extraLarge", "appTimeFormat": "12",
            "taskColumns": "three", "taskDetails": "expanded", "taskListEffect": "none",
            "apiEnabled": false, "remindersEnabled": false
        ]) { _, fixture in fixture }, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedger-render-\(UUID())")
        let store = try WorkStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try store.addProject(name: "Website operations", colorHex: "168C83")
        let attachmentURL = directory.appendingPathComponent("attachments/example.txt")
        let bytes = Data("Synthetic visual fixture. No personal data.".utf8)
        try bytes.write(to: attachmentURL)
        let attachment = Attachment(name: "Certificate renewal and deployment checklist.txt", storedName: "example.txt", size: Int64(bytes.count))
        let today = Calendar.current.startOfDay(for: Date())
        let task = WorkTask(projectID: project.id, title: "Renew the production domain certificate and verify deployment",
                            details: "Check coverage for the primary domain and all subdomains. Verify the updated certificate chain and keep a rollback copy.",
                            notes: "Confirm the owner, record the outcome, and keep the next renewal date visible.",
                            subtasks: [Subtask(title: "Check domain ownership and expiration"), Subtask(title: "Deploy the renewed certificate"), Subtask(title: "Verify HTTPS and document the outcome")],
                            attachments: [attachment], dueAt: today.addingTimeInterval(86400), reminderAt: today.addingTimeInterval(18 * 3600),
                            repeatRule: RepeatRule(every: 6, unit: .month), plannedAt: today, planGranularity: .week)
        try store.saveTask(task)
        for index in 1...5 {
            let copy = WorkTask(projectID: project.id, title: "\(index). Verify an upcoming operational deadline",
                            details: index.isMultiple(of: 2) ? task.details : "Review the result and record the next action.",
                            notes: index.isMultiple(of: 3) ? task.notes : "", subtasks: index.isMultiple(of: 2) ? task.subtasks.map { Subtask(title: $0.title) } : [],
                            dueAt: today.addingTimeInterval(Double(index + 1) * 86400), plannedAt: today, planGranularity: .week)
            try store.saveTask(copy)
        }
        let services = AppServices(store: store, recoveryMode: true)
        let target = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        func card(_ mode: TaskDetailsMode, dark: Bool = false) -> some View {
            TaskCard(store: store, task: task, project: project, isHistory: false, languageIdentifier: "en", timeFormat: .twelveHour)
                .environmentObject(services)
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.appTextScale, 1.3)
                .environment(\.taskDetailsMode, mode)
                .environment(\.compactTaskPlan, true)
                .environment(\.colorScheme, dark ? .dark : .light)
                .padding(12).frame(width: 374)
                .background(dark ? Color(white: 0.12) : .white)
        }
        try await render(card(.expanded), width: 374, height: nil, to: target.appendingPathComponent("card-350-en-extra-large.png"))
        try await render(card(.titles), width: 374, height: nil, to: target.appendingPathComponent("card-350-en-extra-large-titles.png"))
        try await render(card(.expanded, dark: true), width: 374, height: nil, to: target.appendingPathComponent("card-350-en-extra-large-dark.png"))
        let settings = PreferencesView().environmentObject(store).environmentObject(services)
            .environment(\.locale, Locale(identifier: "en")).environment(\.appTextScale, 1.3)
            .environment(\.colorScheme, .light)
        try await render(settings, width: 900, height: 800, to: target.appendingPathComponent("settings-en-extra-large.png"))
        let datePicker = TaskDatePicker(initialDate: today.addingTimeInterval(18 * 3600), includesTime: true,
                                        title: L("提醒日期"), onConfirm: { _ in }, onCancel: {})
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.appTextScale, 1.3).environment(\.colorScheme, .light)
            .padding(12).frame(width: 484).background(.white)
        try await render(datePicker, width: 484, height: nil, to: target.appendingPathComponent("date-time-en-extra-large-12h.png"))
        defaults.setVolatileDomain(defaults.volatileDomain(forName: UserDefaults.argumentDomain).merging(["appTextSize": "standard"]) { _, value in value }, forName: UserDefaults.argumentDomain)
        let grid = RootView(store: store).environmentObject(store).environmentObject(services)
            .environment(\.locale, Locale(identifier: "en")).environment(\.appTextScale, 1)
            .environment(\.colorScheme, .light)
        try await render(grid, width: 1520, height: 1100, to: target.appendingPathComponent("three-columns-en.png"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("api-token").path), "Recovery-mode rendering must not initialize API credentials.")
    }

    @MainActor
    private func render<Content: View>(_ content: Content, width: CGFloat, height: CGFloat?, to url: URL) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 1600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: content)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let fitting = host.fittingSize
        let size = NSSize(width: width, height: height ?? max(80, fitting.height))
        window.setContentSize(size)
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        XCTAssertGreaterThan(png.count, 1000)
        XCTAssertFalse(window.isVisible, "Visual fixtures must never show or activate a desktop window.")
    }
}
