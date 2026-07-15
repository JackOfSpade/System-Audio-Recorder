import Darwin
import Foundation

// MARK: Shell hooks (Section 3.11)

public enum HookEvent: String {
    case onSessionStart
    case onSegmentClose
    case onSessionFinalize
}

public struct HookConfiguration: Sendable {
    public var onSessionStart: String?
    public var onSegmentClose: String?
    public var onSessionFinalize: String?

    public init(onSessionStart: String? = nil, onSegmentClose: String? = nil, onSessionFinalize: String? = nil) {
        self.onSessionStart = onSessionStart
        self.onSegmentClose = onSegmentClose
        self.onSessionFinalize = onSessionFinalize
    }
}

/// Runs the three optional hook commands non-blocking, with a 30 s timeout;
/// stdout/stderr captured to the app log (Section 3.11). Hooks never block
/// or fail the capture pipeline.
public enum HookRunner {
    private static let timeoutSeconds: TimeInterval = 30

    public static func run(_ event: HookEvent, command: String?, sessionPath: String, segmentPath: String? = nil) {
        guard let command, !command.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]

            var env = ProcessInfo.processInfo.environment
            env["TAPDECK_SESSION_PATH"] = sessionPath
            env["TAPDECK_EVENT"] = event.rawValue
            if let segmentPath {
                env["TAPDECK_SEGMENT_PATH"] = segmentPath
            }
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Drain both pipes continuously WHILE the process runs. A pipe's
            // kernel buffer is only a few tens of KB; a hook that writes
            // more than that before anyone reads blocks in write(2) until
            // drained. Reading only after the process exits (the previous
            // approach) means a chatty hook deadlocks against its own full
            // pipe and looks exactly like a genuinely hung hook — it then
            // gets killed by the timeout below despite making fine progress.
            let outBuffer = PipeBuffer()
            let errBuffer = PipeBuffer()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { outBuffer.append(data) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { errBuffer.append(data) }
            }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                FileHandle.standardError.write("TapDeck: hook \(event.rawValue) failed to launch: \(error)\n".data(using: .utf8)!)
                return
            }

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                process.terminate()
                FileHandle.standardError.write("TapDeck: hook \(event.rawValue) timed out after \(Int(timeoutSeconds))s; killed.\n".data(using: .utf8)!)
            }

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            // One final drain for any bytes written between the handler's
            // last firing and process exit — NOT `readDataToEndOfFile()`,
            // which blocks until every writer of the pipe closes it. If the
            // hook's shell command spawned a background/detached child that
            // inherited these fds (e.g. `some-daemon &`), that grandchild
            // can keep the write end open indefinitely even after
            // `process.terminate()` kills the immediate child, parking this
            // thread-pool worker thread forever. A non-blocking drain either
            // returns real EOF (0) or EAGAIN (nothing available right now)
            // instead of waiting for a write end we don't control.
            drainNonBlocking(outPipe.fileHandleForReading, into: outBuffer)
            drainNonBlocking(errPipe.fileHandleForReading, into: errBuffer)

            if let out = String(data: outBuffer.data, encoding: .utf8), !out.isEmpty {
                FileHandle.standardError.write("TapDeck: hook \(event.rawValue) stdout: \(out)\n".data(using: .utf8)!)
            }
            if let err = String(data: errBuffer.data, encoding: .utf8), !err.isEmpty {
                FileHandle.standardError.write("TapDeck: hook \(event.rawValue) stderr: \(err)\n".data(using: .utf8)!)
            }
        }
    }

    /// Reads whatever is immediately available on `handle` without ever
    /// blocking indefinitely: switches the fd to O_NONBLOCK, then loops
    /// `read(2)` until it returns 0 (true EOF — every writer closed) or a
    /// negative value (EAGAIN/EWOULDBLOCK — no more data right now, but the
    /// fd may still be held open by something we don't control). Either way
    /// this always returns instead of parking the calling thread forever.
    private static func drainNonBlocking(_ handle: FileHandle, into buffer: PipeBuffer) {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags != -1 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, raw.count)
            }
            guard n > 0 else { break }
            buffer.append(Data(chunk[0..<n]))
        }
    }
}

/// Thread-safe accumulator for `HookRunner`'s pipe-draining `readabilityHandler`
/// callbacks, which fire on a private dispatch queue distinct from the
/// hook-monitoring thread that also appends a trailing read after teardown.
private final class PipeBuffer: @unchecked Sendable {
    private var storage = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: Triggers (Section 3.12)

public struct ScheduleRule: Sendable, Identifiable, Codable {
    public let id: UUID
    public var hour: Int
    public var minute: Int
    public var durationSeconds: TimeInterval
    /// 1 = Sunday ... 7 = Saturday (Calendar.Component.weekday convention);
    /// empty = one-shot (fires once, then the caller should disable it).
    public var weekdays: Set<Int>
    public var spec: SessionSpecCodable

