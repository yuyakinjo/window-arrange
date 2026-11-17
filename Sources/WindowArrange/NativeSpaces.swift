import AppKit
import ApplicationServices
import ArrangementCore
import ObjectiveC.runtime
import Darwin
import CDockSwipe

struct LiveSpace {
    let record: SpaceRecord
    let runtimeID: UInt64
}

/// Optional, experimental system-only adapter. No helper, daemon, injection or SIP changes.
/// Private symbols are loaded lazily; every move is verified against WindowServer state.
final class NativeSpaces {
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopyDisplays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias MoveWindows = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias BridgeOperation = @convention(c) (AnyObject) -> Int64
    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private let skyLight: UnsafeMutableRawPointer?
    private let applicationServices: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let copyDisplays: CopyDisplays?
    private let copySpaces: CopySpaces?
    private let getWindow: GetWindow?
    private let moveWindows: MoveWindows?
    private let bridgeOperation: BridgeOperation?
    private let currentSpace: CurrentSpace?

    init() {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let ax = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        skyLight = sky; applicationServices = ax
        func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
            guard let handle, let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        connection = symbol(sky, "SLSMainConnectionID", Connection.self)
        copyDisplays = symbol(sky, "SLSCopyManagedDisplaySpaces", CopyDisplays.self)
        copySpaces = symbol(sky, "SLSCopySpacesForWindows", CopySpaces.self)
        getWindow = symbol(ax, "_AXUIElementGetWindow", GetWindow.self)
        moveWindows = symbol(sky, "SLSMoveWindowsToManagedSpace", MoveWindows.self)
        bridgeOperation = symbol(sky, "SLSPerformAsynchronousBridgedWindowManagementOperation", BridgeOperation.self)
        currentSpace = symbol(sky, "SLSManagedDisplayGetCurrentSpace", CurrentSpace.self)
    }
    // Keep loaded handles alive for the lifetime of the adapter.
    deinit { if let skyLight { dlclose(skyLight) }; if let applicationServices { dlclose(applicationServices) } }

    private var hasBridgeEntryPoint: Bool {
        guard let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") else { return false }
        return class_getInstanceMethod(cls, NSSelectorFromString("performWithWMBridgeDelegate")) != nil
    }
    var available: Bool { connection != nil && copyDisplays != nil && copySpaces != nil && getWindow != nil && (moveWindows != nil || bridgeOperation != nil || hasBridgeEntryPoint) }

    /// Returns nil when WindowServer cannot identify the relevant display or Space.
    func hasAdjacentSpace(toRight: Bool, displayID: String?) -> Bool? {
        guard let connection, let copyDisplays,
              let displays = copyDisplays(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return Self.hasAdjacentSpace(toRight: toRight, displayID: displayID, displays: displays) { id in
            self.currentSpace?(connection(), id as CFString)
        }
    }

    static func hasAdjacentSpace(toRight: Bool, displayID: String?, displays: [[String: Any]],
                                 currentSpace: (String) -> UInt64?) -> Bool? {
        // With separate Spaces disabled WindowServer reports a single managed display,
        // sometimes named "Main" instead of a physical display UUID.
        let display: [String: Any]?
        if displays.count == 1 { display = displays[0] }
        else if let displayID {
            display = displays.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(displayID) == .orderedSame }
        } else { display = nil }
        guard let display, let id = display["Display Identifier"] as? String,
              let rawSpaces = display["Spaces"] as? [[String: Any]], !rawSpaces.isEmpty else { return nil }
        let ids = rawSpaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard ids.count == rawSpaces.count else { return nil }
        let current = currentSpace(id).flatMap { $0 == 0 ? nil : $0 }
            ?? (display["Current Space"] as? [String: Any]).flatMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard let current, let index = ids.firstIndex(of: current) else { return nil }
        return toRight ? index < ids.count - 1 : index > 0
    }

