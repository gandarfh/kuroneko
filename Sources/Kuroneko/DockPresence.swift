import AppKit

/// The app lives in the menu bar; while its window is open it is also an
/// ordinary app, in the Dock and in ⌘Tab, and goes back to the menu bar
/// alone when the window closes. Called before the window opens too, so the
/// window comes up with the app already in front.
@MainActor
enum DockPresence {
    static func windowOpened() {
        NSApp.applicationIconImage = icon
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func windowClosed() {
        NSApp.setActivationPolicy(.accessory)
    }

    /// The cat (Support/kuroneko-cat.svg) in amber on a near black square,
    /// drawn here: the bundle has no icon file.
    private static let icon: NSImage = {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            // The margins and corners of a macOS app icon.
            let square = rect.insetBy(dx: 50, dy: 50)
            let shape = NSBezierPath(roundedRect: square, xRadius: 92, yRadius: 92)
            NSGradient(
                starting: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1),
                ending: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
            )?.draw(in: shape, angle: -90)
            NSColor(white: 1, alpha: 0.08).setStroke()
            shape.lineWidth = 3
            shape.stroke()
            NSColor(srgbRed: 0.98, green: 0.74, blue: 0.27, alpha: 1).setFill()
            MenuBarIcon.catPath(in: square.insetBy(dx: 92, dy: 92)).fill()
            return true
        }
    }()
}
