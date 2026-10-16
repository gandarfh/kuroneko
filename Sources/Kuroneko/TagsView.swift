import KuronekoCore
import SwiftUI

/// The tags the user created, under their key: create, rename, describe, set
/// the conditions that put a tag on meetings by itself, delete. The count
/// opens the meetings with the tag.
struct TagsView: View {
    let state: AppState
    let tags: [Tag]
    let counts: [Int64: Int]
    /// Known people, as a hint for conditions about who was there.
    let people: [String]
    /// The search of the toolbar.
    let query: String
    let showMeetings: (String) -> Void

    /// The tag being edited; a new one has no id.
    @State private var editing: Tag?
    @State private var deleting: Tag?

    var body: some View {
        let found = tags.filter(matches)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Filtre e agrupe as reuniões por tags. As condições põem uma tag sozinha; você pode tirar ou pôr depois.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Nova tag") { editing = Tag(name: "", createdAt: Date()) }
                        .disabled(editing != nil && editing?.id == nil)
                }
                .padding(.horizontal, 4)
                if let editing, editing.id == nil {
                    editor(for: editing).card(highlighted: true)
                }
                ForEach(sections(found), id: \.title) { section in
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(section.tags.enumerated()), id: \.element.id) { index, tag in
                                if index > 0 { ListPalette.rule.frame(height: 1) }
                                if editing?.id != nil, editing?.id == tag.id {
                                    editor(for: tag)
                                } else {
                                    row(tag)
                                }
                            }
                        }
                        .card()
                    } header: {
                        Text(section.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                            .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(ListPalette.background)
        .overlay {
            if tags.isEmpty, editing == nil {
                ContentUnavailableView {
                    Label("Nenhuma tag ainda", systemImage: "tag")
                } description: {
                    Text("Crie tags como project=pix ou 1x1=tam para filtrar e agrupar as reuniões.")
                } actions: {
                    Button("Nova tag") { editing = Tag(name: "", createdAt: Date()) }
                }
            } else if !query.isEmpty, found.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .confirmationDialog("Apagar a tag “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("Apagar a tag", role: .destructive) {
                if let id = deleting?.id { state.deleteTag(id) }
                deleting = nil
            }
            Button("Cancelar", role: .cancel) { deleting = nil }
        } message: {
            Text("Ela sai de todas as reuniões. As reuniões continuam.")
        }
    }

    private func row(_ tag: Tag) -> some View {
        let count = counts[tag.id ?? 0] ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tag.name)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                if let description = tag.description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let rules = TagText.rules(tag.rules) {
                    Label("Sozinha quando: \(rules)", systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(CountText.of(count, "reunião", "reuniões")) { showMeetings(tag.name) }
                .buttonStyle(.link)
                .font(.callout)
                .disabled(count == 0)
                .help("Ver as reuniões com esta tag")
            Menu {
                Button("Editar") { editing = tag }
                Button("Ver as reuniões") { showMeetings(tag.name) }
                    .disabled(count == 0)
                Divider()
                Button("Apagar a tag…", role: .destructive) { deleting = tag }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Ações da tag")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = tag }
    }

    private func editor(for tag: Tag) -> some View {
        TagEditor(tag: tag, people: people) { saved in
            let error = state.saveTag(saved)
            if error == nil { editing = nil }
            return error
        } cancel: {
            editing = nil
        }
        .id(tag.id ?? -1)
    }

    private func matches(_ tag: Tag) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return tag.name.localizedCaseInsensitiveContains(query)
            || (tag.description?.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// The tags under their key; plain ones last.
    private func sections(_ tags: [Tag]) -> [(title: String, tags: [Tag])] {
        let byKey = Dictionary(grouping: tags, by: \.key)
        var sections = byKey.keys.compactMap { $0 }.sorted().map { (title: $0, tags: byKey[$0] ?? []) }
        if let plain = byKey[nil] { sections.append((title: "Sem chave", tags: plain)) }
        return sections
    }
}

/// The form of a tag: name, description and the conditions that put it on
/// meetings by itself.
private struct TagEditor: View {
    let tag: Tag
    let people: [String]
    /// Nil when saved, or why not.
    let save: (Tag) -> String?
    let cancel: () -> Void

    @State private var name: String
    @State private var description: String
    @State private var conditions: [ConditionDraft]
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(tag: Tag, people: [String], save: @escaping (Tag) -> String?, cancel: @escaping () -> Void) {
        self.tag = tag
        self.people = people
        self.save = save
        self.cancel = cancel
        _name = State(initialValue: tag.name)
        _description = State(initialValue: tag.description ?? "")
        _conditions = State(initialValue: tag.rules.compactMap(ConditionDraft.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Nome, como project=pix ou 1x1=tam", text: $name)
                .textFieldStyle(.roundedBorder)
                .fontWeight(.semibold)
                .focused($nameFocused)
                .onAppear { if tag.id == nil { nameFocused = true } }
            TextField("Sobre o que é (opcional)", text: $description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            Text("Pôr sozinha quando")
                .font(.callout.weight(.semibold))
                .padding(.top, 4)
            ForEach($conditions) { $condition in
                HStack(spacing: 6) {
                    Picker("Condição", selection: $condition.kind) {
                        ForEach(ConditionDraft.Kind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField(condition.kind.placeholder, text: $condition.text)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        conditions.removeAll { $0.id == condition.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Tirar a condição")
                    .accessibilityLabel("Tirar a condição")
                }
            }
            Button("+ Condição") { conditions.append(ConditionDraft()) }
                .buttonStyle(.link)
                .font(.callout)
            Text(conditions.isEmpty
                ? "Sem condições, a tag só entra quando você põe."
                : "Todas as condições precisam valer. Separe os valores com vírgula. Tags que você tirou de uma reunião não voltam.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if conditions.contains(where: { $0.kind != .titleContains }), !people.isEmpty {
                Text("Pessoas conhecidas: \(PeopleText.line(people, limit: 8))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancelar", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Salvar", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(TagName.normalize(name) == nil)
            }
        }
        .padding(14)
        .onChange(of: name) { error = nil }
    }

    private func submit() {
        var saved = tag
        saved.name = name
        saved.description = description
        // Conditions this version doesn't show are kept as they were.
        let unknown = tag.rules.filter { ConditionDraft($0) == nil }
        saved.rules = conditions.compactMap(\.condition) + unknown
        error = save(saved)
    }
}

/// A condition as the form edits it: what it looks at and the values typed
/// with commas.
private struct ConditionDraft: Identifiable {
    enum Kind: CaseIterable {
        case titleContains
        case peopleInclude
        case peopleAre

        var title: String {
            switch self {
            case .titleContains: "Título contém"
            case .peopleInclude: "Participantes incluem"
            case .peopleAre: "Só você e"
            }
        }

        var placeholder: String {
            switch self {
            case .titleContains: "daily, standup"
            case .peopleInclude: "Tam, Bia"
            case .peopleAre: "Tam"
            }
        }
    }

    let id = UUID()
    var kind: Kind = .titleContains
    var text = ""

    init() {}

    init?(_ condition: TagCondition) {
        switch (condition.field, condition.op) {
        case ("title", "contains"): kind = .titleContains
        case ("people", "includes"): kind = .peopleInclude
        case ("people", "is"): kind = .peopleAre
        default: return nil
        }
        text = condition.values.joined(separator: ", ")
    }

    /// Nil while nothing is typed.
    var condition: TagCondition? {
        let values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        switch kind {
        case .titleContains: return .titleContains(values)
        case .peopleInclude: return .peopleInclude(values)
        case .peopleAre: return .peopleAre(values)
        }
    }
}
