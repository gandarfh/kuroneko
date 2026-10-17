import AppKit
import KeyboardShortcuts
import KuronekoCore
import SwiftUI

@main
struct KuronekoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            menuIcon
        }
        .menuBarExtraStyle(.window)

        // Meetings, pendências, tags and settings in one window, which also
        // puts the app in the Dock while it is open (`DockPresence`).
        Window("Kuroneko", id: WindowID.meetings) {
            MeetingsView(state: state)
        }
        .defaultSize(width: 580, height: 860)
        // The app's main window, which can go full screen: tiling window
        // managers (AeroSpace) leave floating, as a dialog, one that can't.
        .windowManagerRole(.principal)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommand()
            }
        }
    }

    private var menuIcon: Image {
        if state.isMeetingActive { return Image(systemName: "record.circle.fill") }
        if state.processing.current != nil { return Image(systemName: "waveform") }
        // A dot beside the cat: a summary is ready (see "Novidades").
        if state.hasNews { return Image(nsImage: MenuBarIcon.catWithNews) }
        return Image(nsImage: MenuBarIcon.cat)
    }
}

enum WindowID {
    static let meetings = "meetings"
}

/// ⌘, opens the Ajustes of the window.
private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Ajustes…") {
            Navigator.shared.go(to: .settings)
            DockPresence.windowOpened()
            openWindow(id: WindowID.meetings)
        }
        .keyboardShortcut(",")
    }
}

extension KeyboardShortcuts.Name {
    /// ⌃⌥⌘N by default; never an ⌥+digit chord (taken by AeroSpace).
    static let quickNote = Self("quickNote", default: .init(.n, modifiers: [.control, .option, .command]))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only mode even when launched as a bare binary (swift run),
        // where the Info.plist LSUIElement key is not present.
        NSApp.setActivationPolicy(.accessory)
        Theme.apply()
        CaptureShield.start { AppState.shared.hiddenFromScreenCapture }
        KeyboardShortcuts.onKeyUp(for: .quickNote) {
            QuickNoteController.shared.toggle(state: AppState.shared)
        }
        AppState.shared.start()
        CommandDoubleTap.shared.start {
            QuickNoteController.shared.toggle(state: AppState.shared)
        }
        AppState.shared.onTypingCat { visible in
            TypingCatController.shared.update(visible: visible) { AppState.shared.isSomeoneSpeaking() }
        }
        AppState.shared.onVoicePrompt { meetingId in
            VoicePromptController.shared.update(meetingId: meetingId, state: AppState.shared)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CommandDoubleTap.shared.stop()
        // Stop the recorders so the WAV headers are finalized before exit.
        AppState.shared.endActiveMeeting()
    }
}
