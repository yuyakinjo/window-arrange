import AppKit
import SwiftUI
import Carbon
import ArrangementCore

final class HotKeyManager {
    private var handler: EventHandlerRef?
    private var references: [WindowAction: EventHotKeyRef] = [:]
    var onTrigger: ((WindowAction) -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x57415252 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            let index = Int(identifier.id) - 1
            guard WindowAction.allCases.indices.contains(index) else { return OSStatus(eventNotHandledErr) }
            let action = WindowAction.allCases[index]
            DispatchQueue.main.async { [weak manager] in manager?.onTrigger?(action) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    deinit { suspend(); if let handler { RemoveEventHandler(handler) } }
    func suspend() { for ref in references.values { UnregisterEventHotKey(ref) }; references.removeAll() }
    @discardableResult
    func configure(_ shortcuts: [String: Shortcut]) -> [String] {
        suspend()
        var failures: [String] = []
        for action in WindowAction.allCases {
            guard let shortcut = shortcuts[action.rawValue] else { continue }
            if (try? register(shortcut, for: action)) == nil { failures.append(action.title) }
        }
        return failures
    }
    func register(_ shortcut: Shortcut, for action: WindowAction) throws {
        guard handler != nil else { throw ArrangeError("グローバルショートカットの受信を開始できませんでした。") }
        if let old = references.removeValue(forKey: action) { UnregisterEventHotKey(old) }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x57415252, id: UInt32(WindowAction.allCases.firstIndex(of: action)! + 1))
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            throw ArrangeError("このキーはmacOSまたは別のアプリで使用中か、登録できない組み合わせです（\(status)）。")
        }
        references[action] = ref
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var receive: (Shortcut?) -> Void
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView(); view.receive = receive
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: CaptureView, context: Context) { nsView.receive = receive }
    final class CaptureView: NSView {
        var receive: ((Shortcut?) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { receive?(nil); return }
            guard !event.isARepeat else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control) else { NSSound.beep(); return }
            var modifiers: UInt32 = 0, label = ""
            if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
            if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
            if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
            let names: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            let key = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            receive?(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label + key))
        }
    }
}
