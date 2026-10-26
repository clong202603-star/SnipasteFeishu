import Carbon
import Foundation

final class HotkeyManager {
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private static var current: HotkeyManager?
    private static var installed = false

    func register() {
        HotkeyManager.current = self
        if !HotkeyManager.installed {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ -> OSStatus in
                    HotkeyManager.current?.onPress?()
                    return noErr
                },
                1,
                &eventType,
                nil,
                nil
            )
            HotkeyManager.installed = true
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5348_4F54), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_F2),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }
}
