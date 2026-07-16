import CoreAudio
import Foundation

/// Thin, generic helpers over the `AudioObjectGetPropertyData` family so the
/// rest of TapKit never repeats this boilerplate. Every call here runs on the
/// engine queue (Section 4.4) — nothing in this file is real-time-safe or
/// intended for the IOProc thread.
public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let context: String

    public init(status: OSStatus, context: String) {
        self.status = status
        self.context = context
    }

    public var description: String {
        "CoreAudioError(\(context)): OSStatus \(status)"
    }
}

enum CAProp {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size POD property (UInt32, Float64, AudioStreamBasicDescription, pid_t, ...).
    static func readFixed<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        as type: T.Type,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        context: String
    ) throws -> T {
        var address = Self.address(selector, scope: scope)
        let byteCount = MemoryLayout<T>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        var size = UInt32(byteCount)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw)
        guard status == noErr else {
            throw CoreAudioError(status: status, context: context)
        }
        return raw.assumingMemoryBound(to: T.self).pointee
    }

    /// Reads a CFString-valued property (device UID, tap UID, bundle id, ...).
    static func readString(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        context: String
    ) throws -> String {
        var address = Self.address(selector, scope: scope)
        var cfStr: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let s = cfStr else {
            throw CoreAudioError(status: status, context: context)
        }
        return s as String
    }

    /// Reads an array of AudioObjectID (device list, process object list, ...).
    static func readObjectIDArray(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        context: String
    ) throws -> [AudioObjectID] {
        var address = Self.address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status: status, context: context) }
        if size == 0 { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = ids.withUnsafeMutableBufferPointer { buf in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buf.baseAddress!)
        }
        guard status == noErr else { throw CoreAudioError(status: status, context: context) }
        return ids
    }

    /// Sets a fixed-size POD property (nominal sample rate, buffer frame size, ...).
    /// `T` must be a trivial (bitwise-copyable) type — Float64, UInt32, etc.
    static func setFixed<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        value: T,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        context: String
    ) throws {
        var address = Self.address(selector, scope: scope)
        let status = withUnsafeBytes(of: value) { raw -> OSStatus in
            AudioObjectSetPropertyData(objectID, &address, 0, nil, UInt32(raw.count), raw.baseAddress!)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, context: context)
        }
    }
}

/// Device enumeration and lookup helpers used by TapFactory, DeviceObserver,
/// and ProcessCatalog.
public enum AudioDeviceDirectory {
    public static func defaultOutputDevice() throws -> AudioObjectID {
        try CAProp.readFixed(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            as: AudioObjectID.self,
            context: "defaultOutputDevice"
        )
    }

    public static func allDevices() throws -> [AudioObjectID] {
        try CAProp.readObjectIDArray(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDevices,
            context: "allDevices"
        )
    }

    public static func deviceUID(_ deviceID: AudioObjectID) throws -> String {
        try CAProp.readString(deviceID, kAudioDevicePropertyDeviceUID, context: "deviceUID")
    }

    public static func deviceName(_ deviceID: AudioObjectID) throws -> String {
        try CAProp.readString(deviceID, kAudioObjectPropertyName, context: "deviceName")
    }

    public static func nominalSampleRate(_ deviceID: AudioObjectID) throws -> Float64 {
        try CAProp.readFixed(deviceID, kAudioDevicePropertyNominalSampleRate, as: Float64.self, context: "nominalSampleRate")
    }

    public static func setNominalSampleRate(_ deviceID: AudioObjectID, rate: Float64) throws {
        try CAProp.setFixed(deviceID, kAudioDevicePropertyNominalSampleRate, value: rate, context: "setNominalSampleRate")
    }

    /// Output channel count via the output-scope stream configuration
    /// (kAudioDevicePropertyStreamConfiguration returns an AudioBufferList
    /// whose buffers' summed mNumberChannels is the channel count).
    public static func outputChannelCount(_ deviceID: AudioObjectID) throws -> Int {
        var address = CAProp.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else {
            throw CoreAudioError(status: status, context: "outputChannelCount:size")
        }
        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPtr.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawPtr)
        guard status == noErr else {
            throw CoreAudioError(status: status, context: "outputChannelCount:data")
        }
        let ablp = rawPtr.assumingMemoryBound(to: AudioBufferList.self)
        let bufferList = UnsafeMutableAudioBufferListPointer(ablp)
        var total = 0
        for buffer in bufferList {
            total += Int(buffer.mNumberChannels)
        }
        return total
    }

    public static func setBufferFrameSize(_ deviceID: AudioObjectID, frames: UInt32) throws {
        try CAProp.setFixed(deviceID, kAudioDevicePropertyBufferFrameSize, value: frames, context: "setBufferFrameSize")
    }

    /// The device's actual supported I/O buffer size range
    /// (`kAudioDevicePropertyBufferFrameSizeRange`) — the hardware/driver's
    /// real floor and ceiling. This is the absolute lower bound calibration
    /// can never go below, no matter how fast the host machine is.
    public static func bufferFrameSizeRange(_ deviceID: AudioObjectID) throws -> ClosedRange<UInt32> {
        let range = try CAProp.readFixed(
            deviceID, kAudioDevicePropertyBufferFrameSizeRange, as: AudioValueRange.self, context: "bufferFrameSizeRange"
        )
        // Driver-reported values are untrusted input: NaN/infinite/negative/
        // beyond-UInt32.max must degrade to a safe bound, never trap — an
        // unchecked `UInt32(_:)` conversion aborts the process on any of those.
        func safeFrames(_ value: Double, fallback: UInt32) -> UInt32 {
            guard value.isFinite else { return fallback }
            let rounded = value.rounded()
            guard rounded >= 1 else { return 1 }
            guard rounded <= Double(UInt32.max) else { return UInt32.max }
            return UInt32(rounded)
        }
        let minimum = safeFrames(range.mMinimum, fallback: 1)
        let maximum = max(minimum, safeFrames(range.mMaximum, fallback: minimum))
        return minimum...maximum
    }

    /// Resolves a `DevicePolicy` to the `AudioObjectID` it currently names —
    /// the exact rule `TapFactory.create` step 1 and
    /// `CalibrationService.effectiveBufferFrameSize` both need to agree on.
    public static func resolveDevice(for policy: DevicePolicy) throws -> AudioObjectID {
        switch policy {
        case .followSystemDefault:
            return try defaultOutputDevice()
        case .fixed(let uid):
            guard let found = try findDevice(byUID: uid) else {
                throw TapFactoryError.deviceNotFound(uid: uid)
            }
            return found
        }
    }

    public static func findDevice(byUID uid: String) throws -> AudioObjectID? {
        for id in try allDevices() {
            if let existingUID = try? deviceUID(id), existingUID == uid {
                return id
            }
        }
        return nil
    }

    /// Case-insensitive name match (Section 3.8 / 7.2). Returns all matches
    /// so the caller can distinguish "none" / "exactly one" / "ambiguous".
    public static func findDevices(byName name: String) throws -> [AudioObjectID] {
        let lowered = name.lowercased()
        var matches: [AudioObjectID] = []
        for id in try allDevices() {
            if let existingName = try? deviceName(id), existingName.lowercased() == lowered {
                matches.append(id)
            }
        }
        return matches
    }
}
