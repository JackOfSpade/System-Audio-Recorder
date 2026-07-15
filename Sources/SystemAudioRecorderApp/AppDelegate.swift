import AppKit
import SwiftUI

/// AppDelegate owns the status item and the two windows (Library, Settings);
/// each window hosts a SwiftUI root view via `NSHostingController` (Section
/// 2.5). This is a one-way split: SwiftUI views call into TapKit; TapKit
/// never imports SwiftUI or AppKit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let hotkeyCenter = HotkeyCenter()
    private var appState: AppState!

    private static let hasOnboardedKey = "hasCompletedOnboarding"
    private static let toggleRecordHotkeyID: UInt32 = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        NSApp.setActivationPolicy(.accessory) // LSUIElement-equivalent at runtime

        setupStatusItem()
        registerHotkeys()

        if !UserDefaults.standard.bool(forKey: Self.hasOnboardedKey) {
            showOnboarding()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appState.isRecording else { return .terminateNow }
        // Silently refusing to quit (the previous behavior) left no way for
        // the user to tell whether Cmd+Q had done anything at all.
        let alert = NSAlert()
        alert.messageText = "Recording in progress"
        alert.informativeText = "System Audio Recorder is currently recording. Stop the recording before quitting, or quit anyway to stop it now and finalize the recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop Recording and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        appState.stop {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "System Audio Recorder")
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: MenuBarView(
            appState: appState,
            openLibrary: { [weak self] in self?.showLibrary() },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) }
        ))
        popover = pop
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func registerHotkeys() {
        let didRegister = hotkeyCenter.register(
            id: Self.toggleRecordHotkeyID,
            keyCode: HotkeyCenter.defaultToggleRecordKeyCode,
            modifiers: HotkeyCenter.defaultToggleRecordModifiers
        ) { [weak self] in
            Task { @MainActor in self?.appState.toggleRecord() }
        }
        guard !didRegister else { return }
        // Discarding this result (the previous behavior) meant a collision
        // with another app's shortcut (the one case `register()` can
        // actually detect — Section 3.13) was never surfaced; the user
        // would just find the hotkey silently didn't work.
        let alert = NSAlert()
        alert.messageText = "Couldn't register global shortcut"
        alert.informativeText = "⌃⌥⌘R may already be in use by another app. You can still start and stop recording from the menu bar."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showLibrary() {
        if libraryWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "System Audio Recorder Library"
            window.contentViewController = NSHostingController(rootView: LibraryView(appState: appState))
            window.isReleasedWhenClosed = false
            libraryWindow = window
        }
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "System Audio Recorder Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView(appState: appState))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "Welcome to System Audio Recorder"
        window.center()
        window.contentViewController = NSHostingController(rootView: OnboardingView(appState: appState) { [weak self, weak window] in
            UserDefaults.standard.set(true, forKey: Self.hasOnboardedKey)
            window?.close()
            self?.onboardingWindow = nil
        })
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
