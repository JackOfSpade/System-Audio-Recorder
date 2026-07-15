import CoreAudio
import Foundation

public struct AudioProcessInfo: Sendable, Identifiable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningOutput: Bool

    public var id: AudioObjectID { objectID }
}

/// Enumerates audio-capable processes via `kAudioHardwarePropertyProcessObjectList`,
/// translates PID -> process `AudioObjectID` via
/// `kAudioHardwarePropertyTranslatePIDToProcessObject`, and reads per-process
/// `kAudioProcessPropertyBundleID`/`PID`/`IsRunningOutput` (Section 4.2).
///
/// Polls at 1 Hz only while (a) a picker UI is visible, (b) triggers are
/// armed, or (c) any lane's watchdog is in a non-NORMAL state (Section 4.2,
/// Section 8.1). Multiple simultaneous reasons are tracked by a reference
/// count so any one of them keeps polling alive.
public final class ProcessCatalog {
    private let engineQueue: DispatchQueue
    private var pollTimer: DispatchSourceTimer?
    private var activeReasons: Set<String> = []
    private var onPoll: (([AudioProcessInfo]) -> Void)?

    public init(engineQueue: DispatchQueue) {
        self.engineQueue = engineQueue
    }

    /// Installs the poll callback, serialized on `engineQueue` — the same
    /// queue the polling timer fires `onPoll` from. A caller setting this
    /// property directly from its own queue would race the timer's read of
    /// `onPoll` (a plain, unsynchronized closure property) on every 1 Hz
    /// tick; funneling the write through `engineQueue.async` makes every
    /// access to `onPoll` happen on the same queue.
    public func setPollHandler(_ handler: (([AudioProcessInfo]) -> Void)?) {
        engineQueue.async { [weak self] in
            self?.onPoll = handler
        }
    }

    // MARK: One-shot enumeration (engine queue)

    public static func allProcesses() throws -> [AudioProcessInfo] {
        let ids = try CAProp.readObjectIDArray(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList,
            context: "kAudioHardwarePropertyProcessObjectList"
        )
        return ids.compactMap { try? processInfo(for: $0) }
    }

    public static func processInfo(for objectID: AudioObjectID) throws -> AudioProcessInfo {
        let pid = try CAProp.readFixed(objectID, kAudioProcessPropertyPID, as: pid_t.self, context: "kAudioProcessPropertyPID")
        let bundleID = try? CAProp.readString(objectID, kAudioProcessPropertyBundleID, context: "kAudioProcessPropertyBundleID")
        let isRunningRaw = (try? CAProp.readFixed(objectID, kAudioProcessPropertyIsRunningOutput, as: UInt32.self, context: "kAudioProcessPropertyIsRunningOutput")) ?? 0
        return AudioProcessInfo(objectID: objectID, pid: pid, bundleID: bundleID, isRunningOutput: isRunningRaw != 0)
    }

    public static func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifierPID = pid
        var objectID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifierPID) { qptr -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), qptr, &size, &objectID)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "kAudioHardwarePropertyTranslatePIDToProcessObject")
        }
        return objectID
    }

    /// Resolves a bundle id (Section 3.4 exclusion list) to a process
    /// `AudioObjectID`, matching across all currently running audio processes.
    public static func resolveBundleID(_ bundleID: String) -> AudioObjectID? {
        guard let processes = try? allProcesses() else { return nil }
        return processes.first { $0.bundleID == bundleID }?.objectID
    }

    /// "Is any relevant process currently outputting audio?" (Section 8.1
    /// corroboration signal). `excludingPIDs` covers TapDeck's own PID and
    /// any system-mix exclusion list.
    public static func isAnyRelevantProcessOutputting(excludingPIDs: Set<pid_t>) -> Bool {
        guard let processes = try? allProcesses() else { return false }
        for process in processes {
            if excludingPIDs.contains(process.pid) { continue }
            if process.isRunningOutput { return true }
        }
        return false
    }

    // MARK: 1 Hz polling controller

    /// Adds `reason` to the active set and starts polling if this is the
    /// first reason. Call again with a different reason string to add
    /// another independent keep-alive; polling stops only when every reason
    /// has been removed via `removePollingReason`.
    public func addPollingReason(_ reason: String) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            let wasEmpty = self.activeReasons.isEmpty
            self.activeReasons.insert(reason)
            if wasEmpty {
                self.startPolling()
            }
        }
    }

    public func removePollingReason(_ reason: String) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.activeReasons.remove(reason)
            if self.activeReasons.isEmpty {
                self.stopPolling()
            }
        }
    }

    private func startPolling() {
        stopPolling()
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let processes = try? Self.allProcesses() else { return }
            self.onPoll?(processes)
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }
}
