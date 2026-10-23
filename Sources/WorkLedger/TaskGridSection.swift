import Foundation

struct TaskGridSection: Identifiable {
    let headings: [TaskListRow]
    let tasks: [TaskListRow]
    var id: String { headings.last?.id ?? "tasks" }

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
