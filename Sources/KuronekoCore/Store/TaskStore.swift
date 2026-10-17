import Foundation
import GRDB

/// A pendência: what has to be done, by whom, and its status. Meetings
/// mention it (`TaskMention`) — a line of the summary's Pendências, a #acao
/// note — and the same subject spoken of in several meetings (the daily
/// keeps bringing it up) is one task with several mentions once the user
/// joins them.
public struct TaskRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var text: String
    /// As said: "Bruno", "você".
    public var owner: String?
    /// One of the `TaskStatus` list.
    public var statusId: Int64
    /// How it first came up: "summary", "note" or "manual".
    public var source: String
    /// When it first came up: the start of that meeting.
    public var createdAt: Date
    /// In the user's order of the pendências, smaller first; new ones go on
    /// top (`placeOnTop`).
    public var position: Int

    public init(id: Int64? = nil, text: String, owner: String?, statusId: Int64, source: String, createdAt: Date, position: Int = 0) {
        self.id = id
        self.text = text
        self.owner = owner
        self.statusId = statusId
        self.source = source
        self.createdAt = createdAt
        self.position = position
    }
}

extension TaskRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "task"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A status a pendência can be in, from one list the user keeps for every
/// pendência — "Aberta", "Fazendo" and "Feita" to start with. It means
/// nothing to the app: the user filters and groups by it as they like.
public struct TaskStatus: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: Int64?
    public var name: String
    /// Order in lists and on the board; a new pendência takes the first.
    public var position: Int
    /// A name from the app's palette ("gray", "amber", "green"…), so the UI
    /// picks the shade.
    public var color: String
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, position: Int, color: String = "gray", createdAt: Date) {
        self.id = id
        self.name = name
        self.position = position
        self.color = color
        self.createdAt = createdAt
    }
}

extension TaskStatus: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "taskStatus"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A meeting speaking of a pendência.
public struct TaskMention: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var taskId: Int64
    public var meetingId: Int64
    /// "summary", "note" or "manual".
    public var source: String
    /// Of the summary line (`SummaryItem.fingerprint`), to find it again
    /// when the meeting is summarized again.
    public var fingerprint: String?
    /// Of a #acao note.
    public var noteId: Int64?
    /// As said in that meeting.
    public var text: String
    public var owner: String?
    /// Moment of the recording.
    public var tMs: Int?
    /// When it was said.
    public var at: Date

    public init(
        id: Int64? = nil,
        taskId: Int64,
        meetingId: Int64,
        source: String,
        fingerprint: String? = nil,
        noteId: Int64? = nil,
        text: String,
        owner: String?,
        tMs: Int?,
        at: Date
    ) {
        self.id = id
        self.taskId = taskId
        self.meetingId = meetingId
        self.source = source
        self.fingerprint = fingerprint
        self.noteId = noteId
        self.text = text
        self.owner = owner
        self.tMs = tMs
        self.at = at
    }
}

extension TaskMention: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "taskMention"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// The app thinks `taskId` repeats `intoTaskId` (`TaskMatcher`); the user
/// joins them or not. A rejected pair is kept, so it is not proposed again.
public struct TaskMerge: Codable, Equatable, Sendable {
    public var taskId: Int64
    public var intoTaskId: Int64
    /// "proposed" or "rejected".
    public var status: String
    public var createdAt: Date

    public static let proposed = "proposed"
    public static let rejected = "rejected"
}

extension TaskMerge: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "taskMerge"
}

/// A tag the user put on a pendência, or took off (`removedAt`) one it would
/// take from its meetings.
public struct TaskTag: Codable, Equatable, Sendable {
    public var taskId: Int64
    public var tagId: Int64
    public var createdAt: Date
    public var removedAt: Date?
}

extension TaskTag: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "taskTag"
}

