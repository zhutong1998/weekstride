import SwiftUI
import WorkLedgerCore

enum TaskDateShortcut: String, CaseIterable, Identifiable {
    case today = "今天"
    case tomorrow = "明天"
    case nextWeek = "下周"
    case nextMonth = "下个月"

    var id: Self { self }

    func date(relativeTo reference: Date, firstWeekday: Int, calendar: Calendar = .current) -> Date {
        switch self {
        case .today:
            return reference
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: reference) ?? reference
        case .nextWeek:
            let start = WorkPeriod.range(containing: reference, firstWeekday: firstWeekday, calendar: calendar).end
            let time = calendar.dateComponents([.hour, .minute, .second], from: reference)
            return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                 second: time.second ?? 0, of: start) ?? start
        case .nextMonth:
            return calendar.date(byAdding: .month, value: 1, to: reference) ?? reference
        }
    }
}

enum TaskCalendarGrid {
    static func displayHour(_ hour: Int, twelveHour: Bool) -> Int {
        twelveHour ? (hour + 11) % 12 + 1 : hour
    }

    static func hour24(_ hour: Int, afternoon: Bool) -> Int { hour % 12 + (afternoon ? 12 : 0) }

    static func days(in month: Date, calendar: Calendar) -> [Date?] {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        var days = Array<Date?>(repeating: nil, count: leading)
        days += range.map { calendar.date(byAdding: .day, value: $0 - 1, to: start) }
        days += Array<Date?>(repeating: nil, count: (7 - days.count % 7) % 7)
        return days
    }

    static func shiftedMonth(_ month: Date, by offset: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: .month, value: offset, to: month) ?? month
    }

    static func selecting(_ day: Date, preservingTimeOf selection: Date, calendar: Calendar) -> Date {
        let time = calendar.dateComponents([.hour, .minute, .second], from: selection)
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                             second: time.second ?? 0, of: day) ?? day
    }

    static func settingTime(hour: Int, minute: Int, on date: Date, calendar: Calendar) -> Date {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return date }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }
}

struct TaskDatePicker: View {
    @AppStorage("weekStart") private var weekStart = 5
    @AppStorage("appTimeFormat") private var timeFormat: AppTimeFormat = .system
    @Environment(\.locale) private var locale
    @State private var selection: Date
    @State private var displayedMonth: Date
    let includesTime: Bool
    let title: String?
    let onConfirm: (Date) -> Void
    let onCancel: () -> Void

