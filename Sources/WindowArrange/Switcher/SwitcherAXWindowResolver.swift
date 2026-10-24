import ApplicationServices
import Foundation
import Darwin

/// Some apps omit other-Space windows from AXWindows. Like AltTab, resolve their
/// WindowServer IDs to actual AX window roots instead of showing guessed entries.
/// Calls stay on the scanner worker with a bounded time slice per process.
final class SwitcherAXWindowResolver {
    private typealias CreateElement = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private var cursors: [String: (targets: Set<UInt32>, next: UInt64)] = [:]

    deinit { if let handle { dlclose(handle) } }

    func resolve(pid: pid_t, session: String, ids: Set<UInt32>, spaces: NativeSpaces) -> [UInt32: AXUIElement] {
        guard !ids.isEmpty else { cursors.removeValue(forKey: session); return [:] }
        guard let handle, let symbol = dlsym(handle, "_AXUIElementCreateWithRemoteToken") else { return [:] }
        let create = unsafeBitCast(symbol, to: CreateElement.self)
        var cursor = cursors[session].flatMap { $0.targets == ids ? $0.next : nil } ?? 0
        var missing = ids, found: [UInt32: AXUIElement] = [:]
        let deadline = DispatchTime.now().uptimeNanoseconds + 40_000_000
        // Remote AX tokens encode pid, a reserved word, the Cocoa marker and an
        // element ID in native byte order. No application content is traversed.
        func bytes<T>(_ value: T) -> Data { withUnsafeBytes(of: value) { Data($0) } }
        var token = bytes(pid) + bytes(UInt32(0)) + bytes(UInt32(0x636f636f)) + bytes(cursor)
        while !missing.isEmpty && DispatchTime.now().uptimeNanoseconds < deadline {
            token.replaceSubrange(12..<20, with: bytes(cursor))
            cursor &+= 1
            guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.01)
            guard let id = spaces.windowID(element), missing.contains(id),
                  DispatchTime.now().uptimeNanoseconds < deadline,
                  AX.string(element, kAXRoleAttribute) == kAXWindowRole else { continue }
            found[id] = element
            missing.remove(id)
        }
        cursors[session] = (ids, cursor)
        return found
    }

    func retain(sessions: Set<String>) { cursors = cursors.filter { sessions.contains($0.key) } }
}
