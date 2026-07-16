import Foundation

/// Single-file debug log, shared by the GUI and CLI processes (same
/// directory as `CalibrationService`'s `calibration.json`). Exactly one file,
/// truncated at the start of every process launch — call `Log.start()` once,
/// as early as possible, from each entry point (GUI: `AppDelegate
/// .applicationDidFinishLaunching`; CLI: top of `main.swift`). Every other
/// call site appends a timestamped line; nothing here ever rotates or keeps
/// history beyond the current run.
public enum Log {
    private static let queue = DispatchQueue(label: "com.systemaudiorecorder.log")
    private static var fileHandle: FileHandle?

    public static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("System Audio Recorder").appendingPathComponent("debug.log")
    }

    /// Truncates (or creates) the single log file. Must be called exactly
    /// once per process launch, before any other `Log.*` call, or those
    /// calls silently no-op (falling back to stderr only).
    public static func start() {
        queue.sync {
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: fileURL)
        }
    }

    public static func info(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        write(level: "INFO", message: message(), file: file, line: line)
    }

    public static func error(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        write(level: "ERROR", message: message(), file: file, line: line)
    }

    private static func write(level: String, message: String, file: String, line: Int) {
        let entry = "\(ManifestTimestamp.now()) [\(level)] \(file):\(line) \(message)\n"
        guard let data = entry.data(using: .utf8) else { return }
        queue.sync {
            guard let fileHandle else { return } // start() was never called
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        }
        FileHandle.standardError.write(data)
    }
}
