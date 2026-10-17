import Foundation

/// In which order the list shows meetings.
public enum MeetingOrder: String, CaseIterable, Sendable {
    case newest
    case oldest
    case longest
}

/// How the list puts meetings together: by day, by who was there, or by
/// the values of a tag key ("project" makes a section for each project).
public enum MeetingGrouping: Hashable, Sendable {
    case day
    case person
    case tagKey(String)
}

/// The meetings list as the user asked for it: only meetings with the
/// chosen people and tags, grouped and ordered.
public enum MeetingListLayout {
    /// Meetings carrying every one of `tags`.
    public static func filter(_ items: [MeetingListItem], tags: Set<String>) -> [MeetingListItem] {
        guard !tags.isEmpty else { return items }
        return items.filter { tags.isSubset(of: $0.tags) }
    }

    /// Meetings with any of `people`; none chosen is every meeting.
    public static func filter(_ items: [MeetingListItem], people: Set<String>) -> [MeetingListItem] {
        guard !people.isEmpty else { return items }
        return items.filter { !people.isDisjoint(with: $0.people) }
    }

    /// Everyone named in some meeting, by name.
    public static func people(in items: [MeetingListItem]) -> [String] {
        Set(items.flatMap(\.people)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Keys of the tags in use, to group by.
    public static func tagKeys(in items: [MeetingListItem]) -> [String] {
        Set(items.flatMap { $0.tags.compactMap(TagName.key) }).sorted()
    }

    /// By person or tag key, one section per name or value in alphabetical
    /// order, then the meetings without any; a meeting with two is in both.
    public static func sections(
        _ items: [MeetingListItem],
        grouping: MeetingGrouping,
        order: MeetingOrder,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DayGrouping.Group<MeetingListItem>] {
        switch grouping {
        case .day:
            let days = DayGrouping.group(items, date: \.startedAt, now: now, calendar: calendar)
            switch order {
            case .newest:
                return days
            case .oldest:
                return days.reversed().map { day in
                    DayGrouping.Group(title: day.title, isSingleDay: day.isSingleDay, items: sorted(day.items, by: .oldest))
                }
            case .longest:
                return days.map { day in
                    DayGrouping.Group(title: day.title, isSingleDay: day.isSingleDay, items: sorted(day.items, by: .longest))
                }
            }
        case .person:
            return byValue(items, order: order, without: "Sem pessoas identificadas") { Set($0.people) }
        case .tagKey(let key):
            return byValue(items, order: order, without: "Sem \(key)") { item in
                Set(item.tags.filter { TagName.key(of: $0) == key }.map(TagName.value))
            }
        }
    }

    private static func byValue(
        _ items: [MeetingListItem],
        order: MeetingOrder,
        without title: String,
        values: (MeetingListItem) -> Set<String>
    ) -> [DayGrouping.Group<MeetingListItem>] {
        var byValue: [String: [MeetingListItem]] = [:]
        var without: [MeetingListItem] = []
        for item in items {
            let values = values(item)
            if values.isEmpty { without.append(item) }
            for value in values { byValue[value, default: []].append(item) }
        }
        var sections = byValue.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { DayGrouping.Group(title: $0, isSingleDay: false, items: sorted(byValue[$0]!, by: order)) }
        if !without.isEmpty {
            sections.append(DayGrouping.Group(title: title, isSingleDay: false, items: sorted(without, by: order)))
        }
        return sections
    }

    /// Meetings of the same length or moment keep their order.
    static func sorted(_ items: [MeetingListItem], by order: MeetingOrder) -> [MeetingListItem] {
        items.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            switch order {
            case .newest where left.startedAt != right.startedAt:
                return left.startedAt > right.startedAt
            case .oldest where left.startedAt != right.startedAt:
                return left.startedAt < right.startedAt
            // Still recording (no length yet) goes last.
            case .longest where left.durationMs != right.durationMs:
                return (left.durationMs ?? -1) > (right.durationMs ?? -1)
            default:
                return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }
}
