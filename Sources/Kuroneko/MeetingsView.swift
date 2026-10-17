import KuronekoCore
import os
import SwiftUI

/// The meetings window: meetings as cards (filtered by people and tags,
/// grouped by day, person or a tag key, in the order chosen), every
/// pendência, or the tags, with the search of each in the toolbar.
struct MeetingsView: View {
    let state: AppState

    enum Tab: Hashable {
        case meetings
        case tasks
        case tags
        case settings

        var title: String {
            switch self {
            case .meetings: "Reuniões"
            case .tasks: "Pendências"
            case .tags: "Tags"
            case .settings: "Ajustes"
            }
        }
    }

    enum Route: Hashable {
        /// `play` starts the audio at `focusMs` as the meeting opens.
        case meeting(Int64, focusMs: Int?, play: Bool)
    }

    @State private var path: [Route] = []
    @State private var tab: Tab = .meetings
    @State private var query = ""
    @State private var data = ListData()
    @State private var groups: [DayGrouping.Group<MeetingListItem>] = []
    @State private var hits: [SearchHit] = []
    @State private var showSilent = false
    @State private var edit: CardEdit?
    // Every filter stays as the user left it, also after reopening the app.
    /// Only meetings with any of these people (`StoredNames`).
    @AppStorage("meetingsPeople") private var storedPeople = ""
    /// Only meetings with every one of these tags (`StoredNames`).
    @AppStorage("meetingsTags") private var storedTags = ""
    /// "day", "person" or a tag key.
    @AppStorage("meetingsGrouping") private var groupingName = "day"
    @AppStorage("meetingsOrder") private var orderName = MeetingOrder.newest.rawValue
    @AppStorage(HiddenStatuses.key) private var hiddenStatuses = ""
    private let navigator = Navigator.shared
    private let logger = Logger(subsystem: "com.gandarfh.kuroneko", category: "MeetingsView")

    var body: some View {
        HStack(spacing: 0) {
            SidebarRail(selection: tab, tasks: TaskListLayout.filter(data.tasks, hiding: HiddenStatuses.decode(hiddenStatuses)).count) { selected in
                // Back to the list of the section, also from inside a meeting.
                path = []
                tab = selected
            }
            ListPalette.rule.frame(width: 1)
            if tab == .settings {
                // In a stack too, so the window's bar keeps its height and
                // the icons on the left don't jump.
                NavigationStack {
                    SettingsView(state: state)
                        .navigationTitle(tab.title)
                }
            } else {
                sections
            }
        }
        .containerBackground(Theme.background, for: .window)
        .toolbarBackground(Theme.background, for: .windowToolbar)
        .tint(Theme.accent)
        .task(id: state.dataVersion) { reload() }
        .onChange(of: query) { search() }
        .onChange(of: tab) { search() }
        .onChange(of: showSilent) { regroup() }
        .onChange(of: storedPeople) {
            regroup()
            search()
        }
        .onChange(of: storedTags) {
            regroup()
            search()
        }
        .onChange(of: groupingName) { regroup() }
        .onChange(of: orderName) { regroup() }
        .onAppear {
            DockPresence.windowOpened()
            follow(navigator.take())
        }
        .onDisappear { DockPresence.windowClosed() }
        .onChange(of: navigator.request) { follow(navigator.take()) }
    }

