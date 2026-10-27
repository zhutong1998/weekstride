import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import WorkLedgerCore

struct TaskListStructure: Equatable {
    struct Task: Equatable {
        let id: UUID
        let projectID: UUID?
        let tagIDs: [UUID]
        let isStarred: Bool
        let plannedAt: Date?
        let planGranularity: TaskPlanGranularity?
        let dueAt: Date?
        let reminderAt: Date?
        let completedAt: Date?
        let createdAt: Date

        init(_ task: WorkTask) {
            id = task.id; projectID = task.projectID
            tagIDs = task.tagIDs; isStarred = task.isStarred
            plannedAt = task.plannedAt; planGranularity = task.planGranularity
            dueAt = task.dueAt; reminderAt = task.reminderAt; completedAt = task.completedAt; createdAt = task.createdAt
        }
    }

    let projects: [Project]
    let tags: [TaskTag]
    let tasks: [Task]
    let matchingTaskIDs: Set<UUID>?
    let presentationData: LedgerData

    init(data: LedgerData, search: String = "") {
        presentationData = data
        projects = data.projects
        tags = data.tags
        tasks = data.tasks.map(Task.init)
        matchingTaskIDs = search.isEmpty ? nil : Set(data.tasks.filter {
            Self.matches($0, projects: data.projects, tags: data.tags, search: search)
        }.map(\.id))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projects == rhs.projects && lhs.tags == rhs.tags && lhs.tasks == rhs.tasks && lhs.matchingTaskIDs == rhs.matchingTaskIDs
    }

    func needsCompletionFeedback(comparedTo previous: Self, visibleIDs: Set<UUID>) -> Bool {
        let pending = Set(previous.tasks.filter { $0.completedAt == nil && visibleIDs.contains($0.id) }.map(\.id))
        return tasks.contains { pending.contains($0.id) && $0.completedAt != nil }
    }

    func removesTask(_ id: UUID, comparedTo previous: Self) -> Bool {
        previous.tasks.contains { $0.id == id } && !tasks.contains { $0.id == id }
    }

    static func matches(_ task: WorkTask, projects: [Project], tags: [TaskTag] = [], search: String) -> Bool {
        guard !search.isEmpty else { return true }
        let projectName = projects.first { $0.id == task.projectID }?.name ?? ""
        let tagNames = tags.filter { task.tagIDs.contains($0.id) }.map(\.name)
        let text = [task.title, task.details, task.notes, projectName] + tagNames + task.subtasks.map(\.title) + task.attachments.map(\.name)
        return text.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    @MainActor static func changes(in store: WorkStore, search: String = "") -> AnyPublisher<Self, Never> {
        store.$data.map { Self(data: $0, search: search) }.removeDuplicates().eraseToAnyPublisher()
    }
}

@MainActor
final class TaskDraftStorage {
    let changes = CurrentValueSubject<WorkTask?, Never>(nil)
    var task: WorkTask? {
        get { changes.value }
        set { if changes.value != newValue { changes.send(newValue) } }
    }
}

@MainActor
final class TaskEditingRegistry {
    private var states: [UUID: TaskCardEditingState] = [:]
    private var observer: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: finishTaskEdits, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let request = note.object as? TaskEditingExitRequest else { return }
                self?.finish(request)
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(TaskEditingExitRequest()) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    private func finish(_ request: TaskEditingExitRequest) {
        for (id, state) in Array(states) where request.targets(id) {
            if let finish = state.finishHandler, !finish() { request.fail(for: id) }
        }
    }

    func state(for task: WorkTask, isDraft: Bool, initiallyExpanded: Bool) -> TaskCardEditingState {
        if let state = states[task.id] { return state }
        let state = TaskCardEditingState(task: task, isDraft: isDraft, initiallyExpanded: initiallyExpanded)
        states[task.id] = state
        return state
    }

    func retainTasks(_ ids: Set<UUID>) {
        for id in states.keys.filter({ !ids.contains($0) }) {
            guard let state = states.removeValue(forKey: id) else { continue }
            state.finishHandler = nil; state.discardFields()
        }
    }

    func removeAll() {
        for state in states.values { state.finishHandler = nil; state.discardFields() }
        states.removeAll()
    }

    func resetExpansion() {
        for state in states.values { state.expandedOverride = nil }
    }
}

enum TaskListRow: Identifiable {
    case week(TaskPlanFilter, Int, String)
    case project(Project?, Int, String)
    case completed(Int)
    case starred(Int, String)
    case task(WorkTask, Project?)

    var id: String {
        switch self {
        case .week(let filter, _, let section): return "week:\(section):\(filter)"
        case .project(let project, _, let group): return "project:\(group):\(project?.id.uuidString ?? "none")"
        case .completed: return "completed"
        case .starred(_, let section): return "starred:\(section)"
        case .task(let task, _): return "task:\(task.id)"
        }
    }

    static func rows(for tasks: [WorkTask], projects: [Project], scope: SidebarItem, filter: TaskPlanFilter,
                     relativeTo today: Date, firstWeekday: Int, draft: WorkTask? = nil) -> [Self] {
        func cards(_ tasks: [WorkTask]) -> [Self] {
            tasks.map { task in .task(task, projects.first { $0.id == task.projectID }) }
        }
        func groups(_ tasks: [WorkTask]) -> [(Project?, [WorkTask])] {
            let byProject = Dictionary(grouping: tasks, by: \.projectID)
            var result: [(Project?, [WorkTask])] = projects.compactMap { project in
                guard let values = byProject[project.id], !values.isEmpty else { return nil }
                return (project, values)
            }
            if let unassigned = byProject[nil], !unassigned.isEmpty { result.append((nil, unassigned)) }
            return result
        }
        func grouped(_ tasks: [WorkTask], section: String) -> [Self] {
            if scope == .completed {
                return groups(tasks).flatMap { project, tasks in
                    [.project(project, tasks.count, section)] + cards(tasks)
                }
            }
            return TaskPlanFilter.grouped(for: tasks, relativeTo: today, firstWeekday: firstWeekday).flatMap { week, tasks -> [Self] in
                var rows: [Self] = filter == .all ? [.week(week, tasks.count, section)] : []
                for (project, values) in groups(tasks) {
                    if project.map({ scope == .project($0.id) }) != true {
                        rows.append(.project(project, values.count, "\(section):\(week)"))
                    }
                    rows += cards(values)
                }
                return rows
            }
        }
        func prioritized(_ tasks: [WorkTask], section: String) -> [Self] {
            let stars = tasks.filter(\.isStarred)
            let pinned: [Self] = stars.isEmpty ? [] : [.starred(stars.count, section)] + cards(stars)
            return pinned + grouped(tasks.filter { !$0.isStarred }, section: section)
        }
        let tasks = tasks.filter { $0.id != draft?.id }
        let drafts = draft.map { cards([$0]) } ?? []
        if scope == .completed { return prioritized(tasks, section: "history") }
        let pending = tasks.filter { $0.completedAt == nil }
        let completed = tasks.filter { $0.completedAt != nil }
        if TaskListPolicy.isTimeSensitive(scope) {
            return drafts + cards(pending) + (completed.isEmpty ? [] : [.completed(completed.count)] + cards(completed))
        }
        return drafts + prioritized(pending, section: "pending")
            + (completed.isEmpty ? [] : [.completed(completed.count)] + prioritized(completed, section: "completed"))
    }
}

struct RootView: View {
    let store: WorkStore
    @EnvironmentObject private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("weekStart") private var weekStart = 5
    @AppStorage("taskListEffect") private var listEffect: TaskListEffect = .slide
    @AppStorage("reverseTabSwipe") private var reverseTabSwipe = false
    @AppStorage("taskColumns") private var defaultColumns: TaskColumnMode = .one
    @AppStorage("taskDetails") private var defaultDetails: TaskDetailsMode = .expanded
    @AppStorage("appTextSize") private var textSize: AppTextSize = .standard
    @AppStorage("appLanguage") private var language: AppLanguage = .system
    @ObservedObject private var dragState = TaskDragState.shared
    @State private var displaySetting = TaskDisplaySetting()
    @State private var selection: SidebarItem? = .all
    @State private var search = ""
    @State private var showNewProject = false
    @State private var showNewTag = false
    @State private var editingTag: TaskTag?
    @State private var deletingTag: TaskTag?
    @State private var draftStorage = TaskDraftStorage()
    @State private var editingRegistry = TaskEditingRegistry()
    @State private var draftID: UUID?
    // Consumed when the saved card appears, independently of the next draft's highlight.
    @State private var savedDraftIDs: Set<UUID> = []
    @State private var listStructure: TaskListStructure
    @State private var storeError: String?
    @State private var error: String?
    @State private var historyRange: HistoryRange = .week
    @State private var weekAnchor = Date()
    @State private var customStart = Calendar.current.startOfDay(for: Date())
    @State private var customEnd = Date()
    @State private var highlightedTaskID: UUID?
    @State private var taskReveal: TaskReveal?
    @State private var centeredListRevealID: UUID?
    @State private var operationNotice: TaskOperationNotice?
    @State private var planningToday = Calendar.current.startOfDay(for: Date())
    @State private var planFilter: TaskPlanFilter = .thisWeek
    @State private var listUpdateTask: Task<Void, Never>?
    @State private var pendingListStructure: TaskListStructure?
    @State private var listSlide: TaskListSlide?
    @State private var listViewport = TaskListViewportState()
    @FocusState private var sidebarFocus: SidebarItem?
    @State private var searchFocused = false

    init(store: WorkStore) {
        self.store = store
        _listStructure = State(initialValue: TaskListStructure(data: store.data))
        _storeError = State(initialValue: store.errorMessage)
        _planFilter = State(initialValue: PlanFilterPreferences().filter(for: SidebarItem.all.planFilterPreferenceKey))
    }

    private var draftTask: WorkTask? {
        get { draftStorage.task }
        nonmutating set {
            draftStorage.task = newValue
            if draftID != newValue?.id { draftID = newValue?.id }
        }
    }

