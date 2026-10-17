import Foundation

/// Finds which of a meeting's new pendências repeat ones still open — the
/// daily keeps speaking of the same thing in other words — by asking the
/// summary's agent right after the summary, with the pendências' texts
/// only. What it finds becomes proposals the user accepts or not.
public enum TaskMatcher {
    /// Pendências last spoken of longer ago than this are not compared.
    static let lookbackDays = 30
    static let maxCandidates = 40

    public static let instructions = """
        A seguir há pendências NOVAS, de uma reunião que acabou de ser resumida, e pendências ANTERIORES, de reuniões passadas com as mesmas pessoas. Em reuniões recorrentes, como a daily, a mesma pendência volta com outras palavras.

        Para cada pendência nova que for a mesma de uma anterior (o mesmo trabalho a fazer, não só o mesmo tema), responda uma linha no formato "N12 = A7". Na dúvida, não junte. Se nenhuma se repetir, responda só "nenhuma". Não escreva mais nada.
        """

    /// New pendências of the meeting: spoken of only there and never
    /// compared before.
    public static func newTasks(_ db: AppDatabase, meetingId: Int64) throws -> [TaskItem] {
        let decided = try db.taskIdsWithMergeDecision()
        return try db.tasks(meetingId: meetingId).filter { task in
            !decided.contains(task.taskId) && task.mentions.allSatisfy { $0.meetingId == meetingId }
        }
    }

    /// Pendências worth comparing: spoken of recently in the same Meet room,
    /// or owned by someone who was in the meeting.
    public static func candidates(_ db: AppDatabase, meetingId: Int64, excluding: Set<Int64>, now: Date = Date()) throws -> [TaskItem] {
        guard let meeting = try db.meeting(id: meetingId) else { return [] }
        let roomMeetings = Set(try db.meetings().filter { $0.sourceRef != nil && $0.sourceRef == meeting.sourceRef }.compactMap(\.id))
        let people = (try db.peopleByMeeting()[meetingId] ?? []) + ["você"]
        let since = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        return try db.tasks()
            .filter { task in
                guard !excluding.contains(task.taskId), let last = task.mentions.last, last.at >= since,
                      !task.mentions.contains(where: { $0.meetingId == meetingId }) else { return false }
                let sameRoom = task.mentions.contains { roomMeetings.contains($0.meetingId) }
                let samePerson = task.owner.map { owner in people.contains { TaskItem.sameName($0, owner) } } ?? false
                return sameRoom || samePerson
            }
            .sorted { ($0.mentions.last?.at ?? .distantPast) > ($1.mentions.last?.at ?? .distantPast) }
            .prefix(maxCandidates)
            .map { $0 }
    }

    /// The lists the agent reads.
    public static func input(new: [TaskItem], open: [TaskItem]) -> String {
        func line(_ prefix: String, _ task: TaskItem) -> String {
            var text = "\(prefix)\(task.taskId): \(task.text)"
            if let owner = task.owner { text += " — \(owner)" }
            return text
        }
        let days = open.map { task in
            task.mentions.map { $0.at.formatted(.dateTime.day().month(.twoDigits)) }
        }
        return (["NOVAS"] + new.map { line("N", $0) }
            + ["", "ANTERIORES"] + zip(open, days).map { task, days in line("A", task) + " (falada em \(days.joined(separator: ", ")))" })
            .joined(separator: "\n")
    }

    /// "N12 = A7" lines, ids checked against what was asked; a new one is
    /// joined to the first match only.
    public static func parse(_ answer: String, new: Set<Int64>, open: Set<Int64>) -> [(task: Int64, into: Int64)] {
        var pairs: [(task: Int64, into: Int64)] = []
        for match in answer.matches(of: /N\s*(\d+)\s*=\s*A\s*(\d+)/) {
            guard let task = Int64(match.output.1), let into = Int64(match.output.2),
                  new.contains(task), open.contains(into), !pairs.contains(where: { $0.task == task }) else { continue }
            pairs.append((task, into))
        }
        return pairs
    }
}
