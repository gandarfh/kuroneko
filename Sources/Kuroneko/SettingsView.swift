import KuronekoCore
import SwiftUI

struct SettingsView: View {
    let state: AppState

    @State private var typingOtherModel = false
    @State private var testing = false
    /// Of the last "Testar": nil while there is none, the error otherwise.
    @State private var testResult: Result<String, AgentTestFailure>?

    var body: some View {
        Form {
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
                        .foregroundStyle(.orange)
                }
                Text("Usa o \(product) da sua conta. O texto da reunião sai do Mac só nesse momento; o áudio nunca sai.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        .formStyle(.grouped)
        .onAppear { state.loadSummaryModels() }
        .frame(width: 440)
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
                        .foregroundStyle(.green)
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