    private var isHistory: Bool { selection == .completed }
    private var isTimeSensitive: Bool { TaskListPolicy.isTimeSensitive(selection ?? .all) }
    private var scopeSelection: Binding<SidebarItem?> {
        Binding(get: { selection }, set: { selectScope($0) })
    }

    private func selectScope(_ item: SidebarItem?, filter: TaskPlanFilter? = nil) {
        guard finishCurrentEdits() else {
            return
        }
        clearSearchFocus()
        let scope = item ?? .all
        let saved = filter ?? PlanFilterPreferences().filter(for: scope.planFilterPreferenceKey)
        setListLocation(item, filter: scope == .thisWeek ? .thisWeek : (TaskListPolicy.isTimeSensitive(scope) ? .all : validPlanFilter(saved)))
        dismissNavigationFeedback()
    }

    private var listPageID: TaskListPageID {
        TaskListPageID(scope: selection ?? .all, filter: planFilter)
    }

    private func setListLocation(_ scope: SidebarItem?, filter: TaskPlanFilter) {
        guard TaskListPageID(scope: scope ?? .all, filter: filter) != listPageID else { return }
        let destination = TaskViewContext(scope: scope ?? .all, filter: filter, search: "")
        let setting = scope == selection ? displaySetting : TaskDisplayPreferences().setting(
            for: (scope ?? .all).planFilterPreferenceKey, defaultColumns: defaultColumns, defaultDetails: defaultDetails)
        let slide = reduceMotion || listEffect == .none ? nil : TaskListSlide.between(currentContext, destination, projectIDs: listStructure.projects.map(\.id), tagIDs: listStructure.tags.map(\.id))
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        if slide != nil { listViewport.prepareNavigation() }
        withTransaction(transaction) {
            listSlide = slide
            if setting.details != displaySetting.details { editingRegistry.resetExpansion() }
            displaySetting = setting
            selection = scope
            planFilter = filter
        }
    }

    private func validPlanFilter(_ filter: TaskPlanFilter) -> TaskPlanFilter {
        guard case .week(let anchor) = filter else { return filter }
        return .week(WorkPeriod.range(containing: anchor, firstWeekday: weekStart).start)
    }

    private var planningTasks: [WorkTask] {
        tasks(in: selection == .thisWeek ? .all : (selection ?? .all))
    }

    private var completedTasks: [WorkTask] {
        TaskListPolicy.completedTasks(in: selection ?? .all, data: listStructure.presentationData,
                                      relativeTo: planningToday, firstWeekday: weekStart)
    }

