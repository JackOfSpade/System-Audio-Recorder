import Foundation
import CoreAudio
import TapKit

// Exit codes (Section 3.8): 0 ok · 2 permission denied · 3 device/app not
// found · 4 capture error · 5 disk error · 64 usage error.
enum ExitCode: Int32 {
    case ok = 0
    case permissionDenied = 2
    case notFound = 3
    case captureError = 4
    case diskError = 5
    case usage = 64
}

func fail(_ code: ExitCode, _ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code.rawValue)
}

func stderrLine(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

struct ArgParser {
    let args: [String]
    init(_ args: [String]) { self.args = args }

    func flag(_ name: String) -> Bool { args.contains(name) }

    /// Returns the single value following `name`, or nil if `name` wasn't
    /// passed at all. Fails with a usage error — rather than silently
    /// returning nil, as if the flag had never been passed — if `name`
    /// appears with no following value (e.g. a dangling `--device` as the
    /// last argument), or appears more than once (previously only the
    /// FIRST occurrence was honored, silently discarding the rest).
    func value(_ name: String) -> String? {
        let indices = args.indices.filter { args[$0] == name }
        guard let idx = indices.first else { return nil }
        if indices.count > 1 {
            fail(.usage, "\(name) was specified more than once. Pass it exactly once.")
        }
        guard idx + 1 < args.count else {
            fail(.usage, "\(name) requires a value.")
        }
        return args[idx + 1]
    }

    /// Rejects unknown or mistyped options up front (Section 3.8: usage
    /// errors exit 64). Without this, a typo like `--durration 600` was
    /// silently ignored — recording unbounded instead of for 10 minutes.
    /// `options` consume the following token as their value; `flags` don't.
    func validate(flags: Set<String>, options: Set<String>) {
        var index = 0
        while index < args.count {
            let token = args[index]
            if options.contains(token) {
                index += 2 // a missing value is caught by value(_:)
            } else if flags.contains(token) {
                index += 1
            } else {
                fail(.usage, "Unknown option '\(token)'.")
            }
        }
    }
}

// MARK: --device resolution (Section 3.8 / 7.2 — owning surface here)

func resolveDevice(_ arg: String) -> AudioObjectID {
    if let id = try? AudioDeviceDirectory.findDevice(byUID: arg) {
        return id
    }
    let matches = (try? AudioDeviceDirectory.findDevices(byName: arg)) ?? []
    if matches.count == 1 {
        return matches[0]
    } else if matches.count > 1 {
        stderrLine("Ambiguous device name '\(arg)'. Matching UIDs:")
        for m in matches {
            if let uid = try? AudioDeviceDirectory.deviceUID(m) {
                stderrLine("  \(uid)")
            }
        }
        fail(.notFound, "Specify one of the UIDs above with --device.")
    }
    fail(.notFound, "Device not found: \(arg)")
}

func recordingsRoot(from parser: ArgParser) -> URL {
    if let out = parser.value("--out") {
        return URL(fileURLWithPath: out)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/System Audio Recorder")
}

// MARK: record

func runRecord(_ parser: ArgParser) -> Never {
    parser.validate(flags: [], options: ["--device", "--duration", "--max-silence-stop", "--format", "--out"])

    let permission = PermissionBroker.requestCapturePermission()
    guard permission == .granted else {
        fail(.permissionDenied, "System audio capture permission was not granted. Open System Settings > Privacy & Security > Screen & System Audio Recording.")
    }

    // Section 6.2's mandatory launch-time guard: if the file layer can't
    // round-trip Float32 bit-exactly, refuse to record at all.
    guard SegmentWriter.runBitExactSelfCheck(scratchDirectory: FileManager.default.temporaryDirectory) else {
        fail(.captureError, "Bit-exact file-layer self-check failed — refusing to record. See \(Log.fileURL.path).")
    }

    var device: DevicePolicy = .followSystemDefault
    if let deviceArg = parser.value("--device") {
        let id = resolveDevice(deviceArg)
        guard let uid = try? AudioDeviceDirectory.deviceUID(id) else {
            fail(.notFound, "Could not resolve UID for device: \(deviceArg)")
        }
        device = .fixed(deviceUID: uid)
    }

    // Validate every option BEFORE starting the engine. Previously
    // --duration/--max-silence-stop were parsed AFTER engine.start(), so a
    // bad value's fail() call (a hard exit()) killed the process while a
    // real recording (Core Audio taps, disk I/O, an open session.json) was
    // already in flight — abandoned, unfinalized, reported only as a usage
    // error despite real capture having already happened.
    var durationSeconds: Double?
    if let durationArg = parser.value("--duration") {
        guard let parsed = Double(durationArg), parsed > 0 else {
            fail(.usage, "Invalid --duration value: '\(durationArg)'. Expected a positive number of seconds.")
        }
        durationSeconds = parsed
    }

    var maxSilenceStopSeconds: Double?
    if let silenceArg = parser.value("--max-silence-stop") {
        guard let parsed = Double(silenceArg), parsed > 0 else {
            fail(.usage, "Invalid --max-silence-stop value: '\(silenceArg)'. Expected a positive number of seconds.")
        }
        maxSilenceStopSeconds = parsed
    }

    var format: ExportFormat = .caf32
    if let formatArg = parser.value("--format") {
        guard let parsed = ExportFormat(rawValue: formatArg) else {
            fail(.usage, "Invalid --format value: '\(formatArg)'. Expected one of: wav32, caf32.")
        }
        format = parsed
    }

    let spec = SessionSpec(device: device, format: format)
    let engine = CaptureEngine(recordingsRoot: recordingsRoot(from: parser))
    // Rescue any partial master a crashed previous run left behind.
    engine.sessionStore.sweepPartialCaptures()

    let startSemaphore = DispatchSemaphore(value: 0)
    var startError: Error?
    engine.start(spec: spec) { result in
        switch result {
        case .success: break
        case .failure(let error): startError = error
        }
        startSemaphore.signal()
    }
    startSemaphore.wait()

    if let startError {
        fail(.captureError, "Failed to start recording: \(startError)")
    }
    stderrLine("[\(Timestamp.now())] Recording started...")

    var shouldStop = false
    let stopLock = NSLock()
    func requestStop() {
        stopLock.lock(); shouldStop = true; stopLock.unlock()
    }

    // Trap both SIGINT (Ctrl-C) and SIGTERM (the default signal sent by a
    // plain `kill <pid>`, and what launchd/logout/shutdown send) — SIGTERM
    // previously kept its default disposition (Terminate), so the far more
    // common `kill`/supervisor-stop/shutdown path killed the process
    // instantly with the recording never finalized, identical in effect to
    // the --duration ordering bug above.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    // NOT `.main`: this process never calls dispatchMain()/RunLoop.main.run()
    // (it waits via a plain Thread.sleep polling loop below), so nothing
    // would ever drain the main dispatch queue and this handler would never
    // fire. A dedicated background queue is serviced by the libdispatch
    // thread pool regardless of what the main thread is doing.
    let signalQueue = DispatchQueue(label: "com.systemaudiorecorder.cli.signal")
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
    sigintSource.setEventHandler {
        stderrLine("[\(Timestamp.now())] Ctrl-C received, finalizing…")
        requestStop()
    }
    sigintSource.resume()
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
    sigtermSource.setEventHandler {
        stderrLine("[\(Timestamp.now())] SIGTERM received, finalizing…")
        requestStop()
    }
    sigtermSource.resume()

    let deadline = durationSeconds.map { Date().addingTimeInterval($0) }
    var silenceStartedAt: Date?

    while true {
        Thread.sleep(forTimeInterval: 0.2)
        stopLock.lock(); let stop = shouldStop; stopLock.unlock()
        if stop { break }
        // The engine can finalize the session on its own: a `.fixed` device
        // that never returned within the 5-minute wait (Section 3.8: exit 0,
        // a valid session was produced), or a permanent mid-session failure.
        // Without this check the loop would sleep forever — meters are empty
        // once the engine self-stops, so the silence path can't fire either.
        if case .recording = engine.status {} else {
            stderrLine("[\(Timestamp.now())] Engine finalized the session on its own, collecting result…")
            break
        }
        if let deadline, Date() >= deadline {
            stderrLine("[\(Timestamp.now())] --duration elapsed, finalizing…")
            break
        }
        if let maxSilenceStopSeconds {
            // Digital silence counts only while every lane has a live meter
            // snapshot AND its watchdog is NOT actively handling a confirmed
            // Bug-B dropout — during recovery the zeros are the OS bug, not
            // real silence, and stopping would cut off an in-flight rebuild
            // (Section 3.8). An `.empty` snapshot (pipeline not up yet, or
            // parked in WAITING_FOR_DEVICE) has zeroRunSeconds == 0 and so
            // blocks the stop rather than counting as silence.
            let snapshots = engine.meterSnapshots()
            let states = engine.watchdogStates()
            let genuinelySilent = !snapshots.isEmpty && zip(snapshots, states).allSatisfy { snapshot, state in
                // .escalated is also active recovery (retrying every 60s per
                // Section 8.1 — "ESCALATED keeps recording"), not silence.
                snapshot.zeroRunSeconds > 0 && ![.confirmedDropout, .rebuilding, .postRebuildVerify, .escalated].contains(state)
            }
            if genuinelySilent {
                if silenceStartedAt == nil { silenceStartedAt = Date() }
                if let started = silenceStartedAt, Date().timeIntervalSince(started) >= maxSilenceStopSeconds {
                    stderrLine("[\(Timestamp.now())] --max-silence-stop threshold reached, finalizing…")
                    break
                }
            } else {
                silenceStartedAt = nil
            }
        }
    }

    // For a session the engine already finalized itself, stop() is a no-op
    // that reports that session's recorded outcome (saved URLs included).
    let stopSemaphore = DispatchSemaphore(value: 0)
    var stopOutcome: CaptureEngine.StopOutcome?
    engine.stop { outcome in
        stopOutcome = outcome
        stopSemaphore.signal()
    }
    stopSemaphore.wait()

    let outcome = stopOutcome ?? CaptureEngine.StopOutcome(fileURLs: [], failure: .nothingCaptured)
    for url in outcome.fileURLs {
        print(url.path)
    }
    if !outcome.fileURLs.isEmpty {
        // Files were saved — that's a success for scripting purposes, even
        // if the session ended abnormally (the reason went to stderr/log).
        if case .error(let message) = engine.status {
            stderrLine("[\(Timestamp.now())] Note: \(message)")
        }
        exit(ExitCode.ok.rawValue)
    }
    switch outcome.failure {
    case .exportFailed(let detail):
        fail(.diskError, "Recording captured, but export failed: \(detail). The raw .capture_*.caf master was left in the recordings folder.")
    case .nothingCaptured, .none:
        if case .error(let message) = engine.status {
            fail(.captureError, message)
        }
        fail(.captureError, "No audio was captured to save.")
    }
}

// MARK: devices / apps / sessions

func runDevices(_ parser: ArgParser) -> Never {
    parser.validate(flags: ["--json"], options: [])
    let json = parser.flag("--json")
    guard let ids = try? AudioDeviceDirectory.allDevices() else {
        fail(.captureError, "Could not enumerate devices")
    }
    struct Row: Codable { let uid: String; let name: String; let rate: Double; let channels: Int; let bugARisk: Bool }
    var rows: [Row] = []
    for id in ids {
        guard let uid = try? AudioDeviceDirectory.deviceUID(id),
              let name = try? AudioDeviceDirectory.deviceName(id) else { continue }
        let rate = (try? AudioDeviceDirectory.nominalSampleRate(id)) ?? 0
        let channels = (try? AudioDeviceDirectory.outputChannelCount(id)) ?? 0
        guard channels > 0 else { continue } // input-only devices are not capture targets
        rows.append(Row(uid: uid, name: name, rate: rate, channels: channels, bugARisk: channels > 2))
    }
    if json {
        if let data = try? JSONEncoder().encode(rows), let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    } else {
        for r in rows {
            let badge = r.bugARisk ? " [Bug-A risk: \(r.channels)ch]" : ""
            print("\(r.uid)\t\(r.name)\t\(Int(r.rate))Hz\(badge)")
        }
    }
    exit(ExitCode.ok.rawValue)
}

func runApps(_ parser: ArgParser) -> Never {
    parser.validate(flags: ["--json"], options: [])
    let json = parser.flag("--json")
    guard let processes = try? ProcessCatalog.allProcesses() else {
        fail(.captureError, "Could not enumerate processes")
    }
    struct Row: Codable { let bundleId: String?; let pid: Int32; let isOutputting: Bool }
    let rows = processes.map { Row(bundleId: $0.bundleID, pid: $0.pid, isOutputting: $0.isRunningOutput) }
    if json {
        if let data = try? JSONEncoder().encode(rows), let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    } else {
        for r in rows {
            print("\(r.bundleId ?? "(no bundle id)")\t\(r.pid)\t\(r.isOutputting ? "outputting" : "idle")")
        }
    }
    exit(ExitCode.ok.rawValue)
}



// MARK: calibrate

func runCalibrate(_ parser: ArgParser) -> Never {
    parser.validate(flags: [], options: ["--device"])
    let deviceID: AudioObjectID
    if let deviceArg = parser.value("--device") {
        deviceID = resolveDevice(deviceArg)
    } else {
        guard let id = try? AudioDeviceDirectory.defaultOutputDevice() else {
            fail(.notFound, "Could not resolve default output device")
        }
        deviceID = id
    }
    guard let uid = try? AudioDeviceDirectory.deviceUID(deviceID),
          let name = try? AudioDeviceDirectory.deviceName(deviceID) else {
        fail(.notFound, "Could not resolve device UID/name")
    }

    print("System Audio Recorder will play a 5-second test tone through \(name). Continue? [y/N]", terminator: " ")
    guard let answer = readLine(), answer.lowercased() == "y" else {
        print("Cancelled.")
        exit(ExitCode.ok.rawValue)
    }

    let engineQueue = DispatchQueue(label: "com.systemaudiorecorder.cli.calibration")
    let semaphore = DispatchSemaphore(value: 0)
    var finalResult: Result<CalibrationProfile, Error>?
    CalibrationService.runCalibration(deviceUID: uid, engineQueue: engineQueue) { result in
        finalResult = result
        semaphore.signal()
    }
    semaphore.wait()

    switch finalResult {
    case .some(.success(let profile)):
        print("Calibration complete: gainCompensationDB = \(profile.gainCompensationDB)")
        exit(ExitCode.ok.rawValue)
    case .some(.failure(let error)):
        fail(.captureError, "Calibration failed: \(error)")
    case .none:
        fail(.captureError, "Calibration failed: unknown error")
    }
}

// MARK: entry point

Log.start()
Log.info("System Audio Recorder launched (CLI): \(CommandLine.arguments.dropFirst().joined(separator: " "))")

let allArgs = Array(CommandLine.arguments.dropFirst())
guard let verb = allArgs.first else {
    fail(.usage, "usage: systemaudiorecorder <record|devices|apps|calibrate> [options]")
}
let rest = Array(allArgs.dropFirst())
let parser = ArgParser(rest)

switch verb {
case "record": runRecord(parser)
case "devices": runDevices(parser)
case "apps": runApps(parser)
case "calibrate": runCalibrate(parser)
default:
    fail(.usage, "Unknown verb '\(verb)'. usage: systemaudiorecorder <record|devices|apps|calibrate> [options]")
}