/// What keeps the pendências in step with where they come from; runs inside
/// the transaction of the change that calls it.
enum TaskStore {
    static func createTables(_ db: Database) throws {
        try db.create(table: "taskStatus") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("position", .integer).notNull()
            t.column("color", .text).notNull().defaults(to: "gray")
            t.column("createdAt", .datetime).notNull()
        }
        let now = Date()
        for (position, (name, color)) in [("Aberta", "gray"), ("Fazendo", "amber"), ("Feita", "green")].enumerated() {
            var status = TaskStatus(name: name, position: position, color: color, createdAt: now)
            try status.insert(db)
        }
        try db.create(table: "task") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("text", .text).notNull()
            t.column("owner", .text)
            t.belongsTo("status", inTable: "taskStatus", onDelete: .restrict).notNull()
            t.column("source", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("position", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "taskMention") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("task", onDelete: .cascade).notNull()
            t.belongsTo("meeting", onDelete: .cascade).notNull()
            t.column("source", .text).notNull()
            t.column("fingerprint", .text)
            t.belongsTo("note", onDelete: .cascade)
            t.column("text", .text).notNull()
            t.column("owner", .text)
            t.column("tMs", .integer)
            t.column("at", .datetime).notNull()
        }
        try db.create(table: "taskMerge") { t in
            t.column("taskId", .integer).notNull().references("task", onDelete: .cascade)
            t.column("intoTaskId", .integer).notNull().references("task", onDelete: .cascade)
            t.column("status", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.primaryKey(["taskId", "intoTaskId"])
        }
        try db.create(table: "taskTag") { t in
            t.belongsTo("task", onDelete: .cascade).notNull()
            t.belongsTo("tag", onDelete: .cascade).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("removedAt", .datetime)
            t.primaryKey(["taskId", "tagId"])
        }
    }

    // MARK: - Where pendências come from

    /// The Pendências of a summary about to be saved become the meeting's
    /// pendências, and the text keeps the rest: a line already known (the
    /// same text) keeps its pendência, a new line makes a new one in the
    /// first status, on top. Pendências of the previous summary that it
    /// doesn't bring again go, unless the user already changed them.
    /// `checkedStatusId` is for a line already checked ("- [x]"), when the
    /// migration knows where those go. Returns the pendências created.
    @discardableResult
    static func takeTasks(_ db: Database, from document: inout MeetingDocument, checkedStatusId: Int64? = nil) throws -> [Int64] {
        guard document.kind == "summary", let taken = SummaryItems.takeTasks(document.body),
              let meeting = try Meeting.fetchOne(db, key: document.meetingId) else { return [] }
        document.body = taken.rest
        let meetingId = document.meetingId
        var known = Dictionary(grouping: try TaskMention
            .filter(Column("meetingId") == meetingId && Column("source") == "summary")
            .fetchAll(db), by: { $0.fingerprint ?? "" })
        var created: [Int64] = []
        for item in taken.tasks {
            if var mention = known[item.fingerprint]?.popLast() {
                if mention.owner != item.owner || mention.tMs != item.startMs {
                    // Who does it follows the summary until the user changes it.
                    if var task = try TaskRecord.fetchOne(db, key: mention.taskId), task.owner == mention.owner, task.owner != item.owner {
                        task.owner = item.owner
                        try task.update(db)
                    }
                    mention.owner = item.owner
                    mention.tMs = item.startMs
                    try mention.update(db)
                }
                continue
            }
            var task = TaskRecord(
                text: item.text,
                owner: item.owner,
                statusId: try item.done ? (checkedStatusId ?? firstStatusId(db)) : firstStatusId(db),
                source: "summary",
                createdAt: meeting.startedAt
            )
            try task.insert(db)
            var mention = TaskMention(
                taskId: task.id!,
                meetingId: meetingId,
                source: "summary",
                fingerprint: item.fingerprint,
                text: item.text,
                owner: item.owner,
                tMs: item.startMs,
                at: meeting.date(atOffsetMs: item.startMs ?? 0)
            )
            try mention.insert(db)
            created.append(task.id!)
        }
        for mention in known.values.joined() {
            guard try asItCame(db, mention) else { continue }
            try mention.delete(db)
            try deleteIfOrphan(db, taskId: mention.taskId)
        }
        try placeOnTop(db, created)
        return created
    }

    /// The pendência of a summary line is as the summary made it: only that
    /// line speaks of it, and the user didn't change its status, text, who
    /// does it or tags.
    private static func asItCame(_ db: Database, _ mention: TaskMention) throws -> Bool {
        guard let task = try TaskRecord.fetchOne(db, key: mention.taskId) else { return false }
        return try task.statusId == firstStatusId(db)
            && task.text == mention.text && task.owner == mention.owner
            && TaskMention.filter(Column("taskId") == mention.taskId).fetchCount(db) == 1
            && TaskTag.filter(Column("taskId") == mention.taskId).fetchCount(db) == 0
    }

