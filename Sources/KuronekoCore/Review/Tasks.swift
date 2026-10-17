import Foundation
import GRDB

/// Which pendência: "task:12". The references from before pendências were
/// their own — a line of a meeting's summary ("summary:12:7:9f86d081":
/// meeting, line, fingerprint of the text) or a #acao note ("note:45") —
/// still find the pendência they became.
public enum TaskRef: Hashable, Sendable, LosslessStringConvertible {
    case task(id: Int64)
    case summary(meetingId: Int64, line: Int, fingerprint: String)
    case note(id: Int64)

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        switch parts.first {
        case "task" where parts.count == 2:
            guard let id = Int64(parts[1]) else { return nil }
            self = .task(id: id)
        case "summary" where parts.count == 4:
            guard let meetingId = Int64(parts[1]), let line = Int(parts[2]), line >= 0, !parts[3].isEmpty else { return nil }
            self = .summary(meetingId: meetingId, line: line, fingerprint: String(parts[3]))
        case "note" where parts.count == 2:
            guard let id = Int64(parts[1]) else { return nil }
            self = .note(id: id)
        default:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .task(let id): "task:\(id)"
        case .summary(let meetingId, let line, let fingerprint): "summary:\(meetingId):\(line):\(fingerprint)"
        case .note(let id): "note:\(id)"
        }
    }
}

/// A pendência as the list, the meeting screen and the `kuroneko` command
/// show it: what, who, its status, and every meeting that spoke of it. `meetingId`, `startMs` and the like are of one of those meetings: the
/// one being looked at, or else the last one to speak of it.
public struct TaskItem: Codable, Equatable, Sendable, Identifiable {
    /// Notes with this tag are pendências of the user.
    public static let noteTag = "acao"

    /// `TaskRef` as text ("task:12"), for `kuroneko task status`.
    public var ref: String
    public var taskId: Int64
    /// How it first came up: "summary", "note" or "manual".
    public var source: String
    public var meetingId: Int64
    public var meetingTitle: String
    public var meetingStartedAt: Date
    public var text: String
    /// As said: "Bruno", "você".
    public var owner: String?
    /// Moment of that meeting's recording.
    public var startMs: Int?
    /// The name of its status: "Aberta", "Fazendo", "Feita"…
    public var status: String
    public var statusId: Int64
    /// When it first came up.
    public var createdAt: Date
    /// Every meeting that spoke of it, oldest first.
    public var mentions: [Mention]
    /// Its own and its meetings', minus the ones taken off it.
    public var tags: [String]

    public struct Mention: Codable, Equatable, Sendable, Identifiable {
        public var id: Int64
        public var meetingId: Int64
        public var meetingTitle: String
        /// When it was said.
        public var at: Date
        public var text: String
        public var owner: String?
        public var startMs: Int?
        public var source: String
    }

    public var id: String { ref }

    /// The text of a #acao note without the tag.
    static func noteText(_ text: String) -> String {
        text.replacing(/(?i)#acao(?![\p{L}\p{N}_-])/, with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Newest meeting first; inside a meeting, in the order of the recording.
    static func recordingOrder(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.meetingStartedAt != rhs.meetingStartedAt { return lhs.meetingStartedAt > rhs.meetingStartedAt }
        if lhs.meetingId != rhs.meetingId { return lhs.meetingId > rhs.meetingId }
        let left = lhs.startMs ?? .max, right = rhs.startMs ?? .max
        if left != right { return left < right }
        return lhs.taskId < rhs.taskId
    }
}

/// The app thinks one pendência repeats another; the user joins them or not.
public struct TaskMergeProposal: Codable, Equatable, Sendable, Identifiable {
    /// The newer one, which would go.
    public var task: TaskItem
    /// The one it repeats, which would stay.
    public var into: TaskItem

    public var id: String { "\(task.taskId)>\(into.taskId)" }
}

public enum TaskError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    /// There is always at least one status.
    case lastStatus
    case statusExists(String)
    case emptyStatusName

    public var description: String {
        switch self {
        case .notFound(let ref): "pendência não encontrada: \(ref)"
        case .lastStatus: "é preciso ter pelo menos um status"
        case .statusExists(let name): "já existe o status \(name)"
        case .emptyStatusName: "o status precisa de um nome"
        }
    }
}

extension AppDatabase {
    /// Decisões of the meeting's summary (its pendências became the
    /// meeting's, `tasks(meetingId:)`).
    public func summaryItems(meetingId: Int64) throws -> [SummaryItem] {
        try documents(meetingId: meetingId).first { $0.kind == "summary" }.map { SummaryItems.parse($0.body) } ?? []
    }