    private var sections: some View {
        NavigationStack(path: $path) {
            Group {
                switch tab {
                case .meetings, .settings:
                    meetingsList
                case .tasks:
                    TasksView(
                        state: state,
                        tasks: data.tasks,
                        proposals: data.proposals,
                        statuses: data.statuses,
                        catalog: data.tags,
                        people: data.persons.values.sorted(),
                        query: query
                    ) { path.append($0) }
                case .tags:
                    TagsView(state: state, tags: data.tags, counts: data.tagCounts, people: data.persons.values.sorted(), query: query) { name in
                        storedTags = name
                        tab = .meetings
                    }
                }
            }
            .navigationTitle(tab.title)
            .searchable(
                text: $query,
                placement: .toolbar,
                prompt: Text(searchPrompt)
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .meeting(let id, let focusMs, let play):
                    MeetingDetailView(state: state, meetingId: id, focusMs: focusMs, playOnOpen: play) { path.append($0) }
                }
            }
        }
    }

    private var searchPrompt: String {
        switch tab {
        case .meetings, .settings: "Buscar em falas e notas"
        case .tasks: "Buscar pendências"
        case .tags: "Buscar tags"
        }
    }

    // MARK: - Reuniões

    private var meetingsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !data.items.isEmpty {
                    MeetingListControls(
                        items: data.items,
                        people: StoredNames.binding($storedPeople),
                        tags: StoredNames.binding($storedTags),
                        groupingName: $groupingName,
                        orderName: $orderName,
                        showsGrouping: query.isEmpty
                    )
                }
                if query.isEmpty {
                    if let active = state.activeMeeting, let id = active.id {
                        RecordingBanner(meeting: active, transcribedUntilMs: data.transcribedUntilMs) { open(id) }
                    }
                    ForEach(groups, id: \.title) { group in
                        Section {
                            // A meeting can be in more than one section (two
                            // people, two values of the key); each is its own card.
                            ForEach(group.items.map { (key: "\(group.title)/\($0.id)", item: $0) }, id: \.key) { entry in
                                let item = entry.item
                                MeetingCard(
                                    item: item,
                                    meeting: data.meetings[item.id],
                                    showsDay: !group.isSingleDay,
                                    isSilent: data.silent.contains(item.id),
                                    state: state,
                                    catalog: data.tags,
                                    edit: $edit,
                                    open: { open(item.id) },
                                    showTag: { storedTags = $0 }
                                )
                            }
                        } header: {
                            SectionLabel(text: group.title)
                                .padding(.top, 10)
                                .padding(.horizontal, 4)
                        }
                    }
                    if hiddenCount > 0 {
                        silentFooter
                    }
                } else {
                    ForEach(hits) { hit in
                        SearchHitCard(hit: hit, meetingTitle: data.meetings[hit.meetingId]?.title ?? "", who: who(hit)) {
                            path.append(.meeting(hit.meetingId, focusMs: hit.tMs, play: false))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(ListPalette.background)
        .overlay {
            if !query.isEmpty, hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if query.isEmpty, groups.isEmpty, filtered(data.items).count < data.items.count {
                ContentUnavailableView(
                    "Nenhuma reunião com esses filtros",
                    systemImage: "line.3.horizontal.decrease",
                    description: Text("Tire um filtro para ver mais reuniões.")
                )
            } else if query.isEmpty, data.items.isEmpty, state.activeMeeting == nil {
                ContentUnavailableView(
                    "Nenhuma reunião ainda",
                    systemImage: "cat",
                    description: Text("Entre numa chamada do Meet no Chrome e o Kuroneko grava sozinho.")
                )
            }
        }
    }

    private var silentFooter: some View {
        HStack(spacing: 4) {
            if showSilent {
                Button("Esconder as gravações sem fala") { showSilent = false }
                    .buttonStyle(.accentLink)
            } else {
                Text(CountText.of(hiddenCount, "gravação sem fala escondida", "gravações sem fala escondidas"))
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Button("Mostrar") { showSilent = true }
                    .buttonStyle(.accentLink)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    /// Finished meetings with nothing in them, apart from the one recording.
    private var hiddenCount: Int {
        filtered(data.items).count(where: { data.silent.contains($0.id) && $0.id != state.activeMeeting?.id })
    }

    /// Only the meetings of the people and tags in Filtrar; one no meeting
    /// has anymore is no filter anymore.
    private func filtered(_ items: [MeetingListItem]) -> [MeetingListItem] {
        let people = StoredNames.decode(storedPeople).intersection(MeetingListLayout.people(in: data.items))
        let tags = StoredNames.decode(storedTags).intersection(data.items.flatMap(\.tags))
        return MeetingListLayout.filter(MeetingListLayout.filter(items, people: people), tags: tags)
    }

    // MARK: - Navigation

    private func open(_ meetingId: Int64) {
        edit = nil
        path.append(.meeting(meetingId, focusMs: nil, play: false))
    }

    /// A request from outside the window, such as the menu.
    private func follow(_ request: Navigator.Request?) {
        switch request {
        case .meeting(let id):
            tab = .meetings
            path = [.meeting(id, focusMs: nil, play: false)]
        case .tasks:
            path = []
            tab = .tasks
        case .settings:
            path = []
            tab = .settings
        case nil:
            break
        }
    }

    // MARK: - Data

    private func reload() {
        let db = state.db
        do {
            var data = ListData()
            data.items = try db.meetingList()
            data.meetings = Dictionary(uniqueKeysWithValues: try db.meetings().compactMap { meeting in meeting.id.map { ($0, meeting) } })
            data.silent = try db.silentMeetingIds()
            data.persons = Dictionary(uniqueKeysWithValues: try db.persons().compactMap { person in person.id.map { ($0, person.name) } })
            data.tasks = try db.tasks()
            data.tags = try db.tags()
            data.tagCounts = try db.tagCounts()
            data.proposals = try db.mergeProposals()
            data.statuses = try db.taskStatuses()
            if let id = state.activeMeeting?.id {
                data.transcribedUntilMs = try db.transcribedUntilMs(meetingId: id)
            }
            self.data = data
        } catch {
            logger.error("Falha ao carregar as reuniões: \(String(describing: error))")
        }
        regroup()
        search()
    }

    private func regroup() {
        let activeId = state.activeMeeting?.id
        let visible = data.items.filter { item in
            item.id != activeId && (showSilent || !data.silent.contains(item.id))
        }
        let grouping: MeetingGrouping = switch groupingName {
        case "person": .person
        case let key where MeetingListLayout.tagKeys(in: data.items).contains(key): .tagKey(key)
        // A key no meeting has anymore groups by day.
        default: .day
        }
        groups = MeetingListLayout.sections(filtered(visible), grouping: grouping, order: MeetingOrder(rawValue: orderName) ?? .newest)
    }

    private func search() {
        guard !query.isEmpty, tab == .meetings else {
            hits = []
            return
        }
        do {
            let shown = Set(filtered(data.items).map(\.id))
            hits = try state.db.search(query).filter { shown.contains($0.meetingId) }
        } catch {
            logger.error("Falha na busca: \(String(describing: error))")
            hits = []
        }
    }

    private func who(_ hit: SearchHit) -> String {
        switch hit.kind {
        case .note: "Sua nota"
        case .speech(.mic, _, _): "Você"
        case .speech(_, let cluster, let personId):
            personId.flatMap { data.persons[$0] } ?? SpeakerLabel.label(cluster: cluster ?? 0)
        }
    }
}

/// The column of icons on the left of the window: the sections, with the
/// settings at the bottom.
private struct SidebarRail: View {
    let selection: MeetingsView.Tab
    /// Pendências the user's status filter shows.
    let tasks: Int
    let select: (MeetingsView.Tab) -> Void

    var body: some View {
        VStack(spacing: 6) {
            item(.meetings, icon: "rectangle.stack")
            item(.tasks, icon: "checklist", badge: tasks)
            item(.tags, icon: "tag")
            Spacer()
            item(.settings, icon: "gearshape")
        }
        .padding(.vertical, 12)
        .frame(width: 56)
        .frame(maxHeight: .infinity)
        .background(Color(hex: 0x0C0C0D))
    }

    private func item(_ tab: MeetingsView.Tab, icon: String, badge: Int = 0) -> some View {
        let selected = selection == tab
        return Button { select(tab) } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: 38, height: 38)
                .background(selected ? Theme.cardHover : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Theme.accent, in: Capsule())
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        // The fill already shows the section; the system ring is blue.
        .focusEffectDisabled()
        .help(tab.title)
        .accessibilityLabel(badge > 0 ? "\(tab.title), \(badge)" : tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What the window shows, read again whenever stored data changes.
private struct ListData {
    var items: [MeetingListItem] = []
    var meetings: [Int64: Meeting] = [:]
    var silent: Set<Int64> = []
    var persons: [Int64: String] = [:]
    var tasks: [TaskItem] = []
    /// Pendências that look repeated, for the user to join or not.
    var proposals: [TaskMergeProposal] = []
    var statuses: [TaskStatus] = []
    var tags: [Tag] = []
    var tagCounts: [Int64: Int] = [:]
    /// Of the meeting being recorded.
    var transcribedUntilMs: Int?
}

/// The bar above the meetings, as in the Pendências: Filtrar (people and
/// tags), Agrupar and Ordenar on the right, the filters on below.
private struct MeetingListControls: View {
    let items: [MeetingListItem]
    @Binding var people: Set<String>
    @Binding var tags: Set<String>
    @Binding var groupingName: String
    @Binding var orderName: String
    /// Search results come as they are, without groups.
    let showsGrouping: Bool

    var body: some View {
        // A person or a tag no meeting has anymore is no filter anymore.
        let everyone = MeetingListLayout.people(in: items)
        let tagNames = Set(items.flatMap(\.tags)).sorted()
        let people = people.intersection(everyone)
        let tags = tags.intersection(tagNames)
        let filters = people.count + tags.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                Menu {
                    if !everyone.isEmpty {
                        Section("Pessoas") {
                            ForEach(everyone, id: \.self) { name in
                                Toggle(name, isOn: $people.contains(name))
                            }
                        }
                    }
                    if !tagNames.isEmpty {
                        Section("Tags") {
                            ForEach(tagNames, id: \.self) { name in
                                Toggle(name, isOn: $tags.contains(name))
                            }
                        }
                    }
                    if everyone.isEmpty, tagNames.isEmpty {
                        Text("Pessoas com nome e tags aparecem aqui")
                    }
                    if filters > 0 {
                        Divider()
                        Button("Limpar filtros", action: clear)
                    }
                } label: {
                    ToolbarMenuLabel(title: "Filtrar", icon: "line.3.horizontal.decrease", badge: filters)
                }
                .help("Ver só as reuniões de algumas pessoas ou tags")
                if showsGrouping {
                    Menu {
                        Section("Agrupar por") {
                            MenuChoice(title: "Dia", icon: "calendar", value: "day", selection: $groupingName)
                            MenuChoice(title: "Pessoa", icon: "person", value: "person", selection: $groupingName)
                        }
                        Section("Tags") {
                            let keys = MeetingListLayout.tagKeys(in: items)
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
                    .help("Agrupar as reuniões")
                    Menu {
                        Section("Ordenar") {
                            ForEach(MeetingOrder.allCases, id: \.self) { order in
                                MenuChoice(title: Self.title(order), value: order.rawValue, selection: $orderName)
                            }
                        }
                    } label: {
                        ToolbarMenuLabel(title: Self.title(MeetingOrder(rawValue: orderName) ?? .newest), icon: "arrow.up.arrow.down")
                    }
                    .help("Ordenar as reuniões")
                }
            }
            .listToolbarMenus()
            if filters > 0 {
                ActiveFilters(filters: people.sorted().map { name in
                    .init(id: "person:\(name)", title: name, help: "Tirar do filtro") { self.people.remove(name) }
                } + tags.sorted().map { name in
                    .init(id: "tag:\(name)", title: name, help: "Tirar do filtro") { self.tags.remove(name) }
                }, clear: clear)
            }
        }
        .padding(.horizontal, 4)
    }

    private var groupingTitle: String {
        switch groupingName {
        case "person": "Pessoa"
        case let key where MeetingListLayout.tagKeys(in: items).contains(key): key
        default: "Dia"
        }
    }

    private func clear() {
        people = []
        tags = []
    }

    private static func title(_ order: MeetingOrder) -> String {
        switch order {
        case .newest: "Mais recentes"
        case .oldest: "Mais antigas"
        case .longest: "Mais longas"
        }
    }
}

/// The call being recorded, above everything else.
private struct RecordingBanner: View {
    let meeting: Meeting
    let transcribedUntilMs: Int?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                IconTile(systemName: "record.circle.fill", tint: Theme.recording, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Gravando", tint: Theme.recording)
                    Text(meeting.title)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                TimelineView(.periodic(from: meeting.startedAt, by: 1)) { context in
                    Text(Format.clock(ms: Int(context.date.timeIntervalSince(meeting.startedAt) * 1000)))
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(CardButtonStyle())
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.recording.opacity(0.35))
        }
        .accessibilityLabel("Gravando \(meeting.title). Abrir")
    }

    /// "Desde 14:00 · texto até 10:10".
    private var status: String {
        let text = transcribedUntilMs.map { "texto até \(Format.clock(ms: $0))" } ?? "sem texto ainda"
        return "Desde \(DayText.time(meeting.startedAt)) · \(text)"
    }
}

/// Something said or noted that matches the search; opens the meeting there.
private struct SearchHitCard: View {
    let hit: SearchHit
    let meetingTitle: String
    let who: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: hit.kind == .note ? "note.text" : "text.bubble")
                        .foregroundStyle(.secondary)
                    Text(who).font(.callout.bold())
                    Text("·").foregroundStyle(.secondary)
                    Text(Format.clock(ms: hit.tMs))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(hit.text)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meetingTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .card()
        }
        .buttonStyle(.plain)
    }
}

struct StatusBadge: View {
    let meeting: Meeting
    let state: AppState

    var body: some View {
        switch meeting.status {
        case .recording:
            Label("Gravando", systemImage: "record.circle.fill").foregroundStyle(.red).font(.caption)
        case .recorded:
            Text("Na fila").font(.caption).foregroundStyle(.secondary)
        case .processing:
            if let current = state.processing.current, current.meetingId == meeting.id {
                Text("Transcrevendo \(Int(current.progress * 100))%").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Na fila").font(.caption).foregroundStyle(.secondary)
            }
        case .failed:
            Label("Falhou", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
        case .done:
            EmptyView()
        }
    }
}