    /// A voice of the meeting got a name: what it said of pendências calls
    /// them by it, and so do the pendências only that meeting spoke of.
    static func rename(_ db: Database, meetingId: Int64, from previous: String, to name: String) throws {
        func replace(_ text: String) -> String { NameReplacement.replace(previous, with: name, in: text) }
        for var mention in try TaskMention.filter(Column("meetingId") == meetingId).fetchAll(db) {
            let text = replace(mention.text), owner = mention.owner.map(replace)
            guard text != mention.text || owner != mention.owner else { continue }
            if mention.source == "summary" { mention.fingerprint = SummaryItem.fingerprint(of: text) }
            mention.text = text
            mention.owner = owner
            try mention.update(db)
        }
        let only = try Int64.fetchAll(db, sql: """
            SELECT taskId FROM taskMention GROUP BY taskId
            HAVING min(meetingId) = ? AND max(meetingId) = ?
            """, arguments: [meetingId, meetingId])
        for var task in try TaskRecord.filter(only.contains(Column("id"))).fetchAll(db) {
            let text = replace(task.text), owner = task.owner.map(replace)
            guard text != task.text || owner != task.owner else { continue }
            task.text = text
            task.owner = owner
            try task.update(db)
        }
    }

    /// A #acao note is a pendência of the user's; `resolvedStatusId` is for
    /// a note marked resolved before pendências had statuses.
    static func syncNote(_ db: Database, note: Note, resolvedStatusId: Int64? = nil) throws {
        guard let noteId = note.id, note.tags.contains(TaskItem.noteTag),
              try TaskMention.filter(Column("noteId") == noteId).fetchCount(db) == 0,
              let meeting = try Meeting.fetchOne(db, key: note.meetingId) else { return }
        let text = TaskItem.noteText(note.text)
        let at = meeting.date(atOffsetMs: note.tMs)
        var task = TaskRecord(
            text: text,
            owner: "você",
            statusId: try note.resolvedAt != nil ? (resolvedStatusId ?? firstStatusId(db)) : firstStatusId(db),
            source: "note",
            createdAt: at
        )
        try task.insert(db)
        var mention = TaskMention(taskId: task.id!, meetingId: note.meetingId, source: "note", noteId: noteId, text: text, owner: "você", tMs: note.tMs, at: at)
        try mention.insert(db)
        try placeOnTop(db, [task.id!])
    }

    /// Before the note or the meeting goes: their mentions go too, and a
    /// pendência left without any.
    static func removeMentions(_ db: Database, _ request: QueryInterfaceRequest<TaskMention>) throws {
        for mention in try request.fetchAll(db) {
            try mention.delete(db)
            try deleteIfOrphan(db, taskId: mention.taskId)
        }
    }

    /// One the user created stays without mentions; the others existed only
    /// because a meeting spoke of them.
    static func deleteIfOrphan(_ db: Database, taskId: Int64) throws {
        guard try TaskMention.filter(Column("taskId") == taskId).fetchCount(db) == 0,
              let task = try TaskRecord.fetchOne(db, key: taskId), task.source != "manual" else { return }
        try task.delete(db)
    }

    // MARK: - Order

    /// New pendências go on top of the user's order, in the order given.
    static func placeOnTop(_ db: Database, _ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let top = try Int.fetchOne(db, TaskRecord.filter(!ids.contains(Column("id"))).select(min(Column("position")))) ?? 0
        for (index, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE task SET position = ? WHERE id = ?", arguments: [top - ids.count + index, id])
        }
    }

    /// Just before `other` in the user's order, or just after.
    static func place(_ db: Database, _ taskId: Int64, nextTo other: Int64, after: Bool) throws {
        var ids = try Int64.fetchAll(db, TaskRecord.select(Column("id")).order(Column("position"), Column("id")))
        guard taskId != other, let from = ids.firstIndex(of: taskId) else { throw TaskError.notFound("task:\(taskId)") }
        ids.remove(at: from)
        guard let at = ids.firstIndex(of: other) else { throw TaskError.notFound("task:\(other)") }
        ids.insert(taskId, at: after ? at + 1 : at)
        try renumber(db, ids)
    }

