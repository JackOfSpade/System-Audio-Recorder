import Foundation
import CoreAudio

/// A recording is fully described by a `SessionSpec` (DESIGN.md Section 3.4–3.5).
/// `CaptureEngine` consumes this to compute the lane plan (Section 4.6).
public struct SessionSpec: Sendable {
    public var source: SourceModel
    public var device: DevicePolicy
    public var tapConfig: TapConfig
    public var timelinePolicy: TimelinePolicy

    public init(
        source: SourceModel,
        device: DevicePolicy = .followSystemDefault,
        tapConfig: TapConfig = TapConfig(),
        timelinePolicy: TimelinePolicy = .preserveWallClock
    ) {
        self.source = source
        self.device = device
        self.tapConfig = tapConfig
        self.timelinePolicy = timelinePolicy
    }
}

/// One process selector: a bundle id (preferred — survives relaunch) or a raw
/// PID (for processes without bundle ids).
public enum AppSelector: Sendable, Hashable {
    case bundleID(String)
    case pid(pid_t)
}

public enum SourceModel: Sendable {
    /// Global tap of everything the Mac plays, minus an exclusion list.
    /// The exclusion list ALWAYS gets TapDeck's own PID appended by
    /// `CaptureEngine` before building the lane plan (Section 3.4).
    case systemMix(excludeBundleIDs: [String])

    /// One or more chosen apps. `multiTrack == false` -> one mixed lane;
    /// `multiTrack == true` -> one lane per app (Section 4.6).
    case appSet(apps: [AppSelector], multiTrack: Bool)
}

public enum DevicePolicy: Sendable {
    case followSystemDefault
    case fixed(deviceUID: String)
}

/// Default is a stereo mixdown; `matchDeviceLayout` is the advanced unmixed
/// mode (Section 3.4, Section 11 R6 — verify hands-on).
public struct TapConfig: Sendable {
    public var matchDeviceLayout: Bool
    public var muteBehavior: MuteBehavior

    public init(matchDeviceLayout: Bool = false, muteBehavior: MuteBehavior = .unmuted) {
        self.matchDeviceLayout = matchDeviceLayout
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

/// The lane plan computed from a `SessionSpec.source` (Section 4.6).
public struct LanePlan: Sendable {
    public struct LaneDescriptor: Sendable {
        public let index: Int
        public let slug: String
        public let kind: LaneKind
        /// Selectors this lane's CATapDescription should target. Empty for
        /// system-mix lanes (the tap is built from exclusions, not inclusions).
        public let apps: [AppSelector]
        public let excludeBundleIDs: [String]
    }

    public enum LaneKind: String, Sendable {
        case mix
        case app
    }

    public let lanes: [LaneDescriptor]
}

public enum SessionSpecPlanner {
    /// Computes the lane plan per Section 4.6:
    /// - .systemMix -> exactly one lane, slug "mix".
    /// - .appSet(multiTrack: false) -> exactly one lane, slug "mix".
    /// - .appSet(multiTrack: true) -> one lane per app.
    public static func lanePlan(for spec: SessionSpec, ownPID: pid_t) -> LanePlan {
        switch spec.source {
        case .systemMix(let excludeBundleIDs):
            let descriptor = LanePlan.LaneDescriptor(
                index: 0,
                slug: "mix",
                kind: .mix,
                apps: [],
                excludeBundleIDs: excludeBundleIDs
            )
            return LanePlan(lanes: [descriptor])

        case .appSet(let apps, let multiTrack):
            if !multiTrack {
                let descriptor = LanePlan.LaneDescriptor(
                    index: 0,
                    slug: "mix",
                    kind: .mix,
                    apps: apps,
                    excludeBundleIDs: []
                )
                return LanePlan(lanes: [descriptor])
            } else {
                // Disambiguate against the GLOBAL set of already-assigned
                // slugs, not just a per-baseSlug counter — otherwise one
                // app's own literal base slug can coincide with another
                // app's collision-numbered slug (e.g. base slugs "slack-2"
                // and "slack" appearing twice both produce "slack-2"),
                // silently pointing two lanes at the same directory.
                var usedSlugs: Set<String> = []
                var descriptors: [LanePlan.LaneDescriptor] = []
                for (i, app) in apps.enumerated() {
                    let baseSlug = LaneSlug.slug(for: app)
                    var candidate = baseSlug
                    var suffix = 2
                    while usedSlugs.contains(candidate) {
                        candidate = "\(baseSlug)-\(suffix)"
                        suffix += 1
                    }
                    usedSlugs.insert(candidate)
                    descriptors.append(
                        LanePlan.LaneDescriptor(
                            index: i,
                            slug: candidate,
                            kind: .app,
                            apps: [app],
                            excludeBundleIDs: []
                        )
                    )
                }
                return LanePlan(lanes: descriptors)
            }
        }
    }
}

/// Lane slug derivation (Section 6.3): the app's bundle-id short name (last
/// dot-component, lowercased), or the process name for PID-only selectors,
/// or "mix" for system-mix / mixed lanes.
public enum LaneSlug {
    public static func slug(for selector: AppSelector) -> String {
        switch selector {
        case .bundleID(let bundleID):
            let lastComponent = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            return sanitize(lastComponent.lowercased())
        case .pid(let pid):
            return "pid\(pid)"
        }
    }

    private static func sanitize(_ s: String) -> String {
        let mapped = s.map { c -> Character in
            (c.isLetter || c.isNumber) ? c : "-"
        }
        return String(mapped)
    }
}
