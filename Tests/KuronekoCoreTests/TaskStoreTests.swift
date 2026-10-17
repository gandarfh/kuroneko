import Foundation
import GRDB
import Testing
@testable import KuronekoCore

@Suite struct TaskStoreTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(_ db: AppDatabase, _ title: String, day: Int, room: String? = nil) throws -> Int64 {
        try db.startMeeting(title: title, sourceRef: room, at: start.addingTimeInterval(Double(day) * 86_400)).id!
    }

    @Test func theSummaryHandsItsPendenciasOver() throws {
        let db = try AppDatabase.inMemory()
        let id = try meeting(db, "Planning", day: 0)
        try db.setDocument(
            meetingId: id, kind: "summary",
            body: "## Resumo\nRelease 3.4.\n\n## Pendências\n- Abrir o card — Bruno [12:31]\n- Medir o custo — Paulo\n- Subir o QA\n\n## Decisões\n- Usar flag [01:00]",
            source: "claude"
        )
        let before = try db.tasks()
        #expect(before.map(\.text) == ["Abrir o card", "Medir o custo", "Subir o QA"])
        #expect(before.first?.mentions.first?.startMs == 751_000)
        #expect(before.first?.createdAt == start)
        // The text keeps the rest.
        #expect(try db.documents(meetingId: id).first?.body == "## Resumo\nRelease 3.4.\n\n## Decisões\n- Usar flag [01:00]")
        let qa = try #require(before.last)
        try db.setTaskStatus(.task(id: qa.taskId), named: "Fazendo")

        // Summarized again: moved, new owner, one new, and two it doesn't
        // bring again — the one the user changed stays.
        try db.setDocument(meetingId: id, kind: "summary", body: "Intro\n\n## Pendências\n- Revisar o PR\n- Abrir o card — Ana [12:31]", source: "claude")

        let after = try db.tasks()
        // The new line on top.
        #expect(after.map(\.text) == ["Revisar o PR", "Abrir o card", "Subir o QA"])
        #expect(after[1].taskId == before.first?.taskId)
        #expect(after[1].owner == "Ana")
        #expect(after[1].mentions.first?.owner == "Ana")
        #expect(after[2].taskId == qa.taskId)

        // The text of the summary, edited or gone, leaves them alone.
        try db.setDocument(meetingId: id, kind: "summary", body: "Só o resumo.", source: "manual")
        try db.deleteDocument(meetingId: id, kind: "summary")
        #expect(try db.tasks().map(\.text) == ["Revisar o PR", "Abrir o card", "Subir o QA"])
    }

    @Test func acaoNotesAndMeetingsTakeTheirPendenciasWithThem() throws {
        let db = try AppDatabase.inMemory()
        let id = try meeting(db, "Daily", day: 0)
        let note = try db.addNote(meetingId: id, tMs: 5_000, text: "subir o QA #acao")
        try db.addNote(meetingId: id, tMs: 6_000, text: "só uma nota")
        let manual = try db.addTask("Falar com o Diego", owner: "você", meetingId: id, tMs: 7_000)

        #expect(try db.tasks().map(\.text) == ["Falar com o Diego", "subir o QA"])
        #expect(try db.task(.note(id: note.id!))?.owner == "você")

        try db.deleteNote(note.id!)
        #expect(try db.tasks().map(\.text) == ["Falar com o Diego"])

        // Written by the user, it stays without the meeting.
        try db.deleteMeeting(id)
        #expect(try db.tasks().map(\.taskId) == [manual.taskId])
        #expect(try db.tasks().first?.mentions.isEmpty == true)
    }

    @Test func joiningKeepsEveryMention() throws {
        let db = try AppDatabase.inMemory()
        let monday = try meeting(db, "Daily", day: 0, room: "meet/abc")
        let tuesday = try meeting(db, "Daily", day: 1, room: "meet/abc")
        try db.setDocument(meetingId: monday, kind: "summary", body: "## Pendências\n- [ ] Subir o deploy — Diego [01:00]", source: "claude")
        try db.setDocument(meetingId: tuesday, kind: "summary", body: "## Pendências\n- [ ] Deploy ainda travado — Diego [02:00]", source: "claude")
        let old = try #require(try db.tasks(meetingId: monday).first)
        let new = try #require(try db.tasks(meetingId: tuesday).first)

        try db.proposeMerge(taskId: new.taskId, into: old.taskId)
        let proposal = try #require(try db.mergeProposals().first)
        #expect(proposal.task.text == "Deploy ainda travado")
        #expect(proposal.into.text == "Subir o deploy")

        let joined = try db.mergeTasks(new.taskId, into: old.taskId)

        #expect(joined.mentions.map(\.meetingId) == [monday, tuesday])
        #expect(joined.mentions.map(\.text) == ["Subir o deploy", "Deploy ainda travado"])
        #expect(try db.mergeProposals().isEmpty)
        #expect(try db.tasks().count == 1)
        // Each meeting tells it from its own moment.
        #expect(try db.tasks(meetingId: tuesday).first?.startMs == 120_000)
        #expect(try db.meetingList().map(\.openTaskCount) == [1, 1])

        try db.setTaskStatus(.task(id: old.taskId), named: "Feita")
        #expect(try db.tasks().map(\.status) == ["Feita"])
        // The summary line still finds the pendência it became.
        #expect(try db.task(.summary(meetingId: tuesday, line: 1, fingerprint: new.mentions[0].fingerprintForTest))?.taskId == old.taskId)
    }

    @Test func aRejectedPairIsNotProposedAgainAndASplitIsRemembered() throws {
        let db = try AppDatabase.inMemory()
        let monday = try meeting(db, "Daily", day: 0)
        let tuesday = try meeting(db, "Daily", day: 1)
        let a = try db.addTask("Revisar o PR", owner: "Ana", meetingId: monday)
        let b = try db.addTask("Revisar o PR do login", owner: "Ana", meetingId: tuesday)

        try db.proposeMerge(taskId: b.taskId, into: a.taskId)
        try db.rejectMerge(b.taskId, into: a.taskId)
        try db.proposeMerge(taskId: b.taskId, into: a.taskId)
        try db.proposeMerge(taskId: a.taskId, into: b.taskId)
        #expect(try db.mergeProposals().isEmpty)
        #expect(try db.taskIdsWithMergeDecision() == [b.taskId])

        let c = try db.addTask("Atualizar o board", owner: nil, meetingId: tuesday)
        let joined = try db.mergeTasks(c.taskId, into: a.taskId)
        let lastMention = try #require(joined.mentions.last?.id)
        let split = try #require(try db.splitTaskMention(lastMention))
        #expect(split.text == "Atualizar o board")
        // Right below the one it was joined to.
        let order = try db.tasks().map(\.taskId)
        #expect(order.firstIndex(of: split.taskId) == order.firstIndex(of: a.taskId).map { $0 + 1 })
        #expect(try db.task(.task(id: a.taskId))?.mentions.count == 1)
        try db.proposeMerge(taskId: split.taskId, into: a.taskId)
        #expect(try db.mergeProposals().isEmpty)
        // The last mention can't be split from itself.
        let onlyMention = try #require(split.mentions.first?.id)
        #expect(try db.splitTaskMention(onlyMention) == nil)
    }

    @Test func mentionDaysCountTheDaysThatSpokeOfIt() throws {
        let db = try AppDatabase.inMemory()
        let calendar = Calendar(identifier: .gregorian)
        var ids: [Int64] = []
        for day in 0..<3 {
            let id = try meeting(db, "Daily", day: day)
            ids.append(try db.addTask("Deploy travado", owner: "Diego", meetingId: id, tMs: 0, at: start.addingTimeInterval(Double(day) * 86_400)).taskId)
        }
        #expect(try db.task(.task(id: ids[0]))?.mentionsText(calendar: calendar) == nil)
        let task = try db.mergeTasks(ids[1], into: ids[0])
        #expect(task.mentionDays(calendar: calendar) == 2)
        #expect(task.mentionsText(calendar: calendar) == "falada em 2 dias")
        #expect(try db.mergeTasks(ids[2], into: ids[0]).mentionDays(calendar: calendar) == 3)
    }

    @Test func theUserPutsThemInTheirOrder() throws {
        let db = try AppDatabase.inMemory()
        let id = try meeting(db, "Planning", day: 0)
        try db.setDocument(meetingId: id, kind: "summary", body: "## Pendências\n- [ ] A\n- [ ] B\n- [ ] C", source: "claude")
        // New ones on top; a summary's lines in their order.
        try db.addTask("D", owner: nil, meetingId: id)
        #expect(try db.tasks().map(\.text) == ["D", "A", "B", "C"])
        let ids = Dictionary(uniqueKeysWithValues: try db.tasks().map { ($0.text, $0.taskId) })

        try db.moveTask(ids["D"]!, nextTo: ids["C"]!, after: true)
        try db.moveTask(ids["C"]!, nextTo: ids["A"]!)

        #expect(try db.tasks().map(\.text) == ["C", "A", "B", "D"])
        // Editing the summary keeps the order; its new line goes on top.
        try db.setDocument(meetingId: id, kind: "summary", body: "## Pendências\n- [ ] A\n- [ ] B\n- [ ] C\n- [ ] E", source: "manual")
        #expect(try db.tasks().map(\.text) == ["E", "C", "A", "B", "D"])
        // The meeting's own screen goes by the recording.
        #expect(try db.tasks(meetingId: id).map(\.text) == ["A", "B", "C", "D", "E"])
        #expect(throws: TaskError.self) { try db.moveTask(ids["A"]!, nextTo: ids["A"]!) }
        #expect(throws: TaskError.self) { try db.moveTask(ids["A"]!, nextTo: 999) }
    }

    @Test func tagsComeFromTheMeetingsAndFromTheUser() throws {
        let db = try AppDatabase.inMemory()
        let id = try meeting(db, "Planning", day: 0)
        try db.addTag("project=sdks", meetingId: id)
        let task = try db.addTask("Medir o custo", owner: "Paulo", meetingId: id)
        #expect(try db.task(.task(id: task.taskId))?.tags == ["project=sdks"])

        try db.addTaskTag("Cliente=Pix", taskId: task.taskId)
        #expect(try db.task(.task(id: task.taskId))?.tags == ["cliente=pix", "project=sdks"])

        let sdks = try #require(try db.tags().first { $0.name == "project=sdks" }?.id)
        try db.removeTaskTag(sdks, taskId: task.taskId)
        #expect(try db.task(.task(id: task.taskId))?.tags == ["cliente=pix"])
    }

    @Test func editingTheTextAndTheOwner() throws {
        let db = try AppDatabase.inMemory()
        let id = try meeting(db, "Planning", day: 0)
        let task = try db.addTask("medir  custo", owner: " Paulo ", meetingId: id)
        #expect(task.text == "medir custo")
        #expect(task.owner == "Paulo")

        let edited = try db.updateTask(.task(id: task.taskId), text: "Medir o custo do cluster", owner: "")

        #expect(edited.text == "Medir o custo do cluster")
        #expect(edited.owner == nil)
        #expect(edited.mentions.first?.text == "medir custo")
        #expect(throws: TaskError.self) { try db.updateTask(.task(id: 999), text: "x", owner: nil) }
    }
}