    private var activeProjects: [Project] { listStructure.projects.filter { !$0.isArchived } }
    private var historyInterval: DateInterval? {
        switch historyRange {
        case .all: return nil
        case .week: return WorkPeriod.range(containing: weekAnchor, firstWeekday: weekStart, calendar: .current)
        case .custom:
            let start = Calendar.current.startOfDay(for: customStart)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(customStart, customEnd)))!
            return DateInterval(start: start, end: end)
        }
    }

    private func tasks(in item: SidebarItem) -> [WorkTask] {
        TaskListPolicy.tasks(in: item, data: listStructure.presentationData,
                             relativeTo: item == .reminders ? services.reminderReferenceDate : planningToday,
                             firstWeekday: weekStart, historyInterval: item == .completed ? historyInterval : nil)
    }

    private var visibleTasks: [WorkTask] {
        TaskListPolicy.visibleTasks(tasks(in: selection ?? .all) + completedTasks, projects: listStructure.projects, tags: listStructure.tags,
                                    scope: selection ?? .all, filter: planFilter, search: "",
                                    relativeTo: planningToday, firstWeekday: weekStart)
            .filter { listStructure.matchingTaskIDs?.contains($0.id) ?? true }
    }

    private var visibleDraft: WorkTask? {
        guard let id = draftID, let draftTask, draftTask.id == id, !isHistory else { return nil }
        let task = store.data.tasks.first { $0.id == draftTask.id } ?? draftTask
        switch selection ?? .all {
        case .all: return task
        case .project(let id): return task.projectID == id ? task : nil
        case .tag, .starred: return task
        default: return nil
        }
    }

    private func taskRows(for tasks: [WorkTask]) -> [TaskListRow] {
        TaskListRow.rows(for: tasks, projects: listStructure.projects, scope: selection ?? .all, filter: planFilter,
                         relativeTo: planningToday, firstWeekday: weekStart, draft: visibleDraft)
    }

    private func thisWeekCount(in tasks: [WorkTask]) -> Int {
        let includes = TaskPlanFilter.thisWeek.predicate(relativeTo: planningToday, firstWeekday: weekStart)
        return tasks.lazy.filter(includes).count
    }

    private var title: String {
        switch selection ?? .all {
        case .all: return L("全部任务")
        case .thisWeek: return L("本周任务")
        case .starred: return L("星标任务")
        case .upcoming: return L("即将到期")
        case .overdue: return L("已逾期")
        case .reminders: return L("待处理提醒")
        case .completed: return L("已完成")
        case .project(let id): return listStructure.projects.first { $0.id == id }?.name ?? L("项目")
        case .tag(let id): return listStructure.tags.first { $0.id == id }?.name ?? L("标签")
        }
    }

    var body: some View {
        let visible = visibleTasks
        let rows = taskRows(for: visible)
        let hasVisibleDraft = visibleDraft != nil
        let pageIsHistory = isHistory
        let pageIsTimeSensitive = isTimeSensitive
        let all = tasks(in: .all)
        let upcoming = tasks(in: .upcoming)
        let starred = tasks(in: .starred)
        let overdue = tasks(in: .overdue)
        let reminders = tasks(in: .reminders)
        let scoped = tasks(in: selection ?? .all)
        let allWeekCount = thisWeekCount(in: all)
        let pageID = listPageID
        NavigationSplitView {
            VStack(spacing: 0) {
                List {
                    Section(L("工作台")) {
                        sidebarRow(L("全部任务"), symbol: "square.stack.3d.up", item: .all, count: all.count, weekCount: allWeekCount)
                        sidebarRow(L("本周任务"), symbol: "calendar.badge.clock", item: .thisWeek, weekCount: allWeekCount)
                        sidebarRow(L("星标任务"), symbol: "star", item: .starred, count: starred.count, weekCount: thisWeekCount(in: starred))
                        sidebarRow(L("即将到期"), symbol: "calendar", item: .upcoming, count: upcoming.count, weekCount: thisWeekCount(in: upcoming))
                        sidebarRow(L("已逾期"), symbol: "exclamationmark.circle", item: .overdue, count: overdue.count, weekCount: thisWeekCount(in: overdue))
                        if !reminders.isEmpty || selection == .reminders {
                            sidebarRow(L("待处理提醒"), symbol: "bell.badge", item: .reminders, count: reminders.count)
                        }
                        sidebarRow(L("已完成"), symbol: "checkmark.circle", item: .completed)
                    }
                    Section {
                        ForEach(activeProjects) { project in
                            let tasks = listStructure.presentationData.tasks.filter { $0.projectID == project.id && $0.completedAt == nil }
                            Button { selectScope(.project(project.id)) } label: {
                            SidebarHoverRow(selected: selection == .project(project.id), dropColor: Color(hex: project.colorHex), onTaskDrop: { moveTask($0, toProject: project.id) }) {
                                HStack {
                                    Circle().fill(Color(hex: project.colorHex)).frame(width: 9, height: 9)
                                    Text(project.name).lineLimit(1)
                                    Spacer()
                                    ThisWeekBadge(count: thisWeekCount(in: tasks))
                                    if !tasks.isEmpty {
                                        Text("\(tasks.count)")
                                            .appFont(.caption).foregroundStyle(.secondary)
                                            .accessibilityLabel(L("共 \(tasks.count) 项未完成任务"))
                                    }
                                }
                            }
                            }.buttonStyle(.plain).listRowBackground(Color.clear)
                                .accessibilityIdentifier("scope.\(SidebarItem.project(project.id).planFilterPreferenceKey)")
                                .focused($sidebarFocus, equals: .project(project.id))
                                .accessibilityAddTraits(selection == .project(project.id) ? .isSelected : [])
                                .help(L("查看「\(project.name)」的未完成任务"))
                                .contextMenu {
                                    Button(L("归档项目")) {
                                        do {
                                            try store.archiveProject(id: project.id)
                                            if selection == .project(project.id) { selectScope(.all) }
                                        } catch { self.error = localizedError(error) }
                                    }
                                }
                        }
                        HoverGlassButton(action: { showNewProject = true }) {
                            Image(systemName: "plus").appFont(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel(L("新建项目"))
                        .help(L("新建一个项目，用来分类管理任务"))
                        if listStructure.projects.contains(where: \.isArchived) {
                            Menu {
                                ForEach(listStructure.projects.filter(\.isArchived)) { project in
                                    Button(L("恢复 · \(project.name)")) {
                                        do { try store.unarchiveProject(id: project.id); selectScope(.project(project.id)) }
                                        catch { self.error = localizedError(error) }
                                    }
                                }
                            } label: { Label(L("已归档项目"), systemImage: "archivebox") }
                                .menuStyle(.borderlessButton).foregroundStyle(.secondary)
                                .help(L("查看已归档项目，点击项目名称可恢复"))
                        }
                    } header: { Text(L("项目")) }
                    Section {
                        ForEach(listStructure.tags) { tag in tagSidebarRow(tag) }
                        HoverGlassButton(action: { showNewTag = true }) {
                            Image(systemName: "plus").appFont(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel(L("新建标签"))
                        .help(L("新建标签；任务可以同时拥有多个标签"))
                    } header: { Text(L("标签")) }
                }.listStyle(.sidebar)
                    .onMoveCommand { direction in
                        let items: [SidebarItem] = [.all, .thisWeek, .starred, .upcoming, .overdue]
                            + (reminders.isEmpty && selection != .reminders ? [] : [.reminders])
                            + [.completed] + activeProjects.map { .project($0.id) } + listStructure.tags.map { .tag($0.id) }
                        guard let index = items.firstIndex(of: selection ?? .all) else { return }
                        if direction == .up { let target = items[max(0, index - 1)]; selectScope(target); sidebarFocus = selection }
                        if direction == .down { let target = items[min(items.count - 1, index + 1)]; selectScope(target); sidebarFocus = selection }
                    }
                Divider()
                HStack {
                    Label(L("仅本地保存"), systemImage: "internaldrive").appFont(.caption).foregroundStyle(.secondary)
                        .help(L("任务和附件保存在这台 Mac 的应用数据目录"))
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }.nativeActionButton().help(L("设置"))
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 300)
        } detail: {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if isHistory {
                        periodControls.padding(.top, 18)
                        Divider()
                    } else if (selection != .thisWeek && !isTimeSensitive) || dragState.taskID != nil {
                        planningFilterControls
                            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 2)
                    }
                    GeometryReader { viewport in
                        TaskListViewport(state: listViewport, page: pageID, slide: listSlide, effect: listEffect, reduceMotion: reduceMotion, resetScroll: taskReveal == nil) {
                            ScrollViewReader { proxy in
                                let singleColumn = displaySetting.columns == .one
                                Group {
                                    if singleColumn {
                                        singleColumnTasks(rows: rows, width: viewport.size.width, history: pageIsHistory, timeSensitive: pageIsTimeSensitive, page: pageID, proxy: proxy)
                                    } else {
                                        multiColumnTasks(rows: rows, width: viewport.size.width, history: pageIsHistory, timeSensitive: pageIsTimeSensitive, page: pageID, proxy: proxy)
                                    }
                                }
                                .modifier(TaskListScrollActivity())
                                .overlay {
                                    if visible.isEmpty && !hasVisibleDraft {
                                        emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                                .task(id: taskReveal) {
                                    guard let request = taskReveal else { return }
                                    await Task.yield()
                                    guard !Task.isCancelled, pageID == listPageID, taskReveal?.id == request.id else { return }
                                    if singleColumn {
                                        withAnimation(reduceMotion || !request.animatedScroll ? nil : .easeInOut(duration: 0.22)) {
                                            proxy.scrollTo("task:\(request.taskID)", anchor: draftID == request.taskID ? .top : .center)
                                        }
                                    } else if let row = gridRows(rows, width: viewport.size.width).first(where: { $0.tasks.contains { $0.id == "task:\(request.taskID)" } }) {
                                        withAnimation(reduceMotion || !request.animatedScroll ? nil : .easeInOut(duration: 0.22)) {
                                            proxy.scrollTo(row.id, anchor: draftID == request.taskID ? .top : .center)
                                        }
                                    }
                                }
                            }
                            .frame(width: viewport.size.width, height: viewport.size.height)
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                        .frame(width: viewport.size.width, height: viewport.size.height)
                    }
                    .clipped()
                }
                .background(TaskTabSwipeBoundary(enabled: !isHistory && !isTimeSensitive && selection != .thisWeek && dragState.taskID == nil,
                                                 reverseDirection: reverseTabSwipe,
                                                 onSwipe: swipePlanFilter))
                operationBar
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: operationNotice != nil)
            }.background(Color(nsColor: .windowBackgroundColor))
                .navigationTitle(title)
                .hideStandardToolbarTitle()
                .toolbar { scopeToolbar(count: scoped.count, weekCount: isHistory ? 0 : thisWeekCount(in: scoped)) }
                .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        }
        .frame(minWidth: 950, minHeight: 620)
        .environment(\.taskPlanningDay, planningToday)
        .environment(\.locale, language.locale)
        .onAppear(perform: loadDisplaySetting)
        .onChange(of: defaultColumns) { _, _ in loadDisplaySetting() }
        .onChange(of: defaultDetails) { _, _ in loadDisplaySetting() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WorkLedger.viewPreferencesChanged"))) { note in
            guard let scope = note.object as? String, scope == (selection ?? .all).planFilterPreferenceKey else { return }
            loadDisplaySetting()
            let filter = PlanFilterPreferences().filter(for: scope)
            if filter != planFilter { setListLocation(selection, filter: filter) }
        }
        .sheet(isPresented: $showNewProject) { ProjectEditor() }
        .sheet(isPresented: $showNewTag) { TagEditor() }
        .sheet(item: $editingTag) { TagEditor(tag: $0) }
        .confirmationDialog(L("删除这个标签？"), isPresented: Binding(get: { deletingTag != nil }, set: { if !$0 { deletingTag = nil } }), titleVisibility: .visible) {
            Button(L("删除标签"), role: .destructive) { deleteSelectedTag() }
            Button(L("取消"), role: .cancel) { deletingTag = nil }
        } message: { Text(L("只移除标签，任务和所属项目会保留。")) }
        .onReceive(store.$data) { data in
            receiveListStructure(TaskListStructure(data: data, search: search))
        }
        .onChange(of: currentContext) { _, _ in
            guard pendingListStructure != nil else { return }
            listUpdateTask?.cancel(); listUpdateTask = nil; pendingListStructure = nil
            let next = TaskListStructure(data: store.data, search: search)
            if listStructure != next { listStructure = next }
        }
        .onChange(of: reduceMotion) { _, _ in
            listSlide = nil
            listUpdateTask?.cancel(); listUpdateTask = nil; pendingListStructure = nil
            listStructure = TaskListStructure(data: store.data, search: search)
        }
        .onDisappear { listUpdateTask?.cancel(); _ = finishCurrentEdits(); editingRegistry.removeAll() }
        .onChange(of: search) { _, query in
            let next = TaskListStructure(data: store.data, search: query)
            if listStructure != next { listStructure = next }
        }
        .onChange(of: weekStart, initial: true) { _, _ in
            let next = validPlanFilter(planFilter)
            if planFilter != next { listSlide = nil; planFilter = next }
        }
        .onReceive(store.$errorMessage.removeDuplicates()) { message in
            if storeError != message { storeError = message }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in refreshPlanningDay() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: RunLoop.main)) { _ in refreshPlanningDay() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshPlanningDay() } }
        .alert(L("操作未完成"), isPresented: Binding(get: { error != nil || storeError != nil }, set: { if !$0 { error = nil; storeError = nil; store.errorMessage = nil } })) {
            Button(L("好")) { error = nil; storeError = nil; store.errorMessage = nil }
        } message: { Text(localizedErrorMessage(error ?? storeError ?? "")) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WorkLedger.newTask"))) { _ in createTask() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WorkLedger.focusSearch"))) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WorkLedger.showAll"))) { _ in
            selectScope(.all, filter: .all); search = ""
        }
        #if WORKLEDGER_PERFORMANCE_TESTS
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WorkLedger.testSelectScope"))) { notification in
            if let scope = notification.object as? SidebarItem { selectScope(scope) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WorkLedger.testSelectPlanFilter"))) { notification in
            if let filter = notification.object as? TaskPlanFilter { selectPlanFilter(filter) }
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WorkLedger.openTask"))) { notification in
            guard let string = notification.object as? String, let id = UUID(uuidString: string) else { return }
            openTask(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: TaskOperationEvent.notification)) { notification in
            guard let event = notification.object as? TaskOperationEvent else { return }
            let origin = currentContext
            DispatchQueue.main.async {
                guard currentContext == origin else { return }
                handleTaskOperation(event, from: origin)
            }
        }
        .task(id: taskReveal?.id) {
            guard let request = taskReveal else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if taskReveal?.id == request.id { highlightedTaskID = nil }
        }
    }

    private func receiveListStructure(_ next: TaskListStructure) {
        if !savedDraftIDs.isEmpty {
            let remaining = savedDraftIDs.intersection(next.tasks.map(\.id))
            if remaining != savedDraftIDs { savedDraftIDs = remaining }
        }
        if let id = draftID, next.removesTask(id, comparedTo: pendingListStructure ?? listStructure) {
            draftTask = nil
        }
        editingRegistry.retainTasks(Set(store.data.tasks.map(\.id)).union(draftID.map { [$0] } ?? []))
        // A publisher can replay during a render; the same result must not restart the feedback timer.
        guard pendingListStructure != next else { return }
        if listStructure == next {
            // Do not write Task state for an unchanged replay: it would render and subscribe again.
            guard listUpdateTask != nil else { return }
            listUpdateTask?.cancel(); listUpdateTask = nil; pendingListStructure = nil
            return
        }
        listUpdateTask?.cancel(); listUpdateTask = nil; pendingListStructure = nil
        let visibleIDs = Set(visibleTasks.map(\.id))
        if !reduceMotion, next.needsCompletionFeedback(comparedTo: listStructure, visibleIDs: visibleIDs) {
            pendingListStructure = next
            // Persist immediately; hold only list membership long enough to show the completed checkmark.
            listUpdateTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    listStructure = TaskListStructure(data: store.data, search: search)
                }
                listUpdateTask = nil
                pendingListStructure = nil
            }
        } else {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { listStructure = next }
        }
    }

    @ToolbarContentBuilder private func scopeToolbar(count: Int, weekCount: Int) -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            // Measure both controls together to keep native toolbar sizing stable.
            ToolbarItem(id: "taskScope", placement: .navigation) {
                HStack(spacing: 4) {
                    ScopeMenu(title: title, count: count, weekCount: weekCount, selection: scopeSelection, projects: listStructure.projects, tags: listStructure.tags, hasPendingReminders: !tasks(in: .reminders).isEmpty)
                    addTaskButton
                }.accessibilityElement(children: .contain)
            }.sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .navigation)
        } else {
            ToolbarItem(placement: .navigation) {
                ScopeMenu(title: title, count: count, weekCount: weekCount, selection: scopeSelection, projects: listStructure.projects, tags: listStructure.tags, hasPendingReminders: !tasks(in: .reminders).isEmpty)
            }
            ToolbarItem(placement: .navigation) { addTaskButton }
        }
        ToolbarItem(placement: .automatic) { displayMenu }
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .automatic) { searchField }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) { searchField }
        }
    }

    private var searchField: some View {
        NativeTaskSearchField(text: $search, focused: Binding(get: { searchFocused }, set: { searchFocused = $0 }),
                              placeholder: L("搜索任务、备注、附件"))
            .frame(width: 190, height: 28 * textSize.scale)
            .help(L("搜索任务、备注和附件（⌘F），按 Esc 退出搜索输入"))
    }

    private func clearSearchFocus() {
        searchFocused = false
    }

    private var addTaskButton: some View {
        HoverGlassButton(action: createTask) {
            Image(systemName: "plus").appFont(.system(size: 16, weight: .medium))
        }
        .accessibilityLabel(L("新增任务"))
        .help(L("新增任务（⌘N），回车保存；点击空白保留编辑"))
    }

    private var selectedProjectID: UUID? {
        if case .project(let id) = selection, activeProjects.contains(where: { $0.id == id }) { return id }
        return nil
    }

    private func createTask() {
        guard finishCurrentEdits() else { return }
        clearSearchFocus()
        search = ""
        if draftTask == nil {
            let plannedAt: Date?
            switch planFilter {
            case .all, .thisWeek: plannedAt = planningToday
            case .nextWeek: plannedAt = TaskPlanning.weekDate(offset: 1, relativeTo: planningToday, firstWeekday: weekStart)
            case .week(let date): plannedAt = date
            case .unscheduled: plannedAt = nil
            }
            let tagIDs: [UUID]
            if case .tag(let id) = selection { tagIDs = [id] } else { tagIDs = [] }
            draftTask = WorkTask(projectID: selectedProjectID, title: "", plannedAt: plannedAt, planGranularity: plannedAt == nil ? nil : .week,
                                 tagIDs: tagIDs, isStarred: selection == .starred)
        }
        let destination: SidebarItem
        if case .tag(let id) = selection { destination = .tag(id) }
        else if selection == .starred { destination = .starred }
        else { destination = draftTask?.projectID.map(SidebarItem.project) ?? .all }
        setListLocation(destination, filter: planFilter)
        if let id = draftTask?.id { revealTask(id) }
    }

    private func sidebarRow(_ title: String, symbol: String, item: SidebarItem, count: Int? = nil, weekCount: Int? = nil) -> some View {
        Button { selectScope(item) } label: {
        SidebarHoverRow(selected: selection == item, onTaskDrop: item == .all ? { moveTask($0, toProject: nil) } : nil) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let weekCount { ThisWeekBadge(count: weekCount) }
                if let count, count > 0 {
                    Text("\(count)")
                        .appFont(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel(L("共 \(count) 项未完成任务"))
                }
            }
        }
        }.buttonStyle(.plain).listRowBackground(Color.clear)
            .accessibilityIdentifier("scope.\(item.planFilterPreferenceKey)")
            .focused($sidebarFocus, equals: item)
            .accessibilityAddTraits(selection == item ? .isSelected : [])
            .help(L("查看\(title)"))
    }

    private func refreshPlanningDay() {
        let filter = validPlanFilter(planFilter)
        if planFilter != filter { listSlide = nil; planFilter = filter }
        let today = Calendar.current.startOfDay(for: Date())
        if today != planningToday { planningToday = today }
    }

    private func tagSidebarRow(_ tag: TaskTag) -> some View {
        let tasks = tasks(in: .tag(tag.id))
        return Button { selectScope(.tag(tag.id)) } label: {
            SidebarHoverRow(selected: selection == .tag(tag.id), dropColor: Color(hex: tag.colorHex), onTaskDrop: { addTag($0, tagID: tag.id) }) {
                HStack {
                    Image(systemName: "tag").foregroundStyle(Color(hex: tag.colorHex)).frame(width: 13)
                    Text(tag.name).lineLimit(1)
                    Spacer()
                    ThisWeekBadge(count: thisWeekCount(in: tasks))
                    if !tasks.isEmpty { Text("\(tasks.count)").appFont(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
        }
        .buttonStyle(.plain).listRowBackground(Color.clear)
        .accessibilityIdentifier("scope.\(SidebarItem.tag(tag.id).planFilterPreferenceKey)")
        .focused($sidebarFocus, equals: .tag(tag.id))
        .accessibilityAddTraits(selection == .tag(tag.id) ? .isSelected : [])
        .help(L("查看标签任务；拖入任务以添加标签，保留项目和其他标签"))
        .contextMenu {
            Button(L("编辑标签")) { editingTag = tag }
            Button(L("删除标签"), role: .destructive) { deletingTag = tag }
        }
    }

    private func deleteSelectedTag() {
        guard let tag = deletingTag, finishCurrentEdits() else { return }
        do {
            _ = try store.deleteTag(id: tag.id)
            deletingTag = nil
            if selection == .tag(tag.id) { selectScope(.all) }
        } catch { self.error = localizedError(error) }
    }

    private func addTag(_ items: [TaskDragItem], tagID: UUID) -> Bool {
        guard items.count == 1, let item = items.first, finishCurrentEdits(),
              let before = store.data.tasks.first(where: { $0.id == item.taskID }),
              let tag = store.data.tags.first(where: { $0.id == tagID }) else { return false }
        guard !before.tagIDs.contains(tagID) else { return true }
        do {
            try store.addTagToTask(id: before.id, tagID: tagID)
            guard let after = store.data.tasks.first(where: { $0.id == before.id }) else { return false }
            revealTask(after.id, animatedScroll: false)
            operationNotice = TaskOperationNotice(taskID: after.id, title: after.title, message: L("已添加标签「\(tag.name)」"),
                                                 symbol: "tag", undo: .tags(before: before, after: after))
            return true
        } catch { self.error = localizedError(error); return false }
    }

    private func moveTask(_ items: [TaskDragItem], toProject projectID: UUID?) -> Bool {
        guard items.count == 1, let item = items.first else { return false }
        guard finishCurrentEdits() else { return false }
        guard let before = store.data.tasks.first(where: { $0.id == item.taskID }) else { return false }
        guard before.projectID != projectID else { return true }
        let origin = currentContext
        do {
            try store.moveTask(id: item.taskID, toProject: projectID)
            guard let after = store.data.tasks.first(where: { $0.id == item.taskID }) else { return false }
            let followed = followTask(after, after: .moved, from: origin)
            let destination = after.projectID.flatMap { id in store.data.projects.first { $0.id == id }?.name } ?? L("未关联项目")
            operationNotice = TaskOperationNotice(taskID: after.id, title: after.title, message: L("已移至「\(destination)」"), symbol: "folder.badge.arrow.forward", undo: .project(before: before, after: after), origin: followed ? origin : nil)
            return true
        } catch {
            self.error = localizedError(error)
            return false
        }
    }

    private func taskCardContent(_ task: WorkTask, project: Project?, history: Bool, timeSensitive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if timeSensitive || task.isStarred {
                HStack(spacing: 5) {
                    Circle().fill(project.map { Color(hex: $0.colorHex) } ?? .secondary).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(project?.name ?? L("未关联项目")).appFont(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 14).padding(.top, 4)
            }
            ObservedTaskCard(store: store, task: task, project: project, isHistory: history || task.completedAt != nil, isNavigationTarget: highlightedTaskID == task.id,
                     initiallyExpanded: savedDraftIDs.contains(task.id),
                     draft: draftID == task.id ? draftStorage : nil,
                     editingState: editingRegistry.state(for: task, isDraft: draftID == task.id && !store.data.tasks.contains { $0.id == task.id }, initiallyExpanded: savedDraftIDs.contains(task.id)),
                     onCreated: {
                         guard draftTask?.id == task.id else { return }
                         let origin = currentContext
                         savedDraftIDs.insert(task.id)
                         draftTask = nil
                         revealTask(task.id, animatedScroll: false)
                         DispatchQueue.main.async {
                             guard TaskListPolicy.shouldFollowCreatedTask(task.id, currentDraftID: draftID, reveal: taskReveal,
                                                                          origin: origin, current: currentContext),
                                   let saved = store.data.tasks.first(where: { $0.id == task.id }), saved.completedAt == nil,
                                   let destination = TaskNavigation.destination(for: saved, after: .created, from: origin,
                                                                                relativeTo: planningToday, firstWeekday: weekStart),
                                   destination != origin else { return }
                             _ = followTask(saved, after: .created, from: origin)
                         }
                     },
                     onCancel: { if draftTask?.id == task.id { draftTask = nil } },
                     onInitialExpansionConsumed: { _ = savedDraftIDs.remove(task.id) })
        }
    }

    private func singleColumnTasks(rows: [TaskListRow], width: CGFloat, history: Bool, timeSensitive: Bool, page: TaskListPageID, proxy: ScrollViewProxy) -> some View {
        List(rows) { row in
            VStack(alignment: .leading, spacing: 0) {
                if case .task(let task, let project) = row {
                    taskCardContent(task, project: project, history: history, timeSensitive: timeSensitive)
                } else {
                    taskHeading(row)
                }
            }
            .id(row.id)
            .onAppear {
                guard let request = taskReveal, row.id == "task:\(request.taskID)", centeredListRevealID != request.id else { return }
                // The first jump realizes the row; recenter after its actual height is measured.
                DispatchQueue.main.async {
                    guard page == listPageID, taskReveal?.id == request.id, centeredListRevealID != request.id else { return }
                    centeredListRevealID = request.id
                    proxy.scrollTo(row.id, anchor: draftID == request.taskID ? .top : .center)
                }
            }
            .padding(.bottom, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.taskDetailsMode, displaySetting.details)
        .environment(\.taskListPreservesEditing, true)
        .environment(\.compactTaskPlan, width - 56 < 650 * textSize.scale)
        .contentMargins(.top, history ? 14 : 4, for: .scrollContent)
        .contentMargins(.bottom, 28, for: .scrollContent)
    }

    private func gridRows(_ rows: [TaskListRow], width: CGFloat) -> [TaskGridSection] {
        let columns = displaySetting.columns.columnCount(availableWidth: width - 56, textScale: textSize.scale)
        let saved = rows.filter { $0.id != "task:\(draftID?.uuidString ?? "")" }
        let drafts = visibleDraft.map { task in
            [TaskGridSection(headings: [], tasks: [.task(task, listStructure.projects.first { $0.id == task.projectID })])]
        } ?? []
        return drafts + TaskGridSection.rows(saved, columns: columns)
    }

    private func multiColumnTasks(rows: [TaskListRow], width: CGFloat, history: Bool, timeSensitive: Bool, page: TaskListPageID, proxy: ScrollViewProxy) -> some View {
        let columns = displaySetting.columns.columnCount(availableWidth: width - 56, textScale: textSize.scale)
        return List(gridRows(rows, width: width)) { row in
            let isDraft = row.tasks.first?.id == "task:\(draftID?.uuidString ?? "")"
            let rowColumns = isDraft ? 1 : columns
            VStack(alignment: .leading, spacing: 4) {
                ForEach(row.headings) { taskHeading($0) }
                TaskColumnLayout(idealWidth: width - 56) {
                    ForEach(row.tasks) { item in
                        if case .task(let task, let project) = item {
                            taskCardContent(task, project: project, history: history, timeSensitive: timeSensitive)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                    }
                    ForEach(0..<max(0, rowColumns - row.tasks.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: 0).accessibilityHidden(true)
                    }
                }
                .environment(\.taskCardFillsGridRow, true)
                .environment(\.compactTaskPlan, (width - 56) / CGFloat(rowColumns) < 650 * textSize.scale)
            }
            .accessibilityElement(children: .contain)
            .id(row.id)
            .onAppear {
                guard let request = taskReveal, row.tasks.contains(where: { $0.id == "task:\(request.taskID)" }), centeredListRevealID != request.id else { return }
                DispatchQueue.main.async {
                    guard page == listPageID, taskReveal?.id == request.id, centeredListRevealID != request.id else { return }
                    centeredListRevealID = request.id
                    proxy.scrollTo(row.id, anchor: draftID == request.taskID ? .top : .center)
                }
            }
            .padding(.bottom, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.taskDetailsMode, displaySetting.details)
        .environment(\.taskListPreservesEditing, true)
        .contentMargins(.top, history ? 14 : 4, for: .scrollContent)
        .contentMargins(.bottom, 28, for: .scrollContent)
    }

    private var currentContext: TaskViewContext {
        TaskViewContext(scope: selection ?? .all, filter: planFilter, search: search,
                        history: TaskHistoryContext(range: historyRange, weekAnchor: weekAnchor, customStart: customStart, customEnd: customEnd))
    }

    private func finishCurrentEdits() -> Bool {
        let request = TaskEditingExitRequest()
        NotificationCenter.default.post(name: finishTaskEdits, object: request)
        if let id = request.failedTaskID {
            clearSearchFocus()
            if !search.isEmpty {
                search = ""
                listStructure = TaskListStructure(data: store.data, search: "")
            }
            if let task = store.data.tasks.first(where: { $0.id == id }) ?? draftTask {
                if visibleDraft?.id != id && !visibleTasks.contains(where: { $0.id == id }) {
                    if task.completedAt != nil {
                        historyRange = .all
                        setListLocation(.completed, filter: .all)
                    } else {
                        setListLocation(task.projectID.map(SidebarItem.project) ?? .all,
                                        filter: TaskPlanFilter(task: task, relativeTo: planningToday, firstWeekday: weekStart))
                    }
                }
                revealTask(id, animatedScroll: false)
                operationNotice = TaskOperationNotice(taskID: id, title: task.title,
                    message: L("请先修正正在编辑的内容，再继续操作。"), symbol: "exclamationmark.circle")
            }
        }
        return !request.failed
    }

    private func dismissNavigationFeedback() {
        operationNotice = nil; highlightedTaskID = nil; taskReveal = nil
    }

    @discardableResult private func applyContext(_ context: TaskViewContext) -> Bool {
        guard finishCurrentEdits() else { return false }
        clearSearchFocus()
        setListLocation(context.scope, filter: context.scope == .thisWeek ? .thisWeek : (TaskListPolicy.isTimeSensitive(context.scope) ? .all : validPlanFilter(context.filter)))
        search = context.search
        if let history = context.history {
            historyRange = history.range
            weekAnchor = history.weekAnchor
            customStart = history.customStart
            customEnd = history.customEnd
        }
        let next = TaskListStructure(data: store.data, search: context.search)
        if listStructure != next { listStructure = next }
        return true
    }

    private func revealTask(_ id: UUID, animatedScroll: Bool = true) {
        highlightedTaskID = id
        taskReveal = TaskReveal(taskID: id, animatedScroll: animatedScroll)
    }

    @discardableResult private func followTask(_ task: WorkTask, after action: TaskNavigation.Action, from origin: TaskViewContext) -> Bool {
        guard let destination = TaskNavigation.destination(for: task, after: action, from: origin, relativeTo: planningToday, firstWeekday: weekStart),
              applyContext(destination) else { return false }
        revealTask(task.id, animatedScroll: destination == origin)
        return destination != origin
    }

    private func handleTaskOperation(_ event: TaskOperationEvent, from origin: TaskViewContext) {
        switch event {
        case .planned(let before, let after):
            guard let current = store.data.tasks.first(where: { $0.id == after.id }), current.projectID == after.projectID,
                  current.plannedAt == after.plannedAt, current.planGranularity == after.planGranularity,
                  current.completedAt == after.completedAt else { return }
            let followed = followTask(current, after: .planned, from: origin)
            let target = planFilterTitle(TaskPlanFilter(task: current, relativeTo: planningToday, firstWeekday: weekStart))
            operationNotice = TaskOperationNotice(taskID: current.id, title: current.title, message: L("已安排到\(target)"), symbol: "calendar", undo: .plan(before: before, after: after), origin: followed ? origin : nil)
        case .completed(let result):
            guard !result.alreadyCompleted, store.data.tasks.first(where: { $0.id == result.task.id })?.completedAt == result.task.completedAt else { return }
            operationNotice = TaskOperationNotice(taskID: result.task.id, title: result.task.title,
                                                message: result.nextTask == nil ? L("任务已完成") : L("任务已完成，已创建下一次任务"),
                                                symbol: "checkmark.circle", undo: .completion(result.task), nextTaskID: result.nextTask?.id)
        case .restored(let task):
            guard store.data.tasks.first(where: { $0.id == task.id })?.completedAt == nil else { return }
            operationNotice = TaskOperationNotice(taskID: task.id, title: task.title, message: L("已撤销完成"), symbol: "arrow.uturn.backward")
        case .edited(let task, let message, let symbol, let undo):
            guard let current = store.data.tasks.first(where: { $0.id == task.id }) else { return }
            clearSearchFocus()
            var notice = TaskOperationNotice(taskID: task.id, title: current.title, message: message, symbol: symbol)
            notice.undo = undo
            operationNotice = notice
        }
    }

    private func openTask(_ id: UUID) {
        if draftTask?.id == id {
            _ = finishCurrentEdits()
            revealTask(id, animatedScroll: false)
            return
        }
        guard let task = store.data.tasks.first(where: { $0.id == id }) else {
            error = L("任务已不存在。"); return
        }
        let origin = currentContext
        let previous = operationNotice
        guard let destination = TaskNavigation.destination(for: task, after: .open, from: origin, relativeTo: planningToday, firstWeekday: weekStart),
              applyContext(destination) else { return }
        revealTask(id, animatedScroll: destination == origin)
        if var notice = previous, notice.taskID == id {
            if notice.origin == nil && destination != origin { notice.origin = origin }
            operationNotice = notice
        } else {
            operationNotice = TaskOperationNotice(taskID: id, title: task.title, message: L("已定位任务"), symbol: "scope", origin: destination == origin ? nil : origin)
        }
    }

    private func undoOperation(_ notice: TaskOperationNotice) {
        guard let undo = notice.undo, finishCurrentEdits() else { return }
        do {
            let contextBeforeUndo = currentContext
            let restored = try undo.apply(to: store)
            if let origin = notice.origin { _ = applyContext(origin) }
            revealTask(restored.id, animatedScroll: currentContext == contextBeforeUndo)
            operationNotice = TaskOperationNotice(taskID: restored.id, title: restored.title, message: L("已撤销上次操作"), symbol: "arrow.uturn.backward")
        } catch { self.error = localizedError(error) }
    }

    @ViewBuilder private var operationBar: some View {
        if let notice = operationNotice {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: notice.symbol)
                    .appFont(.system(size: 15, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.message).appFont(.callout.weight(.medium)).lineLimit(1)
                    Text(notice.title).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if notice.undo != nil {
                        Button(L("撤销")) { undoOperation(notice) }.nativeActionButton().help(L("撤销刚才的任务操作，保留其他内容修改"))
                    }
                    if let origin = notice.origin {
                        Button(L("返回原列表")) { if applyContext(origin) { dismissNavigationFeedback() } }
                            .nativeActionButton().help(L("返回操作前的项目、筛选、搜索和历史日期范围"))
                    }
                    Button(L("查看任务")) { openTask(notice.taskID) }.nativeActionButton().help(L("定位这项任务；已完成任务会在完成记录中打开"))
                    if let nextID = notice.nextTaskID {
                        Button(L("下一次任务")) { openTask(nextID) }.nativeActionButton().help(L("查看刚创建的下一次循环任务"))
                    }
                    Button { dismissNavigationFeedback() } label: {
                        Image(systemName: "xmark").appFont(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless).help(L("关闭操作提示")).accessibilityLabel(L("关闭操作提示"))
                }.fixedSize().accessibilityElement(children: .contain)
            }
            .controlSize(.small).padding(.horizontal, 28).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func projectHeading(_ project: Project?, count: Int) -> some View {
        HStack(spacing: 8) {
            Circle().fill(project.map { Color(hex: $0.colorHex) } ?? .secondary).frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(project?.name ?? L("未关联项目")).appFont(.title3.weight(.semibold)).lineLimit(1)
            if project?.isArchived == true {
                Text(L("已归档")).appFont(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.045), in: Capsule())
            }
            Text("\(count)").appFont(.title3.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel(L("\(count) 项任务"))
            Spacer()
        }.padding(.top, 2).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }

    private func planFilterTitle(_ filter: TaskPlanFilter) -> String {
        switch filter {
        case .all: return L("全部")
        case .thisWeek: return L("本周")
        case .nextWeek: return L("下周")
        case .unscheduled: return L("未安排")
        case .week(let date):
            let interval = WorkPeriod.range(containing: date, firstWeekday: weekStart)
            return "\(dayText(interval.start)) — \(dayText(interval.end.addingTimeInterval(-1)))"
        }
    }

    private func weekHeading(_ filter: TaskPlanFilter, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(planFilterTitle(filter)).appFont(.callout.weight(.semibold))
            Text("\(count)").appFont(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel(L("\(count) 项任务"))
            if let offset = [TaskPlanFilter.thisWeek: 0, .nextWeek: 1][filter] {
                let date = TaskPlanning.weekDate(offset: offset, relativeTo: planningToday, firstWeekday: weekStart)
                let range = WorkPeriod.range(containing: date, firstWeekday: weekStart)
                Text("\(dayText(range.start)) — \(dayText(range.end.addingTimeInterval(-1)))")
                    .appFont(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.top, 4).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        let title = title, search = search, isHistory = isHistory, isTimeSensitive = isTimeSensitive
        let selection = selection, historyInterval = historyInterval, planFilter = planFilter
        let planTitle = selection == .thisWeek ? L("本周") : planFilterTitle(planFilter)
        let timeSensitiveTitle = selection == .reminders ? L("暂无待处理提醒") : L("暂无\(title)任务")
        return ContentUnavailableView {
            Label(search.isEmpty ? (isHistory ? L("当前范围暂无完成记录") : (isTimeSensitive ? timeSensitiveTitle : (planFilter == .all ? L("当前列表暂无任务") : L("\(planTitle)暂无任务")))) : L("没有匹配的任务"), systemImage: search.isEmpty ? (isHistory ? "checkmark.seal" : "tray") : "magnifyingglass")
        } description: {
            VStack(spacing: 4) {
                if search.isEmpty {
                    if isHistory {
                        if let interval = historyInterval {
                            Text("\(dayText(interval.start)) — \(dayText(interval.end.addingTimeInterval(-1)))").monospacedDigit()
                        } else {
                            Text(L("全部完成记录"))
                        }
                        Text(L("完成任务后，可在对应日期范围查看。"))
                    } else if isTimeSensitive {
                        Text(selection == .reminders ? L("提醒时间已到的未完成任务会显示在这里。") : L("按截止日期查看任务，不受周计划影响。"))
                    } else {
                        Text("\(title) · \(planTitle)")
                        Text(L("新增任务，或切换计划范围查看。"))
                    }
                } else {
                    Text(isTimeSensitive ? L("试试其他关键词，或切换项目。") : L("试试其他关键词，或切换项目和计划范围。"))
                }
            }
        } actions: {
            if !isHistory && !isTimeSensitive && selection != .thisWeek && planFilter != .all {
                Button(L("全部任务")) { selectPlanFilter(.all) }.nativeActionButton()
            }
            if !isHistory && search.isEmpty {
                Button(L("新建任务"), action: createTask).nativeActionButton(prominent: true)
                    .help(L("填写任务信息，回车保存；明细和备注可用 Shift＋回车换行"))
            }
        }
    }

    private var planningFilterControls: some View {
        let tasks = planningTasks.filter { listStructure.matchingTaskIDs?.contains($0.id) ?? true }
        let groups = TaskPlanFilter.grouped(for: tasks, relativeTo: planningToday, firstWeekday: weekStart)
        let counts = Dictionary(uniqueKeysWithValues: groups.map { ($0.filter, $0.tasks.count) })
        let filters: [TaskPlanFilter] = dragState.taskID == nil ? (groups.isEmpty ? [] : [.all] + groups.map(\.filter))
            : TaskPlanFilter.options(for: planningTasks, relativeTo: planningToday, firstWeekday: weekStart)
        return planningFilterTabs(filters, counts: counts, totalCount: tasks.count)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func planningFilterTabs(_ filters: [TaskPlanFilter], counts: [TaskPlanFilter: Int], totalCount: Int) -> some View {
        TaskFlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(filters) { filter in
                planningFilterTab(filter, count: filter == .all ? totalCount : (counts[filter] ?? 0))
                    .id(filter)
            }
        }.padding(.vertical, filters.isEmpty ? 0 : 2)
    }

    private func planningFilterTab(_ filter: TaskPlanFilter, count: Int) -> some View {
        PlanningDropTab(title: planFilterTitle(filter), count: count, selected: planFilter == filter,
                        action: { selectPlanFilter(filter) }, onDrop: { moveTask($0, toPlan: filter) })
            .accessibilityIdentifier("plan.\(filter)")
    }

    private func swipePlanFilter(_ direction: TaskTabSwipeDirection) {
        let tasks = planningTasks.filter { listStructure.matchingTaskIDs?.contains($0.id) ?? true }
        let groups = TaskPlanFilter.grouped(for: tasks, relativeTo: planningToday, firstWeekday: weekStart)
        let filters: [TaskPlanFilter] = groups.isEmpty ? [] : [.all] + groups.map(\.filter)
        guard filters.count > 1 else { return }
        guard let index = filters.firstIndex(of: planFilter) else {
            selectPlanFilter(.all)
            return
        }
        let destination = index + (direction == .next ? 1 : -1)
        guard filters.indices.contains(destination) else { return }
        selectPlanFilter(filters[destination])
    }

    private func selectPlanFilter(_ filter: TaskPlanFilter) {
        guard finishCurrentEdits() else { return }
        clearSearchFocus(); dismissNavigationFeedback()
        setListLocation(selection == .thisWeek && filter != .thisWeek ? .all : selection, filter: filter)
        PlanFilterPreferences().save(filter, for: (selection ?? .all).planFilterPreferenceKey)
    }

    private func loadDisplaySetting() {
        let setting = TaskDisplayPreferences().setting(for: (selection ?? .all).planFilterPreferenceKey, defaultColumns: defaultColumns, defaultDetails: defaultDetails)
        guard setting != displaySetting else { return }
        guard finishCurrentEdits() else { return }
        if displaySetting.details != setting.details { editingRegistry.resetExpansion() }
        displaySetting = setting
    }

    private func setDisplaySetting(_ setting: TaskDisplaySetting) {
        guard finishCurrentEdits() else { return }
        TaskDisplayPreferences().save(setting, for: (selection ?? .all).planFilterPreferenceKey)
        if displaySetting.details != setting.details { editingRegistry.resetExpansion() }
        displaySetting = setting
    }

    private var displayMenu: some View {
        Menu {
            Picker(L("列数"), selection: Binding(get: { displaySetting.columns }, set: { setDisplaySetting(TaskDisplaySetting(columns: $0, details: displaySetting.details)) })) {
                ForEach(TaskColumnMode.allCases) { Text($0.title).tag($0) }
            }
            Picker(L("任务内容"), selection: Binding(get: { displaySetting.details }, set: { setDisplaySetting(TaskDisplaySetting(columns: displaySetting.columns, details: $0)) })) {
                ForEach(TaskDetailsMode.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button(L("使用设置中的默认显示方式")) {
                guard finishCurrentEdits() else { return }
                TaskDisplayPreferences().reset(for: (selection ?? .all).planFilterPreferenceKey)
                loadDisplaySetting()
            }
        } label: { Image(systemName: "rectangle.grid.2x2") }
        .id(language.localeIdentifier)
        .disabled(dragState.taskID != nil)
        .help(L("任务显示：列数与详情模式，当前项目独立记忆"))
        .accessibilityLabel(L("任务显示方式"))
    }

    @ViewBuilder private func taskHeading(_ row: TaskListRow) -> some View {
        switch row {
        case .starred(let count, _):
            HStack(spacing: 8) {
                Label(L("星标任务"), systemImage: "star.fill").appFont(.headline).foregroundStyle(.orange)
                Text("\(count)").appFont(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.top, 8).padding(.bottom, 4)
        case .week(let bucket, let count, _): weekHeading(bucket, count: count)
        case .project(let project, let count, _): projectHeading(project, count: count)
        case .completed(let count):
            HStack(spacing: 8) {
                Text(L("已完成")).appFont(.callout.weight(.semibold))
                Text("\(count)").appFont(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.top, 12).padding(.bottom, 2)
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        case .task: EmptyView()
        }
    }

    private func moveTask(_ items: [TaskDragItem], toPlan filter: TaskPlanFilter) -> Bool {
        guard items.count == 1, let id = items.first?.taskID, finishCurrentEdits(),
              let before = store.data.tasks.first(where: { $0.id == id }) else { return false }
        do {
            let after = try TaskPlanDrop.applying(filter, to: before, relativeTo: planningToday, firstWeekday: weekStart)
            if after != before { try store.saveTask(after) }
            let target = filter == .all ? TaskPlanFilter.all : TaskPlanFilter(task: after, relativeTo: planningToday, firstWeekday: weekStart)
            let origin = currentContext
            let scope: SidebarItem?
            if selection == .thisWeek && target == .thisWeek { scope = .thisWeek }
            else if selection == .thisWeek || isTimeSensitive { scope = target == .all ? .all : (after.projectID.map(SidebarItem.project) ?? .all) }
            else { scope = selection }
            setListLocation(scope, filter: target)
            PlanFilterPreferences().save(target, for: (scope ?? .all).planFilterPreferenceKey)
            revealTask(id, animatedScroll: false)
            if after != before {
                let saved = store.data.tasks.first { $0.id == id } ?? after
                operationNotice = TaskOperationNotice(taskID: id, title: saved.title, message: L("已调整周计划"), symbol: "calendar", undo: .plan(before: before, after: saved), origin: currentContext != origin ? origin : nil)
            }
            return true
        } catch { self.error = localizedError(error); return false }
    }

    private var periodControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker(L("查看范围"), selection: $historyRange) {
                    ForEach(HistoryRange.allCases, id: \.self) { Text(localizedLabel($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).frame(width: 290)
                    .accessibilityLabel(L("完成记录的日期范围")).help(L("按任务的完成日期查看工作周期、自选日期或全部历史"))
                Spacer()
                if historyRange == .week {
                    Picker(L("每周开始"), selection: $weekStart) {
                        ForEach(weekdayOptions, id: \.0) { value, label in Text(label).tag(value) }
                    }.frame(width: 190).help(L("设置每周的起始日，计划周与完成记录会同步调整"))
                }
            }
            if historyRange == .week, let interval = historyInterval {
                HStack(spacing: 8) {
                    Button { shiftWeek(-1) } label: { Image(systemName: "chevron.left") }
                        .nativeActionButton().help(L("查看上一工作周期")).accessibilityLabel(L("上一工作周期"))
                    Text("\(dayText(interval.start)) — \(dayText(interval.end.addingTimeInterval(-1)))")
                        .appFont(.callout.weight(.medium)).monospacedDigit()
                    Button { shiftWeek(1) } label: { Image(systemName: "chevron.right") }
                        .nativeActionButton().help(L("查看下一工作周期")).accessibilityLabel(L("下一工作周期"))
                    Button(L("本周期")) { weekAnchor = Date() }.nativeActionButton().help(L("回到今天所在的工作周期"))
                    Spacer()
                }
            } else if historyRange == .custom {
                HStack(spacing: 14) {
                    DatePicker(L("开始"), selection: $customStart, displayedComponents: .date).help(L("筛选完成日期不早于这一天的任务"))
                    DatePicker(L("结束"), selection: $customEnd, in: customStart..., displayedComponents: .date).help(L("包含这一天完成的任务"))
                    Spacer()
                }.fixedSize()
            }
        }.appFont(.callout).controlSize(.small).padding(.horizontal, 28).padding(.bottom, 12)
    }

    private func shiftWeek(_ direction: Int) {
        weekAnchor = Calendar.current.date(byAdding: .day, value: direction * 7, to: weekAnchor) ?? weekAnchor
    }
}

private struct NativeTaskSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    @Environment(\.appTextScale) private var textScale

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(string: text)
        field.controlSize = .small
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        // Unchanged native setters can restart toolbar constraint layout during menu tracking.
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if field.accessibilityLabel() != placeholder { field.setAccessibilityLabel(placeholder) }
        let font = NSFont.systemFont(ofSize: 12 * textScale)
        if field.font != font { field.font = font }
        if field.stringValue != text { field.stringValue = text }
        let hasFocus = field.currentEditor() != nil || field.window?.firstResponder === field
        guard focused != hasFocus, let window = field.window else { return }
        let requestedFocus = focused
        DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
            guard let field, let coordinator, field.window === window, coordinator.parent.focused == requestedFocus else { return }
            if requestedFocus { window.makeFirstResponder(field) }
            else if field.currentEditor() != nil || window.firstResponder === field { window.makeFirstResponder(nil) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeTaskSearchField
        init(_ parent: NativeTaskSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) { if !parent.focused { parent.focused = true } }
        func controlTextDidEndEditing(_ notification: Notification) { if parent.focused { parent.focused = false } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.focused = false
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}

private struct ThisWeekBadge: View {
    let count: Int
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale.identifier
        if count > 0 {
            Text("\(count)").appFont(.caption.weight(.bold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.075), in: Circle())
                .accessibilityLabel(L("本周 \(count) 项，含已超时任务"))
                .help(L("本周安排：\(count) 项（含已超时的未完成任务）"))
        }
    }
}

@Observable
final class TaskListScrollState {
    var scrolling = false
}

private struct TaskListPreservesEditingKey: EnvironmentKey {
    static let defaultValue = false
}

private struct TaskListScrollingKey: EnvironmentKey {
    static let defaultValue = TaskListScrollState()
}

extension EnvironmentValues {
    var taskListPreservesEditing: Bool {
        get { self[TaskListPreservesEditingKey.self] }
        set { self[TaskListPreservesEditingKey.self] = newValue }
    }

    var taskListScrollState: TaskListScrollState {
        get { self[TaskListScrollingKey.self] }
        set { self[TaskListScrollingKey.self] = newValue }
    }
}

private struct TaskListScrollActivity: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activity = TaskListScrollState()

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .environment(\.taskListScrollState, activity)
                .onScrollPhaseChange { _, phase in
                    let next = phase != .idle
                    guard next != activity.scrolling else { return }
                    // Moving cards must not expand under the pointer; restore hover once scrolling stops.
                    withAnimation(next || reduceMotion ? nil : .easeOut(duration: 0.18)) { activity.scrolling = next }
                }
        } else {
            content
        }
    }
}

private struct PlanningDropTab: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    let onDrop: ([TaskDragItem]) -> Bool
    @State private var targeted = false
    @ObservedObject private var dragState = TaskDragState.shared
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title).fontWeight(selected ? .semibold : .medium)
                if count > 0 { Text("\(count)").appFont(.caption.monospacedDigit()).opacity(0.8) }
            }.fixedSize()
        }
        .buttonStyle(PlanningFilterButtonStyle(selected: selected))
        .overlay(Capsule().strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
        .dropDestination(for: TaskDragItem.self) { items, _ in onDrop(items) } isTargeted: { targeted = $0 }
        .onChange(of: dragState.taskID) { _, id in if id == nil { targeted = false } }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(L("\(title)，\(count) 项待办"))
        .help(L("点击查看；拖入任务以调整周计划，拖到全部保留原计划"))
    }
}

private struct PlanningFilterButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.taskHoverEnabled) private var taskHoverEnabled
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let active = isEnabled && taskHoverEnabled && hovered
        configuration.label
            .appFont(.callout)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background {
                Capsule().fill(selected ? Color.accentColor.opacity(active ? 0.18 : 0.12) : Color.primary.opacity(active ? 0.07 : 0.035))
                    .animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.12), value: active)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
            }
            .overlay {
                Capsule().strokeBorder(selected ? Color.accentColor.opacity(active ? 0.35 : 0.24) : Color.primary.opacity(active ? 0.13 : 0.06), lineWidth: 0.7)
                    .animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.12), value: active)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovered = isEnabled && taskHoverEnabled && $0 }
            .onChange(of: taskHoverEnabled) { _, enabled in if !enabled { hovered = false } }
    }
}