    /// Every pendência, whatever its status (what to show is the user's
    /// filter), in the user's order.
    public func tasks() throws -> [TaskItem] {
        try writer.read { db in try Self.taskItems(db, TaskRecord.all()) }
    }

    /// Pendências the meeting spoke of, told from that meeting (its moment
    /// of the recording), in the order of the recording.
    public func tasks(meetingId: Int64) throws -> [TaskItem] {
        try writer.read { db in
            let ids = try Int64.fetchAll(db, sql: "SELECT DISTINCT taskId FROM taskMention WHERE meetingId = ?", arguments: [meetingId])
            return try Self.taskItems(db, TaskRecord.filter(ids.contains(Column("id"))), focus: meetingId)
                .sorted(by: TaskItem.recordingOrder)
        }
    }

    public func task(_ ref: TaskRef) throws -> TaskItem? {
        try writer.read { db in
            guard let id = try Self.taskId(db, ref) else { return nil }
            return try Self.taskItems(db, TaskRecord.filter(Column("id") == id)).first
        }
    }

    @discardableResult
    public func setTaskStatus(_ ref: TaskRef, statusId: Int64) throws -> TaskItem {
        try writer.write { db in try Self.setStatus(db, ref, statusId: statusId) }
    }

    /// By name, ignoring case and accents, as `kuroneko task status` does.
    @discardableResult
    public func setTaskStatus(_ ref: TaskRef, named name: String) throws -> TaskItem {
        guard let status = try taskStatuses().first(where: { TaskItem.sameName($0.name, name) }), let id = status.id else {
            throw TaskError.notFound("status \(name)")
        }
        return try setTaskStatus(ref, statusId: id)
    }

    private static func setStatus(_ db: Database, _ ref: TaskRef, statusId: Int64) throws -> TaskItem {
        guard let id = try Self.taskId(db, ref) else { throw TaskError.notFound(ref.description) }
        try TaskStore.setStatus(db, taskId: id, statusId: statusId)
        guard let item = try Self.taskItems(db, TaskRecord.filter(Column("id") == id)).first else {
            throw TaskError.notFound(ref.description)
        }
        return item
    }

    /// A pendência the user writes, in a meeting.
    @discardableResult
    public func addTask(_ text: String, owner: String?, meetingId: Int64, tMs: Int? = nil, at date: Date = Date()) throws -> TaskItem {
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let owner = owner?.trimmingCharacters(in: .whitespaces)
        return try writer.write { db in
            guard let meeting = try Meeting.fetchOne(db, key: meetingId) else { throw TaskError.notFound("reunião \(meetingId)") }
            var task = TaskRecord(
                text: text, owner: owner?.isEmpty == false ? owner : nil,
                statusId: try TaskStore.firstStatusId(db), source: "manual", createdAt: date
            )
            try task.insert(db)
            var mention = TaskMention(
                taskId: task.id!, meetingId: meetingId, source: "manual", text: text, owner: task.owner, tMs: tMs,
                at: tMs.map { meeting.date(atOffsetMs: $0) } ?? date
            )
            try mention.insert(db)
            try TaskStore.placeOnTop(db, [task.id!])
            return try Self.taskItems(db, TaskRecord.filter(Column("id") == task.id!)).first!
        }
    }

    /// Just before `other` in the user's order of the pendências, or just
    /// after.
    public func moveTask(_ taskId: Int64, nextTo other: Int64, after: Bool = false) throws {
        try writer.write { db in try TaskStore.place(db, taskId, nextTo: other, after: after) }
    }

    /// New text or owner; the meetings keep what they said.
    @discardableResult
    public func updateTask(_ ref: TaskRef, text: String, owner: String?) throws -> TaskItem {
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let owner = owner?.trimmingCharacters(in: .whitespaces)
        return try writer.write { db in
            guard let id = try Self.taskId(db, ref), var task = try TaskRecord.fetchOne(db, key: id), !text.isEmpty else {
                throw TaskError.notFound(ref.description)
            }
            task.text = text
            task.owner = owner?.isEmpty == false ? owner : nil
            try task.update(db)
            return try Self.taskItems(db, TaskRecord.filter(Column("id") == id)).first!
        }
    }

    // MARK: - Repeated pendências

    /// What the app thinks repeats what, waiting for the user.
    public func mergeProposals() throws -> [TaskMergeProposal] {
        try writer.read { db in
            let merges = try TaskMerge.filter(Column("status") == TaskMerge.proposed).order(Column("createdAt")).fetchAll(db)
            let ids = Set(merges.flatMap { [$0.taskId, $0.intoTaskId] })
            let items = Dictionary(uniqueKeysWithValues: try Self.taskItems(db, TaskRecord.filter(ids.contains(Column("id")))).map { ($0.taskId, $0) })
            return merges.compactMap { merge in
                guard let task = items[merge.taskId], let into = items[merge.intoTaskId] else { return nil }
                return TaskMergeProposal(task: task, into: into)
            }
        }
    }

