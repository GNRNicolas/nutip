// The one global hotkey, through Carbon's RegisterEventHotKey: the API app
// launchers use, and the only one that works with no permission at all.
import Carbon.HIToolbox
import Foundation

/// A hotkey preset. Stored by name; the table is the only place a combination
/// is spelled out.
enum Hotkey: String, CaseIterable {
    case optionCommandS, controlOptionS, controlOptionSpace, optionSpace, shiftCommandSpace, controlCommandN
    case commandZ   // used by the toast only, never a preset
    case commandY   // likewise: "add the reason I just skipped"

    static var presets: [Hotkey] { allCases.filter { $0 != .commandZ && $0 != .commandY } }

    static var current: Hotkey {
        get { Hotkey(rawValue: Settings.defaults.string(forKey: "hotkey") ?? "") ?? .optionCommandS }
        set { Settings.defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    private var spec: (label: String, key: UInt32, modifiers: Int) {
        switch self {
        // Letters are looked up in the current layout: key code 6 is Z on
        // ANSI and W on AZERTY, and ⌘W is not an undo anyone wants.
        case .commandZ:           return ("⌘Z", KeyCodes.forCharacter("z") ?? 6, cmdKey)
        case .commandY:           return ("⌘Y", KeyCodes.forCharacter("y") ?? 16, cmdKey)
        case .optionCommandS:     return ("⌥⌘S", KeyCodes.forCharacter("s") ?? 1, optionKey | cmdKey)
        case .controlOptionS:     return ("⌃⌥S", KeyCodes.forCharacter("s") ?? 1, controlKey | optionKey)
        case .controlOptionSpace: return ("⌃⌥Space", 49, controlKey | optionKey)
        case .optionSpace:        return ("⌥Space", 49, optionKey)
        case .shiftCommandSpace:  return ("⇧⌘Space", 49, shiftKey | cmdKey)
        case .controlCommandN:    return ("⌃⌘N", KeyCodes.forCharacter("n") ?? 45, controlKey | cmdKey)
        }
    }

    var label: String { spec.label }
    var keyCode: UInt32 { spec.key }
    var carbonModifiers: UInt32 { UInt32(spec.modifiers) }
}

final class GlobalHotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onPress: (() -> Void)?
    private static let signature: OSType = 0x4E555449  // 'NUTI'
    private static var nextID: UInt32 = 1
    private let id: UInt32 = { defer { nextID += 1 }; return nextID }()

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Several instances share the application target, so each checks
        // the hotkey id is its own before acting.
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            guard hk.id == me.id else { return OSStatus(eventNotHandledErr) }
            me.onPress?()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Replaces whatever was registered. macOS accepts a combination already
    /// held by another app without complaint, so a silent conflict shows up as
    /// "nothing happens": the menu bar item is always there as a way in.
    func register(_ hotkey: Hotkey, onPress: @escaping () -> Void) {
        unregister()
        self.onPress = onPress
        let id = EventHotKeyID(signature: GlobalHotkey.signature, id: self.id)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.write("hotkey: RegisterEventHotKey refused \(hotkey.label) (status \(status))") }
        else { Log.write("hotkey: \(hotkey.label) (key code \(hotkey.keyCode))") }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// Key code of the key that produces a character on the current keyboard
/// layout. Carbon hotkeys are registered by key code, and key codes are
/// positions, not letters.
enum KeyCodes {
    static func forCharacter(_ char: String) -> UInt32? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = unsafeBitCast(layoutData, to: CFData.self) as Data
        let wanted = char.lowercased()
        return data.withUnsafeBytes { raw -> UInt32? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            for code in 0..<128 {
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                            UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                                            &dead, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == wanted {
                    return UInt32(code)
                }
            }
            return nil
        }
    }
}
