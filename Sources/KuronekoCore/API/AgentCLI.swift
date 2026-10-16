import Foundation

/// The coding agent that writes summaries, run non-interactively with the
/// user's own account: Claude Code (`claude -p`) or Codex (`codex exec`).
/// The instructions go as the prompt and the meeting on stdin; the text of a
/// meeting leaves the Mac only here.
public struct AgentCLI: Equatable, Sendable {
    public static let claude = "claude"
    public static let codex = "codex"
    public static let commands = [claude, codex]

    /// The command: `claude` or `codex`.
    public var command: String
    /// "opus", "gpt-6-astra"…; empty leaves the choice to the CLI.
    public var model: String

    public init(command: String, model: String = "") {
        self.command = command
        self.model = model
    }

    /// How the screens call it: "Claude", "Codex".
    public var title: String { Self.title(of: command) }

    public static func title(of command: String) -> String {
        command == codex ? "Codex" : "Claude"
    }

    /// A long meeting takes a minute or two.
    public static let defaultTimeout: TimeInterval = 300

    public func run(prompt: String, input: String, timeout: TimeInterval = defaultTimeout) throws -> String {
        let (executable, environment) = try Self.locate(command)
        return try run(executable: executable, environment: environment, prompt: prompt, input: input, timeout: timeout)
    }

    func run(executable: URL, environment: [String: String], prompt: String, input: String, timeout: TimeInterval) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-agent-\(UUID().uuidString)", isDirectory: true)
        let lastMessage = folder.appendingPathComponent("last-message.md")
        let result: Execution
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            result = try Self.execute(
                executable,
                arguments: arguments(prompt: prompt, folder: folder, lastMessage: lastMessage),
                environment: environment,
                input: Data(input.utf8),
                timeout: timeout
            )
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw AgentError.couldNotRun(command, error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        if result.timedOut { throw AgentError.timedOut(command, Int(timeout)) }
        guard result.status == 0 else {
            let detail = Self.failureDetail(
                errors: String(decoding: result.errors, as: UTF8.self),
                output: String(decoding: result.output, as: UTF8.self)
            )
            throw AgentError.failed(command, status: result.status, detail: detail)
        }
        // Codex prints its progress too; its answer alone is in the file.
        let output = command == Self.codex ? (try? Data(contentsOf: lastMessage)) ?? Data() : result.output
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentError.emptyOutput(command) }
        return text
    }

    /// No session is kept on disk (it would hold a copy of the meeting);
    /// Codex runs in an empty folder it can't write to.
    func arguments(prompt: String, folder: URL, lastMessage: URL) -> [String] {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelArguments = model.isEmpty ? [] : ["--model", model]
        switch command {
        case Self.codex:
            return ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
                    "--cd", folder.path, "--output-last-message", lastMessage.path]
                + modelArguments + [prompt]
        default:
            return ["-p", prompt, "--no-session-persistence"] + modelArguments
        }
    }

    /// What went wrong, in the agent's words: Codex's last "ERROR:" line
    /// (the message of its JSON), else the end of stderr, else of stdout,
    /// where Claude prints its errors.
    static func failureDetail(errors: String, output: String) -> String {
        let lines = errors.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let line = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            let text = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
            if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            return text
        }
        let source = lines.isEmpty ? output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : lines
        return source.suffix(3).joined(separator: "\n")
    }

    // MARK: - Finding the command

    /// Where these CLIs usually land when the shell can't tell.
    static let knownDirectories = ["~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]

    /// `KURONEKO_CLAUDE` or `KURONEKO_CODEX` when set; else the command in
    /// the PATH, which for the app opened from Finder is only /usr/bin:/bin:…
    /// — so the PATH of the user's login shell is asked for. The command runs
    /// with that PATH, since an npm install needs `node` from it.
    static func locate(
        _ command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        knownDirectories: [String] = knownDirectories,
        shellPath: (_ interactive: Bool) -> String? = { loginShellPath(interactive: $0) }
    ) throws -> (URL, [String: String]) {
        if let path = environment["KURONEKO_\(command.uppercased())"], !path.isEmpty {
            return (URL(fileURLWithPath: path), environment)
        }
        let current = environment["PATH"] ?? ""
        if let found = find(command, in: current) {
            return (found, environment)
        }
        let known = knownDirectories.map { $0.replacingOccurrences(of: "~", with: home) }.joined(separator: ":")
        // A non-interactive shell skips .zshrc, where PATH is often set; an
        // interactive one is only started when nothing else found it.
        for interactive in [false, true] {
            let path = [shellPath(interactive) ?? "", known, current].filter { !$0.isEmpty }.joined(separator: ":")
            if let found = find(command, in: path) {
                var environment = environment
                environment["PATH"] = path
                return (found, environment)
            }
        }
        throw AgentError.notFound(command)
    }

    static func find(_ name: String, in path: String) -> URL? {
        path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func loginShellPath(interactive: Bool) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"]
            ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }
            ?? "/bin/zsh"
        // Markers, because an interactive shell may print a greeting.
        let marker = "__KURONEKO_PATH__"
        let arguments = (interactive ? ["-l", "-i"] : ["-l"]) + ["-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        guard let result = try? execute(URL(fileURLWithPath: shell), arguments: arguments, environment: nil, input: Data(), timeout: 10),
              !result.timedOut else { return nil }
        let text = String(decoding: result.output, as: UTF8.self)
        guard let start = text.range(of: marker), let end = text.range(of: marker, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    // MARK: - Processes

    struct Execution {
        var status: Int32
        var output: Data
        var errors: Data
        var timedOut: Bool
    }

    /// Input and output go through files instead of pipes: nothing blocks on
    /// a full pipe, and a helper left behind by a killed process can't hold
    /// the output open.
    static func execute(_ executable: URL, arguments: [String], environment: [String: String]?, input: Data, timeout: TimeInterval) throws -> Execution {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kuroneko-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inputURL = folder.appendingPathComponent("input")
        let outputURL = folder.appendingPathComponent("output")
        let errorsURL = folder.appendingPathComponent("errors")
        try input.write(to: inputURL)
        try Data().write(to: outputURL)
        try Data().write(to: errorsURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = try FileHandle(forReadingFrom: inputURL)
        process.standardOutput = try FileHandle(forWritingTo: outputURL)
        process.standardError = try FileHandle(forWritingTo: errorsURL)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 3)
            }
        }
        return Execution(
            status: process.isRunning ? -1 : process.terminationStatus,
            output: (try? Data(contentsOf: outputURL)) ?? Data(),
            errors: (try? Data(contentsOf: errorsURL)) ?? Data(),
            timedOut: timedOut
        )
    }
}