    /// Pendências already compared: proposed for joining, or turned down.
    public func taskIdsWithMergeDecision() throws -> Set<Int64> {
        try writer.read { db in Set(try Int64.fetchAll(db, sql: "SELECT taskId FROM taskMerge")) }
    }

    public func proposeMerge(taskId: Int64, into intoTaskId: Int64, at date: Date = Date()) throws {
        try writer.write { db in try TaskStore.propose(db, taskId: taskId, into: intoTaskId, at: date) }
    }

    /// Joins `taskId` into `intoTaskId`, proposed or not.
    @discardableResult
    public func mergeTasks(_ taskId: Int64, into intoTaskId: Int64) throws -> TaskItem {
        try writer.write { db in
            try TaskStore.merge(db, taskId: taskId, into: intoTaskId)
            guard let item = try Self.taskItems(db, TaskRecord.filter(Column("id") == intoTaskId)).first else {
                throw TaskError.notFound(TaskRef.task(id: intoTaskId).description)
            }
            return item
        }
    }

    public func rejectMerge(_ taskId: Int64, into intoTaskId: Int64) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE taskMerge SET status = ? WHERE taskId = ? AND intoTaskId = ?",
                arguments: [TaskMerge.rejected, taskId, intoTaskId]
            )
        }
    }

    /// A mention joined by mistake becomes a pendência of its own.
    @discardableResult
    public func splitTaskMention(_ mentionId: Int64, at date: Date = Date()) throws -> TaskItem? {
        try writer.write { db in
            guard let id = try TaskStore.split(db, mentionId: mentionId, at: date) else { return nil }
            return try Self.taskItems(db, TaskRecord.filter(Column("id") == id)).first
        }
    }

    // MARK: - Tags

    /// The tag goes into the catalog if new, as on meetings.
    public func addTaskTag(_ name: String, taskId: Int64, at date: Date = Date()) throws {
        guard let name = TagName.normalize(name) else { throw TagError.emptyName }
        try writer.write { db in
            var tag = try Tag.filter(Column("name") == name).fetchOne(db) ?? Tag(name: name, createdAt: date)
            if tag.id == nil { try tag.insert(db) }
            try TaskTag(taskId: taskId, tagId: tag.id!, createdAt: date).save(db)
        }
    }

    /// Off the pendência, also when it came from a meeting.
    public func removeTaskTag(_ tagId: Int64, taskId: Int64, at date: Date = Date()) throws {
        try writer.write { db in
            try TaskTag(taskId: taskId, tagId: tagId, createdAt: date, removedAt: date).save(db)
        }
    }

    // MARK: - Statuses

    /// The user's list, in their order.
    public func taskStatuses() throws -> [TaskStatus] {
        try writer.read { db in try TaskStatus.order(Column("position"), Column("id")).fetchAll(db) }
    }

    /// At the end of the list.
    @discardableResult
    public func createTaskStatus(_ name: String, color: String = "gray", at date: Date = Date()) throws -> TaskStatus {
        let name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { throw TaskError.emptyStatusName }
        return try writer.write { db in
            let all = try TaskStatus.fetchAll(db)
            guard !all.contains(where: { TaskItem.sameName($0.name, name) }) else { throw TaskError.statusExists(name) }
            var status = TaskStatus(name: name, position: (all.map(\.position).max() ?? -1) + 1, color: color, createdAt: date)
            try status.insert(db)
            return status
        }
    }

    /// New name, or new color when given.
    @discardableResult
    public func updateTaskStatus(_ id: Int64, name: String, color: String? = nil) throws -> TaskStatus {
        let name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { throw TaskError.emptyStatusName }
        return try writer.write { db in
            guard var status = try TaskStatus.fetchOne(db, key: id) else { throw TaskError.notFound("status \(id)") }
            guard try !TaskStatus.filter(Column("id") != id).fetchAll(db).contains(where: { TaskItem.sameName($0.name, name) }) else {
                throw TaskError.statusExists(name)
            }
            status.name = name
            if let color { status.color = color }
            try status.update(db)
            return status
        }
    }

    /// To `index` in the list (0 is first).
    public func moveTaskStatus(_ id: Int64, to index: Int) throws {
        try writer.write { db in
            var all = try TaskStatus.order(Column("position"), Column("id")).fetchAll(db)
            guard let from = all.firstIndex(where: { $0.id == id }) else { throw TaskError.notFound("status \(id)") }
            let status = all.remove(at: from)
            all.insert(status, at: min(max(index, 0), all.count))
            for (position, var item) in all.enumerated() where item.position != position {
                item.position = position
                try item.update(db)
            }
        }
    }

    /// Its pendências go to `moveTo` first; the last status stays.
    public func deleteTaskStatus(_ id: Int64, moveTo: Int64) throws {
        try writer.write { db in
            guard try TaskStatus.fetchCount(db) > 1 else { throw TaskError.lastStatus }
            guard id != moveTo, try TaskStatus.exists(db, key: id), try TaskStatus.exists(db, key: moveTo) else {
                throw TaskError.notFound("status \(id)")
            }
            try db.execute(sql: "UPDATE task SET statusId = ? WHERE statusId = ?", arguments: [moveTo, id])
            _ = try TaskStatus.deleteOne(db, key: id)
        }
    }

    /// How many pendências each status has.
    public func taskStatusCounts() throws -> [Int64: Int] {
        try writer.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT statusId, count(*) AS n FROM task GROUP BY statusId").map {
                ($0["statusId"] as Int64, $0["n"] as Int)
            })
        }
    }

    // MARK: - Reading

    static func taskId(_ db: Database, _ ref: TaskRef) throws -> Int64? {
        switch ref {
        case .task(let id):
            return try TaskRecord.exists(db, key: id) ? id : nil
        case .summary(let meetingId, _, let fingerprint):
            return try TaskMention
                .filter(Column("meetingId") == meetingId && Column("source") == "summary" && Column("fingerprint") == fingerprint)
                .fetchOne(db)?.taskId
        case .note(let id):
            return try TaskMention.filter(Column("noteId") == id).fetchOne(db)?.taskId
        }
    }

    /// `focus` tells them from that meeting when it spoke of them.
    static func taskItems(_ db: Database, _ request: QueryInterfaceRequest<TaskRecord>, focus: Int64? = nil) throws -> [TaskItem] {
        let tasks = try request.order(Column("position"), Column("id")).fetchAll(db)
        guard !tasks.isEmpty else { return [] }
        let ids = tasks.compactMap(\.id)
        let mentions = Dictionary(grouping: try TaskMention
            .filter(ids.contains(Column("taskId")))
            .order(Column("at"), Column("id"))
            .fetchAll(db), by: \.taskId)
        let meetingIds = Set(mentions.values.joined().map(\.meetingId))
        let meetings = Dictionary(uniqueKeysWithValues: try Meeting.filter(meetingIds.contains(Column("id"))).fetchAll(db).compactMap { m in m.id.map { ($0, m) } })
        let tagNames = Dictionary(uniqueKeysWithValues: try Tag.fetchAll(db).compactMap { t in t.id.map { ($0, t.name) } })
        var meetingTags: [Int64: Set<Int64>] = [:]
        for row in try MeetingTag.filter(meetingIds.contains(Column("meetingId")) && Column("removedAt") == nil).fetchAll(db) {
            meetingTags[row.meetingId, default: []].insert(row.tagId)
        }
        let ownTags = Dictionary(grouping: try TaskTag.filter(ids.contains(Column("taskId"))).fetchAll(db), by: \.taskId)
        let statuses = Dictionary(uniqueKeysWithValues: try TaskStatus.fetchAll(db).compactMap { s in s.id.map { ($0, s) } })

        return tasks.compactMap { task -> TaskItem? in
            guard let id = task.id else { return nil }
            let list = (mentions[id] ?? []).compactMap { mention -> TaskItem.Mention? in
                guard let meeting = meetings[mention.meetingId] else { return nil }
                return TaskItem.Mention(
                    id: mention.id ?? 0, meetingId: mention.meetingId, meetingTitle: meeting.title, at: mention.at,
                    text: mention.text, owner: mention.owner, startMs: mention.tMs, source: mention.source
                )
            }
            // The meeting being looked at, or the last one that spoke of it.
            let shown = list.last { $0.meetingId == focus } ?? list.last
            let meeting = shown.flatMap { meetings[$0.meetingId] }
            var tagIds = Set(list.flatMap { meetingTags[$0.meetingId] ?? [] })
            for row in ownTags[id] ?? [] {
                if row.removedAt == nil { tagIds.insert(row.tagId) } else { tagIds.remove(row.tagId) }
            }
            return TaskItem(
                ref: TaskRef.task(id: id).description,
                taskId: id,
                source: task.source,
                meetingId: shown?.meetingId ?? 0,
                meetingTitle: meeting?.title ?? "",
                meetingStartedAt: meeting?.startedAt ?? task.createdAt,
                text: task.text,
                owner: task.owner,
                startMs: shown?.startMs,
                status: statuses[task.statusId]?.name ?? "",
                statusId: task.statusId,
                createdAt: task.createdAt,
                mentions: list,
                tags: tagIds.compactMap { tagNames[$0] }.sorted()
            )
        }
    }
}