    init(initialDate: Date, includesTime: Bool = false, title: String? = nil,
         onConfirm: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        _selection = State(initialValue: initialDate)
        _displayedMonth = State(initialValue: Calendar.current.dateInterval(of: .month, for: initialDate)?.start ?? initialDate)
        self.includesTime = includesTime
        self.title = title
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = locale
        calendar.firstWeekday = (1...7).contains(weekStart) ? weekStart : 2
        return calendar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title ?? (includesTime ? L("选择日期与时间") : L("选择日期")))
                .appFont(.system(size: 15, weight: .semibold))
            Divider()
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    monthCalendar
                    Divider()
                    HStack {
                        Text(L("日期"))
                            .appFont(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        DatePicker(L("日期"), selection: $selection, displayedComponents: .date)
                            .datePickerStyle(.field).labelsHidden().controlSize(.regular)
                            .help(L("直接输入日期，点击确定后保存"))
                    }
                    if includesTime { timeControls }
                }
                .frame(width: 288)
                Divider()
                shortcuts.frame(width: 112)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 8) {
                Text(L("选择后点击“确定”保存"))
                    .appFont(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(L("取消"), action: onCancel)
                    .nativeActionButton().keyboardShortcut(.cancelAction)
                    .help(L("关闭日期选择，保留原来的日期"))
                Button(L("确定")) { confirm(selection) }
                    .nativeActionButton(prominent: true).keyboardShortcut(.defaultAction)
                    .help(L("保存选中的日期\(includesTime ? L("与时间") : "")"))
            }
            .controlSize(.regular)
        }
        .appFont(.system(size: 13))
        .padding(16).frame(width: 460)
        .environment(\.calendar, calendar)
        .onChange(of: selection) { previous, date in
            guard !calendar.isDate(previous, inSameDayAs: date) else { return }
            displayedMonth = calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
    }

    private var selectedHour: Int { calendar.component(.hour, from: selection) }
    private var selectedMinute: Int { calendar.component(.minute, from: selection) }
    private var usesTwelveHourTime: Bool {
        if timeFormat != .system { return timeFormat == .twelveHour }
        return Locale.current.hourCycle == .oneToTwelve || Locale.current.hourCycle == .zeroToEleven
    }
    private var clockHour: Int { TaskCalendarGrid.displayHour(selectedHour, twelveHour: usesTwelveHourTime) }

    private var timeControls: some View {
        HStack(spacing: 8) {
            Text(L("时间"))
                .appFont(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Picker(L("小时"), selection: Binding(get: { clockHour }, set: { hour in
                setTime(hour: usesTwelveHourTime ? TaskCalendarGrid.hour24(hour, afternoon: selectedHour >= 12) : hour, minute: selectedMinute)
            })) {
                ForEach(usesTwelveHourTime ? Array(1...12) : Array(0..<24), id: \.self) { hour in Text(String(format: "%02d", hour)).tag(hour) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: usesTwelveHourTime ? 60 : 76)
            .accessibilityLabel(L("小时")).help(L("选择小时"))
            Text(":").foregroundStyle(.secondary)
            Picker(L("分钟"), selection: Binding(get: { selectedMinute }, set: { setTime(hour: selectedHour, minute: $0) })) {
                ForEach(0..<60) { minute in Text(String(format: "%02d", minute)).tag(minute) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: usesTwelveHourTime ? 60 : 76)
            .accessibilityLabel(L("分钟")).help(L("选择分钟"))
            if usesTwelveHourTime {
                Picker(L("上午或下午"), selection: Binding(get: { selectedHour >= 12 }, set: { afternoon in
                    setTime(hour: TaskCalendarGrid.hour24(clockHour, afternoon: afternoon), minute: selectedMinute)
                })) {
                    Text(calendar.amSymbol).tag(false)
                    Text(calendar.pmSymbol).tag(true)
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 64)
                .accessibilityLabel(L("上午或下午"))
            }
        }
        .monospacedDigit().controlSize(.regular)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("快捷选择"))
                .appFont(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(TaskDateShortcut.allCases) { shortcut in
                Button { apply(shortcut) } label: {
                    Text(localizedLabel(shortcut.rawValue)).frame(maxWidth: .infinity, minHeight: 18)
                }
                .nativeActionButton().controlSize(.regular)
                .help(L("选择\(localizedLabel(shortcut.rawValue))，点击确定后保存"))
            }
            if includesTime {
                Divider().padding(.vertical, 6)
                Text(L("常用时间"))
                    .appFont(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach([9, 12, 14, 18], id: \.self) { hour in
                    let time = timeFormat.formatted(TaskCalendarGrid.settingTime(hour: hour, minute: 0, on: selection, calendar: calendar), locale: locale)
                    Button { setTime(hour: hour, minute: 0) } label: {
                        Text(time)
                            .monospacedDigit().frame(maxWidth: .infinity, minHeight: 18)
                    }
                    .nativeActionButton(prominent: selectedHour == hour && selectedMinute == 0)
                    .controlSize(.regular)
                    .help(L("设为 \(time)，点击确定后保存"))
                }
            }
        }
    }

    private func setTime(hour: Int, minute: Int) {
        selection = TaskCalendarGrid.settingTime(hour: hour, minute: minute, on: selection, calendar: calendar)
    }

    private var monthCalendar: some View {
        VStack(spacing: 6) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .appFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 28, height: 28)
                }
                .buttonStyle(HoverHighlightButtonStyle(cornerRadius: 14)).help(L("上个月")).accessibilityLabel(L("上个月"))
                Spacer()
                Text(displayedMonth.formatted(.dateTime.year().month(.wide).locale(locale)))
                    .appFont(.system(size: 12, weight: .medium))
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .appFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 28, height: 28)
                }
                .buttonStyle(HoverHighlightButtonStyle(cornerRadius: 14)).help(L("下个月")).accessibilityLabel(L("下个月"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 3) {
                ForEach(0..<7, id: \.self) { column in
                    let weekday = (calendar.firstWeekday - 1 + column) % 7
                    Text(calendar.veryShortStandaloneWeekdaySymbols[weekday])
                        .appFont(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(height: 22)
                        .accessibilityLabel(calendar.weekdaySymbols[weekday])
                }
                let days = TaskCalendarGrid.days(in: displayedMonth, calendar: calendar)
                ForEach(days.indices, id: \.self) { index in
                    if let day = days[index] {
                        dayButton(day)
                    } else {
                        Color.clear.frame(height: 36).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func dayButton(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selection)
        let today = calendar.isDateInToday(day)
        return Button {
            selection = TaskCalendarGrid.selecting(day, preservingTimeOf: selection, calendar: calendar)
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .appFont(.system(size: 13, weight: selected || today ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background {
                    if selected { Circle().fill(Color.accentColor).frame(width: 30, height: 30) }
                }
                .overlay {
                    if today && !selected {
                        Circle().stroke(Color.accentColor, lineWidth: 1).frame(width: 30, height: 30)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightButtonStyle(cornerRadius: 18))
        .accessibilityLabel(day.formatted(.dateTime.year().month(.wide).day().weekday(.wide).locale(locale)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(L("选择\(day.formatted(.dateTime.year().month(.wide).day().locale(locale)))，点击确定后保存"))
    }

    private func shiftMonth(_ offset: Int) {
        displayedMonth = TaskCalendarGrid.shiftedMonth(displayedMonth, by: offset, calendar: calendar)
    }

    private func apply(_ shortcut: TaskDateShortcut) {
        let now = Date()
        let time = calendar.dateComponents([.hour, .minute, .second], from: selection)
        let reference = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                      second: time.second ?? 0, of: now) ?? now
        let date = shortcut.date(relativeTo: reference, firstWeekday: weekStart, calendar: calendar)
        selection = date
        displayedMonth = calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    private func confirm(_ date: Date) {
        onConfirm(includesTime ? date : calendar.startOfDay(for: date))
    }
}
