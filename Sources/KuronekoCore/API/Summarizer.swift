import Foundation

/// Writes a meeting's summary with the agent chosen in Ajustes (Claude or
/// Codex) and saves it as the "summary" text: for `kuroneko summarize`, and
/// for the app, by itself once a meeting is transcribed or when asked.
public struct Summarizer: Sendable {
    /// The agent, the instructions and the meeting as text in, the Markdown out.
    public typealias Runner = @Sendable (_ agent: AgentCLI, _ prompt: String, _ input: String) throws -> String

    public let db: AppDatabase
    /// Read on every summary, so a change in Ajustes counts right away.
    private let agent: @Sendable () -> AgentCLI
    private let run: Runner

    public init(
        db: AppDatabase,
        run: @escaping Runner = { try $0.run(prompt: $1, input: $2) },
        agent: @escaping @Sendable () -> AgentCLI = { SummarySettings.agent() }
    ) {
        self.db = db
        self.agent = agent
        self.run = run
    }

    /// Worth summarizing by itself: something was said and there is no
    /// summary yet (a regenerated or edited one is never replaced).
    public func needsSummary(meetingId: Int64) throws -> Bool {
        guard !(try db.segments(meetingId: meetingId).isEmpty) else { return false }
        return !(try db.documents(meetingId: meetingId).contains { $0.kind == "summary" })
    }

    /// `markingNews` tells the user something new is waiting (a summary
    /// nobody asked for right now).
    @discardableResult
    public func summarize(meetingId: Int64, markingNews: Bool = false) throws -> MeetingDocument {
        guard let meeting = try db.export(meetingId: meetingId) else { throw SummaryError.noMeeting(meetingId) }
        guard meeting.timeline.contains(where: { $0.type == "speech" }) else { throw SummaryError.noTranscript(meetingId) }
        let agent = agent()
        let body = try run(agent, SummaryPrompt.instructions, TranscriptText.render(meeting, includeDocuments: false))
        let document = try db.setDocument(meetingId: meetingId, kind: "summary", body: body, source: agent.command)
        if markingNews {
            try db.markNews(meetingId: meetingId)
        }
        return document
    }
}

public enum SummaryError: Error, Equatable, CustomStringConvertible {
    case noMeeting(Int64)
    case noTranscript(Int64)

    public var description: String {
        switch self {
        case .noMeeting(let id): "reunião \(id) não existe"
        case .noTranscript(let id): "a reunião \(id) ainda não tem transcrição"
        }
    }
}