    public init(id: UUID = UUID(), hour: Int, minute: Int, durationSeconds: TimeInterval, weekdays: Set<Int>, spec: SessionSpecCodable) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.durationSeconds = durationSeconds
        self.weekdays = weekdays
        self.spec = spec
    }
}

/// A `Codable` wire form of `SessionSpec` (which itself isn't Codable, since
/// it's a plain value type designed for in-process use). Recording is always
/// a global system-mix tap; the only per-rule knob is the exclusion list.
public struct SessionSpecCodable: Sendable, Codable {
    public var excludeBundleIDs: [String]

    public init(excludeBundleIDs: [String] = []) {
        self.excludeBundleIDs = excludeBundleIDs
    }

    public func toSessionSpec() -> SessionSpec {
        SessionSpec(excludeBundleIDs: excludeBundleIDs)
    }
}

public protocol TriggerEngineDelegate: AnyObject {
    /// Returns true if a recording is already running (Section 3.12: a rule
    /// firing while busy is skipped with a notification, not queued).
    func triggerEngineIsRecording(_ engine: TriggerEngine) -> Bool
    func triggerEngine(_ engine: TriggerEngine, requestsStart spec: SessionSpec, reason: String)
    func triggerEngine(_ engine: TriggerEngine, requestsStopAfter duration: TimeInterval)
    func triggerEngine(_ engine: TriggerEngine, skippedTriggerNamed name: String)
    /// A schedule rule reached its fire time (whether or not it actually
    /// started a recording — it may have been skipped because one was
    /// already running). `isOneShot` mirrors `ScheduleRule.weekdays.isEmpty`;
    /// when true, the caller MUST remove this rule (by id) from what it
    /// next passes to `setScheduleRules`, or it will fire again at the same
    /// hour:minute every day from now on — `TriggerEngine` itself has no
    /// way to permanently retire a rule, only to suppress it for the rest
    /// of the day it already fired on.
    func triggerEngine(_ engine: TriggerEngine, didFireScheduleRule ruleID: UUID, isOneShot: Bool)
}

/// Schedule rules and app-activity auto-record (Section 3.12), executed on a
/// dedicated queue. `ProcessCatalog` is shared with the rest of the engine
/// so armed-trigger polling participates in the same 1 Hz reference-counted
/// controller (Section 4.2).
public final class TriggerEngine {
    public weak var delegate: TriggerEngineDelegate?
    private let processCatalog: ProcessCatalog
    private let queue = DispatchQueue(label: "com.tapdeck.triggerengine")

    private var scheduleRules: [ScheduleRule] = []
    private var scheduleTimer: DispatchSourceTimer?
    /// Per-rule "already fired today" marker, keyed by calendar day
    /// (year/month/day) — a rule fires AT MOST once per day, whenever it
    /// first becomes due within `scheduleCatchupWindow`. Keying by day
    /// (rather than the exact wall-clock minute) does double duty: (1) DST
    /// fall-back replays the same hour:minute twice on one real calendar
    /// day, and a per-day key recognizes the second pass as already
    /// handled without needing a separate check; (2) it's what makes the
    /// catch-up window itself safe — a rule can become due anywhere inside
    /// that window and still only fire once.
    private var lastFiredKey: [UUID: String] = [:]
    /// A 30s poll can occasionally skip a beat (system sleep/wake,
    /// scheduling jitter under load) and next observe the clock a minute or
    /// two past a rule's scheduled time. Without any tolerance, requiring
    /// EXACT equality between the observed minute and the rule's hour:minute
    /// means that single missed tick permanently loses the rule for the
    /// whole day. This window bounds how late a catch-up fire is allowed to
    /// be — long enough to absorb ordinary jitter, short enough that waking
    /// from a multi-hour sleep doesn't fire an hours-late, pointless
    /// recording.
    private static let scheduleCatchupWindow: TimeInterval = 5 * 60

    /// Armed app-activity triggers: bundle id -> hangTime seconds.
    private var armedApps: [String: TimeInterval] = [:]
    private var armedAppLastSeenOutputting: [String: Date] = [:]
    private var armedAppCurrentlyRecording: Set<String> = []
    private static let pollReasonTriggers = "triggers-armed"

    public init(processCatalog: ProcessCatalog) {
        self.processCatalog = processCatalog
    }

    // MARK: Schedule rules

