import AudioToolbox
import CoreAudio
import Foundation

public enum ExportFormat: String, Sendable, CaseIterable {
    case wav32, caf32
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
        case .invalidGainCompensation(let value): return "Invalid gain compensation value (\(value)) - the calibration profile may be corrupted"
        }
    }
}

/// Post-capture writes from the in-memory Float32 master. Sample rate is never
/// changed on export (no SRC anywhere in the product), and supported public
/// file formats stay 32-bit Float PCM.
public enum ExportService {
    /// `gainCompensationDB`, when non-nil, is a scalar multiply applied only
    /// to the export copy. The in-memory master remains untouched.
    public static func export(
        masterURL: URL,
        to destinationURL: URL,
        format: ExportFormat,
        gainCompensationDB: Double?,
        ditherEnabled: Bool = true
    ) throws -> ExportResult {
        _ = ditherEnabled

        var clientASBD = try readMasterFormat(masterURL)
        guard var readFile = try? openForReading(masterURL, clientFormat: &clientASBD) else {
            throw ExportError.sourceUnreadable
        }
        defer { ExtAudioFileDispose(readFile) }

        let channels = Int(clientASBD.mChannelsPerFrame)
        let sampleRate = clientASBD.mSampleRate
        if let gainCompensationDB, !gainCompensationDB.isFinite {
            throw ExportError.invalidGainCompensation(gainCompensationDB)
        }
        let gainLinear: Float = gainCompensationDB.map { Float(pow(10.0, $0 / 20.0)) } ?? 1.0

        switch format {
        case .wav32:
            return try exportFloat32WAV(
                readFile: &readFile,
                channels: channels,
                sampleRate: sampleRate,
                destinationURL: destinationURL,
                gainLinear: gainLinear
            )
        case .caf32:
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: masterURL, to: destinationURL)
            return ExportResult(url: destinationURL, clippedSampleCount: 0)
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

        var desired = SegmentWriter.canonicalASBD(
            sampleRate: clientFormat.mSampleRate,
            channels: clientFormat.mChannelsPerFrame
        )
        let status = ExtAudioFileSetProperty(
            f,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &desired
        )
        guard status == noErr else {
            ExtAudioFileDispose(f)
            throw ExportError.sourceUnreadable
        }
        clientFormat = desired
        return f
    }

    private static func exportFloat32WAV(
        readFile: inout ExtAudioFileRef,
        channels: Int,
        sampleRate: Float64,
        destinationURL: URL,
        gainLinear: Float
    ) throws -> ExportResult {
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".systemaudiorecorder_export_tmp_\(UUID().uuidString)")
        do {
            try writeFloat32WAVFile(
                to: tempURL,
                readFile: &readFile,
                channels: channels,
                sampleRate: sampleRate,
                gainLinear: gainLinear
            )
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
            return ExportResult(url: destinationURL, clippedSampleCount: 0)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private static func writeFloat32WAVFile(
        to url: URL,
        readFile: inout ExtAudioFileRef,
        channels: Int,
        sampleRate: Float64,
        gainLinear: Float
    ) throws {
        var floatASBD = SegmentWriter.canonicalASBD(sampleRate: sampleRate, channels: UInt32(channels))
        var writeFile: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileWAVEType,
            &floatASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &writeFile
        )
        guard createStatus == noErr, let wf = writeFile else {
            throw ExportError.destinationUnwritable(createStatus)
        }
        defer { ExtAudioFileDispose(wf) }

        let setClientStatus = ExtAudioFileSetProperty(
            wf,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &floatASBD
        )
        guard setClientStatus == noErr else {
            throw ExportError.destinationUnwritable(setClientStatus)
        }

        let chunkFrames = 48000
        var floatBuf = [Float32](repeating: 0, count: chunkFrames * channels)
        while true {
            var framesRead = UInt32(chunkFrames)
            let readStatus = floatBuf.withUnsafeMutableBytes { raw -> OSStatus in
                var bl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(raw.count),
                        mData: raw.baseAddress
                    )
                )
                return ExtAudioFileRead(readFile, &framesRead, &bl)
            }
            guard readStatus == noErr else {
                throw ExportError.sourceUnreadable
            }
            if framesRead == 0 { break }

            let sampleCount = Int(framesRead) * channels
            if gainLinear != 1.0 {
                for i in 0..<sampleCount {
                    floatBuf[i] *= gainLinear
                }
            }

            let writeStatus = floatBuf.withUnsafeMutableBytes { raw -> OSStatus in
                var bl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(sampleCount * MemoryLayout<Float32>.size),
                        mData: raw.baseAddress
                    )
                )
                return ExtAudioFileWrite(wf, framesRead, &bl)
            }
            guard writeStatus == noErr else {
                throw ExportError.destinationUnwritable(writeStatus)
            }
        }
    }
}
