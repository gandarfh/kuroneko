import Foundation
import Testing
@testable import KuronekoCore

@Suite struct SummarizerTests {
    private func transcribed(_ db: AppDatabase) throws -> Int64 {
        let id = try db.startMeeting(title: "Planning").id!
        try db.endMeeting(id)
        try db.saveTranscript(
            meetingId: id,
            speakers: [MeetingSpeaker(meetingId: id, diarCluster: 0, speechMs: 5000)],
            segments: [Segment(meetingId: id, tStartMs: 60_000, tEndMs: 65_000, channel: .system, diarCluster: 0, text: "migrar o banco até sexta")]
        )
        return id
    }

    @Test func savesTheAgentsSummaryAndMarksNews() throws {
        let db = try AppDatabase.inMemory()
        let id = try transcribed(db)
        let seen = Locked<[String]>([])
        let summarizer = Summarizer(
            db: db,
            run: { agent, prompt, input in
                seen.value = [agent.model, prompt, input]
                return "## Resumo\nMigração até sexta."
            },
            agent: { AgentCLI(command: "codex", model: "gpt-6-astra") }
        )

        #expect(try summarizer.needsSummary(meetingId: id))
        let document = try summarizer.summarize(meetingId: id, markingNews: true)

        #expect(document.kind == "summary")
        #expect(document.source == "codex")
        #expect(seen.value.first == "gpt-6-astra")
        #expect(seen.value[1] == SummaryPrompt.instructions)
        #expect(seen.value.last?.contains("[01:00] Pessoa 1: migrar o banco até sexta") == true)
        #expect(try !summarizer.needsSummary(meetingId: id))
        #expect(try db.meetingsWithNews().map(\.id) == [id])
    }

    @Test func onRequestItIsNotNews() throws {
        let db = try AppDatabase.inMemory()
        let id = try transcribed(db)

        try Summarizer(db: db) { _, _, _ in "resumo" }.summarize(meetingId: id)

        #expect(try db.meetingsWithNews().isEmpty)
    }

    @Test func nothingToSummarizeWithoutSpeech() throws {
        let db = try AppDatabase.inMemory()
        let id = try db.startMeeting(title: "Vazia").id!
        let summarizer = Summarizer(db: db) { _, _, _ in Issue.record("o agente não devia rodar"); return "" }

        #expect(try !summarizer.needsSummary(meetingId: id))
        #expect(throws: SummaryError.noTranscript(id)) { try summarizer.summarize(meetingId: id) }
        #expect(throws: SummaryError.noMeeting(99)) { try summarizer.summarize(meetingId: 99) }
    }

    @Test func aFailedRunSavesNothing() throws {
        let db = try AppDatabase.inMemory()
        let id = try transcribed(db)

        #expect(throws: AgentError.emptyOutput("claude")) {
            try Summarizer(db: db) { _, _, _ in throw AgentError.emptyOutput("claude") }.summarize(meetingId: id, markingNews: true)
        }
        #expect(try db.documents(meetingId: id).isEmpty)
        #expect(try db.meetingsWithNews().isEmpty)
    }
}

@Suite struct NewsTests {
    @Test func newsUntilSeen() throws {
        let db = try AppDatabase.inMemory()
        let old = try db.startMeeting(title: "Antiga").id!
        let new = try db.startMeeting(title: "Nova").id!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try db.markNews(meetingId: new, at: now)
        try db.markNews(meetingId: old, at: now.addingTimeInterval(60))

        #expect(try db.meetingsWithNews().map(\.id) == [old, new])
        #expect(try db.meetingList().first { $0.id == new }?.newsAt == now)
        try db.markSeen(meetingId: old)
        #expect(try db.meetingsWithNews().map(\.id) == [new])
        try db.deleteMeeting(new)
        #expect(try db.meetingsWithNews().isEmpty)
    }
}

