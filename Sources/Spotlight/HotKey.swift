import Carbon.HIToolbox

// Registers a system-wide keyboard shortcut using Carbon's RegisterEventHotKey.
// It works even when another app is focused, and needs no special permissions.
@MainActor
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onPress: () -> Void

    init(keyCode: Int, modifiers: Int, onPress: @escaping () -> Void) {
        self.onPress = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The C callback can't capture variables, so we smuggle `self` through
        // as a raw pointer and recover it inside the callback.
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hotkey events on the main thread.
                MainActor.assumeIsolated { hotKey.onPress() }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x53504C54), id: 1)  // 'SPLT'
        RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
