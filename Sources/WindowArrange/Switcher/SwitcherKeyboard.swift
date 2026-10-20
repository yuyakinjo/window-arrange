import AppKit
import Carbon
import ArrangementCore

final class SwitcherKeyboard {
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowed = Set<CGKeyCode>()
    private var heldModifiers: UInt32 = 0
    private var recordingCommandTab: ((Shortcut) -> Void)?
    private let nativeCommandTab = NativeCommandTab.shared
    private(set) var settings = SwitcherSettings()
    var active = false
    var suspended = false
    var onSummon: ((Bool) -> Void)?
    var onCommand: ((SwitcherCommand) -> Void)?
    var onRelease: (() -> Void)?
    var onOutsideClick: ((CGPoint) -> Bool)?
    var onInputFailure: (() -> Void)?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == 0x57535749 else { return OSStatus(eventNotHandledErr) }
            let keyboard = Unmanaged<SwitcherKeyboard>.fromOpaque(context).takeUnretainedValue()
            if id.id == 3 || id.id == 4 {
                let reverse = id.id == 4
                keyboard.recordingCommandTab?(Shortcut(keyCode: 48, modifiers: reverse ? 256 | 512 : 256, label: reverse ? "⇧⌘⇥" : "⌘⇥"))
            } else if !keyboard.suspended { keyboard.onSummon?(id.id == 2) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    deinit { stop() }
    func stop() {
        recordingCommandTab = nil
        nativeCommandTab.restore()
        hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys.removeAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
    func configure(_ settings: SwitcherSettings) throws {
        try nativeCommandTab.replace([])
        hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys.removeAll()
        self.settings = settings
        if recordingCommandTab != nil {
            do {
                try register(Shortcut(keyCode: 48, modifiers: 256, label: "⌘⇥"), id: 3)
                try register(Shortcut(keyCode: 48, modifiers: 256 | 512, label: "⇧⌘⇥"), id: 4)
                try nativeCommandTab.replace([1, 2])
            } catch {
                hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys.removeAll()
                throw error
            }
            return
        }
        guard settings.enabled, !suspended else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            return
        }
        guard handler != nil else { throw ArrangeError("ウィンドウ切替のキー受信を開始できませんでした。") }
        do {
            try register(settings.summon, id: 1)
            // Shift+summon can start a session backwards, as well as reverse an open one.
            if settings.summon.modifiers & UInt32(shiftKey) == 0 {
                var reverse = settings.summon; reverse.modifiers |= UInt32(shiftKey)
                try register(reverse, id: 2)
            }
            let nativeIDs = NativeCommandTab.hotKeyIDs(for: settings.summon)
            if !nativeIDs.isEmpty {
                guard ensureEventTap() else { throw ArrangeError("⌘Tabで切替画面を開くには、アクセシビリティの許可が必要です。") }
                try nativeCommandTab.replace(nativeIDs)
            }
        } catch {
            hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys.removeAll()
            throw error
        }
        _ = ensureEventTap()
    }
    func validateSummon(_ shortcut: Shortcut) throws {
        // Recording already holds these exact chords; registering them twice would fail.
        if recordingCommandTab != nil, !NativeCommandTab.hotKeyIDs(for: shortcut).isEmpty { return }
        var references: [EventHotKeyRef] = []
        defer { references.forEach { UnregisterEventHotKey($0) } }
        var chords = [shortcut]
        if shortcut.modifiers & UInt32(shiftKey) == 0 {
            var reverse = shortcut; reverse.modifiers |= UInt32(shiftKey); chords.append(reverse)
        }
        for (index, chord) in chords.enumerated() {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(chord.keyCode, chord.modifiers, EventHotKeyID(signature: 0x57535749, id: UInt32(index + 3)),
                GetApplicationEventTarget(), 0, &reference)
            guard status == noErr, let reference else { throw ArrangeError("この呼び出しキーはmacOSまたは他のアプリで使用中か、登録できない組み合わせです（\(status)）。") }
            references.append(reference)
        }
    }
    func beginShortcutRecording(_ receive: @escaping (Shortcut) -> Void) throws {
        recordingCommandTab = receive
        do { try configure(settings) }
        catch { recordingCommandTab = nil; throw error }
    }
    func endShortcutRecording() {
        guard recordingCommandTab != nil else { return }
        recordingCommandTab = nil
        nativeCommandTab.restore()
        hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys.removeAll()
    }
    private func register(_ shortcut: Shortcut, id: UInt32) throws {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: 0x57535749, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw ArrangeError("切替キー「\(shortcut.label)」を登録できません。macOSや他の操作との競合を確認してください（\(status)）。") }
        hotKeys.append(ref)
    }
    @discardableResult
    func ensureEventTap() -> Bool {
        guard AXIsProcessTrusted() else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            return false
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return true }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<SwitcherKeyboard>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func begin(holding: Bool) {
        active = true
        heldModifiers = holding ? settings.summon.modifiers : 0
    }
    func end() { active = false; heldModifiers = 0 }
    static func modifiers(_ flags: CGEventFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.maskCommand) { value |= UInt32(cmdKey) }
        if flags.contains(.maskControl) { value |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { value |= UInt32(optionKey) }
        if flags.contains(.maskShift) { value |= UInt32(shiftKey) }
        return value
    }
    var holdReleased: Bool {
        let current = Self.modifiers(CGEventSource.flagsState(.combinedSessionState))
        return heldModifiers != 0 && current & heldModifiers != heldModifiers
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if active { DispatchQueue.main.async { [weak self] in self?.onInputFailure?() } }
            return Unmanaged.passUnretained(event)
        }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, swallowed.remove(code) != nil { return nil }
        guard active, !suspended else { return Unmanaged.passUnretained(event) }
        if type == .flagsChanged {
            let modifiers = Self.modifiers(event.flags)
            if heldModifiers != 0 && modifiers & heldModifiers != heldModifiers {
                heldModifiers = 0
                DispatchQueue.main.async { [weak self] in self?.onRelease?() }
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            _ = onOutsideClick?(event.location)
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        swallowed.insert(code)
        let command = SwitcherKeyRouting.command(key: Shortcut(keyCode: UInt32(code), modifiers: Self.modifiers(event.flags), label: ""),
            settings: settings, heldModifiers: heldModifiers)
        if let command { DispatchQueue.main.async { [weak self] in self?.onCommand?(command) } }
        return nil
    }
}
