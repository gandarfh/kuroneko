import AppKit
import SwiftUI

/// The look of every Kuroneko window: always dark, near black, soft cards
/// without borders, amber for what matters and red while recording.
enum Theme {
    static let background = Color(hex: 0x111113)
    /// The menu panel, a little lighter at the top.
    static let panel = LinearGradient(colors: [Color(hex: 0x1E1E20), Color(hex: 0x0F0F10)], startPoint: .top, endPoint: .bottom)
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.09)
    static let hairline = Color.white.opacity(0.08)
    static let accent = Color(hex: 0xFABD45)
    static let accentFill = Color(hex: 0xFABD45).opacity(0.14)
    static let recording = Color(hex: 0xFF5C54)
    static let ready = Color(hex: 0x4CC26E)
    static let warning = Color(hex: 0xFF9F0A)
    static let radius: CGFloat = 16
    static let smallRadius: CGFloat = 12

    /// Dark whatever the system uses: the colors are made for it.
    @MainActor
    static func apply() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A soft card: the rounded fill every block of the app sits on.
struct PanelCard: ViewModifier {
    var radius = Theme.radius
    var fill = Theme.card

    func body(content: Content) -> some View {
        content.background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func panelCard(radius: CGFloat = Theme.radius, fill: Color = Theme.card) -> some View {
        modifier(PanelCard(radius: radius, fill: fill))
    }
}

/// A card that is a button: lighter under the pointer, dimmer when pressed.
struct CardButtonStyle: ButtonStyle {
    var radius = Theme.radius

    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration, radius: radius)
    }

    private struct CardButtonBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .panelCard(radius: radius, fill: hovering ? Theme.cardHover : Theme.card)
                .opacity(configuration.isPressed ? 0.75 : 1)
                .onHover { hovering = $0 }
        }
    }
}

/// An icon on a small rounded square of its color.
struct IconTile<Glyph: View>: View {
    var tint = Theme.accent
    var size: CGFloat = 34
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        glyph()
            .font(.system(size: size * 0.42))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

extension IconTile where Glyph == Image {
    init(systemName: String, tint: Color = Theme.accent, size: CGFloat = 34) {
        self.init(tint: tint, size: size) { Image(systemName: systemName) }
    }
}

/// Icons SF Symbols lacks.
@MainActor
enum Glyphs {
    /// Git's merge: two commits on a line and a third joining it, as git
    /// tools draw it.
    static let merge: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            let lines = NSBezierPath()
            lines.lineWidth = 1.5
            lines.lineCapStyle = .round
            lines.move(to: NSPoint(x: 4.5, y: 5.3))
            lines.line(to: NSPoint(x: 4.5, y: 10.7))
            lines.move(to: NSPoint(x: 4.5, y: 5.3))
            lines.curve(to: NSPoint(x: 9.7, y: 9.5), controlPoint1: NSPoint(x: 4.5, y: 8.2), controlPoint2: NSPoint(x: 6.6, y: 9.5))
            lines.stroke()
            for center in [NSPoint(x: 4.5, y: 3.3), NSPoint(x: 4.5, y: 12.7), NSPoint(x: 11.7, y: 9.5)] {
                let circle = NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
                circle.lineWidth = 1.5
                circle.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// For views that take an icon by name.
    static let mergeName = "kuroneko.merge"

    static func mergeImage(size: CGFloat) -> some View {
        Image(nsImage: merge)
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
    }
}

/// The colors a status can have, by the name stored with it.
enum StatusPalette {
    static let names = ["gray", "amber", "green", "blue", "purple", "pink", "red", "teal"]

    static func color(_ name: String) -> Color {
        switch name {
        case "amber": Theme.accent
        case "green": Theme.ready
        case "blue": Color(hex: 0x5AA9FF)
        case "purple": Color(hex: 0xB18CFF)
        case "pink": Color(hex: 0xFF7AB6)
        case "red": Theme.recording
        case "teal": Color(hex: 0x40C8C0)
        default: Color(hex: 0x98989F)
        }
    }

    /// The color as a dot for menus, which draw SF Symbols in one color.
    @MainActor
    static func dot(_ name: String) -> NSImage {
        if let image = dots[name] { return image }
        let color = NSColor(color(name))
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 9, height: 9)).fill()
            return true
        }
        image.isTemplate = false
        dots[name] = image
        return image
    }

    @MainActor private static var dots: [String: NSImage] = [:]

    static func title(_ name: String) -> String {
        switch name {
        case "amber": "Âmbar"
        case "green": "Verde"
        case "blue": "Azul"
        case "purple": "Roxo"
        case "pink": "Rosa"
        case "red": "Vermelho"
        case "teal": "Turquesa"
        default: "Cinza"
        }
    }
}

