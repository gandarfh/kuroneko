import Foundation
import Testing
@testable import KuronekoCore

@Suite struct TaskMatcherTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func readsOnlyPairsThatWereAsked() {
        let answer = """
            N12 = A7
            n13 = a8
            N14=A99
            N12 = A9
            N15 = A8 (o mesmo deploy)
            """
        let pairs = TaskMatcher.parse(answer, new: [12, 14, 15], open: [7, 8, 9])
        #expect(pairs.map(\.task) == [12, 15])
        #expect(pairs.map(\.into) == [7, 8])
        #expect(TaskMatcher.parse("nenhuma", new: [1], open: [2]).isEmpty)
    }

    @Test func comparesWithTheSameRoomOrTheSamePeopleRecently() throws {
        let db = try AppDatabase.inMemory()
        func day(_ n: Double) -> Date { start.addingTimeInterval(n * 86_400) }
        let daily1 = try db.startMeeting(title: "Daily", sourceRef: "meet/abc", at: day(0)).id!
        let other = try db.startMeeting(title: "1:1", sourceRef: "meet/xyz", at: day(1)).id!
        let old = try db.startMeeting(title: "Daily", sourceRef: "meet/abc", at: day(-40)).id!
        let daily2 = try db.startMeeting(title: "Daily", sourceRef: "meet/abc", at: day(2)).id!
        let room = try db.addTask("Subir o deploy", owner: "Diego", meetingId: daily1, tMs: 0)
        let mine = try db.addTask("Falar com o RH", owner: "você", meetingId: other, tMs: 0)
        _ = try db.addTask("Pedir acesso", owner: "Marta", meetingId: other, tMs: 0)
        _ = try db.addTask("Antiga", owner: "Diego", meetingId: old, tMs: 0)
        let fresh = try db.addTask("Deploy travado", owner: "Diego", meetingId: daily2, tMs: 0)

        #expect(try TaskMatcher.newTasks(db, meetingId: daily2).map(\.taskId) == [fresh.taskId])
        let candidates = try TaskMatcher.candidates(db, meetingId: daily2, excluding: [fresh.taskId], now: day(2))
        #expect(candidates.map(\.taskId) == [mine.taskId, room.taskId])

        let input = TaskMatcher.input(new: [fresh], open: candidates)
        #expect(input.contains("N\(fresh.taskId): Deploy travado — Diego"))
        #expect(input.contains("A\(room.taskId): Subir o deploy — Diego (falada em "))
    }

    @Test func theSummaryIsFollowedByProposalsNotJoins() throws {
        let db = try AppDatabase.inMemory()
        let monday = try db.startMeeting(title: "Daily", sourceRef: "meet/abc", at: start).id!
        try db.setDocument(meetingId: monday, kind: "summary", body: "## Pendências\n- [ ] Subir o deploy — Diego", source: "claude")
        let tuesday = try db.startMeeting(title: "Daily", sourceRef: "meet/abc", at: start.addingTimeInterval(86_400)).id!
        try db.endMeeting(tuesday)
        try db.saveTranscript(
            meetingId: tuesday,
            speakers: [MeetingSpeaker(meetingId: tuesday, diarCluster: 0, speechMs: 5000)],
            segments: [Segment(meetingId: tuesday, tStartMs: 0, tEndMs: 5000, channel: .system, diarCluster: 0, text: "o deploy ainda não subiu")]
        )
        let old = try #require(try db.tasks().first)
        let prompts = Locked<[String]>([])
        let summarizer = Summarizer(db: db, run: { _, prompt, input in
            prompts.value.append(prompt)
            if prompt == TaskMatcher.instructions {
                let id = input.firstMatch(of: /N(\d+):/)!.output.1
                return "N\(id) = A\(old.taskId)"
            }
            return "## Pendências\n- [ ] Deploy ainda travado — Diego [00:02]"
        }, agent: { AgentCLI(command: "claude", model: "") })

        try summarizer.summarize(meetingId: tuesday)

        #expect(prompts.value.count == 2)
        #expect(try db.tasks().count == 2)
        let proposal = try #require(try db.mergeProposals().first)
        #expect(proposal.into.taskId == old.taskId)
        #expect(proposal.task.text == "Deploy ainda travado")
        // Asked once: summarizing again does not ask about the same pair.
        #expect(try summarizer.proposeMerges(meetingId: tuesday, now: start.addingTimeInterval(86_400)) == 0)
        #expect(prompts.value.count == 2)
    }

    @Test func aFailedComparisonKeepsTheSummary() throws {
        let db = try AppDatabase.inMemory()
        let monday = try db.startMeeting(title: "Daily", sourceRef: "meet/abc", at: start).id!
        _ = try db.addTask("Subir o deploy", owner: "Diego", meetingId: monday)
        let tuesday = try db.startMeeting(title: "Daily", sourceRef: "meet/abc", at: start.addingTimeInterval(86_400)).id!
        try db.saveTranscript(
            meetingId: tuesday,
            speakers: [MeetingSpeaker(meetingId: tuesday, diarCluster: 0, speechMs: 5000)],
            segments: [Segment(meetingId: tuesday, tStartMs: 0, tEndMs: 5000, channel: .system, diarCluster: 0, text: "deploy")]
        )
        let summarizer = Summarizer(db: db, run: { _, prompt, _ in
            if prompt == TaskMatcher.instructions { throw AgentError.emptyOutput("claude") }
            return "## Pendências\n- [ ] Deploy travado — Diego"
        }, agent: { AgentCLI(command: "claude", model: "") })

        try summarizer.summarize(meetingId: tuesday)

        #expect(try db.documents(meetingId: tuesday).first?.kind == "summary")
        #expect(try db.mergeProposals().isEmpty)
    }
}