private struct SidebarHoverRow<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var dropTargeted = false
    let selected: Bool
    let dropColor: Color
    let onTaskDrop: (([TaskDragItem]) -> Bool)?
    let content: Content

    init(selected: Bool = false, dropColor: Color = .accentColor, onTaskDrop: (([TaskDragItem]) -> Bool)? = nil, @ViewBuilder content: () -> Content) {
        self.selected = selected; self.dropColor = dropColor; self.onTaskDrop = onTaskDrop; self.content = content()
    }

    var body: some View {
        if let onTaskDrop {
            row.dropDestination(for: TaskDragItem.self) { items, _ in onTaskDrop(items) }
                isTargeted: { dropTargeted = $0 }
        } else {
            row
        }
    }

    private var row: some View {
        content
            .appFont(.system(size: 13, weight: .medium))
            .frame(minHeight: 24)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(dropTargeted ? dropColor.opacity(0.12) : (selected ? Color.accentColor.opacity(hovered ? 0.2 : 0.15) : Color.primary.opacity(hovered ? 0.045 : 0)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dropTargeted)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovered)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(dropTargeted ? dropColor : .clear, lineWidth: 1.5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dropTargeted))
            .onHover { hovered = $0 }
    }
}

private struct ScopeMenu: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var presented = false
    @FocusState private var focused: Bool
    @FocusState private var focusedChoice: SidebarItem?
    @AccessibilityFocusState private var accessibilityFocused: Bool
    let title: String
    let count: Int
    let weekCount: Int
    @Binding var selection: SidebarItem?
    let projects: [Project]
    let tags: [TaskTag]
    let hasPendingReminders: Bool

    private var workbenchChoices: [(String, SidebarItem)] {
        var items: [(String, SidebarItem)] = [(L("全部任务"), .all), (L("本周任务"), .thisWeek), (L("星标任务"), .starred), (L("即将到期"), .upcoming), (L("已逾期"), .overdue)]
        if hasPendingReminders || selection == .reminders { items.append((L("待处理提醒"), .reminders)) }
        return items + [(L("已完成"), .completed)]
    }

    private var choices: [(String, SidebarItem)] {
        workbenchChoices + projectChoices + tagChoices
    }

    private var projectChoices: [(String, SidebarItem)] {
        projects.filter { !$0.isArchived || selection == .project($0.id) }.map {
            ($0.name + ($0.isArchived ? L("（已归档）") : ""), .project($0.id))
        }
    }

    private var tagChoices: [(String, SidebarItem)] { tags.map { ($0.name, .tag($0.id)) } }

    var body: some View {
        let _ = locale.identifier
        let items = choices
        let active = hovered || focused || accessibilityFocused || presented
        Button { presented.toggle() } label: {
            HStack(spacing: 8) {
                if case .project(let id) = selection,
                   let project = projects.first(where: { $0.id == id }) {
                    Circle().fill(Color(hex: project.colorHex)).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                if case .tag(let id) = selection, let tag = tags.first(where: { $0.id == id }) {
                    Image(systemName: "tag").foregroundStyle(Color(hex: tag.colorHex)).accessibilityHidden(true)
                }
                if selection == .starred { Image(systemName: "star.fill").foregroundStyle(.orange).accessibilityHidden(true) }
                Text(title).appFont(.system(size: 14, weight: .semibold)).lineLimit(1)
                if weekCount > 0 { ThisWeekBadge(count: weekCount) }
                if count > 0 {
                    Text("\(count)").appFont(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").appFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).opacity(active ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
                    .accessibilityHidden(true)
            }.padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .transition(.opacity)
                    }
                }.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
        }
        .buttonStyle(.plain).fixedSize().focusable(interactions: .edit).focusEffectDisabled()
        .focused($focused).taskAccessibilityFocused($accessibilityFocused)
        .onHover { hovered = $0 }
        .accessibilityLabel(L("\(title)，\(weekCount > 0 ? L("本周 \(weekCount) 项，") : "")\(count > 0 ? L("\(count) 项任务，") : "")切换项目"))
        .help(L("点击切换项目或工作台分类"))
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("工作台")).appFont(.caption.weight(.medium)).foregroundStyle(.secondary).padding(8)
                        ForEach(items.prefix(workbenchChoices.count), id: \.1) { name, item in
                            choice(name, item: item)
                        }
                        if !projectChoices.isEmpty {
                            Divider().padding(.vertical, 4)
                            Text(L("项目")).appFont(.caption.weight(.medium)).foregroundStyle(.secondary).padding(8)
                            ForEach(projectChoices, id: \.1) { name, item in
                                choice(name, item: item)
                            }
                        }
                        if !tagChoices.isEmpty {
                            Divider().padding(.vertical, 4)
                            Text(L("标签")).appFont(.caption.weight(.medium)).foregroundStyle(.secondary).padding(8)
                            ForEach(tagChoices, id: \.1) { name, item in choice(name, item: item) }
                        }
                    }.padding(8)
                }
                .frame(width: 260, height: min(CGFloat(items.count) * 32 + 90, 440))
                .onAppear { focusedChoice = selection ?? .all }
                .onChange(of: focusedChoice) { _, item in
                    if let item { proxy.scrollTo(item) }
                }
                .onExitCommand { presented = false }
            }
        }
    }

    private func choice(_ title: String, item: SidebarItem) -> some View {
        Button { select(item) } label: {
            HStack(spacing: 8) {
                choiceIcon(item).frame(width: 18).accessibilityHidden(true)
                Text(title).appFont(.callout.weight(selection == item ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "checkmark").appFont(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 14).opacity(selection == item ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8).frame(height: 32)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(selection == item ? Color.accentColor.opacity(0.1) : Color.primary.opacity(focusedChoice == item ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(HoverHighlightButtonStyle(cornerRadius: 7)).focusable(interactions: .edit)
        .focused($focusedChoice, equals: item).focusEffectDisabled()
        .onKeyPress(.upArrow) { moveFocus(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveFocus(by: 1); return .handled }
        .onKeyPress(.return) { select(item); return .handled }
        .onKeyPress(.space) { select(item); return .handled }
        .accessibilityAddTraits(selection == item ? .isSelected : [])
        .accessibilityLabel(title)
        .help(L("查看\(title)"))
        .id(item)
    }

    @ViewBuilder private func choiceIcon(_ item: SidebarItem) -> some View {
        switch item {
        case .project(let id):
            Circle().fill(projects.first(where: { $0.id == id }).map { Color(hex: $0.colorHex) } ?? .secondary)
                .frame(width: 8, height: 8)
        case .tag(let id): Image(systemName: "tag").foregroundStyle(tags.first(where: { $0.id == id }).map { Color(hex: $0.colorHex) } ?? .secondary)
        case .starred: Image(systemName: "star.fill").foregroundStyle(.orange)
        case .all: Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
        case .thisWeek: Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary)
        case .upcoming: Image(systemName: "calendar").foregroundStyle(.secondary)
        case .overdue: Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
        case .reminders: Image(systemName: "bell.badge").foregroundStyle(.secondary)
        case .completed: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }

    private func moveFocus(by offset: Int) {
        let items = choices
        let index = items.firstIndex { $0.1 == focusedChoice } ?? 0
        focusedChoice = items[min(max(index + offset, 0), items.count - 1)].1
    }

    private func select(_ item: SidebarItem) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            presented = false
        }
        if selection != item { selection = item }
        DispatchQueue.main.async { focused = true }
    }
}

struct HoverGlassButton<Label: View>: View {
    @Environment(\.taskHoverEnabled) private var taskHoverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @FocusState private var focused: Bool
    @AccessibilityFocusState private var accessibilityFocused: Bool
    let size: CGFloat
    let action: () -> Void
    let label: Label

    init(size: CGFloat = 32, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.size = size; self.action = action; self.label = label()
    }

    var body: some View {
        let active = taskHoverEnabled && (hovered || focused || accessibilityFocused)
        Button(action: action) {
            label
                .frame(width: size, height: size)
                .contentShape(Circle())
                .background {
                    if active {
                        Circle().fill(Color.primary.opacity(0.055))
                            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .transition(.opacity)
                    }
                }.animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.12), value: active)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .taskAccessibilityFocused($accessibilityFocused)
        .onHover { hovered = taskHoverEnabled && $0 }
        .onChange(of: taskHoverEnabled) { _, enabled in if !enabled { hovered = false } }
    }
}

struct HoverHighlightButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.taskHoverEnabled) private var taskHoverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isEnabled && taskHoverEnabled && hovered {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(0.055)).transition(.opacity)
                }
            }
            .animation(reduceMotion || !taskHoverEnabled ? nil : .easeOut(duration: 0.12), value: hovered)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .onHover { hovered = isEnabled && taskHoverEnabled && $0 }
            .onChange(of: taskHoverEnabled) { _, enabled in if !enabled { hovered = false } }
    }
}

