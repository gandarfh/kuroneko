import Foundation

/// In which order the list shows meetings.
public enum MeetingOrder: String, CaseIterable, Sendable {
    case newest
    case oldest
    case longest
}

/// How the list puts meetings together: by day, or by the values of a tag
/// key ("project" makes a section for each project).
public enum MeetingGrouping: Hashable, Sendable {
    case day
    case tagKey(String)
}

/// The meetings list as the user asked for it: only meetings with the
/// chosen tags, grouped and ordered.
public enum MeetingListLayout {
    /// Meetings carrying every one of `tags`.
    public static func filter(_ items: [MeetingListItem], tags: Set<String>) -> [MeetingListItem] {
        guard !tags.isEmpty else { return items }
        return items.filter { tags.isSubset(of: $0.tags) }
    }

    /// Keys of the tags in use, to group by.
    public static func tagKeys(in items: [MeetingListItem]) -> [String] {
        Set(items.flatMap { $0.tags.compactMap(TagName.key) }).sorted()
    }

    /// By tag key, one section per value in alphabetical order, then "Sem
    /// <key>"; a meeting with two values of the key is in both.
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
        case .tagKey(let key):
            var byValue: [String: [MeetingListItem]] = [:]
            var without: [MeetingListItem] = []
            for item in items {
                let values = Set(item.tags.filter { TagName.key(of: $0) == key }.map(TagName.value))
                if values.isEmpty { without.append(item) }
                for value in values { byValue[value, default: []].append(item) }
            }
            var sections = byValue.keys
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { DayGrouping.Group(title: $0, isSingleDay: false, items: sorted(byValue[$0]!, by: order)) }
            if !without.isEmpty {
                sections.append(DayGrouping.Group(title: "Sem \(key)", isSingleDay: false, items: sorted(without, by: order)))
            }
            return sections
        }
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
