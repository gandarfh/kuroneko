import AppKit
import KuronekoCore
import os
import SwiftUI

/// The panel under the cat of the menu bar: what is happening now (ready,
/// or the call being recorded with its time and audio), what is new, and
/// the few things done from here.
struct MenuContent: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HiddenStatuses.key) private var hiddenStatuses = ""

    var body: some View {
        let facts = MenuFacts.shared.read(state, hiddenStatuses: hiddenStatuses)
        VStack(alignment: .leading, spacing: 14) {
            header
            if let meeting = state.activeMeeting {
                recordingHero(meeting)
                if state.isRecording {
                    LevelBars(state: state)
                }
            } else {
                readyHero
            }
            news(facts)
            cards(facts)
            footer(facts)
        }
        .padding(18)
        .frame(width: 340)
        .background(Theme.panel)
        .foregroundStyle(.white)
        .tint(Theme.accent)
    }

    // MARK: - Now

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isMeetingActive ? Theme.recording : state.autoRecord ? Theme.ready : Color.secondary)
                .frame(width: 8, height: 8)
            Text(state.isMeetingActive ? (state.isRecording ? "Gravando" : "Reunião") : "Pronto")
                .font(.system(size: 14, weight: .semibold))
            Text(statusDetail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if state.isMeetingActive {
                Button {
                    state.endActiveMeeting()
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 8, weight: .medium))
                }
                .buttonStyle(CircleButtonStyle(tint: Theme.recording, filled: true, size: 22))
                .focusEffectDisabled()
                .help("Encerrar reunião")
                .accessibilityLabel("Encerrar reunião")
            } else {
                Button {
                    state.startMeeting()
                } label: {
                    // Play to start, stop while recording: a power symbol read
                    // as "quit the app" and a red dot as "already recording".
                    Image(systemName: "play.fill").font(.system(size: 8)).offset(x: 0.5)
                }
                .buttonStyle(CircleButtonStyle(size: 22))
                // The panel opens with the keyboard on its first button; the
                // ring around a 22 pt circle covers it.
                .focusEffectDisabled()
                .help("Gravar agora")
                .accessibilityLabel("Gravar agora")
            }
        }
    }

    private var statusDetail: String {
        if state.isMeetingActive { return audioText }
        return state.autoRecord ? "esperando o Meet" : "gravação manual"
    }

    private var readyHero: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nenhuma call")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.5)
                    .lineLimit(1)
                    .fixedSize()
                Group {
                    if state.autoRecord {
                        Text("Grava quando o Meet abrir")
                    } else {
                        // The same symbol as the button above.
                        HStack(spacing: 4) {
                            Text("Toque no")
                            Image(systemName: "play.fill").font(.system(size: 8))
                            Text("para gravar")
                        }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Text("Gravar\nsozinho")
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize()
                Toggle("Gravar sozinho", isOn: Binding(get: { state.autoRecord }, set: { state.setAutoRecord($0) }))
                    .toggleStyle(.accentSwitch)
                    .labelsHidden()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .panelCard(radius: 14)
        }
    }

    private func recordingHero(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TimelineView(.periodic(from: meeting.startedAt, by: 1)) { context in
                Text(Format.clock(ms: Int(context.date.timeIntervalSince(meeting.startedAt) * 1000)))
                    .font(.system(size: 46, weight: .semibold).monospacedDigit())
                    .tracking(-1)
            }
            Text(meeting.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Text(state.startedAutomatically
                ? "Desde \(Format.time(meeting.startedAt)) · encerra sozinha quando você sair da call"
                : "Desde \(Format.time(meeting.startedAt))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "mic + Chrome", "Chrome (sem mic)".
    private var audioText: String {
        guard state.isRecording else { return "sem gravação de áudio" }
        let system = switch state.systemSource {
        case .chrome: "Chrome"
        case .global: "áudio do sistema"
        case .none: "sem áudio do sistema"
        }
        return state.isMicRecording ? "mic + \(system)" : "\(system) (sem mic)"
    }

    // MARK: - News

    @ViewBuilder
    private func news(_ facts: MenuFacts) -> some View {
        let voices = state.hasVoicesToName && !state.isMeetingActive
        if !state.meetingsWithNews.isEmpty || voices || state.lastError != nil || facts.proposals > 0 {
            VStack(spacing: 8) {
                if let error = state.lastError {
                    NewsRow(icon: "exclamationmark.triangle", tint: Theme.recording, label: "Algo deu errado", title: error, detail: nil)
                        .panelCard()
                }
                ForEach(state.meetingsWithNews, id: \.id) { meeting in
                    Button {
                        if let id = meeting.id { showWindow(.meeting(id)) }
                    } label: {
                        NewsRow(icon: "doc.text", label: "Resumo pronto", title: meeting.title, detail: facts.newsSubtitle(meeting), chevron: true)
                    }
                    .buttonStyle(CardButtonStyle())
                }
                if facts.proposals > 0 {
                    Button {
                        showWindow(.tasks)
                    } label: {
                        NewsRow(
                            icon: Glyphs.mergeName,
                            label: "Pendências repetidas",
                            title: facts.proposals == 1 ? "1 para revisar" : "\(facts.proposals) para revisar",
                            detail: "Parecem a mesma coisa falada de novo",
                            chevron: true
                        )
                    }
                    .buttonStyle(CardButtonStyle())
                }
                if voices {
                    Button {
                        dismiss()
                        state.showVoicePromptNow()
                    } label: {
                        NewsRow(icon: "person.wave.2", label: "Vozes sem nome", title: "Dizer quem falou…", detail: nil, chevron: true)
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
        }
    }

    // MARK: - Cards

    private func cards(_ facts: MenuFacts) -> some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Button {
                    dismiss()
                    QuickNoteController.shared.show(state: state)
                } label: {
                    MenuTile(icon: "square.and.pencil", label: "Nota", value: "Nova nota", accessory: .keys("⌘⌘"))
                }
                .buttonStyle(CardButtonStyle())
                // Shows ⌘⌘ (Command twice) as the hint; the note shortcut
                // (⌃⌥⌘N by default) is global, registered in AppDelegate.
                if state.isMeetingActive {
                    MenuTile(
                        icon: "waveform",
                        label: "Áudio",
                        value: state.isRecording ? audioText : "sem gravação",
                        valueTint: state.isRecording && state.isMicRecording && state.systemSource != nil ? .white : Theme.warning
                    )
                    .panelCard()
                } else {
                    Button {
                        showWindow(.tasks)
                    } label: {
                        MenuTile(icon: "checklist", label: "Pendências", value: facts.shownTasks == 0 ? "nenhuma" : CountText.of(facts.shownTasks, "pendência", "pendências"))
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
            GridRow {
                if let id = state.activeMeeting?.id {
                    Button {
                        showWindow(.meeting(id))
                    } label: {
                        MenuTile(icon: "person.2", label: "Vozes", value: facts.voicesInCall == 0 ? "ainda nenhuma" : "\(facts.voicesInCall) na call")
                    }
                    .buttonStyle(CardButtonStyle())
                } else {
                    Button {
                        showWindow(nil)
                    } label: {
                        MenuTile(icon: "rectangle.stack", label: "Reuniões", value: "\(facts.meetingsThisWeek) na semana", accessory: .keys("⌘O"))
                    }
                    .buttonStyle(CardButtonStyle())
                    .keyboardShortcut("o")
                }
                Menu {
                    Picker("Escrever resumos com", selection: Binding(get: { state.summaryAgent.command }, set: { state.setSummaryCommand($0) })) {
                        Text("Claude Code").tag(AgentCLI.claude)
                        Text("Codex").tag(AgentCLI.codex)
                    }
                    .pickerStyle(.inline)
                } label: {
                    MenuTile(icon: "sparkles", label: "Resumo", value: state.summaryAgent.title, accessory: .chevron)
                        .panelCard()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
        }
    }

    // MARK: - Footer

    private func footer(_ facts: MenuFacts) -> some View {
        HStack(spacing: 7) {
            let status = footerStatus(facts)
            Image(systemName: status.icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(status.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                showWindow(.settings)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",")
            .help("Ajustes (⌘,)")
            .accessibilityLabel("Ajustes")
        }
        .padding(.top, 2)
    }

    private func footerStatus(_ facts: MenuFacts) -> (icon: String, text: String) {
        if let current = state.processing.current, current.meetingId != state.activeMeeting?.id {
            return ("waveform", "Transcrevendo “\(current.title)” · \(Int(current.progress * 100))%")
        }
        if !state.summarizing.isEmpty {
            return ("sparkles", "Escrevendo o resumo…")
        }
        if state.isMeetingActive {
            if let until = facts.transcribedUntilMs {
                return ("text.alignleft", "Transcrito até \(Format.clock(ms: until))")
            }
            return ("text.alignleft", "O texto chega uns 2 min depois da fala")
        }
        return ("checkmark", "Tudo transcrito")
    }

    private func showWindow(_ request: Navigator.Request?) {
        dismiss()
        if let request { Navigator.shared.go(to: request) }
        DockPresence.windowOpened()
        openWindow(id: WindowID.meetings)
    }
}

/// A line of "what is new": an icon, a small label, the title and a detail.
private struct NewsRow: View {
    let icon: String
    var tint = Theme.accent
    let label: String
    let title: String
    let detail: String?
    var chevron = false

    var body: some View {
        HStack(spacing: 11) {
            if icon == Glyphs.mergeName {
                IconTile(tint: tint) { Glyphs.mergeImage(size: 15) }
            } else {
                IconTile(systemName: icon, tint: tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One of the four cards: icon, label and value.
private struct MenuTile: View {
    enum Accessory {
        case keys(String)
        case chevron
    }

    let icon: String
    let label: String
    let value: String
    var valueTint: Color = .white
    var accessory: Accessory?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                switch accessory {
                case .keys(let keys):
                    Text(keys).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                case .chevron:
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                case nil:
                    EmptyView()
                }
            }
            Spacer(minLength: 10)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// How loud the mic and the call are right now, as bars that move from
/// right to left: a quiet mic bar during a call means the mic is not
/// reaching Kuroneko.
private struct LevelBars: View {
    let state: AppState
    @State private var mic = LevelTrail(count: 30)
    @State private var system = LevelTrail(count: 30)

    var body: some View {
        VStack(spacing: 8) {
            if state.isMicRecording {
                row(icon: "mic.fill", label: "Mic", trail: mic)
            }
            if let source = state.systemSource {
                row(icon: "speaker.wave.2.fill", label: source == .chrome ? "Chrome" : "Sistema", trail: system)
            }
        }
        .task {
            while !Task.isCancelled {
                mic.push(SpeechMeter.loudness(state.audioLevel(.mic)))
                system.push(SpeechMeter.loudness(state.audioLevel(.system)))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func row(icon: String, label: String, trail: LevelTrail) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.06)))
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(Array(trail.values.enumerated()), id: \.offset) { index, value in
                    Capsule()
                        .fill(color(value, recent: index >= trail.values.count - 6))
                        .frame(width: 3.5, height: 3 + value * 15)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
            .padding(.horizontal, 10)
            .background(Capsule().fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.02)], startPoint: .leading, endPoint: .trailing)))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume: \(label)")
    }

    private func color(_ value: Double, recent: Bool) -> Color {
        guard value > 0.02 else { return .white.opacity(0.18) }
        return recent ? Theme.accent : .white.opacity(0.35 + value * 0.45)
    }
}

/// What the panel counts, read from the database only when the data
/// changed: the panel is rebuilt on every change of the app state,
/// transcription progress included.
@MainActor
private final class MenuFacts {
    static let shared = MenuFacts()

    private struct Key: Equatable {
        var dataVersion: Int
        var news: [Int64?]
        var activeMeeting: Int64?
        var day: Date
        var hiddenStatuses: String
    }

    /// Every pendência, whatever its status.
    private var tasks: [TaskItem] = []
    /// The ones the user's status filter shows.
    private(set) var shownTasks = 0
    /// Pendências that look repeated, waiting for the user.
    private(set) var proposals = 0
    private(set) var meetingsThisWeek = 0
    private(set) var voicesInCall = 0
    private(set) var transcribedUntilMs: Int?
    private var key: Key?
    private var decisions: [Int64: Int] = [:]
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "MenuContent")

    func read(_ state: AppState, hiddenStatuses: String) -> MenuFacts {
        let key = Key(
            dataVersion: state.dataVersion,
            news: state.meetingsWithNews.map(\.id),
            activeMeeting: state.activeMeeting?.id,
            day: Calendar.current.startOfDay(for: Date()),
            hiddenStatuses: hiddenStatuses
        )
        guard key != self.key else { return self }
        self.key = key
        decisions = [:]
        do {
            tasks = try state.db.tasks()
            shownTasks = TaskListLayout.filter(tasks, hiding: HiddenStatuses.decode(hiddenStatuses)).count
            proposals = try state.db.mergeProposals().count
            meetingsThisWeek = MenuNumbers.meetingsThisWeek(try state.db.meetings(), silent: try state.db.silentMeetingIds())
            for meeting in state.meetingsWithNews {
                guard let id = meeting.id else { continue }
                decisions[id] = try state.db.summaryItems(meetingId: id).count(where: { $0.kind == "decision" })
            }
            if let id = key.activeMeeting {
                voicesInCall = try state.db.speakers(meetingId: id).count
                transcribedUntilMs = try state.db.transcribedUntilMs(meetingId: id)
            } else {
                voicesInCall = 0
                transcribedUntilMs = nil
            }
        } catch {
            logger.error("Falha ao contar o que o menu mostra: \(String(describing: error))")
        }
        return self
    }

    /// "3 pendências · 2 decisões · 1h de reunião".
    func newsSubtitle(_ meeting: Meeting) -> String {
        guard let id = meeting.id else { return "" }
        return NewsText.summaryReady(
            tasks: tasks.count(where: { $0.meetingId == id }),
            decisions: decisions[id] ?? 0,
            durationMs: meeting.durationMs
        )
    }
}
