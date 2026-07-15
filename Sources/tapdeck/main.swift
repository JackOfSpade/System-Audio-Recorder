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

    /// Like `value`, but collects every occurrence (used for repeatable
    /// flags like `--app`) — a dangling trailing occurrence with no value
    /// still fails loudly rather than being silently dropped.
    func values(_ name: String) -> [String] {
        var result: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == name {
                guard i + 1 < args.count else {
                    fail(.usage, "\(name) requires a value.")
                }
                result.append(args[i + 1])
                i += 2
            } else {
                i += 1
            }
        }
        return result
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
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/TapDeck")
}

// MARK: record

func runRecord(_ parser: ArgParser) -> Never {
    let permission = PermissionBroker.requestCapturePermission()
    guard permission == .granted else {
        fail(.permissionDenied, "System audio capture permission was not granted. Open System Settings > Privacy & Security > Screen & System Audio Recording.")
    }

    let appBundleIDs = parser.values("--app")
    let multiTrack = parser.flag("--multitrack")
    if multiTrack && appBundleIDs.count < 2 {
        fail(.usage, "--multitrack requires >= 2 --app values.")
    }
    if parser.flag("--system") && !appBundleIDs.isEmpty {
        // Previously --system silently won and --app was discarded with no
        // warning — the user's app selection had no effect whatsoever.
        fail(.usage, "--system and --app are mutually exclusive: --system records the full unfiltered mix, --app restricts to specific processes. Pass only one.")
    }

    let source: SourceModel
    if parser.flag("--system") || appBundleIDs.isEmpty {
        source = .systemMix(excludeBundleIDs: [])
    } else {
        source = .appSet(apps: appBundleIDs.map { .bundleID($0) }, multiTrack: multiTrack)
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

    let spec = SessionSpec(source: source, device: device)
    let engine = CaptureEngine(recordingsRoot: recordingsRoot(from: parser))

    let startSemaphore = DispatchSemaphore(value: 0)
    var sessionFolder: URL?
    var startError: Error?
    engine.start(spec: spec) { result in
        switch result {
        case .success(let folder): sessionFolder = folder
        case .failure(let error): startError = error
        }
        startSemaphore.signal()
    }
    startSemaphore.wait()

    if let startError {
        fail(.captureError, "Failed to start recording: \(startError)")
    }
    guard let sessionFolder else {
        fail(.captureError, "Failed to start recording: unknown error")
    }
    stderrLine("[\(ManifestTimestamp.now())] Recording started: \(sessionFolder.path)")

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
    let signalQueue = DispatchQueue(label: "com.tapdeck.cli.signal")
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
    sigintSource.setEventHandler {
        stderrLine("[\(ManifestTimestamp.now())] Ctrl-C received, finalizing…")
        requestStop()
    }
    sigintSource.resume()
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
    sigtermSource.setEventHandler {
        stderrLine("[\(ManifestTimestamp.now())] SIGTERM received, finalizing…")
        requestStop()
    }
    sigtermSource.resume()

    let deadline = durationSeconds.map { Date().addingTimeInterval($0) }
    var silenceStartedAt: Date?

    while true {
        Thread.sleep(forTimeInterval: 0.2)
        stopLock.lock(); let stop = shouldStop; stopLock.unlock()
        if stop { break }
        if let deadline, Date() >= deadline {
            stderrLine("[\(ManifestTimestamp.now())] --duration elapsed, finalizing…")
            break
        }
        if let maxSilenceStopSeconds {
            // Digital silence counts only while every lane has a real meter
            // snapshot AND its watchdog is NOT actively handling a confirmed
            // Bug-B dropout — during recovery the zeros are the OS bug, not
            // real silence, and stopping would cut off an in-flight rebuild
            // (Section 3.8). `meterSnapshots()`/`watchdogStates()` are
            // index-aligned per lane (nil means "no snapshot yet", e.g.
            // still preparing) — a missing snapshot blocks the stop rather
            // than being silently skipped, which previously could misalign
            // this zip against the wrong lane's watchdog state entirely.
            let snapshots = engine.meterSnapshots()
            let states = engine.watchdogStates()
            let genuinelySilent = !snapshots.isEmpty && zip(snapshots, states).allSatisfy { snapshot, state in
                guard let snapshot else { return false }
                return snapshot.zeroRunSeconds > 0 && ![.confirmedDropout, .rebuilding, .postRebuildVerify].contains(state)
            }
            if genuinelySilent {
                if silenceStartedAt == nil { silenceStartedAt = Date() }
                if let started = silenceStartedAt, Date().timeIntervalSince(started) >= maxSilenceStopSeconds {
                    stderrLine("[\(ManifestTimestamp.now())] --max-silence-stop threshold reached, finalizing…")
                    break
                }
            } else {
                silenceStartedAt = nil
            }
        }
    }

    let stopSemaphore = DispatchSemaphore(value: 0)
    engine.stop { _ in stopSemaphore.signal() }
    stopSemaphore.wait()

    // SessionStore.writeManifest only logs failures internally; the only
    // externally observable signal of a disk error at finalize time is the
    // manifest never having been marked finalizedAt (Section 6.4).
    let manifestURL = sessionFolder.appendingPathComponent("session.json")
    if let data = try? Data(contentsOf: manifestURL),
       let finalManifest = try? JSONDecoder().decode(SessionManifest.self, from: data),
       finalManifest.session.finalizedAt == nil {
        fail(.diskError, "Recording captured, but the session could not be finalized on disk (\(sessionFolder.path)). Check available disk space.")
    }

    print(sessionFolder.path)
    exit(ExitCode.ok.rawValue)
}

// MARK: devices / apps / sessions

func runDevices(_ parser: ArgParser) -> Never {
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

func runSessions(_ parser: ArgParser) -> Never {
    let json = parser.flag("--json")
    let store = SessionStore(recordingsRoot: recordingsRoot(from: parser))
    store.runCrashRecoveryScan()
    let summaries = store.listSessions()
    struct Row: Codable { let path: String; let date: String; let source: String; let hadDropouts: Bool; let hadGaps: Bool; let recovered: Bool }
    let rows = summaries.map { s -> Row in
        let events = s.manifest.lanes.flatMap { $0.events }
        return Row(
            path: s.folderURL.path,
            date: s.manifest.session.createdAt,
            source: s.manifest.session.sourceType,
            hadDropouts: events.contains { $0.type == .zeroDropoutRebuild },
            hadGaps: events.contains { $0.type == .overrunGap },
            recovered: s.manifest.session.recovered ?? false
        )
    }
    if json {
        if let data = try? JSONEncoder().encode(rows), let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } else {
        for r in rows {
            var badges: [String] = []
            if r.recovered { badges.append("Recovered") }
            if r.hadDropouts { badges.append("Had dropouts") }
            if r.hadGaps { badges.append("Had gaps") }
            let badgeStr = badges.isEmpty ? "" : " [\(badges.joined(separator: ", "))]"
            print("\(r.date)\t\(r.source)\t\(r.path)\(badgeStr)")
        }
    }
    exit(ExitCode.ok.rawValue)
}

// MARK: export

func runExport(_ args: [String]) -> Never {
    guard args.count >= 1 else {
        fail(.usage, "usage: tapdeck export <session-path> --format flac16|flac24|alac16|alac24|aac|wav24 [--compensate-gain on|off] [--out <dir>]")
    }
    let sessionPath = args[0]
    let parser = ArgParser(Array(args.dropFirst()))
    guard let formatStr = parser.value("--format"), let format = ExportFormat(rawValue: formatStr) else {
        fail(.usage, "Missing or invalid --format. Choose one of: \(ExportFormat.allCases.map(\.rawValue).joined(separator: ", "))")
    }

    let sessionFolder = URL(fileURLWithPath: sessionPath)
    let store = SessionStore(recordingsRoot: sessionFolder.deletingLastPathComponent())
    guard let manifest = try? store.readManifest(from: sessionFolder) else {
        fail(.notFound, "Could not read session.json at \(sessionPath)")
    }

    let outDir = parser.value("--out").map { URL(fileURLWithPath: $0) } ?? sessionFolder.appendingPathComponent("exports")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let compensateFlag = parser.value("--compensate-gain")
    if let compensateFlag, compensateFlag != "on", compensateFlag != "off" {
        // Previously any string other than the exact literal "on" was
        // silently treated as "off" — a typo or different casing (e.g.
        // "On", "true") would silently skip gain compensation with no
        // warning at all.
        fail(.usage, "Invalid --compensate-gain value: '\(compensateFlag)'. Expected 'on' or 'off'.")
    }

    var anyFailure = false
    for lane in manifest.lanes {
        let hasProfile = lane.calibration != nil
        let compensate = compensateFlag.map { $0 == "on" } ?? hasProfile
        let gainDB = compensate ? lane.calibration?.gainCompensationDB : nil

        for segment in lane.segments {
            let masterURL = sessionFolder.appendingPathComponent(segment.file)
            let ext: String
            switch format {
            case .flac16, .flac24: ext = "flac"
            case .alac16, .alac24, .aac: ext = "m4a"
            case .wav24: ext = "wav"
            }
            let destURL = outDir.appendingPathComponent(lane.slug).appendingPathComponent(masterURL.deletingPathExtension().lastPathComponent + ".\(ext)")
            try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                let result = try ExportService.export(masterURL: masterURL, to: destURL, format: format, gainCompensationDB: gainDB)
                print(result.url.path)
                if result.clippedSampleCount > 0 {
                    stderrLine("Warning: \(result.clippedSampleCount) samples clipped in \(result.url.lastPathComponent)")
                }
            } catch {
                stderrLine("Export failed for \(masterURL.path): \(error)")
                anyFailure = true
            }
        }
    }
    exit(anyFailure ? ExitCode.captureError.rawValue : ExitCode.ok.rawValue)
}

// MARK: calibrate

func runCalibrate(_ parser: ArgParser) -> Never {
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

    print("TapDeck will play a 5-second test tone through \(name). Continue? [y/N]", terminator: " ")
    guard let answer = readLine(), answer.lowercased() == "y" else {
        print("Cancelled.")
        exit(ExitCode.ok.rawValue)
    }

    let engineQueue = DispatchQueue(label: "com.tapdeck.cli.calibration")
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

let allArgs = Array(CommandLine.arguments.dropFirst())
guard let verb = allArgs.first else {
    fail(.usage, "usage: tapdeck <record|devices|apps|sessions|export|calibrate> [options]")
}
let rest = Array(allArgs.dropFirst())
let parser = ArgParser(rest)

switch verb {
case "record": runRecord(parser)
case "devices": runDevices(parser)
case "apps": runApps(parser)
case "sessions": runSessions(parser)
case "export": runExport(rest)
case "calibrate": runCalibrate(parser)
default:
    fail(.usage, "Unknown verb '\(verb)'. usage: tapdeck <record|devices|apps|sessions|export|calibrate> [options]")
}
