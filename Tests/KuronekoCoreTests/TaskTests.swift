import Foundation
import Testing
@testable import KuronekoCore

@Suite struct SummaryItemsTests {
    private let summary = """
        ## Resumo
        Falamos do release 3.4 [00:30].

        ## Decisões
        - Adiar o cache de sessões para a 3.5 [12:31]
        - [ ] Login novo entra atrás de flag [1:02:03]

        ## Pendências
        - [ ] Abrir o card do cache de sessões — Bruno [12:31]
        - [x] Mandar o relatório do teste de carga — Lucía [31:10]
          - detalhe: incluir p99
        - Revisar o PR do login [44:52] — você
        * [X] Atualizar o board
        1. [ ] Medir o custo do cluster novo — Paulo [52:05–53:10]

        ## Minhas notas
        - [ ] não é pendência [10:00]
        """

    @Test func readsPendenciasAndDecisoes() {
        let items = SummaryItems.parse(summary)

        #expect(items.map(\.kind) == ["decision", "decision", "task", "task", "task", "task", "task"])
        #expect(items.map(\.text) == [
            "Adiar o cache de sessões para a 3.5",
            "Login novo entra atrás de flag",
            "Abrir o card do cache de sessões",
            "Mandar o relatório do teste de carga",
            "Revisar o PR do login",
            "Atualizar o board",
            "Medir o custo do cluster novo",
        ])
        #expect(items.map(\.owner) == [nil, nil, "Bruno", "Lucía", "você", nil, "Paulo"])
        #expect(items.map(\.startMs) == [751_000, 3_723_000, 751_000, 1_870_000, 2_692_000, nil, 3_125_000])
        #expect(items.map(\.done) == [false, false, false, true, false, true, false])
        #expect(items.map(\.line) == [4, 5, 8, 9, 11, 12, 13])
    }

    @Test func headingsWithoutHashesAndOtherSpellings() {
        let text = """
            **Pendências:**
            - [ ] Subir o QA — Ana

            Decisões
            * Usar Postgres

            Pontos em aberto
            - [ ] nada a ver

            ### Próximos passos
            - [ ] Marcar a retro – Marta [05:00]

            # Decisão final (2)
            - Fechado
            """

        let items = SummaryItems.parse(text)

        #expect(items.map(\.text) == ["Subir o QA", "Usar Postgres", "Marcar a retro", "Fechado"])
        #expect(items.map(\.kind) == ["task", "decision", "task", "decision"])
        #expect(items[2].owner == "Marta")
        #expect(items[2].startMs == 300_000)
    }

    @Test func takesThePendenciasOutOfTheText() throws {
        let taken = try #require(SummaryItems.takeTasks(summary))

        #expect(taken.tasks.map(\.text) == [
            "Abrir o card do cache de sessões",
            "Mandar o relatório do teste de carga",
            "Revisar o PR do login",
            "Atualizar o board",
            "Medir o custo do cluster novo",
        ])
        #expect(taken.rest == """
            ## Resumo
            Falamos do release 3.4 [00:30].

            ## Decisões
            - Adiar o cache de sessões para a 3.5 [12:31]
            - [ ] Login novo entra atrás de flag [1:02:03]

            ## Minhas notas
            - [ ] não é pendência [10:00]
            """)
        #expect(SummaryItems.takeTasks("**Pendências:**\n- Subir o QA\n\nDecisões\n* Usar Postgres")?.rest == "Decisões\n* Usar Postgres")
        #expect(SummaryItems.takeTasks("## Pendências\n- Nenhuma pendência.")?.rest == "")
        #expect(SummaryItems.takeTasks("## Resumo\nNada a fazer.") == nil)
    }

    @Test func ignoresEmptyAndPlaceholderBullets() {
        let text = "## Pendências\n- [ ] \n- Nenhuma pendência.\n- Nenhum deploy na sexta [10:00]\nTexto solto.\n"

        #expect(SummaryItems.parse(text).map(\.text) == ["Nenhum deploy na sexta"])
    }
}

@Suite struct TaskTests {
    private let summary = """
        ## Resumo
        Release 3.4.

        ## Pendências
        - [ ] Abrir o card do cache — Bruno [12:31]
        - [x] Mandar o relatório — Lucía [31:10]
        """

    private func setUp() throws -> (AppDatabase, planning: Int64, daily: Int64) {
        let db = try AppDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let planning = try db.startMeeting(title: "Planning", at: start).id!
        let daily = try db.startMeeting(title: "Daily", at: start.addingTimeInterval(3600)).id!
        try db.setDocument(meetingId: planning, kind: "summary", body: summary, source: "claude", at: start)
        try db.addNote(meetingId: daily, tMs: 662_000, text: "subir o QA hoje #acao")
        try db.addNote(meetingId: daily, tMs: 700_000, text: "só uma nota")
        return (db, planning, daily)
    }

    @Test func tasksComeFromSummariesAndAcaoNotes() throws {
        let (db, planning, daily) = try setUp()

        let tasks = try db.tasks()

        // A checked line is a pendência like any other: what [x] means is
        // the user's status, not the app's.
        #expect(tasks.map(\.text) == ["subir o QA hoje", "Abrir o card do cache", "Mandar o relatório"])
        #expect(tasks.map(\.meetingId) == [daily, planning, planning])
        #expect(tasks.map(\.owner) == ["você", "Bruno", "Lucía"])
        #expect(tasks.map(\.source) == ["note", "summary", "summary"])
        #expect(tasks.map(\.status) == ["Aberta", "Aberta", "Aberta"])
        #expect(tasks.first?.startMs == 662_000)
        #expect(tasks.first?.meetingTitle == "Daily")
        #expect(try db.meetingList().map(\.openTaskCount) == [1, 2])
        #expect(try db.documents(meetingId: planning).first?.body == "## Resumo\nRelease 3.4.")
        #expect(try db.export(meetingId: planning)?.summaryItems.isEmpty == true)
    }

    @Test func aStatusChangeLeavesTheTextsAlone() throws {
        let (db, planning, _) = try setUp()
        let summaryTask = try #require(try db.tasks().first { $0.source == "summary" })
        let noteTask = try #require(try db.tasks().first { $0.source == "note" })
        let body = try db.documents(meetingId: planning).first?.body

        let moved = try db.setTaskStatus(try #require(TaskRef(summaryTask.ref)), named: "feita")
        try db.setTaskStatus(try #require(TaskRef(noteTask.ref)), named: "Fazendo")

        #expect(moved.status == "Feita")
        #expect(try db.documents(meetingId: planning).first?.body == body)
        #expect(try db.documents(meetingId: planning).first?.source == "claude")
        #expect(try db.notes(tagged: TaskItem.noteTag).first?.resolvedAt == nil)
        #expect(try db.tasks().map(\.status) == ["Fazendo", "Feita", "Aberta"])
        #expect(throws: TaskError.notFound("status Pronta")) { try db.setTaskStatus(.task(id: moved.taskId), named: "Pronta") }
    }

    @Test func anOldSummaryRefStillFindsIt() throws {
        let (db, planning, _) = try setUp()
        let line = SummaryItem(kind: "task", text: "Abrir o card do cache", line: 7)

        let moved = try db.setTaskStatus(.summary(meetingId: planning, line: 7, fingerprint: line.fingerprint), named: "Fazendo")

        #expect(moved.text == "Abrir o card do cache")
        #expect(moved.status == "Fazendo")
    }

    @Test func refsRoundTrip() {
        #expect(TaskRef("task:12") == .task(id: 12))
        #expect(TaskRef("task:12")?.description == "task:12")
        #expect(TaskRef("task:x") == nil)
        #expect(TaskRef("summary:12:7:9f86d081") == .summary(meetingId: 12, line: 7, fingerprint: "9f86d081"))
        #expect(TaskRef("note:45") == .note(id: 45))
        #expect(TaskRef("note:45")?.description == "note:45")
        #expect(TaskRef("summary:12:7") == nil)
        #expect(TaskRef("45") == nil)
    }

    @Test func parsesTaskCommands() throws {
        #expect(try CLICommand.parse(["tasks"]) == .tasks)
        #expect(try CLICommand.parse(["task", "status", "task:9", "Em", "revisão"]) == .taskStatus(.task(id: 9), status: "Em revisão"))
        #expect(try CLICommand.parse(["task", "status", "note:45", "Feita"]) == .taskStatus(.note(id: 45), status: "Feita"))
        #expect(throws: CLIError.self) { try CLICommand.parse(["task", "status", "task:9"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["task", "status", "45", "Feita"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["task", "done", "note:45"]) }
        #expect(throws: CLIError.self) { try CLICommand.parse(["task", "fazer", "note:45"]) }
    }
}
