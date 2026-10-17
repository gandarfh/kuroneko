import Foundation
import GRDB
import Testing
@testable import KuronekoCore

@Suite struct TagNameTests {
    @Test func normalizesKeyAndValue() {
        #expect(TagName.normalize("  #Project = Pix  Automático ") == "project=pix automático")
        #expect(TagName.normalize("Daily") == "daily")
        #expect(TagName.normalize("  ") == nil)
        #expect(TagName.normalize("#") == nil)
        #expect(TagName.normalize("=") == nil)

        #expect(TagName.key(of: "project=pix") == "project")
        #expect(TagName.value(of: "project=pix") == "pix")
        #expect(TagName.key(of: "daily") == nil)
        #expect(TagName.value(of: "daily") == "daily")
        #expect(TagName.key(of: "=x") == nil)
        #expect(TagName.value(of: "a=b=c") == "b=c")
    }

    @Test func hashtagsMayCarryAKey() {
        #expect(Tags.parse("Planejamento #project=pix #daily") == ["project=pix", "daily"])
    }
}

@Suite struct TagConditionTests {
    @Test func titleContainsAnyValueIgnoringCaseAndAccents() {
        let condition = TagCondition.titleContains(["daily", "standup"])
        #expect(condition.holds(for: TagFacts(title: "Daily do time · 14 de out.")))
        #expect(condition.holds(for: TagFacts(title: "STANDUP")))
        #expect(!condition.holds(for: TagFacts(title: "Planejamento")))
        #expect(TagCondition.titleContains(["migracao"]).holds(for: TagFacts(title: "Migração do banco")))
    }

    @Test func peopleIncludeEveryValue() {
        let facts = TagFacts(title: "", people: ["Tâm", "Bia"], unnamedVoices: 1)
        #expect(TagCondition.peopleInclude(["tam"]).holds(for: facts))
        #expect(TagCondition.peopleInclude(["Tam", "Bia"]).holds(for: facts))
        #expect(!TagCondition.peopleInclude(["Tam", "Rui"]).holds(for: facts))
    }

    @Test func peopleAreExactlyTheValuesAndNobodyUnknown() {
        let oneOnOne = TagCondition.peopleAre(["Tam"])
        #expect(oneOnOne.holds(for: TagFacts(title: "", people: ["Tam"])))
        #expect(!oneOnOne.holds(for: TagFacts(title: "", people: ["Tam", "Bia"])))
        #expect(!oneOnOne.holds(for: TagFacts(title: "", people: ["Tam"], unnamedVoices: 1)))
        #expect(!oneOnOne.holds(for: TagFacts(title: "")))
    }

    @Test func emptyOrUnknownConditionsNeverHold() {
        let facts = TagFacts(title: "Daily", people: ["Tam"])
        #expect(!TagCondition.titleContains([]).holds(for: facts))
        #expect(!TagCondition.titleContains(["  "]).holds(for: facts))
        #expect(!TagCondition(field: "weekday", op: "is", values: ["seg"]).holds(for: facts))
        // A tag without rules is only ever put on by hand.
        #expect(!Tag(name: "x", createdAt: Date()).applies(to: facts))
    }
}

@Suite struct MeetingTagTests {
    private func names(_ db: AppDatabase, _ meetingId: Int64) throws -> [String] {
        try db.meetingTags(meetingId: meetingId).map(\.tag.name)
    }

    private func source(_ db: AppDatabase, _ meetingId: Int64, _ name: String) throws -> String? {
        try db.meetingTags(meetingId: meetingId).first { $0.tag.name == name }?.source
    }

    @Test func theUserCreatesTagsAndNothingElseDoes() throws {
        let db = try AppDatabase.inMemory()
        let id = try #require(try db.startMeeting(title: "Daily").id)

        try db.addTag("Project=Pix", meetingId: id)
        #expect(try names(db, id) == ["project=pix"])
        #expect(try db.tags().map(\.name) == ["project=pix"])

        #expect(throws: TagError.alreadyExists("project=pix")) { try db.createTag("project = pix") }
        #expect(throws: TagError.emptyName) { try db.createTag(" ") }
        #expect(throws: TagError.emptyName) { try db.addTag("#", meetingId: id) }
    }