@Suite struct TaskStatusTests {
    @Test func startsWithOpenDoingAndDone() throws {
        let db = try AppDatabase.inMemory()

        let statuses = try db.taskStatuses()

        #expect(statuses.map(\.name) == ["Aberta", "Fazendo", "Feita"])
        #expect(statuses.map(\.color) == ["gray", "amber", "green"])
    }

    @Test func colorIsKeptUnlessChanged() throws {
        let db = try AppDatabase.inMemory()
        let waiting = try db.createTaskStatus("Esperando", color: "blue")
        #expect(waiting.color == "blue")
        #expect(try db.updateTaskStatus(waiting.id!, name: "Aguardando").color == "blue")
        #expect(try db.updateTaskStatus(waiting.id!, name: "Aguardando", color: "purple").color == "purple")
    }

    @Test func theUsersOrderPicksWhereNewOnesStart() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "Daily").id!
        let statuses = try db.taskStatuses()
        let doing = try #require(statuses[1].id)
        let task = try db.addTask("Subir o deploy", owner: "Diego", meetingId: meeting)
        #expect(task.status == "Aberta")

        let moved = try db.setTaskStatus(.task(id: task.taskId), statusId: doing)
        #expect(moved.status == "Fazendo")

        // "Fazendo" first: new pendências start there.
        try db.moveTaskStatus(doing, to: 0)
        #expect(try db.taskStatuses().map(\.name) == ["Fazendo", "Aberta", "Feita"])
        #expect(try db.addTask("Outra", owner: nil, meetingId: meeting).status == "Fazendo")
        #expect(try db.setTaskStatus(.task(id: task.taskId), named: "aberta").status == "Aberta")
    }

    @Test func namesAreUniqueAndOneStatusAlwaysRemains() throws {
        let db = try AppDatabase.inMemory()
        let statuses = try db.taskStatuses()
        let open = try #require(statuses[0].id), doing = try #require(statuses[1].id), done = try #require(statuses[2].id)

        #expect(throws: TaskError.statusExists("feita")) { try db.createTaskStatus("feita") }
        #expect(throws: TaskError.statusExists("Fazendo")) { try db.updateTaskStatus(open, name: "Fazendo") }
        #expect(throws: TaskError.emptyStatusName) { try db.createTaskStatus("  ") }

        let cancelled = try db.createTaskStatus("Cancelada")
        #expect(cancelled.position == 3)
        try db.deleteTaskStatus(open, moveTo: doing)
        try db.deleteTaskStatus(done, moveTo: doing)
        try db.updateTaskStatus(doing, name: "Em  andamento")
        #expect(try db.taskStatuses().map(\.name) == ["Em andamento", "Cancelada"])
        try db.deleteTaskStatus(try #require(cancelled.id), moveTo: doing)
        #expect(throws: TaskError.lastStatus) { try db.deleteTaskStatus(doing, moveTo: doing) }
    }

    @Test func deletingMovesItsPendencias() throws {
        let db = try AppDatabase.inMemory()
        let meeting = try db.startMeeting(title: "Daily").id!
        let statuses = try db.taskStatuses()
        let review = try db.createTaskStatus("Revisão")
        let task = try db.addTask("Revisar o PR", owner: "Ana", meetingId: meeting)
        try db.setTaskStatus(.task(id: task.taskId), statusId: review.id!)
        #expect(try db.taskStatusCounts()[review.id!] == 1)

        try db.deleteTaskStatus(review.id!, moveTo: statuses[2].id!)

        #expect(try db.tasks().map(\.status) == ["Feita"])
        #expect(try db.taskStatusCounts()[review.id!] == nil)
    }
}

