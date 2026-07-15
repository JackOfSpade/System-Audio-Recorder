import AVFoundation
import Accelerate
import CoreAudio
import Darwin
import SystemAudioRecorderRT
import Foundation

public struct CalibrationProfile: Codable, Sendable {
    public let deviceUID: String
    public let outputChannelCount: Int
    public let macOSBuild: String
    public let gainCompensationDB: Double
    public let measuredAt: String
    public let referenceVolume: Double?

    public init(deviceUID: String, outputChannelCount: Int, macOSBuild: String, gainCompensationDB: Double, measuredAt: String, referenceVolume: Double?) {
        self.deviceUID = deviceUID
        self.outputChannelCount = outputChannelCount
        self.macOSBuild = macOSBuild
        self.gainCompensationDB = gainCompensationDB
        self.measuredAt = measuredAt
        self.referenceVolume = referenceVolume
    }

    public var key: String { "\(deviceUID)|\(outputChannelCount)|\(macOSBuild)" }
}

/// Bug-A calibration (Section 8.3): with user consent, plays a 997 Hz test
/// tone through the target device while capturing via a temporary lane,
/// measures the RMS delta, and stores a per-device gain profile. Playback
/// uses AVFoundation (Section 2.2 — playback side only, never capture);
/// capture uses a normal `CaptureLane`-equivalent temporary tap.
public enum CalibrationService {
    private static let toneFrequency: Double = 997
    private static let toneDurationSeconds: Double = 5
    private static let toneLevelDBFS: Double = -20
    private static let measurementWindowStartSeconds: Double = 1 // skip first 1s (ramp/settling)
    private static let measurementWindowEndSeconds: Double = 4   // skip last 1s

