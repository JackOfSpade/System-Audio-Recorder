import Darwin
import Foundation

/// Owns the recordings folder: naming-template expansion, filename
/// sanitization, collision-free destination URLs, and the launch-time sweep
/// that rescues partial captures left behind by a crash (Section 6.5's
/// recovery intent, applied to the streaming master files).
public final class SessionStore {
    public let recordingsRoot: URL

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

    /// "base.ext", or "base (2).ext", "base (3).ext", ... — the first name
    /// that doesn't already exist in `directory`.
    public static func uniqueDestinationURL(base: String, ext: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(suffix)).\(ext)")
            suffix += 1
        }
        return candidate
    }

    // MARK: Crash sweep (Section 6.5's recovery intent)

    /// Rescues `.capture_*.caf` master files left behind by a crash: patches
    /// the unfinalized CAF header via `CAFRecovery` and promotes the file to
    /// a visible "Recovered <timestamp>" name. Runs at every launch (GUI and
    /// CLI `record`).
    ///
    /// Liveness is decided by the owning session's flock'd `.live` lock file
    /// (see `SegmentWriter.sessionLockURL`): a session that is still running
    /// in another process holds the lock, so its segments — including
    /// finalized ones whose mtime froze hours ago after a mid-session
    /// rotation, and segments parked in waiting-for-device — are never
    /// stolen. The 60 s mtime guard remains as a fallback for files with no
    /// parseable token/lock (and for the actively-written segment, whose
    /// mtime advances every ~50 ms drain flush).
    public func sweepPartialCaptures() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: recordingsRoot, includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }

        for url in contents {
            guard url.lastPathComponent.hasPrefix(SegmentWriter.partialFilePrefix),
                  url.pathExtension == "caf" else { continue }
            if let token = Self.sessionToken(fromPartialFileName: url.lastPathComponent),
               Self.sessionIsLive(token: token, in: recordingsRoot) {
                continue // finalized or open segment of a live session — never touch
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(modified) > 60 else { continue }

            guard let frames = CAFRecovery.patchUnfinalizedSegment(at: url) else {
                Log.error("sweep: could not recover partial capture \(url.lastPathComponent); leaving it in place")
                continue
            }
            guard frames > 0 else {
                // Structurally valid but empty — nothing to rescue.
                try? fm.removeItem(at: url)
                Log.info("sweep: removed empty partial capture \(url.lastPathComponent)")
                continue
            }

            let fixedLocale = Locale(identifier: "en_US_POSIX")
            let formatter = DateFormatter()
            formatter.locale = fixedLocale
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let base = "Recovered \(formatter.string(from: modified))"
            let destination = Self.uniqueDestinationURL(base: base, ext: "caf", in: recordingsRoot)
            do {
                try fm.moveItem(at: url, to: destination)
                Log.info("sweep: recovered crashed recording (\(frames) frames) as \(destination.lastPathComponent)")
            } catch {
                Log.error("sweep: recovered \(url.lastPathComponent) but could not rename it: \(error)")
            }
        }

        // Remove `.live` lock files whose owning process is gone (crash
        // leftovers — a graceful session unlinks its own).
        for url in contents where url.pathExtension == "live" && url.lastPathComponent.hasPrefix(SegmentWriter.partialFilePrefix) {
            let fd = open(url.path, O_RDWR)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                flock(fd, LOCK_UN)
                try? fm.removeItem(at: url)
            }
            close(fd)
        }
    }

    /// Parses the session token out of a partial-segment filename:
    /// ".capture_<token>-<n>.caf" → token (the token itself contains
    /// hyphens — a UUID — so the index is split off at the LAST hyphen,
    /// which must be all digits).
    static func sessionToken(fromPartialFileName name: String) -> String? {
        guard name.hasPrefix(SegmentWriter.partialFilePrefix), name.hasSuffix(".caf") else { return nil }
        let stem = name.dropFirst(SegmentWriter.partialFilePrefix.count).dropLast(4)
        guard let lastDash = stem.lastIndex(of: "-") else { return nil }
        let indexPart = stem[stem.index(after: lastDash)...]
        guard !indexPart.isEmpty, indexPart.allSatisfy({ $0.isNumber }) else { return nil }
        return String(stem[..<lastDash])
    }

    /// True if the session that owns `token` is still alive in some process
    /// — i.e. its `.live` lock file exists and is still exclusively flock'd.
    /// flock releases automatically when the owner dies, so a crashed
    /// session's lock probe succeeds and the sweep may proceed.
    static func sessionIsLive(token: String, in directory: URL) -> Bool {
        let lockURL = SegmentWriter.sessionLockURL(directory: directory, token: token)
        let fd = open(lockURL.path, O_RDWR)
        guard fd >= 0 else { return false } // no lock file — not live
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false // lock acquirable — owner is dead
        }
        return true
    }
}

/// Section 6.5's self-contained CAF byte-layout patch logic — no external
/// spec available to the implementer, so every offset is derived here from
/// first principles (CAF header + chunk framing + the `data` chunk's
/// `mEditCount` prefix).
public enum CAFRecovery {
    /// Locates the unfinalized `data` chunk, truncates to the last whole
    /// frame if the crash landed mid-frame, and patches the chunk's size
    /// field. The channel count comes from the file's own `desc` chunk
    /// unless the caller supplies one. Returns the patched frame count, or
    /// nil if the file could not be parsed as a CAF this app produced.
    public static func patchUnfinalizedSegment(at url: URL, channels: Int? = nil) -> Int? {
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

        var descChannels: Int?
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

            if type == "desc" {
                // CAFAudioDescription (all big-endian): sampleRate f64,
                // formatID u32, formatFlags u32, bytesPerPacket u32,
                // framesPerPacket u32, channelsPerFrame u32, bitsPerChannel
                // u32 — channelsPerFrame sits 24 bytes into the payload.
                if chunkSize >= 32,
                   let payload = try? handle.read(upToCount: 32), payload.count == 32 {
                    let ch = [UInt8](payload).withUnsafeBytes { raw -> UInt32 in
                        raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self).bigEndian
                    }
                    if ch > 0 { descChannels = Int(ch) }
                }
            }

            if type == "data" {
                // A corrupted/hand-edited file could carry channels == 0;
                // `% Int64(bytesPerFrame)` below would then divide by zero
                // and trap (Swift's remainder operator is a fatal error on
                // zero, not NaN/inf like floating point).
                guard let ch = channels ?? descChannels, ch > 0 else { return nil }
                let bytesPerFrame = ch * 4 // Float32 (Section 6.1)

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
