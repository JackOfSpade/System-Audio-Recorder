import Darwin
import Foundation

public struct SessionSummary: Sendable {
    public let folderURL: URL
    public let manifest: SessionManifest
}

/// Creates session folders under the recordings root, reads/writes
/// `session.json`, maintains the library index, and runs the crash-recovery
/// scan at launch (Section 6.3–6.5).
public final class SessionStore {
    public let recordingsRoot: URL
    /// Section 6.4 "Write policy": all manifest file I/O is serialized on
    /// this dedicated serial queue — the engine queue only ever hands event
    /// records to `SessionStore`'s API, never touches the file itself.
    private let ioQueue = DispatchQueue(label: "com.tapdeck.sessionstore.io")

    public init(recordingsRoot: URL) {
        self.recordingsRoot = recordingsRoot
        try? FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
    }

    // MARK: Naming template (Section 6.3)

    public struct NamingContext {
        public let date: Date
        public let source: String
        public let app: String
        public let device: String
        public let rateHz: Double

        public init(date: Date = Date(), source: String, app: String, device: String, rateHz: Double) {
            self.date = date
            self.source = source
            self.app = app
            self.device = device
            self.rateHz = rateHz
        }
    }

    public static func expand(template: String, context: NamingContext) -> String {
        // Fixed-format dates must pin a locale, or `dateFormat`'s pattern
        // letters are reinterpreted per the user's system locale — e.g. a
        // calendar other than Gregorian can change what "yyyy" even means,
        // and some locales render digits in a non-ASCII numbering system.
        // "en_US_POSIX" is Apple's documented fixed-locale for this exact
        // case (stable, Gregorian, ASCII digits, regardless of the user's
        // actual locale).
        let fixedLocale = Locale(identifier: "en_US_POSIX")
        let dateFormatter = DateFormatter()
        dateFormatter.locale = fixedLocale
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = fixedLocale
        timeFormatter.dateFormat = "HH.mm.ss" // dots, not colons (Section 6.3)

        let rateString: String
        if context.rateHz >= 1000 {
            let khz = context.rateHz / 1000.0
            rateString = khz.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(khz))kHz"
                : String(format: "%.1fkHz", khz)
        } else {
            rateString = "\(Int(context.rateHz))Hz"
        }

