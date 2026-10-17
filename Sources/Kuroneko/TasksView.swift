import KuronekoCore
import SwiftUI

/// Every pendência, in the statuses the user didn't hide: first the ones the
/// app thinks repeat another (to join or not), then all of them grouped as
/// asked, as a list or a board. A pendência spoken of in several meetings
/// shows them all.
struct TasksView: View {
    let state: AppState
    let tasks: [TaskItem]
    let proposals: [TaskMergeProposal]
    /// The statuses a pendência can be in, in the user's order.
    let statuses: [TaskStatus]
    /// Every tag there is, for the tag menus.
    let catalog: [Tag]
    /// Known people, as owners to pick.
    let people: [String]
    /// The search of the toolbar.
    let query: String
    let go: (MeetingsView.Route) -> Void

    // Every filter stays as the user left it, also after reopening the app.
    /// Todas ("all"), Minhas ("mine") or Dos outros ("others").
    @AppStorage("tasksScope") private var scopeName = "all"
    /// Only these people's; none is everyone's (`StoredNames`).
    @AppStorage("tasksOwners") private var storedOwners = ""
    /// Only with every one of these tags (`StoredNames`).
    @AppStorage("tasksTags") private var storedTags = ""
    @State private var expanded: Set<Int64> = []
    /// A pendência that changes column or section flies there.
    @Namespace private var cards
    /// The pendência the user just dropped, which settles where it was
    /// dropped instead of flying from where it was.
    @State private var landing: TaskLanding?
    @State private var edit: TaskEdit?
    /// Statuses unchecked in Filtrar (`HiddenStatuses`).
    @AppStorage(HiddenStatuses.key) private var hiddenStatuses = ""
    /// "status", "meeting", "owner" or a tag key.
    @AppStorage("tasksGrouping") private var groupingName = "meeting"
    /// "list" or "board".
    @AppStorage("tasksLayout") private var layout = "list"

