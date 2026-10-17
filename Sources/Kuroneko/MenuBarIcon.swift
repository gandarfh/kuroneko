import AppKit
import KuronekoCore

/// Kuroneko's cat (`CatShape`, from Support/kuroneko-cat.svg) in the menu
/// bar, alone or with a dot beside its ear: something new is waiting (a
/// summary written by itself). Template images, so the menu bar draws them
/// in its own color, legible on light and dark menu bars alike.
@MainActor
enum MenuBarIcon {
    static let cat = make(withDot: false)
    static let catWithNews = make(withDot: true)

    /// The cat filling `rect` with its proportions, in AppKit's bottom-up
    /// coordinates; the Dock icon draws it too.
    static func catPath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let scale = min(rect.width / CatShape.width, rect.height / CatShape.height)
        let left = rect.midX - CatShape.width * scale / 2
        let top = rect.midY + CatShape.height * scale / 2
        func point(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: left + x * scale, y: top - y * scale)
        }
        for command in SVGPath.parse(CatShape.path) ?? [] {
            switch command {
            case .move(let x, let y): path.move(to: point(x, y))
            case .line(let x, let y): path.line(to: point(x, y))
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                path.curve(to: point(x, y), controlPoint1: point(x1, y1), controlPoint2: point(x2, y2))
            case .close: path.close()
            }
        }
        return path
    }

    private static func make(withDot: Bool) -> NSImage {
        // About the height of the menu bar's own symbols.
        let catHeight: CGFloat = 15
        let catWidth = catHeight * CatShape.width / CatShape.height
        let diameter: CGFloat = 5.5, gap: CGFloat = 1.25
        let size = NSSize(width: catWidth + (withDot ? 4 : 0), height: catHeight + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            let catRect = NSRect(x: 0, y: 0.5, width: catWidth, height: catHeight)
            guard withDot else {
                NSColor.black.setFill()
                catPath(in: catRect).fill()
                return true
            }
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            // A thin gap between the dot and the ear keeps both readable.
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: rect)
            clip.appendOval(in: dot.insetBy(dx: -gap, dy: -gap))
            clip.windingRule = .evenOdd
            clip.addClip()
            NSColor.black.setFill()
            catPath(in: catRect).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = withDot ? "Kuroneko: novidades" : "Kuroneko"
        return image
    }
}