private struct TagEditor: View {
    @EnvironmentObject private var store: WorkStore
    @Environment(\.dismiss) private var dismiss
    let tag: TaskTag?
    @State private var name: String
    @State private var color: String
    @State private var error: String?
    private let colors = ["168C83", "397CC6", "9866C7", "D98C32", "C85E70", "617181"]

    init(tag: TaskTag? = nil) {
        self.tag = tag
        _name = State(initialValue: tag?.name ?? "")
        _color = State(initialValue: tag?.colorHex ?? "9866C7")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(tag == nil ? L("新建标签") : L("编辑标签")).appFont(.title2.bold())
            TextField(L("标签名称"), text: $name).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("tag.name").help(L("输入标签名称"))
            HStack(spacing: 14) {
                Text(L("标签颜色")).foregroundStyle(.secondary)
                ForEach(colors, id: \.self) { hex in
                    HoverGlassButton(action: { color = hex }) {
                        Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                            .overlay { if color == hex { Image(systemName: "checkmark").appFont(.caption.bold()).foregroundStyle(.white) } }
                    }.accessibilityLabel(L("颜色 \(hex)")).help(L("选择标签颜色"))
                }
            }
            if let error { Text(error).appFont(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.nativeActionButton().keyboardShortcut(.cancelAction)
                Button(tag == nil ? L("创建") : L("保存")) {
                    do {
                        if let tag { _ = try store.updateTag(id: tag.id, name: name, colorHex: color) }
                        else { _ = try store.addTag(name: name, colorHex: color) }
                        dismiss()
                    } catch { self.error = localizedError(error) }
                }
                .nativeActionButton(prominent: true).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("tag.save")
            }
        }.padding(26).frame(width: 450)
    }
}