@Suite struct TaskMigrationTests {
    @Test func v8MakesPendenciasOfSummariesAndAcaoNotes() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v7")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let resolved = start.addingTimeInterval(600)
        try queue.write { db in
            var meeting = Meeting(startedAt: start, title: "Planning", status: .done)
            try meeting.insert(db)
            var summary = MeetingDocument(
                meetingId: meeting.id!, kind: "summary",
                body: "## Resumo\nRelease 3.4.\n\n## Pendências\n- [ ] Abrir o card — Bruno [12:31]\n- [x] Mandar o relatório — Lucía",
                source: "claude", updatedAt: start.addingTimeInterval(300)
            )
            try summary.insert(db)
            var note = Note(meetingId: meeting.id!, tMs: 1_000, text: "subir o QA #acao", resolvedAt: resolved)
            try note.insert(db)
        }

        let db = try AppDatabase(queue, storage: .temporary())

        let tasks = try db.tasks()
        // In the order of the recording: the note at 0:01, then the lines.
        #expect(tasks.map(\.text) == ["subir o QA", "Abrir o card", "Mandar o relatório"])
        // What was checked before statuses existed comes in "Feita".
        #expect(tasks.first { $0.text == "Mandar o relatório" }?.status == "Feita")
        #expect(tasks.first { $0.text == "subir o QA" }?.status == "Feita")
        #expect(tasks.first { $0.text == "Abrir o card" }?.status == "Aberta")
        #expect(try db.task(.summary(meetingId: 1, line: 4, fingerprint: SummaryItem(kind: "task", text: "Abrir o card", line: 4).fingerprint))?.owner == "Bruno")
        // The summaries keep the rest.
        #expect(try db.documents(meetingId: 1).first?.body == "## Resumo\nRelease 3.4.")
    }
}

extension TaskItem.Mention {
    /// The fingerprint of the summary line the mention came from.
    var fingerprintForTest: String {
        SummaryItem(kind: "task", text: text, line: 0).fingerprint
    }
}
