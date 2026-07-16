import CoreAudio
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PermissionOutcome: String {
    case unknown
    case granted
    case notGranted
}

/// Determines TCC status for `SystemAudioCaptureRequests` by attempting a
/// minimal throwaway probe tap (public API only, default); an optional
/// `PRIVATE_TCC_PROBE` build flag adds the private-SPI exact-status probe
/// (Section 9.4). Both paths run on the engine queue (probe attempts can
/// block until the user answers the system prompt).
public enum PermissionBroker {
    private static let lastKnownKey = "permission.audioCapture.lastKnown"

    public static var cachedOutcome: PermissionOutcome {
        get {
            guard let raw = UserDefaults.standard.string(forKey: lastKnownKey) else { return .unknown }
            return PermissionOutcome(rawValue: raw) ?? .unknown
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: lastKnownKey)
        }
    }

    /// The public throwaway-tap probe (Section 9.4 default path). Builds a
    /// minimal global stereo-mixdown tap excluding System Audio Recorder's own PID,
    /// attempts to create it, and immediately destroys it on success.
    @discardableResult
    public static func requestCapturePermission() -> PermissionOutcome {
        #if PRIVATE_TCC_PROBE
        if let privateResult = privateProbe() {
            cachedOutcome = privateResult
            return privateResult
        }
        #endif
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownProcessObjectID = try? ProcessCatalog.translatePIDToProcessObject(ownPID)
        let excludeList: [AudioObjectID] = ownProcessObjectID.map { [$0] } ?? []

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeList)
        description.name = "System Audio Recorder Permission Probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        let outcome: PermissionOutcome
        if status == noErr {
            AudioHardwareDestroyProcessTap(tapID)
            outcome = .granted
        } else {
            outcome = .notGranted
            Log.error("capture permission probe failed (OSStatus \(status)) — treating as not granted")
        }
        cachedOutcome = outcome
        return outcome
    }

    #if PRIVATE_TCC_PROBE
    /// Private-SPI exact-status probe (Section 9.4, build-flag gated,
    /// default OFF in all distributed builds). Soft-links TCC.framework at
    /// runtime and calls the unexported `TCCAccessPreflight` symbol. Falls
    /// back to nil (letting the caller use the public probe) on any failure.
    private static func privateProbe() -> PermissionOutcome? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW) else {
            return nil
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }

        typealias TCCAccessPreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
        let fn = unsafeBitCast(symbol, to: TCCAccessPreflightFn.self)

        let serviceName = "kTCCServiceSystemAudioCapture" as CFString
        let result = fn(serviceName, nil)
        switch result {
        case 0: return .granted
        case 1: return .notGranted
        case 2: return .unknown
        default: return nil
        }
    }
    #endif
}