    var body: some View {
        let shown = TaskListLayout.filter(tasks, hiding: hidden)
        let found = shown.filter { $0.matches(query) }
        let owners = TaskFilter.owners(in: shown)
        // A person or a tag no pendência has anymore is no filter anymore.
        let people = ownerFilter.wrappedValue.filter { owners.contains($0) }
        let tags = tagFilter.wrappedValue.intersection(shown.flatMap(\.tags))
        let visible = narrowed(found.filter(scope.matches), people: people, tags: tags)
        let sections = TaskListLayout.sections(visible, grouping: grouping, statuses: statuses)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !tasks.isEmpty {
                    controls(found: found, owners: owners, people: people, tags: tags)
                }
                if query.isEmpty, !proposals.isEmpty {
                    SectionLabel(text: "Para revisar · \(proposals.count)", tint: Theme.accent)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                    ForEach(proposals) { proposal in
                        MergeProposalCard(proposal: proposal, state: state)
                    }
                }
                if layout == "board" {
                    board(visible: visible)
                } else {
                    let repeated = CardKey.repeated(in: sections)
                    ForEach(sections) { section in
                        sectionCard(section, repeated: repeated)
                    }
                    if sections.isEmpty, !tasks.isEmpty {
                        Text(query.isEmpty ? "Nenhuma pendência com esses filtros." : "Nenhuma pendência com “\(query)” nesses filtros.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .animation(.spring(duration: 0.4, bounce: 0.15), value: tasks.map(TaskPlace.init))
        }
        .background(ListPalette.background)
        .overlay {
            if tasks.isEmpty, proposals.isEmpty {
                ContentUnavailableView(
                    "Nenhuma pendência",
                    systemImage: "checklist",
                    description: Text("As pendências dos resumos e as notas com #acao aparecem aqui.")
                )
            }
        }
    }

    private var grouping: TaskGrouping {
        switch groupingName {
        case "status": .status
        case "meeting": .meeting
        case "owner": .owner
        case let key where TaskListLayout.tagKeys(in: tasks).contains(key): .tagKey(key)
        // A key no pendência has anymore groups by meeting.
        default: .meeting
        }
    }

    private var scope: TaskFilter {
        switch scopeName {
        case "mine": .mine
        case "others": .others
        default: .all
        }
    }

    private var ownerFilter: Binding<Set<String>> { StoredNames.binding($storedOwners) }

    private var tagFilter: Binding<Set<String>> { StoredNames.binding($storedTags) }

    /// Hidden statuses that still exist.
    private var hidden: Set<Int64> {
        HiddenStatuses.decode(hiddenStatuses).intersection(statuses.compactMap(\.id))
    }

    // MARK: - Controls

    private func narrowed(_ tasks: [TaskItem], people: Set<String>, tags: Set<String>) -> [TaskItem] {
        TaskListLayout.filter(TaskListLayout.filter(tasks, owners: people), tags: tags)
    }

    /// Whose on the left, filter and grouping on the right; the filters on,
    /// below, each one easy to take off.
    private func controls(found: [TaskItem], owners: [String], people: Set<String>, tags: Set<String>) -> some View {
        let tagNames = Set(tasks.flatMap(\.tags)).sorted()
        let hidden = hidden
        let filters = people.count + tags.count + hidden.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PillSegments(segments: [
                    .init(value: "all", title: "Todas", count: found.count),
                    .init(value: "mine", title: "Minhas", count: found.count(where: TaskFilter.mine.matches)),
                    .init(value: "others", title: "Dos outros", count: found.count(where: TaskFilter.others.matches)),
                ], selection: $scopeName)
                Spacer(minLength: 8)
                PillSegments(segments: [
                    .init(value: "list", title: "", icon: "list.bullet"),
                    .init(value: "board", title: "", icon: "rectangle.split.3x1"),
                ], selection: $layout)
                .help("Lista ou quadro")
                Menu {
                    Section("Status") {
                        ForEach(statuses, id: \.id) { status in
                            Toggle(isOn: Binding(
                                get: { status.id.map { !hidden.contains($0) } ?? true },
                                set: { on in if let id = status.id { setHidden(id, !on) } }
                            )) {
                                Label { Text(status.name) } icon: { Image(nsImage: StatusPalette.dot(status.color)) }
                            }
                        }
                    }
                    if !owners.isEmpty {
                        Section("Pessoas") {
                            ForEach(owners, id: \.self) { name in
                                Toggle(name, isOn: ownerFilter.contains(name))
                            }
                        }
                    }
                    if !tagNames.isEmpty {
                        Section("Tags") {
                            ForEach(tagNames, id: \.self) { name in
                                Toggle(name, isOn: tagFilter.contains(name))
                            }
                        }
                    }
                    if filters > 0 {
                        Divider()
                        Button("Limpar filtros") { clearFilters() }
                    }
                } label: {
                    ToolbarMenuLabel(title: "Filtrar", icon: "line.3.horizontal.decrease", badge: filters)
                }
                .help("Esconder status, ou ver só as pendências de algumas pessoas ou tags")
                Menu {
                    Section("Agrupar por") {
                        MenuChoice(title: "Status", icon: "circle.lefthalf.filled", value: "status", selection: $groupingName)
                        MenuChoice(title: "Reunião", icon: "calendar", value: "meeting", selection: $groupingName)
                        MenuChoice(title: "Pessoa", icon: "person", value: "owner", selection: $groupingName)
                    }
                    Section("Tags") {
                        let keys = TaskListLayout.tagKeys(in: tasks)
                        if keys.isEmpty {
                            Text("Tags chave=valor, como project=pix, aparecem aqui")
                        }
                        ForEach(keys, id: \.self) { key in
                            MenuChoice(title: key, icon: "tag", value: key, selection: $groupingName)
                        }
                    }
                } label: {
                    ToolbarMenuLabel(title: groupingTitle, icon: "square.stack")
                }
                .help("Agrupar as pendências")
            }
            .listToolbarMenus()
            if filters > 0 {
                ActiveFilters(filters: statuses.filter { $0.id.map(hidden.contains) ?? false }.compactMap { status in
                    status.id.map { id in
                        .init(id: "status:\(id)", title: "sem \(status.name)", help: "Mostrar as pendências \(status.name) de novo") { setHidden(id, false) }
                    }
                } + people.sorted().map { name in
                    .init(id: "person:\(name)", title: name, help: "Tirar do filtro") { ownerFilter.wrappedValue.remove(name) }
                } + tags.sorted().map { name in
                    .init(id: "tag:\(name)", title: name, help: "Tirar do filtro") { tagFilter.wrappedValue.remove(name) }
                }, clear: clearFilters)
            }
        }
        .padding(.horizontal, 4)
    }