    /// Profiles persist as shared JSON at `~/Library/Application Support/
    /// System Audio Recorder/calibration.json` (Section 8.3), read/written by
    /// both the GUI and the CLI (separate processes, no IPC), written atomically.
    public static var profileStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("System Audio Recorder").appendingPathComponent("calibration.json")
    }

    public static func loadProfiles() -> [CalibrationProfile] {
        guard let data = try? Data(contentsOf: profileStoreURL) else { return [] }
        return (try? JSONDecoder().decode([CalibrationProfile].self, from: data)) ?? []
    }

    public static func saveProfile(_ profile: CalibrationProfile) {
        let dir = profileStoreURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The GUI and CLI are separate OS processes with no shared memory,
        // so an in-process lock (NSLock, DispatchQueue) cannot stop one
        // process's write from clobbering a concurrent update from the
        // other — the atomic tmp+rename below only makes each individual
        // WRITE torn-free, not the read-modify-write sequence as a whole.
        // `flock` on a dedicated lock file serializes that whole sequence
        // across processes.
        let lockURL = dir.appendingPathComponent("calibration.json.lock")
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else {
            // Can't acquire the coordination mechanism at all — fall back
            // to an unsynchronized save rather than losing this profile.
            saveProfileUnlocked(profile, dir: dir)
            return
        }
        defer { close(lockFD) }
        flock(lockFD, LOCK_EX)
        defer { flock(lockFD, LOCK_UN) }

        saveProfileUnlocked(profile, dir: dir)
    }

    private static func saveProfileUnlocked(_ profile: CalibrationProfile, dir: URL) {
        var profiles = loadProfiles()
        profiles.removeAll { $0.key == profile.key }
        profiles.append(profile)
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        let tmp = dir.appendingPathComponent("calibration.json.tmp")
        try? data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(profileStoreURL, withItemAt: tmp)
    }

    public static func profile(deviceUID: String, outputChannelCount: Int, macOSBuild: String) -> CalibrationProfile? {
        let key = "\(deviceUID)|\(outputChannelCount)|\(macOSBuild)"
        return loadProfiles().first { $0.key == key }
    }

    /// Runs the full calibration pass end to end. `engineQueue` is the
    /// caller's `CaptureEngine` engine queue (a temporary tap must still obey
    /// the Section 4.4 serialization rule). Completion is called with the
    /// measured `gainCompensationDB`, or an error.
    public static func runCalibration(
        deviceUID: String,
        engineQueue: DispatchQueue,
        completion: @escaping (Result<CalibrationProfile, Error>) -> Void
    ) {
        engineQueue.async {
            do {
                guard let deviceID = try AudioDeviceDirectory.findDevice(byUID: deviceUID) else {
                    throw CalibrationError.deviceNotFound
                }
                let channelCount = try AudioDeviceDirectory.outputChannelCount(deviceID)

                let capturedRMSdB = try captureToneAndMeasure(deviceID: deviceID, deviceUID: deviceUID)
                let gainCompensationDB = toneLevelDBFS - capturedRMSdB

                let macOSBuild = ProcessInfo.processInfo.operatingSystemVersionString
                let profile = CalibrationProfile(
                    deviceUID: deviceUID,
                    outputChannelCount: channelCount,
                    macOSBuild: macOSBuild,
                    gainCompensationDB: gainCompensationDB,
                    measuredAt: ManifestTimestamp.now(),
                    referenceVolume: nil // Section 11 R1: pre/post-volume question needs hands-on verification
                )
                saveProfile(profile)
                completion(.success(profile))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Plays the test tone via AVAudioPlayer while capturing through a
    /// temporary tap+aggregate (built directly with TapFactory, bypassing
    /// CaptureLane's full session/manifest machinery since this is a
    /// throwaway measurement, not a recording).
    private static func captureToneAndMeasure(deviceID: AudioObjectID, deviceUID: String) throws -> Double {
        let toneURL = try generateToneFile()
        defer { try? FileManager.default.removeItem(at: toneURL) }

        let spec = SessionSpec(device: .fixed(deviceUID: deviceUID))
        let handle = try TapFactory.create(
            spec: spec, laneSlug: "calibration", excludeProcessIDs: [], bufferFrameSize: 512
        )
        defer { TapFactory.destroy(handle) }

        let channels = Int(handle.effectiveFormat.mChannelsPerFrame)
        let bytesPerFrame = UInt32(4 * channels)
        let ringBytes = Int(handle.effectiveFormat.mSampleRate) * channels * 4 * 8
        guard let ring = td_ring_create(ringBytes) else { throw CalibrationError.allocationFailed }
        defer { td_ring_destroy(ring) }
        guard let ctx = td_context_create(ring, bytesPerFrame) else { throw CalibrationError.allocationFailed }
        defer { td_context_destroy(ctx) }
        td_context_arm_first_host_time(ctx)

        let isInterleaved = (handle.effectiveFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        // IOProcHost's init already registers the IOProc with Core Audio —
        // the defer must be in place BEFORE `host.start()` can throw, or a
        // failed start() leaks that registration forever (a `defer`
        // written after a throwing call is never reached, and thus never
        // scheduled, if that call throws).
        let host = try IOProcHost(aggregateID: handle.aggregateID, context: ctx, interleaved: isInterleaved)
        defer { host.stop(); host.destroyIOProc() }
        try host.start()

        let player = try AVAudioPlayer(contentsOf: toneURL)
        player.play()

        var accumulatedSumSquares: Double = 0
        var accumulatedSampleCount: Int = 0
        let scratchFrames = 48000
        var scratch = [UInt8](repeating: 0, count: scratchFrames * Int(bytesPerFrame))

        let deadline = Date().addingTimeInterval(toneDurationSeconds + 1.5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            let elapsed = toneDurationSeconds + 1.5 - deadline.timeIntervalSinceNow
            let inMeasurementWindow = elapsed >= measurementWindowStartSeconds && elapsed <= measurementWindowEndSeconds

            let bytesRead = scratch.withUnsafeMutableBytes { raw -> Int in
                td_ring_read(ring, raw.baseAddress, raw.count, bytesPerFrame)
            }
            guard inMeasurementWindow, bytesRead > 0 else { continue }

            scratch.withUnsafeBytes { raw in
                let floatCount = bytesRead / 4
                let floatPtr = raw.baseAddress!.assumingMemoryBound(to: Float.self)
                var meanSquare: Float = 0
                vDSP_measqv(floatPtr, 1, &meanSquare, vDSP_Length(floatCount))
                accumulatedSumSquares += Double(meanSquare) * Double(floatCount)
                accumulatedSampleCount += floatCount
            }
        }
        player.stop()

        guard accumulatedSampleCount > 0 else { throw CalibrationError.noSamplesCaptured }
        let meanSquare = accumulatedSumSquares / Double(accumulatedSampleCount)
        let rms = sqrt(meanSquare)
        guard rms > 0 else { throw CalibrationError.silentCapture }
        return 20 * log10(rms)
    }

    /// Generates a 5 s, -20 dBFS, 997 Hz sine as a temporary AIFF file for
    /// AVAudioPlayer playback.
    private static func generateToneFile() throws -> URL {
        let sampleRate: Double = 48000
        let frameCount = Int(sampleRate * toneDurationSeconds)
        let amplitude = Float(pow(10.0, toneLevelDBFS / 20.0))

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("systemaudiorecorder_calibration_tone_\(UUID().uuidString).aiff")
        var file: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAIFFType, &asbd, nil, AudioFileFlags.eraseFile.rawValue, &file) == noErr,
              let f = file else {
            throw CalibrationError.toneGenerationFailed
        }
        // From here on, `url` already exists on disk (ExtAudioFileCreateWithURL
        // created it) — every failure exit must remove it, or a temp AIFF
        // is left behind in ~/tmp for every failed calibration attempt.
        var clientASBD = asbd
        guard ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD) == noErr else {
            ExtAudioFileDispose(f)
            try? FileManager.default.removeItem(at: url)
            throw CalibrationError.toneGenerationFailed
        }

        var samples = [Float32](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            let v = amplitude * Float(sin(2 * Double.pi * toneFrequency * t))
            samples[i * 2] = v
            samples[i * 2 + 1] = v
        }
        let writeStatus = samples.withUnsafeMutableBytes { raw -> OSStatus in
            var bl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return ExtAudioFileWrite(f, UInt32(frameCount), &bl)
        }
        ExtAudioFileDispose(f)
        guard writeStatus == noErr else {
            try? FileManager.default.removeItem(at: url)
            throw CalibrationError.toneGenerationFailed
        }
        return url
    }
}

public enum CalibrationError: Error, CustomStringConvertible {
    case deviceNotFound
    case allocationFailed
    case noSamplesCaptured
    case silentCapture
    case toneGenerationFailed

    public var description: String {
        switch self {
        case .deviceNotFound: return "Calibration device not found"
        case .allocationFailed: return "Failed to allocate ring/context for calibration"
        case .noSamplesCaptured: return "No samples captured during calibration window"
        case .silentCapture: return "Captured signal was silent — check device volume/routing"
        case .toneGenerationFailed: return "Failed to generate calibration tone file"
        }
    }
}
