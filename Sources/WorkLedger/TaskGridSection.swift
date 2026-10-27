import SwiftUI

struct TaskColumnLayout: Layout {
    let idealWidth: CGFloat
    var spacing: CGFloat = TaskColumnMode.spacing

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? max(0, idealWidth)
        guard width > 0, !subviews.isEmpty else { return CGSize(width: width, height: 0) }
        let columnWidth = max(0, (width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = max(0, (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (width + spacing), y: bounds.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

struct TaskGridSection: Identifiable {
    let headings: [TaskListRow]
    let tasks: [TaskListRow]
    var id: String { headings.last?.id ?? tasks.first?.id ?? "tasks" }

    static func rows(_ rows: [TaskListRow], columns: Int) -> [Self] {
        let count = max(1, columns)
        return grouped(rows).flatMap { section in
            stride(from: 0, to: section.tasks.count, by: count).map { start in
                Self(headings: start == 0 ? section.headings : [],
                     tasks: Array(section.tasks[start..<min(start + count, section.tasks.count)]))
            }
        }
    }

    static func grouped(_ rows: [TaskListRow]) -> [Self] {
        var result: [Self] = []
        var headings: [TaskListRow] = [], tasks: [TaskListRow] = []
        for row in rows {
            if case .task = row { tasks.append(row) }
            else {
                if !tasks.isEmpty {
                    result.append(Self(headings: headings, tasks: tasks))
                    headings = []; tasks = []
                }
                headings.append(row)
            }
        }
        if !tasks.isEmpty { result.append(Self(headings: headings, tasks: tasks)) }
        return result
    }
}