    func spaces(includeFullscreen: Bool = false) throws -> [LiveSpace] {
        guard available, let connection, let copyDisplays,
              let raw = copyDisplays(connection())?.takeRetainedValue() as? [[String: Any]] else {
            throw ArrangeError("このmacOSではSpaces情報を取得できません。設定でSpacesの記録をオフにすると位置・サイズのみ保存できます。")
        }
        var result: [LiveSpace] = [], index = 0
        for display in raw {
            let displayID = display["Display Identifier"] as? String ?? ""
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let number = space["id64"] as? NSNumber, let type = space["type"] as? NSNumber else { continue }
                index += 1
                guard (type.intValue == 0 || includeFullscreen), let uuid = space["uuid"] as? String, !uuid.isEmpty else { continue }
                result.append(LiveSpace(record: SpaceRecord(id: uuid, index: index, label: type.intValue == 0 ? "デスクトップ \(index)" : "フルスクリーン \(index)", displayID: displayID), runtimeID: number.uint64Value))
            }
        }
        guard !result.isEmpty else { throw ArrangeError("通常のデスクトップを取得できませんでした。Spaces連携はこの環境では利用できません。") }
        return result
    }
    func windowID(_ element: AXUIElement) -> UInt32? {
        var id: UInt32 = 0
        guard let getWindow, getWindow(element, &id) == 0, id != 0 else { return nil }
        return id
    }
    func memberships(_ id: UInt32) -> [UInt64] {
        guard let connection, let copySpaces,
              let values = copySpaces(connection(), 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return values.map(\.uint64Value)
    }
    func spaceForWindow(_ id: UInt32) -> LiveSpace? {
        let ids = memberships(id)
        // Sticky windows have no single desktop to restore.
        guard ids.count == 1 else { return nil }
        return try? spaces().first { $0.runtimeID == ids[0] }
    }
    func activeSpaces(includeFullscreen: Bool = false) throws -> [LiveSpace] {
        guard let connection, let currentSpace else { throw ArrangeError("表示中のSpaceを取得できませんでした。") }
        let all = try spaces(includeFullscreen: includeFullscreen)
        let displays = Set(all.map { $0.record.displayID })
        let active = all.filter { currentSpace(connection(), $0.record.displayID as CFString) == $0.runtimeID }
        guard active.count == displays.count else {
            throw ArrangeError("現在のデスクトップを再表示するための情報を取得できません。フルスクリーンを解除してから再試行してください。")
        }
        return active
    }
    @MainActor
    func activate(_ uuid: String, includeFullscreen: Bool = false) async throws {
        guard let connection, let currentSpace, let copyDisplays,
              let target = try spaces(includeFullscreen: includeFullscreen).first(where: { $0.record.id == uuid }) else {
            throw ArrangeError("表示するSpaceが見つかりませんでした。")
        }
        let displayID = target.record.displayID
        func current() -> UInt64 { currentSpace(connection(), displayID as CFString) }
        if current() == target.runtimeID { return }
        // SLSBridgedManagedDisplaySetCurrentSpaceOperation only rewrites WindowServer's current
        // Space on recent macOS: the screen stays put and the Dock falls out of sync. Ask the Dock
        // instead, one synthetic swipe per Space, in the order Mission Control lists them.
        guard let displays = copyDisplays(connection())?.takeRetainedValue() as? [[String: Any]],
              let display = displays.first(where: { ($0["Display Identifier"] as? String) == displayID }) else {
            throw ArrangeError("表示するSpaceのディスプレイが見つかりませんでした。")
        }
        let order = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        // A swipe switches the display under the pointer.
        let restorePointer = displays.count > 1 ? Self.movePointer(toDisplay: displayID) : nil
        defer { restorePointer?() }
        for _ in 0..<order.count {
            let now = current()
            if now == target.runtimeID { return }
            guard let steps = SpaceSwitchPlan.steps(order: order, current: now, target: target.runtimeID), steps != 0,
                  ds_post_switch(steps < 0 ? DSDirectionLeft : DSDirectionRight) else { break }
            var moved = false
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                if current() != now { moved = true; break }
            }
            guard moved else { break }
        }
        if current() == target.runtimeID { return }
        throw ArrangeError("対象Spaceを表示できませんでした。対象のデスクトップを一度表示してから再試行してください。")
    }
    /// Moves the pointer to the centre of a display identified by its UUID and returns how to put it back.
    private static func movePointer(toDisplay uuid: String) -> (() -> Void)? {
        let original = CGEvent(source: nil)?.location
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        guard let id = ids.first(where: { display in
            guard let raw = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return false }
            return (CFUUIDCreateString(nil, raw) as String).caseInsensitiveCompare(uuid) == .orderedSame
        }) else { return nil }
        let bounds = CGDisplayBounds(id)
        if let original, bounds.contains(original) { return nil }
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
        CGAssociateMouseAndMouseCursorPosition(1)
        guard let original else { return nil }
        return { CGWarpMouseCursorPosition(original); CGAssociateMouseAndMouseCursorPosition(1) }
    }
    @MainActor
    func move(window id: UInt32, to uuid: String) async throws {
        guard let target = try spaces().first(where: { $0.record.id == uuid }) else {
            throw ArrangeError("保存先のSpaceが見つかりません。削除したSpaceは自動作成されません。")
        }
        if memberships(id) == [target.runtimeID] { return }
        if let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
           let performMethod = class_getInstanceMethod(cls, NSSelectorFromString("performWithWMBridgeDelegate")) {
            let allocSelector = NSSelectorFromString("alloc")
            let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
            typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
            typealias Initialize = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?
            guard let meta = object_getClass(cls), let allocIMP = class_getMethodImplementation(meta, allocSelector),
                  let method = class_getInstanceMethod(cls, initSelector) else { throw ArrangeError("Spaces操作のシステムAPIが変更されています。") }
            let allocate = unsafeBitCast(allocIMP, to: Allocate.self)
            let initialize = unsafeBitCast(method_getImplementation(method), to: Initialize.self)
            guard let raw = allocate(cls, allocSelector),
                  let operation = initialize(raw.takeUnretainedValue(), initSelector, [NSNumber(value: id)], target.runtimeID)?.takeRetainedValue() else {
                throw ArrangeError("Spaces操作を開始できませんでした。")
            }
            if let bridgeOperation {
                _ = bridgeOperation(operation)
            } else {
                // Recent macOS versions keep the C dispatcher local, while the operation
                // exposes its asynchronous entry point through the Objective-C runtime.
                typealias Perform = @convention(c) (AnyObject, Selector) -> Void
                let perform = unsafeBitCast(method_getImplementation(performMethod), to: Perform.self)
                perform(operation, NSSelectorFromString("performWithWMBridgeDelegate"))
            }
        } else if let connection, let moveWindows {
            moveWindows(connection(), [NSNumber(value: id)] as CFArray, target.runtimeID)
        } else { throw ArrangeError("このmacOSではSpace間の移動を利用できません。") }
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            if memberships(id) == [target.runtimeID] { return }
        }
        throw ArrangeError("Space間の移動がmacOSに拒否されました。Spaces連携は実験機能で、OSにより動作が異なります。")
    }
}
