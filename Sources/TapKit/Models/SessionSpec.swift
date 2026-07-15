import Foundation
import CoreAudio

/// A recording is fully described by a `SessionSpec` (DESIGN.md Section 3.4–3.5).
/// `CaptureEngine` consumes this to build the single capture lane.
public struct SessionSpec: Sendable {
    /// Bundle ids excluded from the global system-mix tap. TapDeck's own PID
    /// is ALWAYS appended by `CaptureEngine` before building the tap,
    /// regardless of this list (Section 3.4).
    public var excludeBundleIDs: [String]
    public var device: DevicePolicy
    public var tapConfig: TapConfig
    public var timelinePolicy: TimelinePolicy

    public init(
        excludeBundleIDs: [String] = [],
        device: DevicePolicy = .followSystemDefault,
        tapConfig: TapConfig = TapConfig(),
        timelinePolicy: TimelinePolicy = .preserveWallClock
    ) {
        self.excludeBundleIDs = excludeBundleIDs
        self.device = device
        self.tapConfig = tapConfig
        self.timelinePolicy = timelinePolicy
    }
}

public enum DevicePolicy: Sendable {
    case followSystemDefault
    case fixed(deviceUID: String)
}

public struct TapConfig: Sendable {
    public var muteBehavior: MuteBehavior

    public init(muteBehavior: MuteBehavior = .unmuted) {
        self.muteBehavior = muteBehavior
    }
}

public enum MuteBehavior: Sendable {
    case unmuted
    case mutedWhenTapped
}

public enum TimelinePolicy: String, Sendable, Codable {
    case preserveWallClock
    case compressTimeline
}