private struct ProjectEditor: View {
    @EnvironmentObject private var store: WorkStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = "168C83"
    @State private var error: String?
    private let colors = ["168C83", "397CC6", "9866C7", "D98C32", "C85E70", "617181"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L("新建项目")).appFont(.title2.bold())
            TextField(L("项目名称"), text: $name).textFieldStyle(.roundedBorder).help(L("输入新项目的名称"))
            HStack(spacing: 14) {
                Text(L("项目颜色")).foregroundStyle(.secondary)
                ForEach(colors, id: \.self) { hex in
                    HoverGlassButton(action: { color = hex }) {
                        Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                            .overlay { if color == hex { Image(systemName: "checkmark").appFont(.caption.bold()).foregroundStyle(.white) } }
                    }.accessibilityLabel(L("颜色 \(hex)")).help(L("选择此项目颜色"))
                }
            }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.nativeActionButton().keyboardShortcut(.cancelAction).help(L("取消新建项目（Esc）"))
                Button(L("创建")) {
                    do { _ = try store.addProject(name: name, colorHex: color); dismiss() }
                    catch { self.error = localizedError(error) }
                }.nativeActionButton(prominent: true).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(L("创建项目（回车）"))
            }
        }.padding(26).frame(width: 450)
            .alert(L("无法创建项目"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L("好")) { error = nil }
            } message: { Text(error ?? "") }
    }
}