@Suite struct AgentCLITests {
    /// A stand-in for the CLI: a shell script in a fresh folder.
    private func script(_ body: String, named name: String = "claude") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func claudeGetsThePromptTheModelAndTheInputOnStdin() throws {
        let claude = try script(#"echo "$*"; tr a-z A-Z"#)
        defer { try? FileManager.default.removeItem(at: claude.deletingLastPathComponent()) }

        let text = try AgentCLI(command: "claude", model: "opus")
            .run(executable: claude, environment: [:], prompt: "resuma", input: "olá mundo\n", timeout: 10)
        #expect(text == "-p resuma --no-session-persistence --model opus\nOLá MUNDO")

        // No model: the CLI's own default.
        let plain = try AgentCLI(command: "claude", model: " ")
            .run(executable: claude, environment: [:], prompt: "resuma", input: "", timeout: 10)
        #expect(plain == "-p resuma --no-session-persistence")
    }

    @Test func codexAnswersInTheLastMessageFile() throws {
        // Like codex exec: progress on stdout and stderr, the answer in the file.
        let codex = try script(#"""
            out=""; model=""; dir=""; prev=""
            for arg in "$@"; do
              case "$prev" in --output-last-message) out="$arg";; --model) model="$arg";; --cd) dir="$arg";; esac
              prev="$arg"
            done
            echo "pensando..."; echo "tokens: 120" >&2
            { echo "model=$model prompt=$prev"; [ -d "$dir" ] && echo "pasta ok"; tr a-z A-Z; } > "$out"
            """#, named: "codex")
        defer { try? FileManager.default.removeItem(at: codex.deletingLastPathComponent()) }

        let text = try AgentCLI(command: "codex", model: "gpt-6-astra")
            .run(executable: codex, environment: [:], prompt: "resuma", input: "olá mundo\n", timeout: 10)

        #expect(text == "model=gpt-6-astra prompt=resuma\npasta ok\nOLá MUNDO")
        #expect(AgentCLI(command: "codex").arguments(prompt: "p", folder: URL(fileURLWithPath: "/t"), lastMessage: URL(fileURLWithPath: "/t/m")) == [
            "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
            "--cd", "/t", "--output-last-message", "/t/m", "p",
        ])
    }

    @Test func reportsFailuresAndTimeouts() throws {
        let failing = try script("echo 'sem login' >&2; exit 3")
        let silent = try script("cat > /dev/null")
        let slow = try script("sleep 30")
        defer {
            for url in [failing, silent, slow] {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let claude = AgentCLI(command: "claude")
        #expect(throws: AgentError.failed("claude", status: 3, detail: "sem login")) {
            try claude.run(executable: failing, environment: [:], prompt: "x", input: "y", timeout: 10)
        }
        #expect(throws: AgentError.emptyOutput("claude")) {
            try claude.run(executable: silent, environment: [:], prompt: "x", input: "y", timeout: 10)
        }
        // Codex printing but leaving no answer.
        #expect(throws: AgentError.emptyOutput("codex")) {
            try AgentCLI(command: "codex").run(executable: silent, environment: [:], prompt: "x", input: "y", timeout: 10)
        }
        let start = Date()
        #expect(throws: AgentError.timedOut("claude", 1)) {
            try claude.run(executable: slow, environment: [:], prompt: "x", input: "y", timeout: 1)
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func errorsNameTheCommandAndKeepTheEnd() {
        #expect(AgentError.notFound("codex").description == "codex não encontrado — instale o Codex CLI ou aponte KURONEKO_CODEX para ele")
        #expect(AgentError.notFound("claude").description == "claude não encontrado — instale o Claude Code ou aponte KURONEKO_CLAUDE para ele")

        // Codex: a header, a warning, then the error as JSON.
        let codex = """
            OpenAI Codex v0.161.0
            --------
            model: gpt-x
            --------
            warning: Model metadata for `gpt-x` not found.
            ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-x' model is not supported."}}
            """
        #expect(AgentCLI.failureDetail(errors: codex, output: "") == "The 'gpt-x' model is not supported.")
        #expect(AgentCLI.failureDetail(errors: "ERROR: sem rede\n", output: "") == "sem rede")
        // Claude: nothing on stderr, the reason on stdout.
        #expect(AgentCLI.failureDetail(errors: "", output: "There's an issue with the selected model (x).\n") == "There's an issue with the selected model (x).")
        #expect(AgentCLI.failureDetail(errors: "1\n2\n\n3\n4\n", output: "ignorado") == "2\n3\n4")
    }

    @Test func findsTheCommandLikeTheUsersShell() throws {
        let claude = try script("true")
        let folder = claude.deletingLastPathComponent().path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let home = "/nonexistent-home"

        let (overridden, _) = try AgentCLI.locate("claude", environment: ["KURONEKO_CLAUDE": "/opt/claude", "PATH": folder], home: home, knownDirectories: []) { _ in nil }
        #expect(overridden.path == "/opt/claude")

        let (inPath, environment) = try AgentCLI.locate("claude", environment: ["PATH": "/usr/bin:\(folder)"], home: home, knownDirectories: []) { _ in
            Issue.record("o shell não devia ser consultado")
            return nil
        }
        #expect(inPath.path == claude.path)
        #expect(environment["PATH"] == "/usr/bin:\(folder)")

        // From Finder: only the login shell knows where claude is.
        let asked = Locked<[Bool]>([])
        let (fromShell, shellEnvironment) = try AgentCLI.locate("claude", environment: ["PATH": "/usr/bin:/bin"], home: home, knownDirectories: []) { interactive in
            asked.value.append(interactive)
            return interactive ? "\(folder):/usr/bin" : "/usr/bin"
        }
        #expect(fromShell.path == claude.path)
        #expect(asked.value == [false, true])
        #expect(shellEnvironment["PATH"]?.hasPrefix("\(folder):/usr/bin:") == true)

        #expect(throws: AgentError.notFound("claude")) {
            try AgentCLI.locate("claude", environment: ["PATH": "/nonexistent"], home: home, knownDirectories: []) { _ in nil }
        }
    }
}

/// A value tests can change from a @Sendable closure.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite struct SummarySettingsTests {
    @Test func eachAgentKeepsItsModel() throws {
        let defaults = try #require(UserDefaults(suiteName: "kuroneko-test-\(UUID().uuidString)"))
        #expect(SummarySettings.agent(in: defaults) == AgentCLI(command: "claude"))

        SummarySettings.save(AgentCLI(command: "claude", model: "opus"), in: defaults)
        SummarySettings.save(AgentCLI(command: "codex", model: " gpt-6-astra "), in: defaults)
        #expect(SummarySettings.agent(in: defaults) == AgentCLI(command: "codex", model: "gpt-6-astra"))
        #expect(SummarySettings.model(for: "claude", in: defaults) == "opus")

        // Something unknown written by hand falls back to Claude.
        defaults.set("gemini", forKey: "summaryCommand")
        #expect(SummarySettings.agent(in: defaults) == AgentCLI(command: "claude", model: "opus"))
    }
}

@Suite struct AgentModelTests {
    @Test func claudeOffersTheNewestOfEachFamily() {
        #expect(AgentCLI.models(for: "claude").map(\.id) == ["opus", "sonnet", "haiku"])
    }

    @Test func codexListsWhatItShowsInItsOwnPicker() {
        let json = Data("""
            {"fetched_at": "2026-10-16", "models": [
              {"slug": "gpt-6-astra", "display_name": "GPT-6-Astra", "visibility": "list", "priority": 2},
              {"slug": "codex-auto-review", "display_name": "Codex Auto Review", "visibility": "hide", "priority": 43},
              {"slug": "gpt-6.1-sol", "display_name": "GPT-6.1-Sol", "visibility": "list", "priority": 1},
              {"slug": "gpt-sem-nome", "visibility": "list"}
            ]}
            """.utf8)
        #expect(AgentCLI.codexModels(fromJSON: json) == [
            AgentModel(id: "gpt-6.1-sol", name: "GPT-6.1-Sol"),
            AgentModel(id: "gpt-6-astra", name: "GPT-6-Astra"),
            AgentModel(id: "gpt-sem-nome", name: "gpt-sem-nome"),
        ])
        #expect(AgentCLI.codexModels(fromJSON: Data("não é json".utf8)) == [])
    }
}