        var result = template
        result = result.replacingOccurrences(of: "{date}", with: dateFormatter.string(from: context.date))
        result = result.replacingOccurrences(of: "{time}", with: timeFormatter.string(from: context.date))
        result = result.replacingOccurrences(of: "{source}", with: context.source)
        result = result.replacingOccurrences(of: "{app}", with: context.app)
        result = result.replacingOccurrences(of: "{device}", with: context.device)
        result = result.replacingOccurrences(of: "{rate}", with: rateString)
        return result
    }

    /// Section 6.3 sanitization: replace `/`, `:`, control chars with `-`;
    /// collapse whitespace runs; trim; cap at 200 bytes of UTF-8 (bytes, not
    /// characters — truncate only at a character boundary).
    public static func sanitize(_ name: String) -> String {
        var mapped = ""
        mapped.reserveCapacity(name.count)
        for c in name {
            if c == "/" || c == ":" || c.isNewline || (c.asciiValue.map { $0 < 0x20 } ?? false) {
                mapped.append("-")
            } else {
                mapped.append(c)
            }
        }
        let collapsed = mapped
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        var truncated = collapsed
        while truncated.utf8.count > 200, !truncated.isEmpty {
            truncated.removeLast()
        }
        return truncated
    }

    /// Creates the session folder, handling name collisions with " (2)", " (3)", ...
    public func createSessionFolder(title: String) throws -> URL {
        let sanitized = Self.sanitize(title)
        var candidate = recordingsRoot.appendingPathComponent(sanitized)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = recordingsRoot.appendingPathComponent("\(sanitized) (\(suffix))")
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    // MARK: Advisory lock file (Section 6.3 / 6.5)

    public func createLockFile(in folder: URL) {
        let lockURL = folder.appendingPathComponent(".recording.lock")
        let pid = ProcessInfo.processInfo.processIdentifier
        // Record our own executable path alongside the PID (Section 6.5): a
        // bare PID is not enough to prove liveness — after a crash + reboot
        // (or just enough process churn) the OS can hand that same PID to a
        // completely unrelated process, which would make `isLive` treat this
        // session as permanently in-progress and never recover it.
        let exePath = Self.currentExecutablePath() ?? ""
        try? "\(pid)\n\(exePath)".data(using: .utf8)?.write(to: lockURL, options: .atomic)
    }

    private static func currentExecutablePath() -> String? {
        executablePath(for: ProcessInfo.processInfo.processIdentifier)
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [Int8](repeating: 0, count: 4096) // 4 * MAXPATHLEN
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public func removeLockFile(in folder: URL) {
        let lockURL = folder.appendingPathComponent(".recording.lock")
        try? FileManager.default.removeItem(at: lockURL)
    }

    // MARK: Manifest I/O (Section 6.4 write policy — atomic tmp+rename)

    public func writeManifest(_ manifest: SessionManifest, to folder: URL, completion: (() -> Void)? = nil) {
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let finalURL = folder.appendingPathComponent("session.json")
            let tmpURL = folder.appendingPathComponent("session.json.tmp")
            do {
                let data = try encoder.encode(manifest)
                try data.write(to: tmpURL, options: .atomic)
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tmpURL)
            } catch {
                // Previously encode failures were swallowed by `try?` with no
                // logging at all, unlike the write/rename failure below —
                // silently dropping the entire manifest update on the floor.
                FileHandle.standardError.write("TapDeck: manifest write failed: \(error)\n".data(using: .utf8)!)
            }
            completion?()
        }
    }

    public func readManifest(from folder: URL) throws -> SessionManifest {
        let url = folder.appendingPathComponent("session.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionManifest.self, from: data)
    }

    // MARK: Library index

    public func listSessions() -> [SessionSummary] {
        guard let subfolders = try? FileManager.default.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        var summaries: [SessionSummary] = []
        for folder in subfolders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let manifest = try? readManifest(from: folder) else { continue }
            summaries.append(SessionSummary(folderURL: folder, manifest: manifest))
        }
        return summaries.sorted { $0.manifest.session.createdAt > $1.manifest.session.createdAt }
    }

    // MARK: Crash-recovery scan (Section 6.5)

    /// Runs at every launch (GUI and CLI). Section 6.5 liveness guards: skip
    /// any session whose `.recording.lock` names a live PID, or whose
    /// session.json / most-recent segment was modified within the last 30s.
    public func runCrashRecoveryScan() {
        guard let subfolders = try? FileManager.default.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for folder in subfolders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            recoverSessionIfNeeded(at: folder)
        }
    }

    private func recoverSessionIfNeeded(at folder: URL) {
        if isLive(folder) { return }

        guard var manifest = try? readManifest(from: folder) else {
            return // no session.json: reconstruction from bare .caf files is a
                    // documented Section 6.5 case, not implemented in this pass.
        }
        guard manifest.session.finalizedAt == nil else { return } // already finalized

        var allSegmentsRecovered = true
        for laneIndex in manifest.lanes.indices {
            for segmentIndex in manifest.lanes[laneIndex].segments.indices {
                var segment = manifest.lanes[laneIndex].segments[segmentIndex]
                guard !segment.finalized else { continue }
                let segmentURL = folder.appendingPathComponent(segment.file)
                if let frames = CAFRecovery.patchUnfinalizedSegment(at: segmentURL, channels: segment.channels) {
                    segment.frames = frames
                    segment.finalized = true
                    manifest.lanes[laneIndex].segments[segmentIndex] = segment
                } else {
                    allSegmentsRecovered = false
                }
            }
        }

        // Only claim the whole session finalized/recovered if EVERY segment
        // actually patched — `finalizedAt == nil` above is the only gate
        // that lets a future scan ever reconsider this folder, so falsely
        // setting it here would permanently freeze a still-broken segment
        // in its half-recovered (finalized:false) state. Segments that DID
        // patch successfully are still saved either way, so a future scan
        // only ever has to retry the ones that actually failed.
        if allSegmentsRecovered {
            manifest.session.recovered = true
            manifest.session.finalizedAt = ManifestTimestamp.now()
        }
        // The lock file must not be removed until the manifest write it
        // depends on has actually landed on disk — removing it synchronously
        // right after a fire-and-forget write let a process exit (or a
        // second recovery pass) observe a missing lock but a stale manifest.
        writeManifest(manifest, to: folder) { [weak self] in
            if allSegmentsRecovered {
                self?.removeLockFile(in: folder)
            }
        }
    }

    private func isLive(_ folder: URL) -> Bool {
        let lockURL = folder.appendingPathComponent(".recording.lock")
        if let contents = try? String(contentsOf: lockURL, encoding: .utf8) {
            let lines = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if let pidLine = lines.first,
               let pid = pid_t(pidLine.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if kill(pid, 0) == 0 || errno == EPERM {
                    // The PID exists, but PIDs get reused — confirm the live
                    // process is actually the one that created this lock
                    // (same executable path) before trusting it, so a
                    // crashed session isn't held "live" forever by some
                    // unrelated process the OS later assigned the same PID.
                    let recordedPath = lines.count > 1 ? String(lines[1]) : ""
                    if !recordedPath.isEmpty, let livePath = Self.executablePath(for: pid) {
                        return livePath == recordedPath
                    }
                    // No recorded path (older lock format) or we couldn't
                    // read the live process's path (e.g. EPERM) — be
                    // conservative and treat it as live rather than risk
                    // clobbering an in-progress recording.
                    return true
                }
            }
        }

        // Recency check (Section 6.5): skip if session.json or the newest
        // segment was modified within the last 30 seconds.
        let recencyWindow: TimeInterval = 30
        let fm = FileManager.default
        var newestModified: Date = .distantPast
        if let attrs = try? fm.attributesOfItem(atPath: folder.appendingPathComponent("session.json").path),
           let modified = attrs[.modificationDate] as? Date {
            newestModified = max(newestModified, modified)
        }
        if let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in contents where url.pathExtension == "caf" {
                if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modified = values.contentModificationDate {
                    newestModified = max(newestModified, modified)
                }
            }
        }
        return Date().timeIntervalSince(newestModified) < recencyWindow
    }
}