extension View {
    @ViewBuilder
    func hideStandardToolbarTitle() -> some View {
        if #available(macOS 15.0, *) { toolbar(removing: .title) }
        else { navigationTitle("") }
    }

    @ViewBuilder
    func nativeActionButton(prominent: Bool = false) -> some View {
        if prominent { buttonStyle(.borderedProminent) }
        else { buttonStyle(.bordered) }
    }
}

private var weekdayOptions: [(Int, String)] {
    var calendar = Calendar.current
    calendar.locale = AppLocalization.locale
    return [2, 3, 4, 5, 6, 7, 1].map { ($0, calendar.weekdaySymbols[$0 - 1]) }
}

func dayText(_ date: Date) -> String {
    date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).locale(AppLocalization.locale))
}

func repeatText(_ rule: RepeatRule) -> String {
    let unit: String
    switch rule.unit {
    case .day: unit = L("天")
    case .week: unit = L("周")
    case .month: unit = L("个月")
    case .year: unit = L("年")
    }
    return L("\(rule.basis == .completion ? L("完成后") : L("按计划"))每 \(rule.every) \(unit)")
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x168C83
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct TaskTagIconButton: View {
    let tag: TaskTag
    let isPickerPresented: Bool
    let action: () -> Void
    @Environment(\.appTextScale) private var textScale
    @Environment(\.taskHoverEnabled) private var hoverEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "tag.fill")
                .appFont(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: tag.colorHex))
                .frame(width: 22 * textScale, height: 24 * textScale)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(HoverHighlightButtonStyle(cornerRadius: 5))
        .accessibilityLabel(L("标签：\(tag.name)"))
        .background(TaskTagTooltipRegion(text: hoverEnabled && !isPickerPresented ? tag.name : nil))
    }
}

private struct TaskTagTooltipRegion: NSViewRepresentable {
    let text: String?

    func makeNSView(context: Context) -> TooltipView {
        let view = TooltipView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: TooltipView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }

    final class TooltipView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
