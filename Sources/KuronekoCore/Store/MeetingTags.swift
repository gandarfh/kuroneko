import Foundation
import GRDB

/// A tag of the catalog the user keeps: "project=kuroneko", "1x1=tam" or a
/// plain "daily". What comes before "=" is its key, which the list groups
/// by. Its rules put it on meetings by themselves, but nothing automatic
/// ever creates a tag.
public struct Tag: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: Int64?
    public var name: String
    /// What it is about, in the user's words.
    public var description: String?
    /// Every condition must hold for the tag to apply by itself; none means
    /// it is only ever put on by hand.
    public var rules: [TagCondition]
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, description: String? = nil, rules: [TagCondition] = [], createdAt: Date) {
        self.id = id
        self.name = name
        self.description = description
        self.rules = rules
        self.createdAt = createdAt
    }

    public var key: String? { TagName.key(of: name) }
    public var value: String { TagName.value(of: name) }

    public func applies(to facts: TagFacts) -> Bool {
        !rules.isEmpty && rules.allSatisfy { $0.holds(for: facts) }
    }
}

extension Tag: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "tag"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Who put a tag on a meeting; free-form so new ways need no schema change.
public enum TagSource {
    /// The user: in the app, with the `kuroneko` command or a #tag in the title.
    public static let manual = "manual"
    /// The tag's rules; worked out again whenever the meeting or the rules change.
    public static let rule = "rule"
    /// Copied from the previous meeting held in the same room.
    public static let recurring = "recurring"
}

/// A tag on a meeting. Taking it off keeps the row with `removedAt`, so
/// nothing automatic puts it back.
public struct MeetingTag: Codable, Equatable, Sendable {
    public var meetingId: Int64
    public var tagId: Int64
    public var source: String
    public var createdAt: Date
    public var removedAt: Date?

    public init(meetingId: Int64, tagId: Int64, source: String, createdAt: Date, removedAt: Date? = nil) {
        self.meetingId = meetingId
        self.tagId = tagId
        self.source = source
        self.createdAt = createdAt
        self.removedAt = removedAt
    }
}

extension MeetingTag: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meetingTag"
}

/// A tag a meeting has, and who put it there.
public struct AppliedTag: Equatable, Sendable {
    public var tag: Tag
    public var source: String
}

/// One condition of a tag's rule. `field` and `op` are free-form so new
/// kinds need no schema change; one this version doesn't know never holds.
///
/// - `title contains`: the title has any of the values (case and accents ignored)
/// - `people includes`: every value was heard
/// - `people is`: exactly the values were heard, nobody else (you aside)
public struct TagCondition: Codable, Equatable, Hashable, Sendable {
    public var field: String
    public var op: String
    public var values: [String]

    public init(field: String, op: String, values: [String]) {
        self.field = field
        self.op = op
        self.values = values
    }

    public static func titleContains(_ values: [String]) -> TagCondition {
        TagCondition(field: "title", op: "contains", values: values)
    }

    public static func peopleInclude(_ values: [String]) -> TagCondition {
        TagCondition(field: "people", op: "includes", values: values)
    }

    public static func peopleAre(_ values: [String]) -> TagCondition {
        TagCondition(field: "people", op: "is", values: values)
    }

    public func holds(for facts: TagFacts) -> Bool {
        let values = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // An empty condition would match every meeting.
        guard !values.isEmpty else { return false }
        switch (field, op) {
        case ("title", "contains"):
            return values.contains { facts.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        case ("people", "includes"):
            let heard = Set(facts.people.map(Self.fold))
            return values.allSatisfy { heard.contains(Self.fold($0)) }
        case ("people", "is"):
            // A voice nobody named could be anyone.
            return facts.unnamedVoices == 0 && Set(facts.people.map(Self.fold)) == Set(values.map(Self.fold))
        default:
            return false
        }
    }

    private static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// What tag rules look at in a meeting.
public struct TagFacts: Equatable, Sendable {
    public var title: String
    /// Known people heard, with enough speech to be sure of them.
    public var people: [String]
    /// Voices with enough speech that nobody named yet.
    public var unnamedVoices: Int

    public init(title: String, people: [String] = [], unnamedVoices: Int = 0) {
        self.title = title
        self.people = people
        self.unnamedVoices = unnamedVoices
    }
}

/// How tag names are written: lowercase, single spaces, nothing around "=".
public enum TagName {
    /// "#Project = Pix " → "project=pix"; nil when nothing is left.
    public static func normalize(_ text: String) -> String? {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("#") { name.removeFirst() }
        name = name.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: " =", with: "=")
            .replacingOccurrences(of: "= ", with: "=")
        guard !name.isEmpty, name != "=" else { return nil }
        return name
    }

    /// "project" for "project=pix"; nil for a plain tag.
    public static func key(of name: String) -> String? {
        guard let index = name.firstIndex(of: "="), index != name.startIndex else { return nil }
        return String(name[..<index])
    }

    /// "pix" for "project=pix"; the whole name for a plain tag.
    public static func value(of name: String) -> String {
        guard key(of: name) != nil, let index = name.firstIndex(of: "=") else { return name }
        return String(name[name.index(after: index)...])
    }
}

public enum TagError: Error, Equatable, CustomStringConvertible {
    case emptyName
    case alreadyExists(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .emptyName: "a tag precisa de um nome"
        case .alreadyExists(let name): "já existe a tag \(name)"
        case .notFound(let name): "não existe a tag \(name)"
        }
    }
}

