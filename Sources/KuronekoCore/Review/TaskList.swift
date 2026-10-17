import Foundation

/// Which pendências the list shows: every one, the user's ("você"), the
/// other people's, or one person's.
public enum TaskFilter: Hashable, Sendable {
    case all
    case mine
    case others
    case owner(String)

    public func matches(_ task: TaskItem) -> Bool {
        switch self {
        case .all: true
        case .mine: task.isMine
        case .others: !task.isMine && task.owner?.trimmingCharacters(in: .whitespaces).isEmpty == false
        case .owner(let name): !task.isMine && task.owner.map { TaskItem.sameName($0, name) } == true
        }
    }

    /// The other people with pendências, each once, in alphabetical order.
    public static func owners(in tasks: [TaskItem]) -> [String] {
        var owners: [String] = []
        for task in tasks where !task.isMine {
            guard let owner = task.owner?.trimmingCharacters(in: .whitespaces), !owner.isEmpty,
                  !owners.contains(where: { TaskItem.sameName($0, owner) }) else { continue }
            owners.append(owner)
        }
        return owners.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// How the Pendências list puts them together: by the meeting that last
/// spoke of them, by owner, or by the values of a tag key.
public enum TaskGrouping: Hashable, Sendable {
    case status
    case meeting
    case owner
    case tagKey(String)
}

/// A section of the Pendências list, or a column of the board.
public struct TaskSection: Equatable, Sendable, Identifiable {
    public var title: String
    /// The meeting to open, when grouped by meeting.
    public var meetingId: Int64?
    public var meetingStartedAt: Date?
    /// The status, when grouped by status.
    public var statusId: Int64?
    /// The owner or the tag value it stands for; nil for "Sem dono" and
    /// "Sem <key>". What a pendência dropped on the column gets.
    public var value: String?
    public var tasks: [TaskItem]

    public init(title: String, meetingId: Int64? = nil, meetingStartedAt: Date? = nil, statusId: Int64? = nil, value: String? = nil, tasks: [TaskItem]) {
        self.title = title
        self.meetingId = meetingId
        self.meetingStartedAt = meetingStartedAt
        self.statusId = statusId
        self.value = value
        self.tasks = tasks
    }

    public var id: String {
        if let meetingId { return "meeting:\(meetingId)" }
        if let statusId { return "status:\(statusId)" }
        return "title:\(title)"
    }
}

/// The Pendências list as the user asked for it.
public enum TaskListLayout {
    /// Pendências carrying every one of `tags`.
    public static func filter(_ tasks: [TaskItem], tags: Set<String>) -> [TaskItem] {
        guard !tags.isEmpty else { return tasks }
        return tasks.filter { tags.isSubset(of: $0.tags) }
    }

    /// Pendências of any of `owners`; none chosen is every one.
    public static func filter(_ tasks: [TaskItem], owners: Set<String>) -> [TaskItem] {
        guard !owners.isEmpty else { return tasks }
        return tasks.filter { task in
            guard let owner = task.owner else { return false }
            return owners.contains { TaskItem.sameName($0, owner) }
        }
    }

    /// Pendências in none of the `hidden` statuses: a status the user
    /// creates shows up until they hide it.
    public static func filter(_ tasks: [TaskItem], hiding hidden: Set<Int64>) -> [TaskItem] {
        guard !hidden.isEmpty else { return tasks }
        return tasks.filter { !hidden.contains($0.statusId) }
    }

    /// Keys of the tags in use, to group by.
    public static func tagKeys(in tasks: [TaskItem]) -> [String] {
        Set(tasks.flatMap { $0.tags.compactMap(TagName.key) }).sorted()
    }

    /// By meeting, newest first; by owner, the user first, then by name,
    /// then "Sem dono"; by tag key, one section per value, then "Sem <key>".
    /// By status, in the order of `statuses`; the empty ones too with
    /// `keepingEmpty` (the board's columns, somewhere to drop).
    public static func sections(_ tasks: [TaskItem], grouping: TaskGrouping, statuses: [TaskStatus] = [], keepingEmpty: Bool = false) -> [TaskSection] {
        switch grouping {
        case .status:
            let byStatus = Dictionary(grouping: tasks, by: \.statusId)
            return statuses.compactMap { status in
                guard let id = status.id else { return nil }
                let tasks = byStatus[id] ?? []
                guard keepingEmpty || !tasks.isEmpty else { return nil }
                return TaskSection(title: status.name, statusId: id, tasks: tasks)
            }
        case .meeting:
            return TaskGroup.byMeeting(tasks).map {
                TaskSection(title: $0.meetingTitle, meetingId: $0.meetingId, meetingStartedAt: $0.meetingStartedAt, tasks: $0.tasks)
            }
        case .owner:
            var mine: [TaskItem] = [], without: [TaskItem] = []
            var byOwner: [(name: String, tasks: [TaskItem])] = []
            for task in tasks {
                if task.isMine {
                    mine.append(task)
                } else if let owner = task.owner?.trimmingCharacters(in: .whitespaces), !owner.isEmpty {
                    if let at = byOwner.firstIndex(where: { TaskItem.sameName($0.name, owner) }) {
                        byOwner[at].tasks.append(task)
                    } else {
                        byOwner.append((owner, [task]))
                    }
                } else {
                    without.append(task)
                }
            }
            var sections = mine.isEmpty ? [] : [TaskSection(title: "Você", value: "você", tasks: mine)]
            sections += byOwner
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { TaskSection(title: $0.name, value: $0.name, tasks: $0.tasks) }
            if !without.isEmpty { sections.append(TaskSection(title: "Sem dono", tasks: without)) }
            return sections
        case .tagKey(let key):
            var byValue: [String: [TaskItem]] = [:]
            var without: [TaskItem] = []
            for task in tasks {
                let values = Set(task.tags.filter { TagName.key(of: $0) == key }.map(TagName.value))
                if values.isEmpty { without.append(task) }
                for value in values { byValue[value, default: []].append(task) }
            }
            var sections = byValue.keys.sorted().map { TaskSection(title: $0, value: $0, tasks: byValue[$0] ?? []) }
            if !without.isEmpty { sections.append(TaskSection(title: "Sem \(key)", tasks: without)) }
            return sections
        }
    }
}

/// Pendências of one meeting, as the list shows them.
public struct TaskGroup: Equatable, Sendable, Identifiable {
    public var meetingId: Int64
    public var meetingTitle: String
    public var meetingStartedAt: Date
    public var tasks: [TaskItem]

    public var id: Int64 { meetingId }

    /// Newest meeting first; inside each, in the order the tasks come.
    public static func byMeeting(_ tasks: [TaskItem]) -> [TaskGroup] {
        var groups: [TaskGroup] = []
        var index: [Int64: Int] = [:]
        for task in tasks {
            if let at = index[task.meetingId] {
                groups[at].tasks.append(task)
            } else {
                index[task.meetingId] = groups.count
                groups.append(TaskGroup(
                    meetingId: task.meetingId,
                    meetingTitle: task.meetingTitle,
                    meetingStartedAt: task.meetingStartedAt,
                    tasks: [task]
                ))
            }
        }
        return groups.sorted {
            ($0.meetingStartedAt, $0.meetingId) > ($1.meetingStartedAt, $1.meetingId)
        }
    }
}

extension TaskItem {
    /// Owned by the user ("você").
    public var isMine: Bool {
        owner.map { Self.sameName($0, "você") } ?? false
    }

    /// Different days on which meetings spoke of it.
    public func mentionDays(calendar: Calendar = .current) -> Int {
        Set(mentions.map { calendar.startOfDay(for: $0.at) }).count
    }

    /// "falada em 4 dias"; nil when only one day spoke of it.
    public func mentionsText(calendar: Calendar = .current) -> String? {
        let days = mentionDays(calendar: calendar)
        return days > 1 ? "falada em \(days) dias" : nil
    }

    /// Every word of the query in the text, the owner or the meeting title,
    /// ignoring case and accents.
    public func matches(_ query: String) -> Bool {
        let haystack = [text, owner ?? "", meetingTitle].joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { haystack.localizedStandardContains($0) }
    }

    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespaces)
            .compare(rhs.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
