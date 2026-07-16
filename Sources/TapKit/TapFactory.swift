import CoreAudio
import Foundation

/// Everything created by one pass of the Section 4.5 recipe: the tap, the
/// private aggregate device, and the format/channel facts read back along the
/// way. `CaptureLane` owns exactly one of these at a time; a rebuild replaces
/// it wholesale (Section 8.2 — partial restarts are known-ineffective).
public struct TapHandle {
    public let tapID: AudioObjectID
    public let tapUID: String
    public let aggregateID: AudioObjectID
    /// Ground truth for the bytes the IOProc will deliver (Section 5/7).
    public let effectiveFormat: AudioStreamBasicDescription
    public let targetDeviceID: AudioObjectID
}

/// Creates and destroys the `CATapDescription`, the process tap, and the
/// private aggregate device. Owns the exact creation recipe (Section 4.5) and
/// the strict teardown order (Section 8.2). No other module calls
/// `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`, or
/// their destroy counterparts — everything here runs on the engine queue.
public enum TapFactory {
    /// Section 4.5, steps 1–5 (steps 6–7, IOProc registration + start, are
    /// `IOProcHost`'s job — TapFactory only builds the tap + aggregate).
    public static func create(
        spec: SessionSpec,
        laneSlug: String,
        excludeProcessIDs: [AudioObjectID],
        bufferFrameSize: UInt32,
        resolvedDeviceID: AudioObjectID? = nil
    ) throws -> TapHandle {
        // Step 1: resolve the target device (skip if the caller already
        // did — e.g. CaptureLane resolves once and reuses it for both the
        // calibration lookup and this call, rather than resolving twice).
        let deviceID = try resolvedDeviceID ?? AudioDeviceDirectory.resolveDevice(for: spec.device)
        let deviceUID = try AudioDeviceDirectory.deviceUID(deviceID)
        let nominalRate = try AudioDeviceDirectory.nominalSampleRate(deviceID)

        // Step 2: build the CATapDescription — always a global system-mix
        // tap excluding `excludeProcessIDs` (Section 4.5 step 2).
        let description = buildDescription(spec: spec, excludeProcessIDs: excludeProcessIDs)

        // Step 3: create the tap; read back UID + format.
        var tapID: AudioObjectID = 0
        let createStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard createStatus == noErr else {
            throw CoreAudioError(status: createStatus, context: "AudioHardwareCreateProcessTap")
        }
        let tapUID = try CAProp.readString(tapID, kAudioTapPropertyUID, context: "kAudioTapPropertyUID")
        let tapFormat = try CAProp.readFixed(
            tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self, context: "kAudioTapPropertyFormat"
        )
        if tapFormat.mSampleRate != nominalRate {
            // Section 7.2: mismatch is logged, never fatal — the tap format
            // is trusted over the device property.
            Log.error("tap format rate \(tapFormat.mSampleRate) != device nominal rate \(nominalRate); trusting tap format.")
        }

        // Step 4: build the aggregate composition dictionary with EXACTLY
        // these keys (Section 4.5 step 4), then create it.
        let aggregateUID = UUID().uuidString
        let compositionDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "System Audio Recorder Capture \(laneSlug)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: deviceUID]
            ],
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
            ]
        ]

        var aggregateID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(compositionDict as CFDictionary, &aggregateID)
        guard aggStatus == noErr else {
            // Roll back the tap we already created before surfacing the error.
            AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError(status: aggStatus, context: "AudioHardwareCreateAggregateDevice")
        }

        // Step 5: set the aggregate's IO buffer size.
        do {
            try AudioDeviceDirectory.setBufferFrameSize(aggregateID, frames: bufferFrameSize)
        } catch {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        return TapHandle(
            tapID: tapID,
            tapUID: tapUID,
            aggregateID: aggregateID,
            effectiveFormat: tapFormat,
            targetDeviceID: deviceID
        )
    }

    /// Section 8.2, the STRICT teardown order — canonical, never reordered:
    /// AudioDeviceStop -> AudioDeviceDestroyIOProcID -> AudioHardwareDestroyAggregateDevice
    /// -> AudioHardwareDestroyProcessTap. IOProc stop/destroy is the caller's
    /// job (IOProcHost owns the procID); TapFactory only tears down what it
    /// created (steps 3 and 4 of this order). Every step tolerates non-noErr
    /// (e.g. the device already died) and always continues to the next step —
    /// a failed destroy must never abort the teardown or leak later objects.
    public static func destroy(_ handle: TapHandle) {
        let aggStatus = AudioHardwareDestroyAggregateDevice(handle.aggregateID)
        if aggStatus != noErr {
            Log.error("AudioHardwareDestroyAggregateDevice returned \(aggStatus); continuing teardown.")
        }
        let tapStatus = AudioHardwareDestroyProcessTap(handle.tapID)
        if tapStatus != noErr {
            Log.error("AudioHardwareDestroyProcessTap returned \(tapStatus); continuing teardown.")
        }
    }

    /// Section 4.5 step 2 — always a global stereo tap of everything the Mac
    /// plays, minus `excludeProcessIDs` (which always includes System Audio Recorder's own
    /// PID, appended by `CaptureLane`), using `CATapDescription`'s
    /// `stereoGlobalTapButExcludeProcesses:` initializer (verified against
    /// the CoreAudio SDK headers directly, not assumed).
    private static func buildDescription(
        spec: SessionSpec,
        excludeProcessIDs: [AudioObjectID]
    ) -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeProcessIDs)

        description.name = "System Audio Recorder Tap"
        description.isPrivate = true
        switch spec.muteBehavior {
        case .unmuted:
            description.muteBehavior = .unmuted
        case .mutedWhenTapped:
            description.muteBehavior = .mutedWhenTapped
        }

        return description
    }
}

public enum TapFactoryError: Error, CustomStringConvertible {
    case deviceNotFound(uid: String)

    public var description: String {
        switch self {
        case .deviceNotFound(let uid): return "Device not found for UID \(uid)"
        }
    }
}
