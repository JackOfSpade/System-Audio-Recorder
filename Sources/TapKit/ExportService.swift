import AudioToolbox
import CoreAudio
import Foundation

public enum ExportFormat: String, Sendable, CaseIterable {
    case flac16, flac24, alac16, alac24, aac, wav24
}

public struct ExportResult: Sendable {
    public let url: URL
    public let clippedSampleCount: Int
}

public enum ExportError: Error, CustomStringConvertible {
    case sourceUnreadable
    case destinationUnwritable(OSStatus)
    case unsupportedFormat
    case invalidGainCompensation(Double)

    public var description: String {
        switch self {
        case .sourceUnreadable: return "Could not open the CAF master for reading"
        case .destinationUnwritable(let status): return "Could not create export file (OSStatus \(status))"
        case .unsupportedFormat: return "Unsupported export format"
        case .invalidGainCompensation(let value): return "Invalid gain compensation value (\(value)) — the calibration profile may be corrupted"
        }
    }
}

/// Post-capture transcodes from the CAF float master — NEVER by re-capture
/// (Section 6.6). Sample rate is never changed on export (no SRC anywhere in
/// the product). System Audio Recorder performs its own Float32 -> Int16/Int24 quantization
/// (with optional TPDF dither) before handing already-quantized integer PCM
/// to `ExtAudioFile`, so the codec's `AudioConverter` step only ever does
/// lossless encoding — never an uncontrolled float/dither conversion we
/// cannot verify or control.
public enum ExportService {
    /// `gainCompensationDB`, when non-nil, is a non-negative boost applied as
    /// a single float scalar multiply BEFORE quantization (Section 8.3 — the
    /// master itself is never touched; this only affects the export copy).
    /// `ditherEnabled` applies only to 16-bit reductions (Section 6.6).
    public static func export(
        masterURL: URL,
        to destinationURL: URL,
        format: ExportFormat,
        gainCompensationDB: Double?,
        ditherEnabled: Bool = true
    ) throws -> ExportResult {
        var clientASBD = try readMasterFormat(masterURL)
        guard var readFile = try? openForReading(masterURL, clientFormat: &clientASBD) else {
            throw ExportError.sourceUnreadable
        }
        defer { ExtAudioFileDispose(readFile) }

        let channels = Int(clientASBD.mChannelsPerFrame)
        let sampleRate = clientASBD.mSampleRate
        // A NaN/infinite value (e.g. from a corrupted calibration profile)
        // would otherwise propagate through `pow` into `gainLinear` as NaN,
        // silently multiplying every sample to NaN in quantize() — caught
        // there only as a per-sample "clip to silence," so the export would
        // succeed but produce an entirely silent file with no indication
        // anything was wrong.
        if let gainCompensationDB, !gainCompensationDB.isFinite {
            throw ExportError.invalidGainCompensation(gainCompensationDB)
        }
        let gainLinear: Float = gainCompensationDB.map { Float(pow(10.0, $0 / 20.0)) } ?? 1.0

        switch format {
        case .wav24, .flac24, .alac24:
            return try exportIntegerPCM(
                readFile: &readFile, channels: channels, sampleRate: sampleRate,
                destinationURL: destinationURL, format: format, bitDepth: 24,
                gainLinear: gainLinear, dither: false
            )
        case .flac16, .alac16:
            return try exportIntegerPCM(
                readFile: &readFile, channels: channels, sampleRate: sampleRate,
                destinationURL: destinationURL, format: format, bitDepth: 16,
                gainLinear: gainLinear, dither: ditherEnabled
            )
        case .aac:
            return try exportAAC(
                readFile: &readFile, channels: channels, sampleRate: sampleRate,
                destinationURL: destinationURL, gainLinear: gainLinear
            )
        }
    }