    public func setScheduleRules(_ rules: [ScheduleRule]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.scheduleRules = rules
            let liveIDs = Set(rules.map(\.id))
            self.lastFiredKey = self.lastFiredKey.filter { liveIDs.contains($0.key) }
            self.restartScheduleTimer()
        }
    }

    private func restartScheduleTimer() {
        scheduleTimer?.cancel()
        guard !scheduleRules.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 30) // check every 30s for due rules
        timer.setEventHandler { [weak self] in self?.checkScheduleRules() }
        timer.resume()
        scheduleTimer = timer
    }

    private func checkScheduleRules() {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        guard let year = components.year, let month = components.month, let day = components.day,
              let weekday = components.weekday else { return }

        let fireKey = "\(year)-\(month)-\(day)"
        for rule in scheduleRules {
            if !rule.weekdays.isEmpty, !rule.weekdays.contains(weekday) { continue }
            guard lastFiredKey[rule.id] != fireKey else { continue } // already fired today

            var scheduledComponents = DateComponents()
            scheduledComponents.year = year
            scheduledComponents.month = month
            scheduledComponents.day = day
            scheduledComponents.hour = rule.hour
            scheduledComponents.minute = rule.minute
            guard let scheduledDate = calendar.date(from: scheduledComponents) else { continue }

            let secondsPastDue = now.timeIntervalSince(scheduledDate)
            guard secondsPastDue >= 0, secondsPastDue <= Self.scheduleCatchupWindow else { continue }
            lastFiredKey[rule.id] = fireKey

            // One-shot rules (empty weekdays) fire exactly once, ever — but
            // TriggerEngine only knows "today," not "forever," so the
            // delegate has to be the one to permanently retire it.
            let isOneShot = rule.weekdays.isEmpty
            delegate?.triggerEngine(self, didFireScheduleRule: rule.id, isOneShot: isOneShot)

            if delegate?.triggerEngineIsRecording(self) == true {
                delegate?.triggerEngine(self, skippedTriggerNamed: "schedule-\(rule.id)")
                continue
            }
            delegate?.triggerEngine(self, requestsStart: rule.spec.toSessionSpec(), reason: "schedule")
            delegate?.triggerEngine(self, requestsStopAfter: rule.durationSeconds)
        }
    }

    // MARK: App-activity auto-record

    public func armApp(_ bundleID: String, hangTime: TimeInterval = 10) {
        queue.async { [weak self] in
            guard let self else { return }
            let wasEmpty = self.armedApps.isEmpty
            self.armedApps[bundleID] = hangTime
            if wasEmpty {
                self.processCatalog.addPollingReason(Self.pollReasonTriggers)
                self.processCatalog.setPollHandler { [weak self] processes in
                    self?.handlePoll(processes)
                }
            }
        }
    }

    public func disarmApp(_ bundleID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            // If this app-activity trigger is the one currently recording,
            // disarming it must stop that recording — previously this only
            // cleared TriggerEngine's own bookkeeping, leaving the delegate
            // with no signal to stop, so the recording kept running
            // indefinitely (until some unrelated event happened to end it).
            let wasRecording = self.armedAppCurrentlyRecording.contains(bundleID)
            self.armedApps.removeValue(forKey: bundleID)
            self.armedAppLastSeenOutputting.removeValue(forKey: bundleID)
            self.armedAppCurrentlyRecording.remove(bundleID)
            if self.armedApps.isEmpty {
                self.processCatalog.removePollingReason(Self.pollReasonTriggers)
            }
            if wasRecording {
                self.delegate?.triggerEngine(self, requestsStopAfter: 0)
            }
        }
    }

    private func handlePoll(_ processes: [AudioProcessInfo]) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            for (bundleID, hangTime) in self.armedApps {
                let isOutputting = processes.contains { $0.bundleID == bundleID && $0.isRunningOutput }
                if isOutputting {
                    self.armedAppLastSeenOutputting[bundleID] = now
                    if !self.armedAppCurrentlyRecording.contains(bundleID) {
                        if self.delegate?.triggerEngineIsRecording(self) == true {
                            self.delegate?.triggerEngine(self, skippedTriggerNamed: "app-\(bundleID)")
                            continue
                        }
                        self.armedAppCurrentlyRecording.insert(bundleID)
                        // Recording is always the global system mix now — an
                        // armed app is just what starts/stops it, not what's
                        // isolated within it.
                        let spec = SessionSpec()
                        self.delegate?.triggerEngine(self, requestsStart: spec, reason: "app-activity:\(bundleID)")
                    }
                } else if self.armedAppCurrentlyRecording.contains(bundleID) {
                    let lastSeen = self.armedAppLastSeenOutputting[bundleID] ?? now
                    if now.timeIntervalSince(lastSeen) >= hangTime {
                        self.armedAppCurrentlyRecording.remove(bundleID)
                        self.delegate?.triggerEngine(self, requestsStopAfter: 0)
                    }
                }
            }
        }
    }
}
