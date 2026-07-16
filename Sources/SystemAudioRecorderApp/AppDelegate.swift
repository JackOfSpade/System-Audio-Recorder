import AppKit
import SwiftUI
import TapKit

/// AppDelegate owns the status item and the two windows (Library, Settings);
/// each window hosts a SwiftUI root view via `NSHostingController` (Section
/// 2.5). This is a one-way split: SwiftUI views call into TapKit; TapKit
/// never imports SwiftUI or AppKit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let hotkeyCenter = HotkeyCenter()
    private var appState: AppState!

    private static let hasOnboardedKey = "hasCompletedOnboarding"
    private static let toggleRecordHotkeyID: UInt32 = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.start()
        Log.info("System Audio Recorder launched (GUI)")
        appState = AppState()
        NSApp.setActivationPolicy(.accessory) // LSUIElement-equivalent at runtime

        setupStatusItem()
        registerHotkeys()

        // Section 6.2's mandatory launch-time guard against a file-layer
        // regression. The CLI refuses to record on failure; the GUI warns
        // loudly instead of silently producing untrustworthy files.
        if !SegmentWriter.runBitExactSelfCheck(scratchDirectory: FileManager.default.temporaryDirectory) {
            Log.error("bit-exact file-layer self-check FAILED at launch")
            let alert = NSAlert()
            alert.messageText = "Audio file self-check failed"
            alert.informativeText = "The Float32 bit-exact write/read-back check failed at launch. Recordings on this system may be corrupted — see \(Log.fileURL.path)."
            alert.alertStyle = .critical
            alert.runModal()
        }

        if !UserDefaults.standard.bool(forKey: Self.hasOnboardedKey) {
            showOnboarding()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quit while fully idle: nothing to finalize.
        if !appState.isRecording && !appState.isBusy { return .terminateNow }

        if appState.isRecording {
            // Silently refusing to quit (the previous behavior) left no way
            // for the user to tell whether Cmd+Q had done anything at all.
            let alert = NSAlert()
            alert.messageText = "Recording in progress"
            alert.informativeText = "System Audio Recorder is currently recording. Stop the recording before quitting, or quit anyway to stop it now and finalize the recording."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Stop Recording and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }

        // Also covers a start/stop still in flight (isBusy): the reply is
        // queued behind the in-flight operation, so the process can never
        // exit while the export is still writing the recording out.
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

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "System Audio Recorder Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView(
                appState: appState,
                keepSettingsVisible: { [weak self] in
                    self?.settingsWindow?.orderFrontRegardless()
                },
                pinSettingsVisible: { [weak self] pinned in
                    guard let window = self?.settingsWindow else { return }
                    window.hidesOnDeactivate = false
                    window.level = pinned ? .floating : .normal
                    window.orderFrontRegardless()
                }
            ))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            // .closable: with permission denied, the "Done" path is never
            // reachable — without a close button the window was permanently
            // stuck on screen (and back on every launch).
            styleMask: [.titled, .closable], backing: .buffered, defer: false
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
