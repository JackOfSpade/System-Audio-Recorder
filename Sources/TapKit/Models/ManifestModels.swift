import Foundation

/// `session.json` schema v1, field by field (DESIGN.md Section 6.4).
/// All timestamps are ISO-8601 strings with milliseconds and timezone offset.
/// All paths are relative to the session folder, using `/` separators.

/// A minimal JSON-value box used only for the free-form `events[].details`
/// payload, whose shape varies by event type (Section 6.4). Avoids pulling in
/// a third-party "AnyCodable" dependency (Section 2.4: zero third-party deps).
public enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Double.self) { self = .number(v); return }
        if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? container.decode([JSONValue].self) { self = .array(v); return }
        if container.decodeNil() { self = .null; return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSONValue")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    public static func integer(_ v: Int) -> JSONValue { .number(Double(v)) }
}

public struct AppInfo: Codable, Sendable {
    public var name: String
    public var version: String
    public var build: String

    public init(name: String, version: String, build: String) {
        self.name = name
        self.version = version
        self.build = build
    }
}

public struct OSInfo: Codable, Sendable {
    public var version: String
    public var build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }
}

public struct DeviceRef: Codable, Sendable {
    public var uid: String
    public var name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public struct DeviceHistoryEntry: Codable, Sendable {
    public var uid: String
    public var name: String
    public var fromWallTime: String

    public init(uid: String, name: String, fromWallTime: String) {
        self.uid = uid
        self.name = name
        self.fromWallTime = fromWallTime
    }
}

public struct SessionInfo: Codable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: String
    public var finalizedAt: String?
    public var recovered: Bool?
    public var sourceType: String  // always "systemMix"
    public var device: DeviceRef
    public var deviceHistory: [DeviceHistoryEntry]
    public var timelinePolicy: String  // "preserveWallClock" | "compressTimeline"

    public init(
        id: String,
        title: String,
        createdAt: String,
        finalizedAt: String? = nil,
        recovered: Bool? = nil,
        sourceType: String,
        device: DeviceRef,
        deviceHistory: [DeviceHistoryEntry],
        timelinePolicy: String
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.finalizedAt = finalizedAt
        self.recovered = recovered
        self.sourceType = sourceType
        self.device = device
        self.deviceHistory = deviceHistory
        self.timelinePolicy = timelinePolicy
    }
}

public struct ProcessRef: Codable, Sendable {
    public var bundleId: String?
    public var pid: Int32
    public var name: String

    public init(bundleId: String?, pid: Int32, name: String) {
        self.bundleId = bundleId
        self.pid = pid
        self.name = name
    }
}

/// The Bug-A calibration profile matching a lane's current device, or nil if
/// none (Section 8.3). Master audio is NEVER modified by this value; it is
/// metadata for meters and export only.
public struct CalibrationRef: Codable, Sendable {
    public var deviceUID: String
    public var gainCompensationDB: Double
    public var measuredAt: String

    public init(deviceUID: String, gainCompensationDB: Double, measuredAt: String) {
        self.deviceUID = deviceUID
        self.gainCompensationDB = gainCompensationDB
        self.measuredAt = measuredAt
    }
}

public struct SegmentEntry: Codable, Sendable {
    public var index: Int
    public var file: String
    public var startWallTime: String
    /// mach_absolute_time ticks stored as a decimal STRING (u64 can exceed
    /// JSON's 2^53 safe-integer range) — Section 6.4.
    public var startHostTime: String
    public var sampleRate: Double
    public var channels: Int
    public var frames: Int?
    public var finalized: Bool

    public init(
        index: Int,
        file: String,
        startWallTime: String,
        startHostTime: String,
        sampleRate: Double,
        channels: Int,
        frames: Int?,
        finalized: Bool
    ) {
        self.index = index
        self.file = file
        self.startWallTime = startWallTime
        self.startHostTime = startHostTime
        self.sampleRate = sampleRate
        self.channels = channels
        self.frames = frames
        self.finalized = finalized
    }
}

public enum EventType: String, Codable, Sendable {
    case zeroDropoutRebuild
    case overrunGap
    case deviceSwitch
    case rateChange
    case waitingForDevice
    case error
}

public struct EventEntry: Codable, Sendable {
    public var type: EventType
    public var atWallTime: String
    public var framePosition: Int
    public var gapMs: Double?
    public var details: JSONValue

    public init(type: EventType, atWallTime: String, framePosition: Int, gapMs: Double?, details: JSONValue) {
        self.type = type
        self.atWallTime = atWallTime
        self.framePosition = framePosition
        self.gapMs = gapMs
        self.details = details
    }
}

public struct LaneEntry: Codable, Sendable {
    public var index: Int
    public var slug: String
    public var processes: [ProcessRef]
    public var calibration: CalibrationRef?
    public var segments: [SegmentEntry]
    public var events: [EventEntry]

    public init(
        index: Int,
        slug: String,
        processes: [ProcessRef],
        calibration: CalibrationRef?,
        segments: [SegmentEntry],
        events: [EventEntry]
    ) {
        self.index = index
        self.slug = slug
        self.processes = processes
        self.calibration = calibration
        self.segments = segments
        self.events = events
    }
}

/// Top-level `session.json` document.
public struct SessionManifest: Codable, Sendable {
    public var schemaVersion: Int
    public var app: AppInfo
    public var os: OSInfo
    public var session: SessionInfo
    public var lanes: [LaneEntry]

    public init(schemaVersion: Int = 1, app: AppInfo, os: OSInfo, session: SessionInfo, lanes: [LaneEntry]) {
        self.schemaVersion = schemaVersion
        self.app = app
        self.os = os
        self.session = session
        self.lanes = lanes
    }
}

/// ISO-8601 with milliseconds + timezone offset, per Section 6.4.
public enum ManifestTimestamp {
    public static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func now() -> String {
        formatter.string(from: Date())
    }

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
