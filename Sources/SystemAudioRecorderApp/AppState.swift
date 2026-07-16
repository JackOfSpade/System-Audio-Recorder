import CoreAudio
import Foundation
import SwiftUI
import TapKit

/// Bridges `CaptureEngine` (TapKit, no UI imports) to SwiftUI. Owns the
/// single `CaptureEngine` instance for the GUI process (Section 4.1: GUI and
/// CLI each instantiate their own engine; no XPC/IPC in v1).
@MainActor
final class AppState: ObservableObject {
    let engine: CaptureEngine

    @Published var status: EngineStatus = .idle
    @Published var permissionOutcome: PermissionOutcome = PermissionBroker.cachedOutcome
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var meters: [MeterSnapshot] = []
    @Published var lastEventDescription: String = ""

    private var recordStartedAt: Date?
    private var meterPollTimer: Timer?
    /// Guards against two overlapping start()/stop() round-trips — status
    /// only updates once the async `engine.start`/`stop` completion fires,
    /// so two rapid toggles before that happens would otherwise both see
    /// the same stale `isRecording` and both fire the same call.
    private var operationInFlight = false
    /// Stop requests that arrived while a start/stop was already in flight.
    /// They run once the in-flight operation completes — firing them
    /// immediately (the previous behavior) let Cmd+Q's terminate reply race
    /// ahead of a still-running export and kill the process mid-write.
    private var pendingStopCompletions: [() -> Void] = []
    private var stopRequestedWhileBusy = false

    init() {
        self.engine = CaptureEngine(recordingsRoot: AppState.resolvedRecordingsRoot())
        engine.onStatusChanged = { [weak self] status in
            Task { @MainActor in self?.handleStatusChange(status) }
        }
        engine.sessionStore.sweepPartialCaptures()
        // A persisted "not granted" must not disable the Record button
        // forever: the user may have granted access in System Settings since
        // the last probe. Re-probing is silent once TCC has an answer.
        if PermissionBroker.cachedOutcome == .notGranted {
            requestPermissionIfNeeded()
        }
        startMeterPolling()
    }

    /// Settings → General's "Recordings folder" field (`AppStorage` key
    /// `recordingsFolder`) — read directly from `UserDefaults` since
    /// `AppState` is a plain class, not a SwiftUI `View`, so it can't use the
    /// `@AppStorage` property wrapper itself. Falls back to `~/Music/System
    /// Audio Recorder/` if the setting was never touched.
    private static func resolvedRecordingsRoot() -> URL {
        let stored = UserDefaults.standard.string(forKey: "recordingsFolder") ?? "~/Music/System Audio Recorder/"
        return URL(fileURLWithPath: (stored as NSString).expandingTildeInPath, isDirectory: true)
    }

    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }

    /// True while a start/stop round-trip is still in flight.
    var isBusy: Bool { operationInFlight }

    var healthDescription: String {
        switch status {
        case .idle: return "Not recording"
        case .recording: return "● Recording"
        case .error(let message): return "✕ Error: \(message)"
        }
    }

    private func handleStatusChange(_ newStatus: EngineStatus) {
        status = newStatus
        guard !isRecording else { return }
        // The engine left .recording — our own stop() (whose completion also
        // resets these) or an engine-initiated finalize (device-wait timeout,
        // permanent mid-session failure). Either way the clock must stop.
        recordStartedAt = nil
        elapsedSeconds = 0
        if case .idle = newStatus, !operationInFlight,
           let outcome = engine.lastStopOutcome, !outcome.fileURLs.isEmpty {
            lastEventDescription = "Saved: \(outcome.fileURLs.map { $0.lastPathComponent }.joined(separator: ", "))"
        }
    }

    func requestPermissionIfNeeded() {
        engine.requestCapturePermission { [weak self] outcome in
            Task { @MainActor in self?.permissionOutcome = outcome }
        }
    }

    func toggleRecord() {
        guard !operationInFlight else { return }
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !operationInFlight else { return }
        operationInFlight = true

        let defaults = UserDefaults.standard
        let format = ExportFormat(rawValue: defaults.string(forKey: "recordingFormat") ?? "") ?? .caf32
        // A cleared Settings field persists "" (non-nil), so ?? alone won't
        // restore the default — treat empty as unset.
        let storedTemplate = defaults.string(forKey: "namingTemplate") ?? ""
        let namingTemplate = storedTemplate.trimmingCharacters(in: .whitespaces).isEmpty
            ? "{date} {time} — {source}"
            : storedTemplate
        let silentCapture = defaults.bool(forKey: "silentCapture")
        // A recordings-folder change in Settings takes effect on the next
        // recording, not the next launch (no-op while a session is live).
        engine.updateRecordingsRoot(AppState.resolvedRecordingsRoot())

        let spec = SessionSpec(
            muteBehavior: silentCapture ? .mutedWhenTapped : .unmuted,
            format: format
        )
        engine.start(spec: spec, namingTemplate: namingTemplate) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.operationInFlight = false
                switch result {
                case .success:
                    // Only start the elapsed-time clock once the engine has
                    // actually confirmed the session is running — setting
                    // this before the async call (the previous approach)
                    // left it running forever after a failed start, since
                    // nothing ever cleared it.
                    self.recordStartedAt = Date()
                    self.lastEventDescription = "Recording started"
                case .failure(let error):
                    self.recordStartedAt = nil
                    self.lastEventDescription = "Failed to start: \(error)"
                }
                self.runPendingStopsIfNeeded()
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        if let completion { pendingStopCompletions.append(completion) }
        guard !operationInFlight else {
            stopRequestedWhileBusy = true
            return
        }
        operationInFlight = true
        engine.stop { [weak self] outcome in
            Task { @MainActor in
                guard let self else { return }
                self.operationInFlight = false
                self.recordStartedAt = nil
                self.elapsedSeconds = 0
                if !outcome.fileURLs.isEmpty {
                    self.lastEventDescription = "Saved: \(outcome.fileURLs.map { $0.lastPathComponent }.joined(separator: ", "))"
                } else if let failure = outcome.failure {
                    self.lastEventDescription = "\(failure.message) — see \(Log.fileURL.path)"
                }
                self.stopRequestedWhileBusy = false
                let completions = self.pendingStopCompletions
                self.pendingStopCompletions = []
                completions.forEach { $0() }
            }
        }
    }

    /// Runs after a start/stop round-trip completes: a stop requested while
    /// we were busy (e.g. quit during start) executes now.
    private func runPendingStopsIfNeeded() {
        guard stopRequestedWhileBusy || !pendingStopCompletions.isEmpty else { return }
        stopRequestedWhileBusy = false
        if isRecording {
            stop()
        } else {
            let completions = pendingStopCompletions
            pendingStopCompletions = []
            completions.forEach { $0() }
        }
    }

    private func startMeterPolling() {
        // 20 Hz per Section 5.4 step 8 / Section 3.6.1.
        meterPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Don't churn @Published (a SwiftUI invalidation every 50 ms,
                // forever, in an idle menu-bar app) when there is nothing to
                // show and nothing to clear.
                let snapshots = self.engine.meterSnapshots()
                if !snapshots.isEmpty || !self.meters.isEmpty {
                    self.meters = snapshots
                }
                if let started = self.recordStartedAt {
                    self.elapsedSeconds = Date().timeIntervalSince(started)
                }
            }
        }
    }
}
