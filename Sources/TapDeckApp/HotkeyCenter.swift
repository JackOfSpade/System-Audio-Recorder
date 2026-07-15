import Carbon
import Foundation

/// Global hotkeys via Carbon's `RegisterEventHotKey` (Section 3.13). GUI-only
/// — never linked into TapKit or anywhere near the capture path (Section
/// 2.2). Default: ⌃⌥⌘R = toggle record.
final class HotkeyCenter {
    // Keyed by hotkey id, matching `actions` — `register` supports more than
    // one simultaneously-registered hotkey, so a single scalar ref would
    // only ever remember the most recently registered one, silently
    // leaking every earlier registration's ref (and making `unregisterAll`
    // a no-op for them).
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    private static let signature: OSType = 0x54415044 // 'TAPD'

    /// Registration failure (e.g. `eventHotKeyExists`) detects collisions
    /// with hotkeys registered by OTHER apps only; macOS system shortcuts
    /// generally do not fail registration and cannot be reliably detected
    /// (Section 3.13).
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        if handlerRef == nil {
            installHandler()
        }
        // Re-registering an id already in use (e.g. the user rebinding a
        // shortcut) would otherwise overwrite `hotKeyRefs[id]` with the new
        // ref while the OLD ref stays registered with Carbon forever — the
        // previous key combo would keep firing (now dispatching to the NEW
        // action, since lookups are by `id`), in addition to the new combo.
        if let existingRef = hotKeyRefs[id] {
            UnregisterEventHotKey(existingRef)
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            hotKeyRefs.removeValue(forKey: id)
            actions.removeValue(forKey: id)
            return false
        }
        hotKeyRefs[id] = ref
        actions[id] = action
        return true
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actions.removeAll()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            // A failed fetch leaves `hotKeyID` as its zero-initialized
            // default — dispatching on that would silently invoke whatever
            // action (if any) happens to be registered under id 0, instead
            // of surfacing the failure.
            guard status == noErr else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.actions[hotKeyID.id]?()
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)
    }

    deinit {
        // `installHandler()` hands Carbon an unretained pointer to `self`
        // via `Unmanaged.passUnretained` — Carbon does not own a reference,
        // so nothing else guarantees this handler (and every hotkey
        // registration) is torn down before `self` goes away. Without this,
        // a deallocated HotkeyCenter would leave a dangling callback target
        // registered with the OS.
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
    }

    /// Default combo: ⌃⌥⌘R.
    static let defaultToggleRecordKeyCode = UInt32(kVK_ANSI_R)
    static let defaultToggleRecordModifiers = UInt32(controlKey | optionKey | cmdKey)
}
