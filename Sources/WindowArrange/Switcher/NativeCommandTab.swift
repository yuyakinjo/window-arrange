import AppKit
import ArrangementCore
import Darwin

/// The Dock consumes Command-Tab before Carbon dispatches registered hotkeys.
/// Preserve its prior state while our registered shortcuts replace it.
final class NativeCommandTab {
    static let shared = NativeCommandTab()
    private typealias IsEnabled = @convention(c) (UInt32) -> Bool
    private typealias SetEnabled = @convention(c) (UInt32, Bool) -> CGError
    private let handle: UnsafeMutableRawPointer?
    private let isEnabled: ((UInt32) -> Bool)?
    private let setEnabled: ((UInt32, Bool) -> CGError)?
    private let defaults: UserDefaults
    private let installsSignalHandlers: Bool
    private var original: [UInt32: Bool] = [:]
    private var signals: [DispatchSourceSignal] = []
    private let recoveryKey = "nativeCommandTabRecovery"

    private convenience init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let get = handle.flatMap { dlsym($0, "CGSIsSymbolicHotKeyEnabled") }.map { unsafeBitCast($0, to: IsEnabled.self) }
        let set = handle.flatMap { dlsym($0, "CGSSetSymbolicHotKeyEnabled") }.map { unsafeBitCast($0, to: SetEnabled.self) }
        self.init(handle: handle, isEnabled: get.map { function in { function($0) } },
                  setEnabled: set.map { function in { function($0, $1) } }, defaults: .standard, installsSignalHandlers: true)
        atexit { NativeCommandTab.shared.restore() }
    }

    init(handle: UnsafeMutableRawPointer? = nil, isEnabled: ((UInt32) -> Bool)?,
         setEnabled: ((UInt32, Bool) -> CGError)?, defaults: UserDefaults, installsSignalHandlers: Bool = false) {
        self.handle = handle
        self.isEnabled = isEnabled; self.setEnabled = setEnabled
        self.defaults = defaults; self.installsSignalHandlers = installsSignalHandlers
        // Recover after an earlier forced termination, without taking over a live instance.
        if let saved = defaults.dictionary(forKey: recoveryKey),
           let pid = saved["pid"] as? Int32, kill(pid, 0) != 0,
           let ids = saved["enabled"] as? [UInt32], let setEnabled {
            if ids.allSatisfy({ setEnabled($0, true) == .success }) {
                defaults.removeObject(forKey: recoveryKey)
            }
        }
    }
    deinit { restore(); if let handle { dlclose(handle) } }

    static func hotKeyIDs(for shortcut: Shortcut) -> [UInt32] {
        guard shortcut.keyCode == 48 else { return [] }
        switch shortcut.modifiers {
        case 256: return [1, 2] // Includes the automatic Shift+summon chord.
        case 256 | 512: return [2]
        default: return []
        }
    }

    func replace(_ ids: [UInt32]) throws {
        restore()
        guard original.isEmpty else { throw ArrangeError("macOS標準の⌘Tabの設定を復元できませんでした。") }
        guard !ids.isEmpty else { return }
        guard let isEnabled, let setEnabled else {
            throw ArrangeError("このmacOSでは⌘Tabの標準アプリ切替との競合を解除できません。別の呼び出しキーを設定してください。")
        }
        if let saved = defaults.dictionary(forKey: recoveryKey),
           let pid = saved["pid"] as? Int32, pid != getpid(), kill(pid, 0) == 0 {
            throw ArrangeError("別のWindow Arrangeが⌘Tabを使用しています。そちらを終了してください。")
        }
        original = Dictionary(uniqueKeysWithValues: ids.map { ($0, isEnabled($0)) })
        defaults.set(["pid": getpid(), "enabled": original.filter(\.value).map(\.key)], forKey: recoveryKey)
        for id in ids where original[id] == true {
            guard setEnabled(id, false) == .success else {
                restore()
                throw ArrangeError("macOS標準の⌘Tabとの競合を解除できませんでした。")
            }
        }
        if installsSignalHandlers, signals.isEmpty {
            for number in [SIGTERM, SIGINT, SIGHUP] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { NativeCommandTab.shared.restore(); NSApp.terminate(nil) }
                source.resume(); signals.append(source)
            }
        }
    }

    func restore() {
        guard !original.isEmpty, let setEnabled else { return }
        for (id, enabled) in original {
            if setEnabled(id, enabled) == .success { original.removeValue(forKey: id) }
        }
        if original.isEmpty { defaults.removeObject(forKey: recoveryKey) }
    }
}
