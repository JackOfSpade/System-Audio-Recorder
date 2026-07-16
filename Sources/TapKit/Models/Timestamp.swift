import Foundation

/// ISO-8601 with milliseconds + timezone offset — the one timestamp format
/// used for log lines, calibration `measuredAt` fields, and CLI stderr.
public enum Timestamp {
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
