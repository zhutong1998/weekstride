import XCTest
@testable import WorkLedgerCore

@MainActor
final class TaskPlanningTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func calendar(_ timeZone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WorkLedgerPlanningTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testOldJSONLoadsWithoutPlanningFieldsOrMigrationWrites() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = Project(name: "旧项目")
        let task = WorkTask(projectID: project.id, title: "旧任务", dueAt: date("2024-01-31T12:00:00Z"), plannedAt: date("2024-01-04T00:00:00+08:00"), planGranularity: .week)
        let ledger = LedgerData(projects: [project], tasks: [task])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        var tasks = try XCTUnwrap(json["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "plannedAt")
        tasks[0].removeValue(forKey: "planGranularity")
        json["tasks"] = tasks
        let legacyData = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        let url = directory.appendingPathComponent("data.json")
        try legacyData.write(to: url)
        let store = try WorkStore(directory: directory)
        let loaded = try XCTUnwrap(store.data.tasks.first)
        XCTAssertNil(loaded.plannedAt)
        XCTAssertNil(loaded.planGranularity)
        XCTAssertEqual(loaded.dueAt, task.dueAt)
        XCTAssertEqual(loaded.planBucket(relativeTo: date("2024-01-04T12:00:00+08:00"), firstWeekday: 5, calendar: calendar()), .unscheduled)
        XCTAssertEqual(try Data(contentsOf: url), legacyData)
    }

    func testPlanningBucketsUseOnlyIndependentPlanningDateAndMergePastIntoThisWeek() async throws {
        let calendar = calendar()
        let today = date("2026-10-20T12:00:00+08:00")
        var task = WorkTask(projectID: UUID(), title: "独立安排", dueAt: date("2026-10-22T09:00:00+08:00"), reminderAt: today)
        XCTAssertEqual(task.planBucket(relativeTo: today, firstWeekday: 5, calendar: calendar), .unscheduled)
        XCTAssertFalse(task.isPlanOverdue(relativeTo: today, firstWeekday: 5, calendar: calendar))
        let cases: [(String, TaskPlanBucket)] = [
            ("2026-09-01T00:00:00+08:00", .thisWeek),
            ("2026-10-21T23:59:59+08:00", .thisWeek),
            ("2026-10-22T00:00:00+08:00", .nextWeek),
            ("2026-10-29T00:00:00+08:00", .weekAfterNext),
            ("2026-11-05T00:00:00+08:00", .later),
        ]
        for (planned, bucket) in cases {
            task.plannedAt = date(planned)
            XCTAssertEqual(task.planBucket(relativeTo: today, firstWeekday: 5, calendar: calendar), bucket)
            XCTAssertEqual(task.dueAt, date("2026-10-22T09:00:00+08:00"))
            XCTAssertEqual(task.reminderAt, today)
        }
        XCTAssertEqual(TaskPlanBucket.later.title, "后续")
        XCTAssertEqual(TaskPlanBucket.allCases.map(\.id).count, Set(TaskPlanBucket.allCases.map(\.id)).count)
    }

    func testWorkWeekStartChangesGroupingAndWeekPrecisionOverdueBoundary() async throws {
        let calendar = calendar()
        let monday = date("2026-10-19T12:00:00+08:00")
        let thursday = date("2026-10-22T00:00:00+08:00")
        var task = WorkTask(projectID: UUID(), title: "工作周", plannedAt: thursday, planGranularity: .week)
        XCTAssertEqual(task.planBucket(relativeTo: monday, firstWeekday: 5, calendar: calendar), .nextWeek)
        XCTAssertEqual(task.planBucket(relativeTo: monday, firstWeekday: 2, calendar: calendar), .thisWeek)
        task.plannedAt = date("2026-10-19T00:00:00+08:00")
        XCTAssertFalse(task.isPlanOverdue(relativeTo: thursday.addingTimeInterval(-1), firstWeekday: 5, calendar: calendar))
        XCTAssertTrue(task.isPlanOverdue(relativeTo: thursday, firstWeekday: 5, calendar: calendar))
        XCTAssertFalse(task.isPlanOverdue(relativeTo: thursday, firstWeekday: 2, calendar: calendar))
        XCTAssertEqual(task.planBucket(relativeTo: thursday, firstWeekday: 5, calendar: calendar), .thisWeek)
    }

    func testDayAndWeekOverdueUseDistinctPrecisionAndIgnoreCompletedTasks() async throws {
        let calendar = calendar()
        let today = date("2026-10-20T12:00:00+08:00")
        var task = WorkTask(projectID: UUID(), title: "安排精度", plannedAt: date("2026-10-19T23:00:00+08:00"))
        XCTAssertTrue(task.isPlanOverdue(relativeTo: today, firstWeekday: 5, calendar: calendar))
        task.planGranularity = .day
        XCTAssertTrue(task.isPlanOverdue(relativeTo: today, firstWeekday: 5, calendar: calendar))
        task.planGranularity = .week
        XCTAssertFalse(task.isPlanOverdue(relativeTo: today, firstWeekday: 5, calendar: calendar))
        task.planGranularity = .day
        task.plannedAt = date("2026-10-20T00:00:00+08:00")
        XCTAssertFalse(task.isPlanOverdue(relativeTo: today, firstWeekday: 5, calendar: calendar))
        task.plannedAt = date("2026-10-01T00:00:00+08:00")
        task.completedAt = today
        XCTAssertFalse(task.isPlanOverdue(relativeTo: today, firstWeekday: 5, calendar: calendar))
        task.completedAt = nil
        task.plannedAt = nil
        task.planGranularity = nil
        task.dueAt = date("2026-10-01T00:00:00+08:00")
        XCTAssertFalse(task.isPlanOverdue(relativeTo: today, firstWeekday: 5, calendar: calendar))
    }

    func testReplanningOverdueTasksToThisOrNextWeekClearsOverdueAndPersistsOnlyPlanChanges() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let calendar = calendar()
        let today = date("2026-10-20T12:00:00+08:00")
        let oldPlans: [(Date, TaskPlanGranularity)] = [
            (date("2026-10-19T00:00:00+08:00"), .day),
            (date("2026-10-01T00:00:00+08:00"), .week),
        ]
        for weekStart in [5, 2] {
            for (oldDate, oldPrecision) in oldPlans {
                for offset in 0...1 {
                    let task = WorkTask(title: "重新安排", subtasks: [Subtask(title: "已完成步骤", completedAt: oldDate)], dueAt: date("2026-10-18T00:00:00+08:00"), reminderAt: date("2026-10-17T09:00:00+08:00"), plannedAt: oldDate, planGranularity: oldPrecision)
                    try store.saveTask(task)
                    let original = try XCTUnwrap(store.data.tasks.first { $0.id == task.id })
                    XCTAssertTrue(original.isPlanOverdue(relativeTo: today, firstWeekday: weekStart, calendar: calendar))
                    let target = TaskPlanning.weekDate(offset: offset, relativeTo: today, firstWeekday: weekStart, calendar: calendar)
                    try store.updateTask(id: task.id) {
                        $0.plannedAt = target
                        $0.planGranularity = .week
                    }
                    let reloaded = try XCTUnwrap(WorkStore(directory: directory).data.tasks.first { $0.id == task.id })
                    var expected = original
                    expected.plannedAt = target
                    expected.planGranularity = .week
                    expected.updatedAt = reloaded.updatedAt
                    XCTAssertEqual(reloaded, expected)
                    XCTAssertFalse(reloaded.isPlanOverdue(relativeTo: today, firstWeekday: weekStart, calendar: calendar))
                    XCTAssertEqual(reloaded.planBucket(relativeTo: today, firstWeekday: weekStart, calendar: calendar), offset == 0 ? .thisWeek : .nextWeek)
                    let end = WorkPeriod.range(containing: target, firstWeekday: weekStart, calendar: calendar).end
                    XCTAssertFalse(reloaded.isPlanOverdue(relativeTo: end.addingTimeInterval(-1), firstWeekday: weekStart, calendar: calendar))
                    XCTAssertTrue(reloaded.isPlanOverdue(relativeTo: end, firstWeekday: weekStart, calendar: calendar))
                }
            }
        }
    }

    func testWeekChoicesAndBucketsCrossYearWithoutChangingWeekday() async throws {
        let calendar = calendar()
        let today = date("2026-12-31T16:00:00+08:00")
        let expected: [(Int, String, TaskPlanBucket)] = [
            (0, "2026-12-31T00:00:00+08:00", .thisWeek),
            (1, "2027-01-07T00:00:00+08:00", .nextWeek),
            (2, "2027-01-14T00:00:00+08:00", .weekAfterNext),
            (3, "2027-01-21T00:00:00+08:00", .later),
        ]
        for (offset, value, bucket) in expected {
            let planned = TaskPlanning.weekDate(offset: offset, relativeTo: today, firstWeekday: 5, calendar: calendar)
            XCTAssertEqual(planned, date(value))
            XCTAssertEqual(calendar.component(.weekday, from: planned), calendar.component(.weekday, from: today))
            let task = WorkTask(projectID: UUID(), title: "跨年", plannedAt: planned, planGranularity: .week)
            XCTAssertEqual(task.planBucket(relativeTo: today, firstWeekday: 5, calendar: calendar), bucket)
        }
    }

    func testWeekChoicesUseCalendarDaysAcrossBothDSTTransitions() async throws {
        let calendar = calendar("America/Los_Angeles")
        let cases: [(String, String, TimeInterval)] = [
            ("2024-03-07T12:00:00-08:00", "2024-03-14T00:00:00-07:00", 167 * 3600),
            ("2024-10-31T12:00:00-07:00", "2024-11-07T00:00:00-08:00", 169 * 3600),
        ]
        for (start, expected, seconds) in cases {
            let today = date(start)
            let planned = TaskPlanning.weekDate(offset: 1, relativeTo: today, firstWeekday: 5, calendar: calendar)
            XCTAssertEqual(planned, date(expected))
            XCTAssertEqual(planned.timeIntervalSince(calendar.startOfDay(for: today)), seconds)
            let task = WorkTask(projectID: UUID(), title: "夏令时", plannedAt: planned, planGranularity: .week)
            XCTAssertEqual(task.planBucket(relativeTo: today, firstWeekday: 5, calendar: calendar), .nextWeek)
            XCTAssertFalse(task.isPlanOverdue(relativeTo: planned, firstWeekday: 5, calendar: calendar))
            let end = WorkPeriod.range(containing: planned, firstWeekday: 5, calendar: calendar).end
            XCTAssertTrue(task.isPlanOverdue(relativeTo: end, firstWeekday: 5, calendar: calendar))
        }
    }

    func testPlanningPersistsButNewRecurringOccurrenceNeedsItsOwnPlan() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkStore(directory: directory)
        let project = try store.addProject(name: "循环计划")
        let planned = date("2024-01-04T00:00:00+08:00")
        let due = date("2024-01-31T12:00:00Z")
        let reminder = due.addingTimeInterval(-7 * 86400)
        let task = WorkTask(projectID: project.id, title: "每月维护", dueAt: due, reminderAt: reminder, repeatRule: RepeatRule(every: 1, unit: .month, basis: .schedule), plannedAt: planned, planGranularity: .week)
        try store.saveTask(task)
        let loaded = try WorkStore(directory: directory)
        XCTAssertEqual(loaded.data.tasks[0].plannedAt, planned)
        XCTAssertEqual(loaded.data.tasks[0].planGranularity, .week)
        let result = try loaded.completeTask(id: task.id, at: due)
        XCTAssertEqual(result.task.plannedAt, planned)
        XCTAssertEqual(result.task.planGranularity, .week)
        let next = try XCTUnwrap(result.nextTask)
        XCTAssertNil(next.plannedAt)
        XCTAssertNil(next.planGranularity)
        XCTAssertEqual(next.dueAt, Calendar.current.date(byAdding: .month, value: 1, to: due))
        XCTAssertEqual(next.reminderAt?.timeIntervalSince(try XCTUnwrap(next.dueAt)), -7 * 86400)
        XCTAssertEqual(try WorkStore(directory: directory).data, loaded.data)
        let before = loaded.data
        XCTAssertThrowsError(try loaded.updateTask(id: task.id) { $0.plannedAt = nil })
        XCTAssertEqual(loaded.data, before)
        XCTAssertThrowsError(try loaded.updateTask(id: task.id) { $0.plannedAt = Date(timeIntervalSince1970: .infinity) })
        XCTAssertEqual(loaded.data, before)
        try loaded.updateTask(id: task.id) { $0.plannedAt = nil; $0.planGranularity = nil }
        XCTAssertNil(loaded.data.tasks.first(where: { $0.id == task.id })?.plannedAt)
    }

    func testPlanFiltersUseOnlyPlanningDateAndOnlyThisWeekCarriesOldPlansForward() async throws {
        let calendar = calendar()
        let today = date("2026-10-20T12:00:00+08:00")
        let filters: [TaskPlanFilter] = [.all, .thisWeek, .nextWeek, .week(today), .unscheduled]
        let cases: [(Date?, Set<TaskPlanFilter>)] = [
            (nil, [.all, .unscheduled]),
            (date("2026-09-01T00:00:00+08:00"), [.all, .thisWeek]),
            (date("2026-10-21T23:59:59+08:00"), [.all, .thisWeek, .week(today)]),
            (date("2026-10-22T00:00:00+08:00"), [.all, .nextWeek]),
            (date("2026-10-29T00:00:00+08:00"), [.all]),
        ]
        for (plannedAt, expected) in cases {
            let task = WorkTask(title: "只看计划", dueAt: today, reminderAt: today.addingTimeInterval(30 * 86400), plannedAt: plannedAt)
            let original = task
            let matching = Set(filters.filter {
                $0.includes(task, relativeTo: today, firstWeekday: 5, calendar: calendar)
            })
            XCTAssertEqual(matching, expected)
            XCTAssertEqual(task, original)
        }
        XCTAssertEqual(filters.map(\.id), filters)
    }

    func testSpecificWeekFilterRespectsWeekStartAndExclusiveEnd() async throws {
        let calendar = calendar()
        let selected = date("2026-10-21T12:00:00+08:00")
        let cases = [
            (5, date("2026-10-15T00:00:00+08:00"), date("2026-10-22T00:00:00+08:00")),
            (2, date("2026-10-19T00:00:00+08:00"), date("2026-10-26T00:00:00+08:00")),
        ]
        for (weekStart, start, end) in cases {
            for (plannedAt, expected) in [(start.addingTimeInterval(-1), false), (start, true), (end.addingTimeInterval(-1), true), (end, false)] {
                let task = WorkTask(title: "精确工作周", plannedAt: plannedAt, planGranularity: .week)
                XCTAssertEqual(TaskPlanFilter.week(selected).includes(task, relativeTo: selected, firstWeekday: weekStart, calendar: calendar), expected)
            }
        }
        let thursday = WorkTask(title: "周四", plannedAt: date("2026-10-22T00:00:00+08:00"))
        XCTAssertFalse(TaskPlanFilter.week(selected).includes(thursday, firstWeekday: 5, calendar: calendar))
        XCTAssertTrue(TaskPlanFilter.week(selected).includes(thursday, firstWeekday: 2, calendar: calendar))
        XCTAssertTrue(TaskPlanFilter.week(try XCTUnwrap(thursday.plannedAt)).includes(thursday, firstWeekday: 5, calendar: calendar))
    }

    func testCompletedPlanFiltersUseActualCompletionWeekInsteadOfOriginalPlan() async throws {
        let calendar = calendar()
        let today = date("2026-10-21T12:00:00+08:00")
        let priorWeek = TaskPlanFilter.week(date("2026-10-08T00:00:00+08:00"))
        let currentWeek = TaskPlanFilter.week(date("2026-10-15T00:00:00+08:00"))
        let filters: [TaskPlanFilter] = [.all, .thisWeek, .nextWeek, priorWeek, currentWeek, .unscheduled]
        for plannedAt in [nil, date("2026-10-01T00:00:00+08:00"), today, date("2026-11-05T00:00:00+08:00")] {
            var task = WorkTask(title: "以实际完成归属", completedAt: today, plannedAt: plannedAt)
            let original = task
            XCTAssertEqual(TaskPlanFilter(task: task, relativeTo: today, firstWeekday: 5, calendar: calendar), .thisWeek)
            XCTAssertEqual(Set(filters.filter { $0.includes(task, relativeTo: today, firstWeekday: 5, calendar: calendar) }), Set([.all, .thisWeek, currentWeek]))
            XCTAssertEqual(task, original, "Grouping must not rewrite the original plan")
            task.completedAt = date("2026-10-14T23:59:59+08:00")
            XCTAssertEqual(TaskPlanFilter(task: task, relativeTo: today, firstWeekday: 5, calendar: calendar), priorWeek)
            XCTAssertEqual(Set(filters.filter { $0.includes(task, relativeTo: today, firstWeekday: 5, calendar: calendar) }), Set([.all, priorWeek]), "Past completions do not carry into this week")
        }
    }

    func testCompletedOnlyWeeksRemainInOptionsAndRespectWeekStartAndBoundary() async throws {
        let calendar = calendar()
        let today = date("2026-10-21T12:00:00+08:00")
        let sunday = WorkTask(title: "只有完成任务的周", completedAt: date("2026-10-18T12:00:00+08:00"))
        let thursdayEnd = WorkTask(title: "工作周结束瞬间", completedAt: date("2026-10-22T00:00:00+08:00"), plannedAt: today)
        let oldWeek = TaskPlanFilter.week(date("2026-10-12T00:00:00+08:00"))
        XCTAssertEqual(TaskPlanFilter(task: sunday, relativeTo: today, firstWeekday: 5, calendar: calendar), .thisWeek)
        XCTAssertEqual(TaskPlanFilter(task: sunday, relativeTo: today, firstWeekday: 2, calendar: calendar), oldWeek)
        XCTAssertEqual(TaskPlanFilter.options(for: [sunday], relativeTo: today, firstWeekday: 2, calendar: calendar), [.all, .thisWeek, .nextWeek, oldWeek, .unscheduled])
        XCTAssertTrue(oldWeek.includes(sunday, relativeTo: today, firstWeekday: 2, calendar: calendar))
        XCTAssertFalse(TaskPlanFilter.thisWeek.includes(sunday, relativeTo: today, firstWeekday: 2, calendar: calendar))
        XCTAssertEqual(TaskPlanFilter(task: thursdayEnd, relativeTo: today, firstWeekday: 5, calendar: calendar), .nextWeek)
        XCTAssertFalse(TaskPlanFilter.thisWeek.includes(thursdayEnd, relativeTo: today, firstWeekday: 5, calendar: calendar))
        XCTAssertTrue(TaskPlanFilter.nextWeek.includes(thursdayEnd, relativeTo: today, firstWeekday: 5, calendar: calendar))
        var lastSecond = thursdayEnd
        lastSecond.completedAt = thursdayEnd.completedAt!.addingTimeInterval(-1)
        XCTAssertEqual(TaskPlanFilter(task: lastSecond, relativeTo: today, firstWeekday: 5, calendar: calendar), .thisWeek)
    }

    func testBulkPlanQueriesPreserveCompletionWeeksAndCalendarBoundaries() async throws {
        let cases = [
            ("Asia/Shanghai", 5, "2026-10-21T12:00:00+08:00", "2026-10-15T00:00:00+08:00", "2026-10-22T00:00:00+08:00", "2026-10-29T00:00:00+08:00", "2026-10-08T00:00:00+08:00"),
            ("America/Los_Angeles", 5, "2024-03-10T12:00:00-07:00", "2024-03-07T00:00:00-08:00", "2024-03-14T00:00:00-07:00", "2024-03-21T00:00:00-07:00", "2024-02-29T00:00:00-08:00"),
            ("America/Los_Angeles", 2, "2024-11-03T12:00:00-08:00", "2024-10-28T00:00:00-07:00", "2024-11-04T00:00:00-08:00", "2024-11-11T00:00:00-08:00", "2024-10-21T00:00:00-07:00"),
        ]
        for (zone, weekStart, reference, start, end, followingEnd, priorStart) in cases {
            let calendar = calendar(zone), today = date(reference)
            let start = date(start), end = date(end), followingEnd = date(followingEnd)
            let pendingOld = WorkTask(title: "旧待办继续本周", plannedAt: start.addingTimeInterval(-1))
            let pendingStart = WorkTask(title: "本周开始", plannedAt: start)
            let pendingLast = WorkTask(title: "本周最后一秒", plannedAt: end.addingTimeInterval(-1))
            let pendingNext = WorkTask(title: "下周开始", plannedAt: end)
            let pendingNextLast = WorkTask(title: "下周最后一秒", plannedAt: followingEnd.addingTimeInterval(-1))
            let pendingLater = WorkTask(title: "下下周开始", plannedAt: followingEnd)
            let unplanned = WorkTask(title: "尚未安排")
            let completedOld = WorkTask(title: "旧完成不并本周", completedAt: start.addingTimeInterval(-1), plannedAt: today)
            let completedUnplanned = WorkTask(title: "未安排按完成周", completedAt: today)
            let completedFuturePlan = WorkTask(title: "未来计划提前完成", completedAt: today, plannedAt: followingEnd)
            let tasks = [pendingLater, completedOld, unplanned, completedUnplanned, pendingNext, pendingOld, completedFuturePlan, pendingNextLast, pendingStart, pendingLast]
            let original = tasks
            let prior = TaskPlanFilter.week(date(priorStart)), later = TaskPlanFilter.week(followingEnd)
            let currentIDs = Set([pendingOld.id, pendingStart.id, pendingLast.id, completedUnplanned.id, completedFuturePlan.id])
            let expected: [(TaskPlanFilter, Set<UUID>)] = [
                (.all, Set(tasks.map(\.id))),
                (.thisWeek, currentIDs),
                (.nextWeek, Set([pendingNext.id, pendingNextLast.id])),
                (.week(start), currentIDs.subtracting([pendingOld.id])),
                (prior, Set([pendingOld.id, completedOld.id])),
                (later, Set([pendingLater.id])),
                (.unscheduled, Set([unplanned.id])),
            ]
            for (filter, ids) in expected {
                let matches = filter.predicate(relativeTo: today, firstWeekday: weekStart, calendar: calendar)
                XCTAssertEqual(Set(tasks.filter(matches).map(\.id)), ids, "\(zone), \(filter)")
                XCTAssertEqual(tasks.map(matches), tasks.map { filter.includes($0, relativeTo: today, firstWeekday: weekStart, calendar: calendar) })
            }
            let groups = TaskPlanFilter.grouped(for: tasks, relativeTo: today, firstWeekday: weekStart, calendar: calendar)
            XCTAssertEqual(groups.map(\.filter), [.thisWeek, .nextWeek, prior, later, .unscheduled])
            XCTAssertEqual(Set(groups.flatMap(\.tasks).map(\.id)), Set(tasks.map(\.id)))
            XCTAssertEqual(groups.flatMap(\.tasks).count, tasks.count, "Every task appears once")
            for group in groups {
                let individual = tasks.filter { TaskPlanFilter(task: $0, relativeTo: today, firstWeekday: weekStart, calendar: calendar) == group.filter }
                XCTAssertEqual(group.tasks.map(\.id), individual.map(\.id), "Grouping preserves input order inside each bucket")
            }
            XCTAssertEqual(tasks, original)
        }
    }

    func testBulkGroupingOmitsEmptyBucketsWithoutHidingCompletedOnlyWeeks() async throws {
        let calendar = calendar(), today = date("2026-10-21T12:00:00+08:00")
        XCTAssertTrue(TaskPlanFilter.grouped(for: [], relativeTo: today, firstWeekday: 5, calendar: calendar).isEmpty)
        let task = WorkTask(title: "没有计划的上周完成项", completedAt: date("2026-10-14T12:00:00+08:00"))
        let filter = TaskPlanFilter.week(date("2026-10-08T00:00:00+08:00"))
        let groups = TaskPlanFilter.grouped(for: [task], relativeTo: today, firstWeekday: 5, calendar: calendar)
        XCTAssertEqual(groups.map(\.filter), [filter])
        XCTAssertEqual(groups.first?.tasks.map(\.id), [task.id])
        XCTAssertEqual(TaskPlanFilter.options(for: [task], relativeTo: today, firstWeekday: 5, calendar: calendar), [.all, .thisWeek, .nextWeek, filter, .unscheduled])
    }

    func testSpecificWeekFilterUsesCalendarBoundariesAcrossYearAndDST() async throws {
        let cases = [
            ("Asia/Shanghai", "2026-12-31T12:00:00+08:00", "2026-12-31T00:00:00+08:00", "2027-01-07T00:00:00+08:00"),
            ("America/Los_Angeles", "2024-03-10T12:00:00-07:00", "2024-03-07T00:00:00-08:00", "2024-03-14T00:00:00-07:00"),
            ("America/Los_Angeles", "2024-11-03T12:00:00-08:00", "2024-10-31T00:00:00-07:00", "2024-11-07T00:00:00-08:00"),
        ]
        for (zone, selected, start, end) in cases {
            for (plannedAt, expected) in [(date(start), true), (date(end).addingTimeInterval(-1), true), (date(end), false)] {
                let task = WorkTask(title: "日历边界", plannedAt: plannedAt)
                XCTAssertEqual(TaskPlanFilter.week(date(selected)).includes(task, relativeTo: date("2026-10-20T12:00:00+08:00"), firstWeekday: 5, calendar: calendar(zone)), expected)
            }
        }
    }

    func testPlanFilterOptionsIncludeOnlyOccupiedFutureWeeksAndRecomputeForWeekStart() async throws {
        let calendar = calendar()
        let today = date("2026-10-19T12:00:00+08:00")
        let tasks = [
            WorkTask(title: "更远的周", plannedAt: date("2026-11-20T12:00:00+08:00")),
            WorkTask(title: "旧计划", plannedAt: date("2026-10-01T12:00:00+08:00")),
            WorkTask(title: "同一未来周", plannedAt: date("2026-11-19T00:00:00+08:00")),
            WorkTask(title: "下下周", plannedAt: date("2026-10-29T00:00:00+08:00")),
            WorkTask(title: "换起始日后分到新周", plannedAt: date("2026-11-02T12:00:00+08:00")),
            WorkTask(title: "未来计划已于本周完成", completedAt: today, plannedAt: date("2026-11-05T00:00:00+08:00")),
            WorkTask(title: "下周", plannedAt: date("2026-10-22T00:00:00+08:00")),
            WorkTask(title: "仅有提醒和截止日期", dueAt: date("2026-12-31T00:00:00+08:00"), reminderAt: date("2026-12-30T00:00:00+08:00")),
        ]
        let expected: [TaskPlanFilter] = [.all, .thisWeek, .nextWeek, .week(date("2026-10-29T00:00:00+08:00")), .week(date("2026-11-19T00:00:00+08:00")), .unscheduled]
        XCTAssertEqual(TaskPlanFilter.options(for: tasks, relativeTo: today, firstWeekday: 5, calendar: calendar), expected)
        XCTAssertEqual(TaskPlanFilter.options(for: Array(tasks.reversed()), relativeTo: today, firstWeekday: 5, calendar: calendar), expected)
        let groups = Dictionary(grouping: tasks) { TaskPlanFilter(task: $0, relativeTo: today, firstWeekday: 5, calendar: calendar) }
        XCTAssertEqual(Set(groups.keys), Set(expected.dropFirst()))
        XCTAssertEqual(groups[.week(date("2026-10-29T00:00:00+08:00"))]?.count, 2)
        XCTAssertEqual(TaskPlanFilter.options(for: tasks, relativeTo: today, firstWeekday: 2, calendar: calendar), [.all, .thisWeek, .nextWeek, .week(date("2026-11-02T00:00:00+08:00")), .week(date("2026-11-16T00:00:00+08:00")), .unscheduled])
        XCTAssertEqual(TaskPlanFilter.options(for: [], relativeTo: today, firstWeekday: 5, calendar: calendar), [.all, .thisWeek, .nextWeek, .unscheduled])
    }

    func testPlanFilterOptionsRetainSelectedWeekAfterItsLastTaskCompletes() async throws {
        let calendar = calendar()
        let today = date("2026-10-20T12:00:00+08:00")
        let selected = TaskPlanFilter.week(date("2026-11-05T00:00:00+08:00"))
        var task = WorkTask(title: "未来周最后一项", plannedAt: date("2026-11-07T12:00:00+08:00"))
        let expected: [TaskPlanFilter] = [.all, .thisWeek, .nextWeek, selected, .unscheduled]
        XCTAssertEqual(TaskPlanFilter.options(for: [task], relativeTo: today, firstWeekday: 5, calendar: calendar, including: selected), expected)
        task.completedAt = today
        let openTasks = [task].filter { $0.completedAt == nil }
        XCTAssertEqual(TaskPlanFilter.options(for: openTasks, relativeTo: today, firstWeekday: 5, calendar: calendar, including: selected), expected)
        XCTAssertEqual(TaskPlanFilter.options(for: openTasks, relativeTo: today, firstWeekday: 5, calendar: calendar), [.all, .thisWeek, .nextWeek, .unscheduled])
    }

    func testSelectedWeekIsNormalizedDeduplicatedAndSortedWithOccupiedWeeks() async throws {
        let calendar = calendar()
        let today = date("2026-10-20T12:00:00+08:00")
        let tasks = [
            WorkTask(title: "更远的周", plannedAt: date("2026-11-20T12:00:00+08:00")),
            WorkTask(title: "所选周", plannedAt: date("2026-11-06T09:00:00+08:00")),
            WorkTask(title: "较近的周", plannedAt: date("2026-10-30T12:00:00+08:00")),
        ]
        let expected: [TaskPlanFilter] = [.all, .thisWeek, .nextWeek, .week(date("2026-10-29T00:00:00+08:00")), .week(date("2026-11-05T00:00:00+08:00")), .week(date("2026-11-19T00:00:00+08:00")), .unscheduled]
        XCTAssertEqual(TaskPlanFilter.options(for: tasks, relativeTo: today, firstWeekday: 5, calendar: calendar, including: .week(date("2026-11-08T23:59:59+08:00"))), expected)
    }

    func testSelectedNamedWeekUsesConfiguredWeekStartWithoutChangingSemanticFilters() async throws {
        let calendar = calendar()
        let today = date("2026-10-20T12:00:00+08:00")
        let selected = TaskPlanFilter.week(date("2026-11-04T12:00:00+08:00"))
        for (weekStart, start) in [(5, "2026-10-29T00:00:00+08:00"), (2, "2026-11-02T00:00:00+08:00")] {
            XCTAssertEqual(TaskPlanFilter.options(for: [], relativeTo: today, firstWeekday: weekStart, calendar: calendar, including: selected), [.all, .thisWeek, .nextWeek, .week(date(start)), .unscheduled])
        }
        let past = date("2026-10-01T00:00:00+08:00")
        XCTAssertEqual(TaskPlanFilter.options(for: [], relativeTo: today, firstWeekday: 5, calendar: calendar, including: .week(past)), [.all, .thisWeek, .nextWeek, .week(past), .unscheduled])
        for selected in [TaskPlanFilter.all, .thisWeek, .nextWeek, .unscheduled] {
            XCTAssertEqual(TaskPlanFilter.options(for: [], relativeTo: today, firstWeekday: 5, calendar: calendar, including: selected), [.all, .thisWeek, .nextWeek, .unscheduled])
        }
    }
}
