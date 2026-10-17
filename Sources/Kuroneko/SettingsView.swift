import KuronekoCore
import SwiftUI

/// The Ajustes of the window, in pages: Geral (recording, privacy), Modelos
/// (who writes the summaries, what transcribes) and Atalhos (the quick note).
struct SettingsView: View {
    let state: AppState

    enum Page: String, CaseIterable {
        case general, models, tasks, shortcuts

        var title: String {
            switch self {
            case .general: "Geral"
            case .models: "Modelos"
            case .tasks: "Pendências"
            case .shortcuts: "Atalhos"
            }
        }
    }

    @AppStorage("settingsPage") private var page = Page.general
    @State private var typingOtherModel = false
    @State private var testing = false
    /// Of the last "Testar": nil while there is none, the error otherwise.
    @State private var testResult: Result<String, AgentTestFailure>?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch page {
                case .general: general
                case .models: models
                case .tasks: TaskStatusSettings(state: state)
                case .shortcuts: shortcuts
                }
            }
            .formStyle(.grouped)
            quitBar
        }
        // The pages take the title's place in the window's bar, as the
        // sections' search does elsewhere: the bar keeps its height.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Ajustes", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .toolbar(removing: .title)
        .toggleStyle(.accentSwitch)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .tint(Theme.accent)
        .onAppear { state.loadSummaryModels() }
    }

    /// At the bottom of every page, apart from the settings.
    private var quitBar: some View {
        HStack(spacing: 12) {
            Text("Fecha o Kuroneko de vez: ele para de gravar as calls.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Sair do Kuroneko", role: .destructive) { NSApp.terminate(nil) }
                .buttonStyle(.danger)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { ListPalette.rule.frame(height: 1) }
    }

    @ViewBuilder private var general: some View {
        Section("Gravação") {
            Toggle("Gravar chamadas do Meet automaticamente", isOn: Binding(
                get: { state.autoRecord },
                set: { state.setAutoRecord($0) }
            ))
            Toggle("Abrir ao iniciar sessão", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            Toggle("Mostrar o gatinho digitando durante a gravação", isOn: Binding(
                get: { state.showTypingCat },
                set: { state.setShowTypingCat($0) }
            ))
        }
        Section("Privacidade") {
            Toggle("Esconder o Kuroneko ao compartilhar ou gravar a tela", isOn: Binding(
                get: { state.hiddenFromScreenCapture },
                set: { state.setHiddenFromScreenCapture($0) }
            ))
            Text("Menu, notas, cartões e janelas ficam visíveis só para você, inclusive apresentando a tela inteira no Meet. Desligue para tirar prints do app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var models: some View {
        Section("Resumo") {
            Toggle("Resumir sozinho depois da transcrição", isOn: Binding(
                get: { state.autoSummarize },
                set: { state.setAutoSummarize($0) }
            ))
            Picker("Escrever com", selection: Binding(
                get: { state.summaryAgent.command },
                set: {
                    state.setSummaryCommand($0)
                    typingOtherModel = false
                    testResult = nil
                }
            )) {
                Text("Claude Code").tag(AgentCLI.claude)
                Text("Codex").tag(AgentCLI.codex)
            }
            modelPicker
            agentTest
            if state.summaryAgent.model.isEmpty {
                Text("Sem modelo, o \(state.summaryAgent.title) usa o padrão dele, que pode mudar sem você saber.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            Text("Usa o \(product) da sua conta. O texto da reunião sai do Mac só nesse momento; o áudio nunca sai.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Transcrição") {
            LabeledContent("Fala para texto", value: "Whisper large-v3-turbo")
            LabeledContent("Quem falou", value: "pyannote community-1")
            Text("Rodam no Mac, sem internet; o áudio não sai daqui.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Vocabulário") {
            TextField("Termos separados por vírgula", text: Binding(
                get: { state.extraVocabulary },
                set: { state.setExtraVocabulary($0) }
            ), axis: .vertical)
            .lineLimit(3...6)
            Text("Nomes de projetos, clientes e jargões do time, para a transcrição escrever do jeito certo. Os nomes das pessoas que você identificar entram sozinhos.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var shortcuts: some View {
        Section("Nota rápida") {
            LabeledContent("Abrir:") {
                Text("⌘⌘ (dois toques no Command)")
            }
            commandDoubleTapStatus
            // No KeyboardShortcuts.Recorder: it reads its strings through
            // Bundle.module, which crashes an installed app.
            LabeledContent("Outro atalho:") {
                Text("⌃⌥⌘N")
            }
            Text("Funciona em qualquer app durante uma gravação. Na nota, ⌘1, ⌘2 e ⌘3 anexam um print da janela, da tela inteira ou de uma área. Use #tags, como #acao ou #duvida. Digite @Nome enquanto alguém fala para o Kuroneko saber quem é aquela voz.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Picker value of "Outro…", which opens a field to type the name.
    private static let otherModel = "\u{0}other"

    @ViewBuilder
    private var modelPicker: some View {
        let agent = state.summaryAgent
        let models = state.summaryModels
        if state.loadingSummaryModels, models.isEmpty {
            LabeledContent("Modelo") {
                ProgressView().controlSize(.small)
            }
        } else {
            Picker("Modelo", selection: Binding(
                get: { typingOtherModel ? Self.otherModel : agent.model },
                set: { value in
                    typingOtherModel = value == Self.otherModel
                    if !typingOtherModel { state.setSummaryModel(value) }
                    testResult = nil
                }
            )) {
                ForEach(models) { model in
                    Text(model.name).tag(model.id)
                }
                // Typed before and not in the list.
                if !agent.model.isEmpty, !models.contains(where: { $0.id == agent.model }) {
                    Text(agent.model).tag(agent.model)
                }
                Divider()
                Text("Outro…").tag(Self.otherModel)
                Text("Padrão do \(agent.title)").tag("")
            }
            if typingOtherModel {
                TextField("Nome do modelo", text: Binding(
                    get: { agent.model },
                    set: {
                        state.setSummaryModel($0)
                        testResult = nil
                    }
                ), prompt: Text(agent.command == AgentCLI.codex ? "o mesmo nome do codex --model" : "o nome completo, como claude-opus-5-5"))
            }
            if models.isEmpty, agent.command == AgentCLI.codex {
                Text("Não deu para ler os modelos do Codex. Confira se ele está instalado e com login, ou escolha Outro… e digite o nome.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var product: String {
        state.summaryAgent.command == AgentCLI.codex ? "Codex CLI" : "Claude Code"
    }

    /// "Testar" runs the agent once with the model typed.
    private var agentTest: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button("Testar") {
                testing = true
                testResult = nil
                Task {
                    let failure = await state.testSummaryAgent()
                    testResult = failure.map { .failure(AgentTestFailure(reason: $0)) } ?? .success(state.summaryAgent.title)
                    testing = false
                }
            }
            .disabled(testing)
            if testing {
                ProgressView().controlSize(.small)
                Text("Perguntando ao \(state.summaryAgent.title)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                switch testResult {
                case .success(let title):
                    Label("O \(title) respondeu.", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.ready)
                case .failure(let failure):
                    Text(failure.reason)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .textSelection(.enabled)
                case nil:
                    EmptyView()
                }
            }
        }
    }

    /// ⌘⌘ needs Input Monitoring to see the keys typed in other apps.
    @ViewBuilder private var commandDoubleTapStatus: some View {
        let hotkey = CommandDoubleTap.shared
        if hotkey.isListening {
            Label {
                Text("Monitoramento de Entrada permitido")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            HStack {
                Label {
                    Text("O ⌘⌘ precisa da permissão de Monitoramento de Entrada.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Spacer()
                Button("Permitir…") {
                    hotkey.requestPermission()
                }
            }
        }
    }
}

/// Why "Testar" failed, as the agent said.
struct AgentTestFailure: Error {
    var reason: String
}

/// The statuses a pendência can be in, the same for every one: name, color
/// and order. What each one means is the user's; the app gives it none.
private struct TaskStatusSettings: View {
    let state: AppState

    @State private var statuses: [TaskStatus] = []
    @State private var counts: [Int64: Int] = [:]
    /// Names being typed, by status.
    @State private var names: [Int64: String] = [:]
    @State private var newName = ""
    @State private var newColor = "blue"
    /// The status being deleted, and where its pendências go.
    @State private var deleting: (id: Int64, moveTo: Int64)?
    @State private var problem: String?

    var body: some View {
        Section {
            ForEach(Array(statuses.enumerated()), id: \.element.id) { index, status in
                if let id = status.id {
                    row(status, id: id, index: index)
                    if deleting?.id == id {
                        deleteRow(status, id: id)
                    }
                }
            }
            HStack(spacing: 8) {
                colorMenu(selection: $newColor)
                TextField("Novo status", text: $newName, prompt: Text("Novo status, como Esperando"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(create)
                Button("Adicionar", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Theme.recording)
            }
        } header: {
            Text("Status das pendências")
        } footer: {
            Text("Valem para todas as pendências. A nova entra no primeiro status; para esconder um status da lista, desmarque ele em Filtrar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: state.dataVersion) { reload() }
    }

    private func row(_ status: TaskStatus, id: Int64, index: Int) -> some View {
        HStack(spacing: 8) {
            colorMenu(selection: Binding(
                get: { status.color },
                set: { color in problem = state.updateTaskStatus(id, name: status.name, color: color) }
            ), status: status)
            TextField("Nome do status", text: Binding(get: { names[id] ?? status.name }, set: { names[id] = $0 }), prompt: Text("Nome"))
                .textFieldStyle(.plain)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .onSubmit { rename(status, id: id) }
                .help("Renomear: escreva e aperte ↩")
            Text(CountText.of(counts[id] ?? 0, "pendência", "pendências"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                Button {
                    move(id, from: index, to: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .help("Subir")
                Button {
                    move(id, from: index, to: index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == statuses.count - 1)
                .help("Descer")
                Button {
                    startDeleting(id)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(statuses.count == 1)
                .help(statuses.count == 1 ? "É preciso ter pelo menos um status" : "Apagar o status")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func deleteRow(_ status: TaskStatus, id: Int64) -> some View {
        HStack(spacing: 8) {
            Text(counts[id, default: 0] > 0 ? "Mover as \(CountText.of(counts[id] ?? 0, "pendência", "pendências")) para" : "Apagar “\(status.name)”?")
                .font(.callout)
            if counts[id, default: 0] > 0 {
                Picker("Mover para", selection: Binding(
                    get: { deleting?.moveTo ?? 0 },
                    set: { deleting?.moveTo = $0 }
                )) {
                    ForEach(statuses.filter { $0.id != id }, id: \.id) { other in
                        Text(other.name).tag(other.id ?? 0)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            Button("Cancelar") { deleting = nil }
            Button("Apagar", role: .destructive) {
                guard let deleting else { return }
                problem = state.deleteTaskStatus(deleting.id, moveTo: deleting.moveTo)
                self.deleting = nil
            }
            .buttonStyle(.danger)
        }
    }

    /// The status's icon in its color; a click picks another color.
    private func colorMenu(selection: Binding<String>, status: TaskStatus? = nil) -> some View {
        Menu {
            ForEach(StatusPalette.names, id: \.self) { name in
                Toggle(isOn: Binding(get: { selection.wrappedValue == name }, set: { if $0 { selection.wrappedValue = name } })) {
                    Label { Text(StatusPalette.title(name)) } icon: { Image(nsImage: StatusPalette.dot(name)) }
                }
            }
        } label: {
            Circle()
                .fill(StatusPalette.color(status?.color ?? selection.wrappedValue))
                .frame(width: 12, height: 12)
                .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Cor do status")
    }

    private func reload() {
        statuses = (try? state.db.taskStatuses()) ?? []
        counts = (try? state.db.taskStatusCounts()) ?? [:]
        names = [:]
    }

    /// Moved on screen first, sliding past its neighbor, then saved.
    private func move(_ id: Int64, from index: Int, to target: Int) {
        guard statuses.indices.contains(target) else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            statuses.swapAt(index, target)
        }
        state.moveTaskStatus(id, to: target)
    }

    private func rename(_ status: TaskStatus, id: Int64) {
        guard let name = names[id], name != status.name else { return }
        problem = state.updateTaskStatus(id, name: name)
        if problem != nil { names[id] = nil }
    }

    private func create() {
        problem = state.createTaskStatus(newName, color: newColor)
        if problem == nil { newName = "" }
    }

    private func startDeleting(_ id: Int64) {
        guard let other = statuses.first(where: { $0.id != id })?.id else { return }
        deleting = (id, other)
    }
}
