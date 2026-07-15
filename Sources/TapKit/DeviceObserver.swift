import CoreAudio
import Foundation

/// Reactions this observer drives (Section 7.3/7.4): all callbacks are
/// delivered on the engine queue, already serialized (Section 4.4).
public protocol DeviceObserverDelegate: AnyObject {
    func deviceObserverDefaultOutputChanged(_ observer: DeviceObserver)
    func deviceObserverNominalRateChanged(_ observer: DeviceObserver, deviceID: AudioObjectID)
    func deviceObserverDeviceListChanged(_ observer: DeviceObserver)
}

/// Registers CoreAudio property listeners for default-output-device changes,
/// per-device nominal-sample-rate changes, and device-list changes/device
/// death (Section 4.2). Listener blocks are registered with the engine queue
/// as their dispatch queue, so every reaction is already serialized.
///
/// Section 7.4: "Device/rate notifications can arrive in bursts... wait 500ms
/// and act once on the final observed state." Each `start*` method's listener
/// debounces via a cancel-and-reschedule `DispatchWorkItem`.
public final class DeviceObserver {
    private let engineQueue: DispatchQueue
    public weak var delegate: DeviceObserverDelegate?

    private static let debounceSeconds: TimeInterval = 0.5

    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputDebounce: DispatchWorkItem?

    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateListenerDeviceID: AudioObjectID?
    private var rateDebounce: DispatchWorkItem?

    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var deviceListDebounce: DispatchWorkItem?

    public init(engineQueue: DispatchQueue) {
        self.engineQueue = engineQueue
    }

    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Default output device (Section 7.4)

    public func startObservingDefaultOutput() {
        stopObservingDefaultOutput()
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.debounce(&self.defaultOutputDebounce) { [weak self] in
                guard let self else { return }
                self.delegate?.deviceObserverDefaultOutputChanged(self)
            }
        }
        defaultOutputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, engineQueue, block)
    }

    public func stopObservingDefaultOutput() {
        defaultOutputDebounce?.cancel()
        defaultOutputDebounce = nil
        guard let block = defaultOutputListener else { return }
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, engineQueue, block)
        defaultOutputListener = nil
    }

    // MARK: Nominal sample rate on a specific device (Section 7.3)

    public func startObservingNominalRate(for deviceID: AudioObjectID) {
        stopObservingNominalRate()
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.debounce(&self.rateDebounce) { [weak self] in
                guard let self else { return }
                self.delegate?.deviceObserverNominalRateChanged(self, deviceID: deviceID)
            }
        }
        rateListener = block
        rateListenerDeviceID = deviceID
        AudioObjectAddPropertyListenerBlock(deviceID, &addr, engineQueue, block)
    }

    public func stopObservingNominalRate() {
        rateDebounce?.cancel()
        rateDebounce = nil
        guard let block = rateListener, let deviceID = rateListenerDeviceID else { return }
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(deviceID, &addr, engineQueue, block)
        rateListener = nil
        rateListenerDeviceID = nil
    }

    // MARK: Device list changed / device died (Section 7.5, .fixed policy)

    public func startObservingDeviceList() {
        stopObservingDeviceList()
        var addr = address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.debounce(&self.deviceListDebounce) { [weak self] in
                guard let self else { return }
                self.delegate?.deviceObserverDeviceListChanged(self)
            }
        }
        deviceListListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, engineQueue, block)
    }

    public func stopObservingDeviceList() {
        deviceListDebounce?.cancel()
        deviceListDebounce = nil
        guard let block = deviceListListener else { return }
        var addr = address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, engineQueue, block)
        deviceListListener = nil
    }

    private func debounce(_ slot: inout DispatchWorkItem?, action: @escaping () -> Void) {
        slot?.cancel()
        let item = DispatchWorkItem(block: action)
        slot = item
        engineQueue.asyncAfter(deadline: .now() + Self.debounceSeconds, execute: item)
    }

    deinit {
        stopObservingDefaultOutput()
        stopObservingNominalRate()
        stopObservingDeviceList()
    }
}