    @Test func aTagTakenOffStaysOffUntilTheUserPutsItBack() throws {
        let db = try AppDatabase.inMemory()
        let id = try #require(try db.startMeeting(title: "Daily do time").id)
        let tag = try db.createTag("daily", rules: [.titleContains(["daily"])])
        #expect(try source(db, id, "daily") == TagSource.rule)

        try db.removeTag(tag.id!, meetingId: id)
        #expect(try names(db, id) == [])
        try db.renameMeeting(id, title: "Daily do time (2)")
        try db.updateTag(tag)
        #expect(try names(db, id) == [])
        #expect(try db.tagCounts()[tag.id!] == nil)

        try db.addTag("daily", meetingId: id)
        #expect(try source(db, id, "daily") == TagSource.manual)
    }

    @Test func rulesGoThroughPastMeetingsAndFollowChanges() throws {
        let db = try AppDatabase.inMemory()
        let daily = try #require(try db.startMeeting(title: "Daily · 13 de out.").id)
        let planning = try #require(try db.startMeeting(title: "Planejamento").id)
        let tagged = try #require(try db.startMeeting(title: "Daily · 14 de out.").id)
        try db.addTag("team=core", meetingId: tagged)

        // Created now, the tag reaches the meetings that already happened.
        var tag = try db.createTag("ritual=daily", rules: [.titleContains(["daily"])])
        #expect(try names(db, daily) == ["ritual=daily"])
        #expect(try names(db, planning) == [])

        // Renaming a meeting checks the rules again.
        try db.renameMeeting(planning, title: "Daily estendida")
        #expect(try names(db, planning) == ["ritual=daily"])
        try db.renameMeeting(daily, title: "Retro")
        #expect(try names(db, daily) == [])

        // A rule edited to stop matching takes off only what it put on.
        try db.addTag("ritual=daily", meetingId: tagged)
        tag.rules = [.titleContains(["standup"])]
        try db.updateTag(tag)
        #expect(try names(db, planning) == [])
        #expect(try names(db, tagged) == ["ritual=daily", "team=core"])
    }

    @Test func peopleRulesWaitForEveryVoiceToHaveAName() throws {
        let db = try AppDatabase.inMemory()
        let id = try #require(try db.startMeeting(title: "Conversa").id)
        try db.createTag("1x1=tam", rules: [.peopleAre(["Tam"])])

        // During the call: a batch brings a voice nobody named yet.
        try db.appendTranscript(meetingId: id, speakers: [MeetingSpeaker(meetingId: id, diarCluster: 0, speechMs: 60_000)], segments: [])
        #expect(try names(db, id) == [])

        try db.assignSpeaker(meetingId: id, diarCluster: 0, personName: "Tam")
        #expect(try names(db, id) == ["1x1=tam"])

        // Someone else joins and talks: not a 1:1 anymore.
        try db.appendTranscript(meetingId: id, speakers: [MeetingSpeaker(meetingId: id, diarCluster: 1, speechMs: 20_000)], segments: [])
        #expect(try names(db, id) == [])

        // A voice that barely spoke doesn't count.
        try db.saveTranscript(meetingId: id, speakers: [
            MeetingSpeaker(meetingId: id, personId: try db.persons().first?.id, diarCluster: 0, speechMs: 60_000),
            MeetingSpeaker(meetingId: id, diarCluster: 1, speechMs: 1_000),
        ], segments: [])
        #expect(try names(db, id) == ["1x1=tam"])
    }

