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
    let processCatalog: ProcessCatalog

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

    init() {
        self.engine = CaptureEngine(recordingsRoot: AppState.resolvedRecordingsRoot())
        self.processCatalog = ProcessCatalog(engineQueue: DispatchQueue(label: "com.systemaudiorecorder.app.processcatalog"))
        engine.onStatusChanged = { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        engine.sessionStore.runCrashRecoveryScan()
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

    var healthDescription: String {
        switch status {
        case .idle: return "Not recording"
        case .recording: return "● Recording"
        case .error(let message): return "✕ Error: \(message)"
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
        let storedFormat = UserDefaults.standard.string(forKey: "recordingFormat") ?? ExportFormat.caf32.rawValue
        let format = ExportFormat(rawValue: storedFormat) ?? .caf32
        let spec = SessionSpec(format: format)
        engine.start(spec: spec) { [weak self] result in
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
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard !operationInFlight else { completion?(); return }
        operationInFlight = true
        engine.stop { [weak self] fileURL in
            Task { @MainActor in
                guard let self else { completion?(); return }
                self.operationInFlight = false
                self.recordStartedAt = nil
                self.elapsedSeconds = 0
                if let fileURL {
                    self.lastEventDescription = "Saved: \(fileURL.lastPathComponent)"
                }
                completion?()
            }
        }
    }

    private func startMeterPolling() {
        // 20 Hz per Section 5.4 step 8 / Section 3.6.1.
        meterPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.meters = self.engine.meterSnapshots().map { $0 ?? .empty }
                if let started = self.recordStartedAt {
                    self.elapsedSeconds = Date().timeIntervalSince(started)
                }
            }
        }
    }
}
