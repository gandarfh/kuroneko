import SwiftUI

// The bar above the lists of Reuniões and Pendências: Filtrar, Agrupar and
// the like as pill menus on the right, and the filters on below, each one
// easy to take off. Both lists keep what the user chose in the defaults.

extension View {
    /// The look of the bar's menus.
    func listToolbarMenus() -> some View {
        menuStyle(.button)
            .buttonStyle(PillButtonStyle())
            .menuIndicator(.hidden)
    }
}

/// Icon, title and a count of what is on, as the bar's menus show.
struct ToolbarMenuLabel: View {
    let title: String
    let icon: String
    var badge = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
            Text(title)
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Theme.accent, in: Capsule())
            } else {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize()
    }
}

/// An option of a menu that is one of several, checked when in use.
struct MenuChoice<Value: Equatable>: View {
    let title: String
    var icon: String?
    let value: Value
    @Binding var selection: Value

    var body: some View {
        Toggle(isOn: Binding(get: { selection == value }, set: { if $0 { selection = value } })) {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
    }
}

/// The filters on, under the bar: each one with ✕ to take it off, and
/// "Limpar" for all of them.
struct ActiveFilters: View {
    struct Filter: Identifiable {
        let id: String
        let title: String
        let help: String
        let remove: () -> Void
    }

    let filters: [Filter]
    let clear: () -> Void

    var body: some View {
        WrappingLayout {
            ForEach(filters) { filter in
                FilterChip(title: "\(filter.title)  ✕", selected: true, action: filter.remove)
                    .help(filter.help)
            }
            if filters.count > 1 {
                Button("Limpar", action: clear)
                    .buttonStyle(.accentLink)
                    .font(.callout)
            }
        }
    }
}

/// A filter on or off, as a chip.
struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(selected ? Theme.accent : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? Theme.accentFill : ListPalette.card, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Names kept in the defaults, one per line.
enum StoredNames {
    static func decode(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").map(String.init))
    }

    static func encode(_ names: Set<String>) -> String {
        names.sorted().joined(separator: "\n")
    }

    /// The names kept in `text`, to change as a set.
    static func binding(_ text: Binding<String>) -> Binding<Set<String>> {
        Binding(get: { decode(text.wrappedValue) }, set: { text.wrappedValue = encode($0) })
    }
}

extension Binding where Value == Set<String> {
    /// Whether `name` is in the set, for a toggle in a menu.
    func contains(_ name: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.contains(name) },
            set: { on in if on { wrappedValue.insert(name) } else { wrappedValue.remove(name) } }
        )
    }
}
