import Foundation
import Testing
@testable import KuronekoCore

@Suite struct TaskListTests {
    private let summary = """
        ## Pendências
        - [ ] Abrir o card do cache de sessões — Bruno [12:31]
        - [ ] Mandar o relatório do teste de carga — Lucía [31:10]
        - [ ] Revisar o PR do login — Você [44:52]
        - [ ] Atualizar o board — bruno
        - [ ] Ver com alguém
        """

    /// Planning (with a summary) on Friday, then a daily today with a #acao note.
    private func tasks() throws -> (db: AppDatabase, tasks: [TaskItem]) {
        let db = try AppDatabase.inMemory()
        let planning = try db.startMeeting(title: "Planejamento do release", at: Date(timeIntervalSince1970: 1_800_000_000)).id!
        try db.setDocument(meetingId: planning, kind: "summary", body: summary, source: "claude")
        let daily = try db.startMeeting(title: "Daily do time", at: Date(timeIntervalSince1970: 1_800_400_000)).id!
        try db.addNote(meetingId: daily, tMs: 662_000, text: "subir o ambiente de QA hoje #acao")
        return (db, try db.tasks())
    }

    @Test func filtersByOwner() throws {
        let tasks = try tasks().tasks

        #expect(tasks.filter(TaskFilter.all.matches).count == 6)
        #expect(tasks.filter(TaskFilter.mine.matches).map(\.text) == ["subir o ambiente de QA hoje", "Revisar o PR do login"])
        #expect(tasks.filter(TaskFilter.owner("Bruno").matches).map(\.text) == ["Abrir o card do cache de sessões", "Atualizar o board"])
        #expect(TaskFilter.owners(in: tasks) == ["Bruno", "Lucía"])
    }

    @Test func othersAreEveryoneButTheUserWithAnOwner() throws {
        let tasks = try tasks().tasks

        #expect(tasks.filter(TaskFilter.others.matches).map(\.text) == [
            "Abrir o card do cache de sessões", "Mandar o relatório do teste de carga", "Atualizar o board",
        ])
    }

    @Test func filtersByAnyOfSeveralPeople() throws {
        let tasks = try tasks().tasks

        #expect(TaskListLayout.filter(tasks, owners: ["bruno", "Lucia"]).map(\.text) == [
            "Abrir o card do cache de sessões", "Mandar o relatório do teste de carga", "Atualizar o board",
        ])
        #expect(TaskListLayout.filter(tasks, owners: []).count == tasks.count)
    }

    @Test func groupsByOwnerAndByTagKey() throws {
        let (db, tasks) = try tasks()

        let byOwner = TaskListLayout.sections(tasks, grouping: .owner)
        #expect(byOwner.map(\.title) == ["Você", "Bruno", "Lucía", "Sem dono"])
        #expect(byOwner.map(\.tasks.count) == [2, 2, 1, 1])

        let board = try #require(tasks.first { $0.text == "Atualizar o board" })
        try db.addTaskTag("project=pix", taskId: board.taskId)
        let qa = try #require(tasks.first { $0.text.hasPrefix("subir") })
        try db.addTaskTag("project=sdks", taskId: qa.taskId)
        let tagged = try db.tasks()

        #expect(TaskListLayout.tagKeys(in: tagged) == ["project"])
        let byProject = TaskListLayout.sections(tagged, grouping: .tagKey("project"))
        #expect(byProject.map(\.title) == ["pix", "sdks", "Sem project"])
        #expect(byProject.map(\.tasks.count) == [1, 1, 4])
        #expect(TaskListLayout.filter(tagged, tags: ["project=pix"]).map(\.text) == ["Atualizar o board"])
        #expect(TaskListLayout.sections(tagged, grouping: .meeting).map(\.meetingId) == TaskGroup.byMeeting(tagged).map(\.meetingId))
    }

    @Test func groupsByStatusInTheUsersOrder() throws {
        let (db, tasks) = try tasks()
        let statuses = try db.taskStatuses()
        let doing = try #require(statuses.first { $0.name == "Fazendo" }?.id)
        try db.setTaskStatus(.task(id: tasks[0].taskId), statusId: doing)

        let sections = TaskListLayout.sections(try db.tasks(), grouping: .status, statuses: statuses)

        #expect(sections.map(\.title) == ["Aberta", "Fazendo"])
        #expect(sections.map(\.tasks.count) == [5, 1])
        #expect(sections.map(\.statusId) == [statuses[0].id, statuses[1].id])

        // The board keeps the empty columns, somewhere to drop.
        let columns = TaskListLayout.sections(try db.tasks(), grouping: .status, statuses: statuses, keepingEmpty: true)
        #expect(columns.map(\.title) == ["Aberta", "Fazendo", "Feita"])
        #expect(columns.map(\.tasks.count) == [5, 1, 0])
        #expect(TaskListLayout.sections(tasks, grouping: .owner).first?.value == "você")
    }

    @Test func groupsByMeetingNewestFirst() throws {
        let groups = TaskGroup.byMeeting(try tasks().tasks)

        #expect(groups.map(\.meetingTitle) == ["Daily do time", "Planejamento do release"])
        #expect(groups.map(\.tasks.count) == [1, 5])
    }

    @Test func searchIgnoresCaseAndAccents() throws {
        let tasks = try tasks().tasks

        #expect(tasks.filter { $0.matches("lucia") }.map(\.text) == ["Mandar o relatório do teste de carga"])
        #expect(tasks.filter { $0.matches("relatorio CARGA") }.count == 1)
        #expect(tasks.filter { $0.matches("daily qa") }.map(\.text) == ["subir o ambiente de QA hoje"])
        #expect(tasks.filter { $0.matches("") }.count == 6)
    }

    @Test func hidingAStatusLeavesItsPendenciasOut() throws {
        let (db, tasks) = try tasks()
        let cancelled = try db.createTaskStatus("Cancelada", color: "red")
        try db.setTaskStatus(.task(id: tasks[0].taskId), statusId: try #require(cancelled.id))
        let all = try db.tasks()

        #expect(TaskListLayout.filter(all, hiding: [try #require(cancelled.id)]).count == 5)
        #expect(TaskListLayout.filter(all, hiding: []).count == 6)
        // A status created afterwards shows up until it is hidden.
        let waiting = try db.createTaskStatus("Esperando")
        try db.setTaskStatus(.task(id: tasks[1].taskId), statusId: try #require(waiting.id))
        #expect(TaskListLayout.filter(try db.tasks(), hiding: [try #require(cancelled.id)]).map(\.status).contains("Esperando"))
    }
}