    @Test func aRecurringMeetingTakesTheTagsOfTheLastOneInTheRoom() throws {
        let db = try AppDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try #require(try db.startMeeting(title: "Daily", sourceRef: "meet/abc-defg-hij", at: start).id)
        try db.addTag("project=pix", meetingId: first)
        try db.addTag("team=core", meetingId: first)
        try db.removeTag(try #require(try db.tags().first { $0.name == "team=core" }?.id), meetingId: first)
        try db.createTag("ritual=daily", rules: [.titleContains(["daily"])])
        try db.createTag("1x1=tam", rules: [.peopleAre(["Tam"])])
        try db.endMeeting(first, at: start.addingTimeInterval(900))

        let other = try #require(try db.startMeeting(title: "Outra", sourceRef: "meet/zzz-zzzz-zzz", at: start.addingTimeInterval(3600)).id)
        let second = try #require(try db.startMeeting(title: "Daily", sourceRef: "meet/abc-defg-hij", at: start.addingTimeInterval(86_400)).id)

        #expect(try names(db, other) == [])
        #expect(try names(db, second) == ["project=pix", "ritual=daily"])
        #expect(try source(db, second, "project=pix") == TagSource.recurring)
        #expect(try source(db, second, "ritual=daily") == TagSource.rule)

        // And the next one too, through the one before.
        let third = try #require(try db.startMeeting(title: "Sync", sourceRef: "meet/abc-defg-hij", at: start.addingTimeInterval(172_800)).id)
        #expect(try names(db, third) == ["project=pix"])
    }

    @Test func aHashtagNewInTheTitleIsPutOnByHand() throws {
        let db = try AppDatabase.inMemory()
        let id = try #require(try db.startMeeting(title: "Planejamento").id)

        try db.renameMeeting(id, title: "Planejamento #project=pix")
        #expect(try names(db, id) == ["project=pix"])
        #expect(try source(db, id, "project=pix") == TagSource.manual)

        // Taken off, it doesn't come back with a rename that keeps the hashtag.
        try db.removeTag(try #require(try db.tags().first?.id), meetingId: id)
        try db.renameMeeting(id, title: "Planejamento do Q4 #project=pix")
        #expect(try names(db, id) == [])
    }

    @Test func deletingTagsAndMeetings() throws {
        let db = try AppDatabase.inMemory()
        let a = try #require(try db.startMeeting(title: "A", tags: ["project=pix"]).id)
        let b = try #require(try db.startMeeting(title: "B", tags: ["project=pix", "daily"]).id)
        let pix = try #require(try db.tags().first { $0.name == "project=pix" })
        #expect(try db.tagCounts()[pix.id!] == 2)

        try db.deleteMeeting(a)
        #expect(try db.tagCounts()[pix.id!] == 1)

        try db.deleteTag(pix.id!)
        #expect(try names(db, b) == ["daily"])
        #expect(try db.tags().map(\.name) == ["daily"])
    }

    @Test func renamingATagReachesEveryMeeting() throws {
        let db = try AppDatabase.inMemory()
        let id = try #require(try db.startMeeting(title: "A", tags: ["project=pix"]).id)
        try db.createTag("project=boleto")
        var tag = try #require(try db.tags().first { $0.name == "project=pix" })

        tag.name = "project=boleto"
        #expect(throws: TagError.alreadyExists("project=boleto")) { try db.updateTag(tag) }

        tag.name = "Project=Pix Automático"
        tag.description = "  "
        let updated = try db.updateTag(tag)
        #expect(updated.name == "project=pix automático")
        #expect(updated.description == nil)
        #expect(try names(db, id) == ["project=pix automático"])
    }

    @Test func listAndExportCarryTheTags() throws {
        let db = try AppDatabase.inMemory()
        let id = try #require(try db.startMeeting(title: "Daily", tags: ["project=pix", "daily"]).id)
        try db.createTag("1x1=tam", description: "Conversas com a Tam", rules: [.peopleAre(["Tam"])])

        #expect(try db.meetingList().first?.tags == ["daily", "project=pix"])
        #expect(try db.export(meetingId: id)?.tags == ["daily", "project=pix"])
        let list = try db.tagList()
        #expect(list.map(\.name) == ["1x1=tam", "daily", "project=pix"])
        #expect(list.map(\.meetingCount) == [0, 1, 1])
        #expect(list[0].key == "1x1")
        #expect(list[0].value == "tam")
        #expect(list[0].description == "Conversas com a Tam")
        #expect(list[0].rules == [.peopleAre(["Tam"])])
        #expect(list[1].key == nil)
    }
}

@Suite struct TagMigrationTests {
    @Test func v7MovesFreeTagsToTheCatalogAndFindsMeetRooms() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v6")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO meeting (id, startedAt, title, tags, source, status)
                VALUES (1, '2026-10-13 23:50:00', 'Meet: jos-cgmb-hzr · 13 de out.', '["outro","Daily"]', NULL, 'done'),
                       (2, '2026-10-14 12:15:00', 'rws-ftoc-imb · 14 de out.', '["daily"]', 'meet', 'done'),
                       (3, '2026-10-14 20:00:00', 'Reunião · 14 de out.', '[]', 'manual', 'done')
                """)
        }

        let db = try AppDatabase(queue, storage: .temporary())

        #expect(try db.tags().map(\.name) == ["daily", "outro"])
        #expect(try db.meetingTags(meetingId: 1).map(\.tag.name) == ["daily", "outro"])
        #expect(try db.meetingTags(meetingId: 1).allSatisfy { $0.source == TagSource.manual })
        #expect(try db.meetingTags(meetingId: 2).map(\.tag.name) == ["daily"])
        #expect(try db.meeting(id: 1)?.sourceRef == "meet/jos-cgmb-hzr")
        #expect(try db.meeting(id: 2)?.sourceRef == "meet/rws-ftoc-imb")
        #expect(try db.meeting(id: 3)?.sourceRef == nil)
    }
}

@Suite struct MeetRoomTests {
    @Test func roomFromTheTabAndFromOldTitles() {
        #expect(MeetDetector.sourceRef(forURL: "https://meet.google.com/abc-defg-hij?authuser=0") == "meet/abc-defg-hij")
        #expect(MeetDetector.sourceRef(forURL: "https://meet.google.com/landing") == nil)
        #expect(MeetDetector.sourceRef(inTitle: "Meet: jos-cgmb-hzr · 13 de out.") == "meet/jos-cgmb-hzr")
        #expect(MeetDetector.sourceRef(inTitle: "Daily do time") == nil)
    }
}

@Suite struct MeetingListLayoutTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: Int64, hoursAgo: Double, minutes: Int?, tags: [String], people: [String] = []) -> MeetingListItem {
        let start = now.addingTimeInterval(-hoursAgo * 3600)
        return MeetingListItem(
            id: id, title: "R\(id)", week: "", startedAt: start,
            endedAt: minutes.map { start.addingTimeInterval(Double($0) * 60) }, durationMs: minutes.map { $0 * 60_000 },
            status: "done", tags: tags, people: people, noteCount: 0, documents: [], links: [],
            attachmentCount: 0, openTaskCount: 0, newsAt: nil, unnamedVoiceCount: 0
        )
    }

    private var items: [MeetingListItem] {
        [
            item(1, hoursAgo: 1, minutes: 30, tags: ["daily", "project=pix"], people: ["Diego", "Ana"]),
            item(2, hoursAgo: 30, minutes: 60, tags: ["project=boleto", "project=pix"], people: ["Ana"]),
            item(3, hoursAgo: 200, minutes: 15, tags: ["daily"], people: ["Bruno"]),
            item(4, hoursAgo: 0.2, minutes: nil, tags: []),
        ]
    }

    @Test func filterKeepsMeetingsWithEveryTag() {
        #expect(MeetingListLayout.filter(items, tags: []).map(\.id) == [1, 2, 3, 4])
        #expect(MeetingListLayout.filter(items, tags: ["daily"]).map(\.id) == [1, 3])
        #expect(MeetingListLayout.filter(items, tags: ["daily", "project=pix"]).map(\.id) == [1])
        #expect(MeetingListLayout.tagKeys(in: items) == ["project"])
    }

    @Test func peopleFilterAndGroupThem() {
        #expect(MeetingListLayout.people(in: items) == ["Ana", "Bruno", "Diego"])
        #expect(MeetingListLayout.filter(items, people: []).map(\.id) == [1, 2, 3, 4])
        #expect(MeetingListLayout.filter(items, people: ["Diego", "Bruno"]).map(\.id) == [1, 3])

        let sections = MeetingListLayout.sections(items, grouping: .person, order: .newest, now: now)
        #expect(sections.map(\.title) == ["Ana", "Bruno", "Diego", "Sem pessoas identificadas"])
        #expect(sections.map { $0.items.map(\.id) } == [[1, 2], [3], [1], [4]])
    }

    @Test func groupsByTheValuesOfAKey() {
        let sections = MeetingListLayout.sections(items, grouping: .tagKey("project"), order: .newest, now: now)
        #expect(sections.map(\.title) == ["boleto", "pix", "Sem project"])
        #expect(sections.map { $0.items.map(\.id) } == [[2], [1, 2], [4, 3]])
        #expect(sections.allSatisfy { !$0.isSingleDay })

        let oldest = MeetingListLayout.sections(items, grouping: .tagKey("project"), order: .oldest, now: now)
        #expect(oldest.map { $0.items.map(\.id) } == [[2], [2, 1], [3, 4]])
    }

    @Test func ordersDaysAndMeetings() {
        let utc = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }()
        let newest = MeetingListLayout.sections(items, grouping: .day, order: .newest, now: now, calendar: utc)
        #expect(newest.flatMap { $0.items.map(\.id) } == [4, 1, 2, 3])

        let oldest = MeetingListLayout.sections(items, grouping: .day, order: .oldest, now: now, calendar: utc)
        #expect(oldest.flatMap { $0.items.map(\.id) } == [3, 2, 1, 4])
        #expect(oldest.map(\.title) == newest.map(\.title).reversed())

        // The longest first within each day; still recording last.
        let longest = MeetingListLayout.sections(items, grouping: .day, order: .longest, now: now, calendar: utc)
        #expect(longest.map(\.title) == newest.map(\.title))
        #expect(longest.flatMap { $0.items.map(\.id) } == [1, 4, 2, 3])
    }
}

@Suite struct TagCommandTests {
    @Test func parsesTagCommands() throws {
        #expect(try CLICommand.parse(["meetings", "--tag", "Project=Pix", "--tag", "daily"]) == .meetings(tags: ["project=pix", "daily"]))
        #expect(try CLICommand.parse(["tags"]) == .tags)
        #expect(try CLICommand.parse(["tag", "add", "4", "project=pix", "automático"]) == .tagAdd(meetingId: 4, tag: "project=pix automático"))
        #expect(try CLICommand.parse(["tag", "rm", "4", "#daily"]) == .tagRemove(meetingId: 4, tag: "daily"))

        #expect(throws: CLIError.self) { try CLICommand.parse(["meetings", "--tag"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["meetings", "--tag", " "]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["tag", "add", "4"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["tag", "set", "4", "x"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["tags", "x"]) }
    }
}

@Suite struct TagTextTests {
    @Test func rulesInWords() {
        #expect(TagText.rules([]) == nil)
        #expect(TagText.rules([.titleContains(["daily", "standup"])]) == "título contém “daily” ou “standup”")
        #expect(TagText.rules([.peopleInclude(["Ana", "Bia", "Rui"])]) == "com Ana, Bia e Rui")
        #expect(TagText.rules([.peopleAre(["Tam"])]) == "só você e Tam")
        #expect(TagText.rules([.titleContains(["1:1"]), .peopleAre(["Tam", "Bia"])]) == "título contém “1:1” · só você, Tam e Bia")
        #expect(TagText.rules([TagCondition(field: "weekday", op: "is", values: ["seg"]), .titleContains([" "])]) == nil)
    }

    @Test func whoPutTheTagOn() {
        let tag = Tag(name: "ritual=daily", rules: [.titleContains(["daily"])], createdAt: Date())
        #expect(TagText.source(AppliedTag(tag: tag, source: TagSource.manual)) == "Você pôs esta tag")
        #expect(TagText.source(AppliedTag(tag: tag, source: TagSource.rule)) == "Posta pela regra: título contém “daily”")
        #expect(TagText.source(AppliedTag(tag: tag, source: TagSource.recurring)) == "Veio da reunião anterior nesta sala do Meet")
    }
}