    /// The order the list had before the user could change it: the last
    /// meeting that spoke of it first, then the moment of the recording.
    static func orderByMeetings(_ db: Database) throws {
        let ids = try Int64.fetchAll(db, sql: """
            WITH last AS (
                SELECT m.taskId, mt.startedAt, m.meetingId, m.tMs,
                       ROW_NUMBER() OVER (PARTITION BY m.taskId ORDER BY m.at DESC, m.id DESC) AS rank
                FROM taskMention m JOIN meeting mt ON mt.id = m.meetingId
            )
            SELECT t.id FROM task t LEFT JOIN last l ON l.taskId = t.id AND l.rank = 1
            ORDER BY l.startedAt DESC, l.meetingId DESC, l.tMs IS NULL, l.tMs, t.id
            """)
        try renumber(db, ids)
    }

    private static func renumber(_ db: Database, _ ids: [Int64]) throws {
        let current = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, position FROM task").map {
            ($0["id"] as Int64, $0["position"] as Int)
        })
        for (position, id) in ids.enumerated() where current[id] != position {
            try db.execute(sql: "UPDATE task SET position = ? WHERE id = ?", arguments: [position, id])
        }
    }

    // MARK: - Statuses

    /// Where a new pendência starts: the first status in the user's order.
    static func firstStatusId(_ db: Database) throws -> Int64 {
        guard let id = try TaskStatus.order(Column("position"), Column("id")).fetchOne(db)?.id else {
            throw TaskError.lastStatus
        }
        return id
    }

    // MARK: - What the user does

    static func setStatus(_ db: Database, taskId: Int64, statusId: Int64) throws {
        guard var task = try TaskRecord.fetchOne(db, key: taskId), task.statusId != statusId else { return }
        guard try TaskStatus.exists(db, key: statusId) else { throw TaskError.notFound("status \(statusId)") }
        task.statusId = statusId
        try task.update(db)
    }

    /// `taskId` becomes part of `intoTaskId`: its mentions and tags move,
    /// and it goes.
    static func merge(_ db: Database, taskId: Int64, into intoTaskId: Int64) throws {
        guard taskId != intoTaskId, try TaskRecord.exists(db, key: intoTaskId), try TaskRecord.exists(db, key: taskId) else { return }
        try db.execute(sql: "UPDATE taskMention SET taskId = ? WHERE taskId = ?", arguments: [intoTaskId, taskId])
        try db.execute(sql: "UPDATE OR IGNORE taskTag SET taskId = ? WHERE taskId = ?", arguments: [intoTaskId, taskId])
        // Proposals pointing at the one that goes now point at the one that stays.
        try db.execute(sql: "UPDATE OR IGNORE taskMerge SET intoTaskId = ? WHERE intoTaskId = ? AND taskId != ?", arguments: [intoTaskId, taskId, intoTaskId])
        _ = try TaskRecord.deleteOne(db, key: taskId)
    }

    /// A mention joined by mistake becomes a pendência of its own, and the
    /// pair is not proposed again.
    @discardableResult
    static func split(_ db: Database, mentionId: Int64, at date: Date) throws -> Int64? {
        guard var mention = try TaskMention.fetchOne(db, key: mentionId),
              let old = try TaskRecord.fetchOne(db, key: mention.taskId),
              try TaskMention.filter(Column("taskId") == mention.taskId).fetchCount(db) > 1 else { return nil }
        var task = TaskRecord(text: mention.text, owner: mention.owner, statusId: try firstStatusId(db), source: mention.source, createdAt: mention.at)
        try task.insert(db)
        mention.taskId = task.id!
        try mention.update(db)
        try TaskMerge(taskId: task.id!, intoTaskId: old.id!, status: TaskMerge.rejected, createdAt: date).save(db)
        try place(db, task.id!, nextTo: old.id!, after: true)
        return task.id
    }

    /// Kept as asked unless the pair was already proposed or turned down.
    static func propose(_ db: Database, taskId: Int64, into intoTaskId: Int64, at date: Date) throws {
        guard taskId != intoTaskId,
              try TaskMerge.filter(
                  (Column("taskId") == taskId && Column("intoTaskId") == intoTaskId)
                      || (Column("taskId") == intoTaskId && Column("intoTaskId") == taskId)
              ).fetchCount(db) == 0 else { return }
        try TaskMerge(taskId: taskId, intoTaskId: intoTaskId, status: TaskMerge.proposed, createdAt: date).insert(db)
    }
}