/// Section 6.5's self-contained CAF byte-layout patch logic — no external
/// spec available to the implementer, so every offset is derived here from
/// first principles (CAF header + chunk framing + the `data` chunk's
/// `mEditCount` prefix).
public enum CAFRecovery {
    /// Locates the unfinalized `data` chunk, truncates to the last whole
    /// frame if the crash landed mid-frame, and patches the chunk's size
    /// field. Returns the patched frame count, or nil if the file could not
    /// be parsed as an unfinalized CAF (already finalized, corrupt, etc.).
    public static func patchUnfinalizedSegment(at url: URL, channels: Int) -> Int? {
        // A corrupted/hand-edited manifest could carry `channels: 0` on an
        // unfinalized segment; `% Int64(bytesPerFrame)` below would then
        // divide by zero and trap (Swift's remainder operator does not
        // return NaN/inf like floating point — it's a fatal error), turning
        // one bad segment into a permanent crash-on-launch for every future
        // run of `runCrashRecoveryScan()`.
        guard channels > 0 else { return nil }
        let bytesPerFrame = channels * 4 // Float32 (Section 6.1)
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }

        guard let fileLength = try? handle.seekToEnd() else { return nil }
        guard fileLength >= 8 else { return nil }
        try? handle.seek(toOffset: 0)
        guard let magicHeader = try? handle.read(upToCount: 8), magicHeader.count == 8 else { return nil }
        // "caff" magic + mFileVersion == 1 (big-endian UInt16) — the only
        // CAF version this app (or any known writer) produces. Rejecting
        // anything else up front means the chunk-walk below only ever runs
        // against a file we're confident is actually laid out like a CAF.
        guard [UInt8](magicHeader[0..<4]) == Array("caff".utf8) else { return nil }
        let version = magicHeader.withUnsafeBytes { raw -> UInt16 in
            raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self).bigEndian
        }
        guard version == 1 else { return nil }

        var offset: UInt64 = 8
        while offset + 12 <= fileLength {
            try? handle.seek(toOffset: offset)
            guard let headerData = try? handle.read(upToCount: 12), headerData.count == 12 else { return nil }
            // Copy into a fresh, zero-based, naturally-aligned array: `Data`
            // slices/subranges preserve the original buffer's indices and are
            // not guaranteed aligned for a raw `load(as:)`, which traps on a
            // misaligned pointer. `loadUnaligned` avoids that regardless, but
            // normalizing to `[UInt8]` first also keeps indexing simple.
            let header = [UInt8](headerData)
            let type = String(decoding: header[0..<4], as: UTF8.self)
            let chunkSize = header.withUnsafeBytes { raw -> Int64 in
                raw.loadUnaligned(fromByteOffset: 4, as: Int64.self).bigEndian
            }

            if type == "data" {
                let dataPayloadOffset = offset + 12
                // First 4 bytes of the data chunk payload are mEditCount.
                let audioStart = dataPayloadOffset + 4
                guard audioStart <= fileLength else { return nil }
                var audioDataBytes = Int64(fileLength - audioStart)
                var newFileLength = fileLength

                let remainder = audioDataBytes % Int64(bytesPerFrame)
                if remainder != 0 {
                    audioDataBytes -= remainder
                    newFileLength = audioStart + UInt64(audioDataBytes)
                    try? handle.truncate(atOffset: newFileLength)
                }

                let patchedSize = Int64(newFileLength - dataPayloadOffset)
                try? handle.seek(toOffset: offset + 4) // size field position
                var bigEndian = patchedSize.bigEndian
                let sizeData = Data(bytes: &bigEndian, count: 8)
                try? handle.write(contentsOf: sizeData)

                return Int(audioDataBytes / Int64(bytesPerFrame))
            }

            if chunkSize < 0 {
                // Only `data` may be unknown-size, and only as the last
                // chunk — if we hit -1 on a non-data chunk, the file is not
                // one SegmentWriter produced; bail out safely.
                return nil
            }
            offset += 12 + UInt64(chunkSize)
        }
        return nil
    }
}