    private var groupingTitle: String {
        switch grouping {
        case .status: "Status"
        case .meeting: "Reunião"
        case .owner: "Pessoa"
        case .tagKey(let key): key
        }
    }

    private func setHidden(_ id: Int64, _ hide: Bool) {
        var ids = hidden
        if hide { ids.insert(id) } else { ids.remove(id) }
        hiddenStatuses = HiddenStatuses.encode(ids)
    }

    private func clearFilters() {
        storedOwners = ""
        storedTags = ""
        hiddenStatuses = ""
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionCard(_ section: TaskSection, repeated: Set<Int64>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let meetingId = section.meetingId {
                Button {
                    go(.meeting(meetingId, focusMs: nil, play: false))
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(section.title)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let date = section.meetingStartedAt {
                            Text(DayText.relative(date))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        Spacer(minLength: 8)
                        Text("Abrir")
                            .font(.callout)
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Abrir \(section.title)")
            } else {
                HStack(spacing: 7) {
                    if let id = section.statusId {
                        StatusIcon(status: statuses.first { $0.id == id })
                    }
                    Text(section.title)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            ForEach(section.tasks) { task in
                ListPalette.rule.frame(height: 1)
                row(task, showsMeeting: section.meetingId == nil)
                    .modifier(TaskDragDrop(task: task, enabled: edit?.taskId != task.taskId, lineOffset: -2) { ids in
                        drop(ids, on: section, before: task.taskId)
                    })
                    .modifier(CardMotion(task: task, section: section, repeated: repeated, landing: landing, cards: cards))
            }
        }
        .card()
    }

    private func row(_ task: TaskItem, showsMeeting: Bool) -> some View {
        TaskRow(task: task, showsMeeting: showsMeeting, state: state, statuses: statuses, catalog: catalog, people: people, expanded: $expanded, edit: $edit, go: go)
    }

    // MARK: - Board

    /// One column per status not hidden (or person, or tag value); dropping
    /// a card on a column gives it that, and on a card, its place.
    private func board(visible: [TaskItem]) -> some View {
        let hidden = hidden
        let columns = TaskListLayout.sections(
            visible, grouping: grouping,
            statuses: statuses.filter { $0.id.map { !hidden.contains($0) } ?? false },
            keepingEmpty: true
        )
        let repeated = CardKey.repeated(in: columns)
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns) { column in
                    BoardColumn(
                        column: column,
                        statuses: statuses,
                        state: state,
                        go: go,
                        cards: cards,
                        repeated: repeated,
                        landing: landing,
                        drop: { ids, before in drop(ids, on: column, before: before) }
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.automatic)
    }

    /// What a pendência dropped on a column or section gets: its status,
    /// owner or value of the tag key, and its place in the user's order —
    /// just before the card it was dropped on (`before`), or at the end.
    private func drop(_ ids: [String], on column: TaskSection, before: Int64? = nil) -> Bool {
        var changed = false
        for id in ids.compactMap(Int64.init) {
            guard let task = tasks.first(where: { $0.taskId == id }) else { continue }
            let ref = TaskRef.task(id: id)
            switch grouping {
            case .status:
                if let statusId = column.statusId, statusId != task.statusId {
                    state.setTaskStatus(ref, statusId: statusId)
                }
            case .owner:
                if task.owner?.lowercased() != column.value?.lowercased() {
                    state.updateTask(ref, text: task.text, owner: column.value)
                }
            case .tagKey(let key):
                let target = column.value.map { "\(key)=\($0)" }
                let moves = target.map { !task.tags.contains($0) } ?? task.tags.contains { TagName.key(of: $0) == key }
                if moves {
                    for name in task.tags where TagName.key(of: name) == key {
                        if let tagId = catalog.first(where: { $0.name == name })?.id { state.removeTaskTag(tagId, taskId: id) }
                    }
                    if let target { state.addTaskTag(target, taskId: id) }
                }
            case .meeting:
                // Which meeting spoke of it is not the user's to change.
                guard column.meetingId == task.meetingId else { return false }
            }
            land(id, in: column, before: before)
            if let before {
                if before != id { state.moveTask(id, nextTo: before) }
            } else if let last = column.tasks.last(where: { $0.taskId != id }) {
                state.moveTask(id, nextTo: last.taskId, after: true)
            }
            changed = true
        }
        return changed
    }

    /// Remembers where the pendência was dropped, for its card to settle
    /// there; forgotten once it did, without animating anything.
    private func land(_ taskId: Int64, in column: TaskSection, before: Int64?) {
        let token = (landing?.token ?? 0) + 1
        landing = TaskLanding(taskId: taskId, section: column.id, before: before, token: token)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard landing?.token == token else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { landing = nil }
        }
    }
}

/// A pendência that can be dragged elsewhere, and that takes the ones
/// dropped on it just before itself, with a line where they will go.
private struct TaskDragDrop: ViewModifier {
    let task: TaskItem
    /// Off while its text is edited, so the mouse selects text.
    var enabled = true
    /// Where the line goes above it, in the gap to the one before.
    var lineOffset: CGFloat
    let drop: ([String]) -> Bool

    @State private var targeted = false

    func body(content: Content) -> some View {
        Group {
            if enabled {
                content.draggable(String(task.taskId)) {
                    Text(task.text)
                        .padding(8)
                        .frame(width: 220, alignment: .leading)
                        .panelCard(radius: Theme.smallRadius, fill: ListPalette.card)
                }
            } else {
                content
            }
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items)
        } isTargeted: { on in
            withAnimation(.easeOut(duration: 0.12)) { targeted = on }
        }
        .overlay(alignment: .top) {
            if targeted {
                Capsule()
                    .fill(Theme.accent)
                    .frame(height: 3)
                    .offset(y: lineOffset)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Where a pendência is, so the list animates when that changes.
private struct TaskPlace: Hashable {
    var taskId: Int64
    var statusId: Int64
    var owner: String?
    var tags: [String]

    init(_ task: TaskItem) {
        taskId = task.taskId
        statusId = task.statusId
        owner = task.owner
        tags = task.tags
    }
}

/// A pendência dropped by the user and where: in which column or section,
/// and before which card (nil: at the end).
struct TaskLanding: Equatable {
    var taskId: Int64
    var section: String
    var before: Int64?
    var token: Int

    /// The card is already where it was dropped.
    func holds(_ task: TaskItem, in section: TaskSection) -> Bool {
        guard task.taskId == taskId, section.id == self.section,
              let index = section.tasks.firstIndex(where: { $0.taskId == taskId }) else { return false }
        let next = section.tasks.indices.contains(index + 1) ? section.tasks[index + 1].taskId : nil
        return next == before
    }
}

/// How the card of a pendência moves: changed by a menu or the CLI, it
/// flies from where it was; dropped by the user, it leaves its old place at
/// once and settles where it was dropped, under the mouse.
private struct CardMotion: ViewModifier {
    let task: TaskItem
    let section: TaskSection
    let repeated: Set<Int64>
    let landing: TaskLanding?
    let cards: Namespace.ID

    func body(content: Content) -> some View {
        let dropped = landing?.taskId == task.taskId
        // A new card once there: nothing to fly from.
        let landed = landing?.holds(task, in: section) == true
        content
            // Where it was, it is gone the moment it is dropped.
            .opacity(dropped && !landed ? 0 : 1)
            .matchedGeometryEffect(id: CardKey(task.taskId, in: section, repeated: repeated, landed: landed), in: cards)
            .id(landed)
            .transition(dropped
                ? .asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .identity)
                : .opacity)
    }
}

/// The card of a pendência for `matchedGeometryEffect`: the same in every
/// column, so it flies from one to another; one shown in several columns
/// (two values of the tag key) gets one per column instead.
private struct CardKey: Hashable {
    var taskId: Int64
    var section: String?
    var landed: Bool

    init(_ taskId: Int64, in section: TaskSection, repeated: Set<Int64>, landed: Bool = false) {
        self.taskId = taskId
        self.section = repeated.contains(taskId) ? section.id : nil
        self.landed = landed
    }

    static func repeated(in sections: [TaskSection]) -> Set<Int64> {
        var seen: Set<Int64> = [], repeated: Set<Int64> = []
        for task in sections.flatMap(\.tasks) where !seen.insert(task.taskId).inserted {
            repeated.insert(task.taskId)
        }
        return repeated
    }
}

/// The statuses the user unchecked in Filtrar, kept between launches: the
/// counts of the panel and of the sidebar leave them out too.
enum HiddenStatuses {
    static let key = "tasksHiddenStatuses"

    static func decode(_ text: String) -> Set<Int64> {
        Set(text.split(separator: ",").compactMap { Int64($0) })
    }

    static func encode(_ ids: Set<Int64>) -> String {
        ids.sorted().map(String.init).joined(separator: ",")
    }
}

/// A pendência being changed in its row: its text and owner, or a new tag.
struct TaskEdit: Equatable {
    enum Field: Equatable {
        case text
        case tag
    }

    var taskId: Int64
    var field: Field
    var text: String
    var owner: String = ""
}

/// Status, text, who, how many days spoke of it, its tags, and the last
/// moment it was said; opened, every meeting that spoke of it. The same in
/// the Pendências and on a meeting's screen.
struct TaskRow: View {
    let task: TaskItem
    /// Outside a meeting's card: says which meeting it is from.
    let showsMeeting: Bool
    /// The meeting on screen, which is not opened again.
    var current: Int64?
    /// False when the meeting on screen has no audio: the moment is only shown.
    var canPlay = true
    let state: AppState
    let statuses: [TaskStatus]
    let catalog: [Tag]
    let people: [String]
    @Binding var expanded: Set<Int64>
    @Binding var edit: TaskEdit?
    let go: (MeetingsView.Route) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusMenu(task: task, statuses: statuses, state: state)

                VStack(alignment: .leading, spacing: 4) {
                    if editing(.text) {
                        textEditor
                    } else {
                        Text(task.text)
                            .fixedSize(horizontal: false, vertical: true)
                        detailLine
                    }
                    if !task.tags.isEmpty {
                        WrappingLayout {
                            ForEach(task.tags, id: \.self) { Chip(text: $0, tint: .gray) }
                        }
                    }
                    if editing(.tag) {
                        tagEditor
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let startMs = task.startMs, task.meetingId != 0, !canPlay {
                    Text(Format.clock(ms: startMs))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if let startMs = task.startMs, task.meetingId != 0 {
                    Button {
                        go(.meeting(task.meetingId, focusMs: startMs, play: true))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 8))
                            Text(Format.clock(ms: startMs)).monospacedDigit()
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.quietLink)
                    .help(task.meetingId == current ? "Ouvir esse momento" : "Ouvir a última vez que falaram disso")
                    .accessibilityLabel("Ouvir esse momento, \(Format.clock(ms: startMs))")
                }
                actions
            }
            if isExpanded {
                mentions
                    .padding(.leading, 27)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // All of the row drags and takes drops, not only its text.
        .contentShape(Rectangle())
    }

    private var ref: TaskRef { .task(id: task.taskId) }

    private var isExpanded: Bool {
        expanded.contains(task.taskId) && task.mentions.count > 1
    }

    /// "Diego · falada em 3 dias"; the meeting too when outside its card.
    private var detailLine: some View {
        HStack(spacing: 0) {
            Text(detail).foregroundStyle(.secondary)
            if let mentions = task.mentionsText() {
                Text(detail.isEmpty ? "" : " · ").foregroundStyle(.secondary)
                Button {
                    toggleExpanded()
                } label: {
                    HStack(spacing: 3) {
                        Text(mentions)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .buttonStyle(.accentLink)
                .help(isExpanded ? "Esconder as reuniões" : "Ver as reuniões que falaram disso")
            }
        }
        .font(.callout)
        .lineLimit(2)
    }

    private var detail: String {
        var parts: [String] = []
        if showsMeeting, !task.meetingTitle.isEmpty { parts.append(task.meetingTitle) }
        if task.source == "note", task.mentions.count == 1 {
            parts.append("sua nota #\(TaskItem.noteTag)")
        } else if let owner = task.owner {
            parts.append(owner)
        }
        return parts.joined(separator: " · ")
    }

    /// Every meeting that spoke of it, oldest first: when, which, what was
    /// said, the moment to hear, and "Separar" for one joined by mistake.
    private var mentions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(task.mentions) { mention in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(mention.at.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mention.meetingTitle)
                            .font(.callout)
                            .lineLimit(1)
                        Text("“\(mention.text)”" + (mention.owner.map { " — \($0)" } ?? ""))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let startMs = mention.startMs {
                        Button {
                            go(.meeting(mention.meetingId, focusMs: startMs, play: true))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill").font(.system(size: 8))
                                Text(Format.clock(ms: startMs)).monospacedDigit()
                            }
                            .font(.callout)
                        }
                        .buttonStyle(.quietLink)
                        .help("Ouvir esse momento")
                    }
                    Button("Separar") { state.splitTaskMention(mention.id) }
                        .buttonStyle(.quietLink)
                        .font(.callout)
                        .help("Não é a mesma pendência: volta a ser uma pendência sozinha")
                }
            }
        }
        .padding(10)
        .panelCard(radius: Theme.smallRadius)
    }

    // MARK: - Actions

    private var actions: some View {
        MoreMenu(help: "Ações da pendência") {
            Menu("Status") {
                StatusOptions(task: task, statuses: statuses, state: state)
            }
            Divider()
            Button("Editar…") { begin(.text) }
            Menu("Tags") {
                ForEach(catalog, id: \.id) { tag in
                    Toggle(tag.name, isOn: Binding(
                        get: { task.tags.contains(tag.name) },
                        set: { on in
                            if on {
                                state.addTaskTag(tag.name, taskId: task.taskId)
                            } else if let id = tag.id {
                                state.removeTaskTag(id, taskId: task.taskId)
                            }
                        }
                    ))
                }
                if !catalog.isEmpty { Divider() }
                Button("Nova tag…") { begin(.tag) }
            }
            if task.mentions.count > 1 {
                Button(isExpanded ? "Esconder as reuniões" : "Ver as reuniões (\(task.mentions.count))") { toggleExpanded() }
            }
            if task.meetingId != 0, task.meetingId != current {
                Button("Abrir a reunião") { go(.meeting(task.meetingId, focusMs: task.startMs, play: false)) }
            }
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Pendência", text: editBinding(\.text))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            HStack(spacing: 6) {
                TextField("Quem faz", text: editBinding(\.owner))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onSubmit(save)
                if !people.isEmpty {
                    Menu {
                        Button("você") { edit?.owner = "você" }
                        ForEach(people, id: \.self) { name in
                            Button(name) { edit?.owner = name }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Escolher uma pessoa")
                }
                Spacer(minLength: 0)
                Button("Cancelar") { edit = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar", action: save)
                    .buttonStyle(.accent)
            }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var tagEditor: some View {
        HStack(spacing: 6) {
            TextField("Nova tag, como project=pix", text: editBinding(\.text))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(saveTag)
            Button("+ Tag", action: saveTag)
                .disabled(TagName.normalize(edit?.text ?? "") == nil)
            Button("Cancelar") { edit = nil }
                .keyboardShortcut(.cancelAction)
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func editing(_ field: TaskEdit.Field) -> Bool {
        edit?.taskId == task.taskId && edit?.field == field
    }

    private func begin(_ field: TaskEdit.Field) {
        edit = field == .text
            ? TaskEdit(taskId: task.taskId, field: .text, text: task.text, owner: task.owner ?? "")
            : TaskEdit(taskId: task.taskId, field: .tag, text: "")
    }

    private func editBinding(_ keyPath: WritableKeyPath<TaskEdit, String>) -> Binding<String> {
        Binding(get: { edit?[keyPath: keyPath] ?? "" }, set: { edit?[keyPath: keyPath] = $0 })
    }

    private func save() {
        guard let edit, !edit.text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.updateTask(ref, text: edit.text, owner: edit.owner)
        self.edit = nil
    }

    private func saveTag() {
        guard let text = edit?.text, TagName.normalize(text) != nil else { return }
        state.addTaskTag(text, taskId: task.taskId)
        edit = nil
    }

    private func toggleExpanded() {
        if expanded.contains(task.taskId) { expanded.remove(task.taskId) } else { expanded.insert(task.taskId) }
    }

}

/// "Parece a mesma pendência": the new one, the one it repeats, and the
/// user's choice.
private struct MergeProposalCard: View {
    let proposal: TaskMergeProposal
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                IconTile { Glyphs.mergeImage(size: 15) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parece a mesma pendência").fontWeight(.semibold)
                    Text("Juntando, fica uma só, com as reuniões das duas.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            side("Nova", proposal.task)
            side("Já existente", proposal.into)
            HStack(spacing: 8) {
                Button {
                    state.mergeTasks(proposal.task.taskId, into: proposal.into.taskId)
                } label: {
                    Label { Text("Juntar") } icon: { Glyphs.mergeImage(size: 12) }
                }
                .buttonStyle(.accent)
                .help("Juntar as duas numa pendência só")
                Button("Manter separadas") {
                    state.rejectMerge(proposal.task.taskId, into: proposal.into.taskId)
                }
                .buttonStyle(PillButtonStyle())
                .font(.callout)
                .help("Não são a mesma: o Kuroneko não pergunta de novo")
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func side(_ label: String, _ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: label)
            Text(task.text).fixedSize(horizontal: false, vertical: true)
            Text(meta(task))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 45)
    }

    /// "Diego · Daily, ter 14/10" or "Diego · falada em 3 dias".
    private func meta(_ task: TaskItem) -> String {
        var parts: [String] = []
        if let owner = task.owner { parts.append(owner) }
        if let mentions = task.mentionsText() {
            parts.append(mentions)
        } else if let mention = task.mentions.last {
            parts.append("\(mention.meetingTitle), \(mention.at.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits)))")
        }
        return parts.joined(separator: " · ")
    }
}

/// The status of a pendência as a dot in its color, that opens the list of
/// statuses.
struct StatusMenu: View {
    let task: TaskItem
    let statuses: [TaskStatus]
    let state: AppState

    var body: some View {
        Menu {
            StatusOptions(task: task, statuses: statuses, state: state)
        } label: {
            StatusIcon(status: statuses.first { $0.id == task.statusId })
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // On the first line of the text beside it.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
        .help("Status: \(task.status)")
        .accessibilityLabel("Status: \(task.status)")
    }
}

/// The statuses to pick, the current one checked, and where to edit them.
struct StatusOptions: View {
    let task: TaskItem
    let statuses: [TaskStatus]
    let state: AppState

    var body: some View {
        ForEach(statuses, id: \.id) { status in
            Toggle(isOn: Binding(
                get: { task.statusId == status.id },
                set: { on in if on, let id = status.id { state.setTaskStatus(.task(id: task.taskId), statusId: id) } }
            )) {
                Label { Text(status.name) } icon: { Image(nsImage: StatusPalette.dot(status.color)) }
            }
        }
        Divider()
        Button("Editar os status…") {
            UserDefaults.standard.set(SettingsView.Page.tasks.rawValue, forKey: "settingsPage")
            Navigator.shared.go(to: .settings)
        }
    }
}

/// A dot in the status's color, the same shape for every status: what a
/// status means is the user's.
struct StatusIcon: View {
    let status: TaskStatus?

    var body: some View {
        Circle()
            .fill(StatusPalette.color(status?.color ?? "gray"))
            .frame(width: 10, height: 10)
    }
}

/// A column of the board: its title and count, its cards, and somewhere to
/// drop more.
private struct BoardColumn: View {
    let column: TaskSection
    let statuses: [TaskStatus]
    let state: AppState
    let go: (MeetingsView.Route) -> Void
    let cards: Namespace.ID
    /// Pendências in more than one column.
    let repeated: Set<Int64>
    let landing: TaskLanding?
    /// The pendências dropped, and the card they were dropped on (nil: on
    /// the column, so at its end).
    let drop: ([String], Int64?) -> Bool

    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let id = column.statusId {
                    StatusIcon(status: statuses.first { $0.id == id })
                }
                Text(column.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(column.tasks.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            ForEach(column.tasks) { task in
                BoardCard(task: task, statuses: statuses, state: state, go: go)
                    .modifier(TaskDragDrop(task: task, lineOffset: -5.5) { ids in drop(ids, task.taskId) })
                    .modifier(CardMotion(task: task, section: column, repeated: repeated, landing: landing, cards: cards))
            }
            if column.tasks.isEmpty {
                Text("Arraste uma pendência para cá")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .topLeading)
        .background(
            (targeted ? Theme.accentFill : Color.white.opacity(0.03)),
            in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        )
        .dropDestination(for: String.self) { items, _ in
            drop(items, nil)
        } isTargeted: { targeted = $0 }
    }
}

/// A pendência on the board: status, text, who, how many days spoke of it,
/// its first tags and the last moment it was said. Dragged to another
/// column it changes, onto another card it goes before it; clicked, it
/// opens its meeting.
private struct BoardCard: View {
    let task: TaskItem
    let statuses: [TaskStatus]
    let state: AppState
    let go: (MeetingsView.Route) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusMenu(task: task, statuses: statuses, state: state)
                Text(task.text)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let detail = [task.owner, task.mentionsText()].compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 26)
            }
            if !task.tags.isEmpty || task.startMs != nil {
                HStack(spacing: 6) {
                    ForEach(task.tags.prefix(2), id: \.self) { Chip(text: $0, tint: .gray) }
                    Spacer(minLength: 0)
                    if let startMs = task.startMs, task.meetingId != 0 {
                        Button {
                            go(.meeting(task.meetingId, focusMs: startMs, play: true))
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "play.fill").font(.system(size: 7))
                                Text(Format.clock(ms: startMs)).monospacedDigit()
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.quietLink)
                        .help("Ouvir a última vez que falaram disso")
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
        .panelCard(radius: Theme.smallRadius, fill: ListPalette.card)
        .onTapGesture {
            if task.meetingId != 0 { go(.meeting(task.meetingId, focusMs: task.startMs, play: false)) }
        }
        .help(task.meetingTitle.isEmpty ? task.text : "\(task.text) — \(task.meetingTitle)")
    }
}