extension AppDatabase {
    // MARK: - Catalog

    public func tags() throws -> [Tag] {
        try writer.read { db in try Tag.order(Column("name")).fetchAll(db) }
    }

    /// Meetings carrying each tag (taken-off tags aside), by tag id.
    public func tagCounts() throws -> [Int64: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT tagId, count(*) AS n FROM meetingTag WHERE removedAt IS NULL GROUP BY tagId")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["tagId"], $0["n"]) })
        }
    }

    /// A new tag of the catalog; its rules go through every meeting.
    @discardableResult
    public func createTag(_ name: String, description: String? = nil, rules: [TagCondition] = [], at date: Date = Date()) throws -> Tag {
        guard let name = TagName.normalize(name) else { throw TagError.emptyName }
        return try writer.write { db in
            guard try Tag.filter(Column("name") == name).fetchOne(db) == nil else { throw TagError.alreadyExists(name) }
            var tag = Tag(name: name, description: Self.cleaned(description), rules: rules, createdAt: date)
            try tag.insert(db)
            try TagStore.applyRules(db, meetingIds: nil, at: date)
            return tag
        }
    }

    /// Renames the tag, or changes its description or rules; the rules go
    /// through every meeting again, so one no longer matching loses it.
    @discardableResult
    public func updateTag(_ tag: Tag, at date: Date = Date()) throws -> Tag {
        guard let id = tag.id else { throw TagError.notFound(tag.name) }
        guard let name = TagName.normalize(tag.name) else { throw TagError.emptyName }
        return try writer.write { db in
            guard var stored = try Tag.fetchOne(db, key: id) else { throw TagError.notFound(tag.name) }
            if let other = try Tag.filter(Column("name") == name).fetchOne(db), other.id != id {
                throw TagError.alreadyExists(name)
            }
            stored.name = name
            stored.description = Self.cleaned(tag.description)
            stored.rules = tag.rules
            try stored.update(db)
            try TagStore.applyRules(db, meetingIds: nil, at: date)
            return stored
        }
    }

    /// The tag leaves the catalog and every meeting.
    public func deleteTag(_ id: Int64) throws {
        try writer.write { db in
            try MeetingTag.filter(Column("tagId") == id).deleteAll(db)
            _ = try Tag.deleteOne(db, key: id)
        }
    }

    private static func cleaned(_ text: String?) -> String? {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    // MARK: - On meetings

    /// Puts the tag on the meeting by hand, creating it when new: the user
    /// may create tags, only automatic sources may not.
    @discardableResult
    public func addTag(_ name: String, meetingId: Int64, at date: Date = Date()) throws -> Tag {
        guard let name = TagName.normalize(name) else { throw TagError.emptyName }
        return try writer.write { db in try TagStore.addManual(db, name: name, meetingId: meetingId, at: date) }
    }

    /// Takes the tag off the meeting for good: no rule or recurring meeting
    /// puts it back, only the user.
    public func removeTag(_ tagId: Int64, meetingId: Int64, at date: Date = Date()) throws {
        try writer.write { db in
            guard var row = try MeetingTag.fetchOne(db, key: ["meetingId": meetingId, "tagId": tagId]),
                  row.removedAt == nil else { return }
            row.removedAt = date
            try row.update(db)
        }
    }

    /// The meeting's tags, by name.
    public func meetingTags(meetingId: Int64) throws -> [AppliedTag] {
        try writer.read { db in
            let rows = try MeetingTag.filter(Column("meetingId") == meetingId && Column("removedAt") == nil).fetchAll(db)
            let tags = try Tag.fetchAll(db, keys: rows.map(\.tagId))
            let sources = Dictionary(uniqueKeysWithValues: rows.map { ($0.tagId, $0.source) })
            return tags
                .map { AppliedTag(tag: $0, source: sources[$0.id ?? 0] ?? TagSource.manual) }
                .sorted { $0.tag.name < $1.tag.name }
        }
    }

    /// Names of every meeting's tags, sorted.
    public func tagNamesByMeeting() throws -> [Int64: [String]] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT meetingTag.meetingId, tag.name
                FROM meetingTag JOIN tag ON tag.id = meetingTag.tagId
                WHERE meetingTag.removedAt IS NULL
                ORDER BY tag.name
                """)
            var result: [Int64: [String]] = [:]
            for row in rows {
                result[row["meetingId"], default: []].append(row["name"])
            }
            return result
        }
    }
}

/// Tag changes made inside other writes (a meeting starting, a transcript
/// arriving, a voice named), in the same transaction.
enum TagStore {
    static func addManual(_ db: Database, name: String, meetingId: Int64, at date: Date) throws -> Tag {
        var tag = try Tag.filter(Column("name") == name).fetchOne(db) ?? Tag(name: name, createdAt: date)
        if tag.id == nil {
            try tag.insert(db)
        }
        // Already there from a rule or the previous meeting: now it is the
        // user's, and stays even if the rule stops matching.
        try MeetingTag(meetingId: meetingId, tagId: tag.id!, source: TagSource.manual, createdAt: date).save(db)
        return tag
    }

    /// A meeting in a room held before (a recurring event) takes the tags the
    /// last meeting there had from the user or from before; the ones from
    /// rules are worked out for each meeting.
    static func inheritFromSameRoom(_ db: Database, meetingId: Int64, at date: Date) throws {
        guard let meeting = try Meeting.fetchOne(db, key: meetingId), let room = meeting.sourceRef,
              let previous = try Meeting
                  .filter(Column("sourceRef") == room && Column("id") != meetingId && Column("startedAt") <= meeting.startedAt)
                  .order(Column("startedAt").desc)
                  .fetchOne(db),
              let previousId = previous.id else { return }
        let inherited = try MeetingTag
            .filter(Column("meetingId") == previousId && Column("removedAt") == nil)
            .filter([TagSource.manual, TagSource.recurring].contains(Column("source")))
            .fetchAll(db)
        for row in inherited where try MeetingTag.fetchOne(db, key: ["meetingId": meetingId, "tagId": row.tagId]) == nil {
            try MeetingTag(meetingId: meetingId, tagId: row.tagId, source: TagSource.recurring, createdAt: date).insert(db)
        }
    }

    /// Puts each tag whose rules hold on the meetings (all of them when nil)
    /// and takes it off where it came from its rules and they no longer
    /// hold. Tags the user put on or took off are left as they are.
    static func applyRules(_ db: Database, meetingIds: [Int64]?, at date: Date) throws {
        let tags = try Tag.fetchAll(db)
        let meetings = try meetingIds.map { try Meeting.fetchAll(db, keys: $0) } ?? Meeting.fetchAll(db)
        guard !meetings.isEmpty else { return }
        let ids = meetings.compactMap(\.id)
        let facts = try self.facts(db, meetings: meetings)
        var existing: [Int64: [Int64: MeetingTag]] = [:]
        for row in try MeetingTag.filter(ids.contains(Column("meetingId"))).fetchAll(db) {
            existing[row.meetingId, default: [:]][row.tagId] = row
        }
        for meetingId in ids {
            guard let facts = facts[meetingId] else { continue }
            for tag in tags {
                guard let tagId = tag.id else { continue }
                let row = existing[meetingId]?[tagId]
                if tag.applies(to: facts) {
                    if row == nil {
                        try MeetingTag(meetingId: meetingId, tagId: tagId, source: TagSource.rule, createdAt: date).insert(db)
                    }
                } else if let row, row.source == TagSource.rule, row.removedAt == nil {
                    try row.delete(db)
                }
            }
        }
    }

    static func facts(_ db: Database, meetings: [Meeting]) throws -> [Int64: TagFacts] {
        var facts: [Int64: TagFacts] = [:]
        for meeting in meetings {
            guard let id = meeting.id else { continue }
            facts[id] = TagFacts(title: meeting.title)
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT meetingSpeaker.meetingId, person.name
            FROM meetingSpeaker LEFT JOIN person ON person.id = meetingSpeaker.personId
            WHERE meetingSpeaker.speechMs >= ?
            """, arguments: [VoiceReview.minSpeechMs])
        for row in rows {
            let meetingId: Int64 = row["meetingId"]
            guard facts[meetingId] != nil else { continue }
            if let name: String = row["name"] {
                if !facts[meetingId]!.people.contains(name) { facts[meetingId]!.people.append(name) }
            } else {
                facts[meetingId]!.unnamedVoices += 1
            }
        }
        return facts
    }
}
