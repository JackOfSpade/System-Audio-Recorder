import Foundation
import CoreAudio

/// A recording is fully described by a `SessionSpec` (DESIGN.md Section 3.4–3.5).
/// `CaptureEngine` consumes this to build the single capture lane.
public struct SessionSpec: Sendable {
    /// Bundle ids excluded from the global system-mix tap. System Audio Recorder's own PID
    /// is ALWAYS appended by `CaptureEngine` before building the tap,
    /// regardless of this list (Section 3.4).
    public var excludeBundleIDs: [String]
    public var device: DevicePolicy
    public var muteBehavior: MuteBehavior
    public var timelinePolicy: TimelinePolicy

    public init(
        excludeBundleIDs: [String] = [],
        device: DevicePolicy = .followSystemDefault,
        muteBehavior: MuteBehavior = .unmuted,
        timelinePolicy: TimelinePolicy = .preserveWallClock
    ) {
        self.excludeBundleIDs = excludeBundleIDs
        self.device = device
        self.muteBehavior = muteBehavior
        self.timelinePolicy = timelinePolicy
    }
}

public enum DevicePolicy: Sendable {
    case followSystemDefault
    case fixed(deviceUID: String)
}

public enum MuteBehavior: Sendable {
    case unmuted
    case mutedWhenTapped
}

public enum TimelinePolicy: String, Sendable, Codable {
    case preserveWallClock
    case compressTimeline
}