/// The round button of a panel's corner: start, stop, close.
struct CircleButtonStyle: ButtonStyle {
    var tint: Color = .white
    var filled = false
    var size: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint.opacity(0.9))
            .frame(width: size, height: size)
            .background(Circle().fill(filled ? tint.opacity(0.16) : Color.white.opacity(0.06)))
            .overlay(Circle().strokeBorder(filled ? tint.opacity(0.7) : Color.white.opacity(0.18), lineWidth: size < 30 ? 1 : 1.5))
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// "AO VIVO", "VOZES": the small caps above a block.
struct SectionLabel: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(tint)
    }
}

/// A text button in amber, in place of the system's blue links.
struct AccentLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentLinkBody(configuration: configuration)
    }

    private struct AccentLinkBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == AccentLinkStyle {
    static var accentLink: AccentLinkStyle { AccentLinkStyle() }
}

/// A capsule on the card fill, for the menus above a list: "Tags ⌄".
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration)
    }

    private struct PillBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(hovering ? Theme.cardHover : Theme.card, in: Capsule())
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}

/// "⋯" of a card: gray, without the menu's chrome.
struct MoreMenu<Content: View>: View {
    var help: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The main action of a place: amber with dark text ("Salvar", "Gerar
/// resumo"), where the system would draw a blue button with white text.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentBody(configuration: configuration)
    }

    private struct AccentBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

extension ButtonStyle where Self == AccentButtonStyle {
    static var accent: AccentButtonStyle { AccentButtonStyle() }
}

/// A text button in gray that turns amber under the pointer: the times of
/// the transcript, which are many and would turn the page amber.
struct QuietLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration)
    }

    private struct QuietBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? Theme.accent : .secondary)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == QuietLinkStyle {
    static var quietLink: QuietLinkStyle { QuietLinkStyle() }
}

/// An amber switch: the system's ignores the app's tint and stays blue.
struct AccentSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentSwitch(configuration: configuration)
    }

    private struct AccentSwitch: View {
        let configuration: Configuration
        @Environment(\.labelsVisibility) private var labelsVisibility

        var body: some View {
            HStack {
                // `.labelsHidden()` only reaches a custom style through this.
                if labelsVisibility != .hidden {
                    configuration.label
                    Spacer(minLength: 12)
                }
                Button {
                    withAnimation(.snappy(duration: 0.15)) { configuration.isOn.toggle() }
                } label: {
                    Capsule()
                        .fill(configuration.isOn ? Theme.accent : Color.white.opacity(0.16))
                        .frame(width: 34, height: 20)
                        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                            Circle()
                                .fill(.white)
                                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                                .padding(2)
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityValue(configuration.isOn ? "ligado" : "desligado")
            }
        }
    }
}

extension ToggleStyle where Self == AccentSwitchStyle {
    static var accentSwitch: AccentSwitchStyle { AccentSwitchStyle() }
}

/// A round-cornered box that fills amber with a dark check when done.
struct AccentCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(configuration.isOn ? Theme.accent : Color.white.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(configuration.isOn ? 0 : 0.22))
                }
                .overlay {
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.black.opacity(0.85))
                    }
                }
                .frame(width: 17, height: 17)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Centered on the first line of the text beside it.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        .accessibilityValue(configuration.isOn ? "feita" : "aberta")
    }
}

extension ToggleStyle where Self == AccentCheckboxStyle {
    static var accentCheckbox: AccentCheckboxStyle { AccentCheckboxStyle() }
}

/// What can't be undone, such as quitting: red text on a red tint.
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(Theme.recording)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Theme.recording.opacity(configuration.isPressed ? 0.26 : 0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension ButtonStyle where Self == DangerButtonStyle {
    static var danger: DangerButtonStyle { DangerButtonStyle() }
}

/// A few choices side by side in one capsule, the chosen one lit: "Todas 5 ·
/// Minhas 1 · Dos outros 4".
struct PillSegments<Value: Hashable>: View {
    struct Segment {
        var value: Value
        var title: String
        var count: Int?
        /// Shown alone when the title is empty, which then only helps.
        var icon: String?
    }

    let segments: [Segment]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.value) { segment in
                let selected = segment.value == selection
                Button {
                    selection = segment.value
                } label: {
                    HStack(spacing: 5) {
                        if let icon = segment.icon {
                            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                        }
                        if !segment.title.isEmpty {
                            Text(segment.title)
                        }
                        if let count = segment.count {
                            Text("\(count)")
                                .monospacedDigit()
                                .foregroundStyle(selected ? Theme.accent : .secondary)
                        }
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(selected ? Color.white.opacity(0.11) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.card, in: Capsule())
        .fixedSize()
    }
}