    private static func readMasterFormat(_ url: URL) throws -> AudioStreamBasicDescription {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let f = file else {
            throw ExportError.sourceUnreadable
        }
        defer { ExtAudioFileDispose(f) }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &size, &asbd)
        guard status == noErr else { throw ExportError.sourceUnreadable }
        return asbd
    }

    private static func openForReading(_ url: URL, clientFormat: inout AudioStreamBasicDescription) throws -> ExtAudioFileRef {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let f = file else {
            throw ExportError.sourceUnreadable
        }
        // Force Float32 interleaved client format at the master's native rate
        // and channel count — matches the fidelity rule (no SRC).
        var desired = SegmentWriter.canonicalASBD(sampleRate: clientFormat.mSampleRate, channels: clientFormat.mChannelsPerFrame)
        let status = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &desired)
        guard status == noErr else {
            ExtAudioFileDispose(f) // else `f` (and its underlying fd) leaks on every failed export attempt
            throw ExportError.sourceUnreadable
        }
        clientFormat = desired
        return f
    }

    /// FLAC/ALAC/WAV path: quantize Float32 -> Int16/Int24 ourselves (with
    /// optional TPDF dither), pack the integer client buffer, and let
    /// ExtAudioFile encode/write it — the codec step is lossless from there.
    private static func exportIntegerPCM(
        readFile: inout ExtAudioFileRef,
        channels: Int,
        sampleRate: Float64,
        destinationURL: URL,
        format: ExportFormat,
        bitDepth: Int,
        gainLinear: Float,
        dither: Bool
    ) throws -> ExportResult {
        let bytesPerSample = bitDepth == 16 ? 2 : 3
        var intClientASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerSample * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerSample * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bitDepth),
            mReserved: 0
        )

        let (fileTypeID, fileFormatID): (AudioFileTypeID, AudioFormatID)
        switch format {
        case .wav24: (fileTypeID, fileFormatID) = (kAudioFileWAVEType, kAudioFormatLinearPCM)
        case .flac16, .flac24: (fileTypeID, fileFormatID) = (kAudioFileFLACType, kAudioFormatFLAC)
        case .alac16, .alac24: (fileTypeID, fileFormatID) = (kAudioFileM4AType, kAudioFormatAppleLossless)
        case .aac: fatalError("handled by exportAAC")
        }

        var fileASBD: AudioStreamBasicDescription
        if fileFormatID == kAudioFormatLinearPCM {
            fileASBD = intClientASBD // WAV: file format == client format, no converter engaged
        } else {
            fileASBD = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: fileFormatID,
                mFormatFlags: appleLosslessFormatFlags(bitDepth: bitDepth, formatID: fileFormatID),
                mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bitDepth), mReserved: 0
            )
        }

        // Write to a temp file in the same directory as the final
        // destination, then atomically replace it only on success — writing
        // straight to `destinationURL` (the previous approach) left a
        // truncated/corrupt file at that exact path (or clobbered a prior
        // good export there) if a read/write status ever failed partway
        // through, with nothing to clean it up.
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".systemaudiorecorder_export_tmp_\(UUID().uuidString)")
        do {
            let clipCount = try writeIntegerPCMFile(
                to: tempURL, readFile: &readFile, fileTypeID: fileTypeID,
                fileASBD: &fileASBD, intClientASBD: &intClientASBD,
                channels: channels, bitDepth: bitDepth, bytesPerSample: bytesPerSample,
                gainLinear: gainLinear, dither: dither
            )
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
            return ExportResult(url: destinationURL, clippedSampleCount: clipCount)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private static func writeIntegerPCMFile(
        to url: URL,
        readFile: inout ExtAudioFileRef,
        fileTypeID: AudioFileTypeID,
        fileASBD: inout AudioStreamBasicDescription,
        intClientASBD: inout AudioStreamBasicDescription,
        channels: Int,
        bitDepth: Int,
        bytesPerSample: Int,
        gainLinear: Float,
        dither: Bool
    ) throws -> Int {
        var writeFile: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(url as CFURL, fileTypeID, &fileASBD, nil, AudioFileFlags.eraseFile.rawValue, &writeFile)
        guard createStatus == noErr, let wf = writeFile else {
            throw ExportError.destinationUnwritable(createStatus)
        }
        // This function's own scope ends (running this defer) before the
        // caller attempts to rename the file, so the write handle is always
        // closed before the rename — not deferred at the caller's level,
        // where it would still be open at the point of the rename.
        defer { ExtAudioFileDispose(wf) }

        let setClientStatus = ExtAudioFileSetProperty(wf, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &intClientASBD)
        guard setClientStatus == noErr else { throw ExportError.destinationUnwritable(setClientStatus) }

        var clipCount = 0
        var ditherState = TPDFDither()
        let chunkFrames = 48000
        var floatBuf = [Float32](repeating: 0, count: chunkFrames * channels)
        var intBuf = [UInt8](repeating: 0, count: chunkFrames * channels * bytesPerSample)

        while true {
            var framesRead = UInt32(chunkFrames)
            let readStatus = floatBuf.withUnsafeMutableBytes { raw -> OSStatus in
                var bl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return ExtAudioFileRead(readFile, &framesRead, &bl)
            }
            guard readStatus == noErr else { break }
            if framesRead == 0 { break }

            let sampleCount = Int(framesRead) * channels
            quantize(
                floats: &floatBuf, sampleCount: sampleCount, into: &intBuf,
                bitDepth: bitDepth, bytesPerSample: bytesPerSample,
                gainLinear: gainLinear, dither: dither, ditherState: &ditherState,
                clipCount: &clipCount
            )

            let writeStatus = intBuf.withUnsafeMutableBytes { raw -> OSStatus in
                var bl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(sampleCount * bytesPerSample), mData: raw.baseAddress))
                return ExtAudioFileWrite(wf, framesRead, &bl)
            }
            guard writeStatus == noErr else { throw ExportError.destinationUnwritable(writeStatus) }
        }

        return clipCount
    }

    private static func appleLosslessFormatFlags(bitDepth: Int, formatID: AudioFormatID) -> UInt32 {
        guard formatID == kAudioFormatAppleLossless else { return 0 }
        // kAppleLosslessFormatFlag_16BitSourceData = 1, _24BitSourceData = 3
        return bitDepth == 16 ? 1 : 3
    }

    /// Float32 -> signed Int16/Int24 (packed, little-endian), hard-clipping
    /// at full scale (Section 6.6: floats legally exceed ±1.0; int exports
    /// cannot represent that, so out-of-range samples clip and are counted).
    private static func quantize(
        floats: inout [Float32], sampleCount: Int, into intBuf: inout [UInt8],
        bitDepth: Int, bytesPerSample: Int, gainLinear: Float,
        dither: Bool, ditherState: inout TPDFDither, clipCount: inout Int
    ) {
        let maxValue: Float = bitDepth == 16 ? 32767.0 : 8_388_607.0
        let minValue: Float = bitDepth == 16 ? -32768.0 : -8_388_608.0

        intBuf.withUnsafeMutableBytes { rawOut in
            for i in 0..<sampleCount {
                let sample = floats[i] * gainLinear
                var scaled = sample * (bitDepth == 16 ? 32768.0 : 8_388_608.0)
                if dither {
                    scaled += ditherState.next()
                }
                var rounded = scaled.rounded()
                if !rounded.isFinite {
                    // NaN/Inf sample (corrupted master data, or a NaN
                    // introduced upstream) — Swift's Int32(Float) traps on
                    // non-finite input, and `min`/`max` don't clamp NaN
                    // (every comparison against NaN is false), so without
                    // this the whole export crashes on a single bad sample.
                    clipCount += 1
                    rounded = rounded.isNaN ? 0 : (rounded > 0 ? maxValue : minValue)
                } else if rounded > maxValue || rounded < minValue {
                    clipCount += 1
                }
                rounded = min(max(rounded, minValue), maxValue)
                let intValue = Int32(rounded)

                let byteOffset = i * bytesPerSample
                if bytesPerSample == 2 {
                    let v = Int16(truncatingIfNeeded: intValue)
                    rawOut.storeBytes(of: v.littleEndian, toByteOffset: byteOffset, as: Int16.self)
                } else {
                    // Packed 24-bit little-endian: low 3 bytes of the 32-bit value.
                    let bytes = withUnsafeBytes(of: intValue.littleEndian) { Array($0) }
                    rawOut[byteOffset] = bytes[0]
                    rawOut[byteOffset + 1] = bytes[1]
                    rawOut[byteOffset + 2] = bytes[2]
                }
            }
        }
    }

    /// AAC ~256 kbps VBR (Section 6.6). Lossy: no manual quantization
    /// control needed — hand Float32 straight to the AAC encoder.
    private static func exportAAC(
        readFile: inout ExtAudioFileRef,
        channels: Int,
        sampleRate: Float64,
        destinationURL: URL,
        gainLinear: Float
    ) throws -> ExportResult {
        // Same atomic-write reasoning as exportIntegerPCM: write to a temp
        // file, replace the final destination only on success.
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".systemaudiorecorder_export_tmp_\(UUID().uuidString)")
        do {
            try writeAACFile(to: tempURL, readFile: &readFile, channels: channels, sampleRate: sampleRate, gainLinear: gainLinear)
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
            return ExportResult(url: destinationURL, clippedSampleCount: 0)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private static func writeAACFile(
        to url: URL,
        readFile: inout ExtAudioFileRef,
        channels: Int,
        sampleRate: Float64,
        gainLinear: Float
    ) throws {
        var clientASBD = SegmentWriter.canonicalASBD(sampleRate: sampleRate, channels: UInt32(channels))
        var fileASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0
        )
        var writeFile: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &fileASBD, nil, AudioFileFlags.eraseFile.rawValue, &writeFile)
        guard createStatus == noErr, let wf = writeFile else {
            throw ExportError.destinationUnwritable(createStatus)
        }
        // As in writeIntegerPCMFile: this function's own scope ends (running
        // this defer) before the caller attempts to rename the file.
        defer { ExtAudioFileDispose(wf) }

        guard ExtAudioFileSetProperty(wf, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD) == noErr else {
            throw ExportError.destinationUnwritable(-1)
        }

        var vbrQuality = UInt32(96) // 0-127 scale used by AudioConverter VBR quality
        if let converter = try? getUnderlyingAudioConverter(wf) {
            AudioConverterSetProperty(converter, kAudioConverterCodecQuality, UInt32(MemoryLayout<UInt32>.size), &vbrQuality)
        }

        let chunkFrames = 48000
        var floatBuf = [Float32](repeating: 0, count: chunkFrames * channels)
        while true {
            var framesRead = UInt32(chunkFrames)
            let readStatus = floatBuf.withUnsafeMutableBytes { raw -> OSStatus in
                var bl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return ExtAudioFileRead(readFile, &framesRead, &bl)
            }
            guard readStatus == noErr else { break }
            if framesRead == 0 { break }
            if gainLinear != 1.0 {
                for i in 0..<(Int(framesRead) * channels) { floatBuf[i] *= gainLinear }
            }
            let writeStatus = floatBuf.withUnsafeMutableBytes { raw -> OSStatus in
                var bl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: framesRead * UInt32(channels) * 4, mData: raw.baseAddress))
                return ExtAudioFileWrite(wf, framesRead, &bl)
            }
            guard writeStatus == noErr else { throw ExportError.destinationUnwritable(writeStatus) }
        }
    }

    private static func getUnderlyingAudioConverter(_ file: ExtAudioFileRef) throws -> AudioConverterRef {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        let status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter)
        guard status == noErr, let c = converter else { throw ExportError.destinationUnwritable(status) }
        return c
    }
}

/// Minimal triangular-PDF disther generator (sum of two independent uniform
/// randoms in [-0.5, 0.5], giving a triangular distribution in [-1, 1]) —
/// Section 6.6's default-ON 16-bit dither.
struct TPDFDither {
    private var rng = SystemRandomNumberGenerator()
    mutating func next() -> Float {
        let a = Float.random(in: -0.5...0.5, using: &rng)
        let b = Float.random(in: -0.5...0.5, using: &rng)
        return a + b
    }
}
