import AppKit
import ApplicationServices
import ArrangementCore
import ObjectiveC.runtime
import Darwin

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
    private let skyLight: UnsafeMutableRawPointer?
    private let applicationServices: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let copyDisplays: CopyDisplays?
    private let copySpaces: CopySpaces?
    private let getWindow: GetWindow?
    private let moveWindows: MoveWindows?
    private let bridgeOperation: BridgeOperation?

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
    }
    // Keep loaded handles alive for the lifetime of the adapter.
    deinit { if let skyLight { dlclose(skyLight) }; if let applicationServices { dlclose(applicationServices) } }

    private var hasBridgeEntryPoint: Bool {
        guard let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") else { return false }
        return class_getInstanceMethod(cls, NSSelectorFromString("performWithWMBridgeDelegate")) != nil
    }
    var available: Bool { connection != nil && copyDisplays != nil && copySpaces != nil && getWindow != nil && (moveWindows != nil || bridgeOperation != nil || hasBridgeEntryPoint) }

    func spaces() throws -> [LiveSpace] {
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
                guard type.intValue == 0, let uuid = space["uuid"] as? String, !uuid.isEmpty else { continue }
                result.append(LiveSpace(record: SpaceRecord(id: uuid, index: index, label: "デスクトップ \(index)", displayID: displayID), runtimeID: number.uint64Value))
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
    private func memberships(_ id: UInt32) -> [UInt64] {
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