/// A model an agent offers, for the picker in Ajustes.
public struct AgentModel: Equatable, Identifiable, Sendable {
    /// What goes in `--model`.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

extension AgentCLI {
    /// Claude's aliases always point at the newest of each family.
    public static let claudeModels = [
        AgentModel(id: "opus", name: "Opus"),
        AgentModel(id: "sonnet", name: "Sonnet"),
        AgentModel(id: "haiku", name: "Haiku"),
    ]

    /// The models the agent offers to the user's account. For Codex, the
    /// list it keeps itself (`~/.codex/models_cache.json`), else the one it
    /// prints (`codex debug models`, a few seconds); empty when neither works.
    public static func models(for command: String) -> [AgentModel] {
        guard command == codex else { return claudeModels }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.codex"
        if let cache = try? Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("models_cache.json")) {
            let models = codexModels(fromJSON: cache)
            if !models.isEmpty { return models }
        }
        guard let (executable, environment) = try? locate(codex),
              let result = try? execute(executable, arguments: ["debug", "models"], environment: environment, input: Data(), timeout: 30),
              !result.timedOut, result.status == 0 else { return [] }
        return codexModels(fromJSON: result.output)
    }

    /// `{"models": [{"slug", "display_name", "visibility", "priority"}]}`:
    /// the ones Codex shows in its own picker, in its order.
    static func codexModels(fromJSON data: Data) -> [AgentModel] {
        struct Catalog: Decodable {
            struct Model: Decodable {
                var slug: String
                var display_name: String?
                var visibility: String?
                var priority: Int?
            }
            var models: [Model]
        }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        return catalog.models
            .filter { ($0.visibility ?? "list") == "list" }
            .enumerated()
            .sorted { ($0.element.priority ?? .max, $0.offset) < ($1.element.priority ?? .max, $1.offset) }
            .map { AgentModel(id: $0.element.slug, name: $0.element.display_name ?? $0.element.slug) }
    }
}

public enum AgentError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case couldNotRun(String, String)
    case failed(String, status: Int32, detail: String)
    case timedOut(String, Int)
    case emptyOutput(String)

    public var description: String {
        switch self {
        case .notFound(let command):
            let product = command == AgentCLI.codex ? "o Codex CLI" : "o Claude Code"
            return "\(command) não encontrado — instale \(product) ou aponte KURONEKO_\(command.uppercased()) para ele"
        case .couldNotRun(let command, let reason):
            return "não foi possível rodar o \(command): \(reason)"
        case .failed(let command, let status, let detail):
            return "o \(command) falhou (\(status))\(detail.isEmpty ? "" : ": \(detail)")"
        case .timedOut(let command, let seconds):
            return "o \(command) não respondeu em \(seconds) s"
        case .emptyOutput(let command):
            return "o \(command) não devolveu nada"
        }
    }
}

/// Which agent writes the summaries and with which model, as set in the
/// app's Ajustes; the `kuroneko` command reads the same choice. Each agent
/// keeps its own model, so switching back finds it.
public enum SummarySettings {
    static let commandKey = "summaryCommand"

    static func modelKey(_ command: String) -> String {
        "summaryModel.\(command)"
    }

    /// The app's defaults, also from the `kuroneko` command.
    public static var defaults: UserDefaults {
        let app = "com.gandarfh.kuroneko"
        // The app's own domain can't be opened as a suite from inside it.
        guard Bundle.main.bundleIdentifier != app else { return .standard }
        return UserDefaults(suiteName: app) ?? .standard
    }

    public static func agent(in defaults: UserDefaults = defaults) -> AgentCLI {
        let command = defaults.string(forKey: commandKey).flatMap { AgentCLI.commands.contains($0) ? $0 : nil } ?? AgentCLI.claude
        return AgentCLI(command: command, model: model(for: command, in: defaults))
    }

    public static func model(for command: String, in defaults: UserDefaults = defaults) -> String {
        defaults.string(forKey: modelKey(command)) ?? ""
    }

    public static func save(_ agent: AgentCLI, in defaults: UserDefaults = defaults) {
        defaults.set(agent.command, forKey: commandKey)
        defaults.set(agent.model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelKey(agent.command))
    }
}
