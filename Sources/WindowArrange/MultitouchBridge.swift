import AppKit
import ArrangementCore
import Darwin

// Layout of MultitouchSupport's MTTouch. Only the identifier and the normalized
// position are read; the remaining fields exist to keep the stride correct.
private struct MTPoint { var x: Float; var y: Float }
private struct MTVector { var position: MTPoint; var velocity: MTPoint }
private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTVector
    var zero2: Int32
    var zero3: Int32
    var density: Float
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (MTDeviceRef?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32

/// Receives raw trackpad contacts from the system-internal MultitouchSupport framework.
///
/// Public scroll events carry no finger position, so an edge gesture cannot be built on
/// them. Symbols are resolved lazily: a macOS release that drops them leaves `available`
/// false instead of crashing the app.
final class MultitouchBridge {
    static let shared = MultitouchBridge()

    private typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias Register = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    private typealias Unregister = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    private typealias StartDevice = @convention(c) (MTDeviceRef, Int32) -> Void
    private typealias StopDevice = @convention(c) (MTDeviceRef) -> Void

    private let handle: UnsafeMutableRawPointer?
    private let createList: CreateList?
    private let register: Register?
    private let unregister: Unregister?
    private let startDevice: StartDevice?
    private let stopDevice: StopDevice?
    private var devices: [AnyObject] = []

    /// Called on the main queue with the contacts of one frame.
    var onFrame: (([TrackpadContact], TimeInterval) -> Void)?
    private(set) var running = false

    private init() {
        let framework = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
        handle = framework
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let framework, let address = dlsym(framework, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        createList = symbol("MTDeviceCreateList", CreateList.self)
        register = symbol("MTRegisterContactFrameCallback", Register.self)
        unregister = symbol("MTUnregisterContactFrameCallback", Unregister.self)
        startDevice = symbol("MTDeviceStart", StartDevice.self)
        stopDevice = symbol("MTDeviceStop", StopDevice.self)
    }

    var available: Bool {
        createList != nil && register != nil && unregister != nil && startDevice != nil && stopDevice != nil
    }

    /// Attaches to every multitouch device currently present. Returns the number attached.
    @discardableResult
    func start() -> Int {
        stop()
        guard available, let createList, let register, let startDevice else { return 0 }
        guard let list = createList()?.takeRetainedValue() as? [AnyObject] else { return 0 }
        for device in list {
            let reference = Unmanaged.passUnretained(device).toOpaque()
            register(reference, multitouchFrameCallback)
            startDevice(reference, 0)
        }
        // Hold the devices so the callbacks stay registered against live objects.
        devices = list
        running = !list.isEmpty
        return list.count
    }

    func stop() {
        running = false
        guard let unregister, let stopDevice else { devices = []; return }
        for device in devices {
            let reference = Unmanaged.passUnretained(device).toOpaque()
            stopDevice(reference)
            unregister(reference, multitouchFrameCallback)
        }
        devices = []
    }
}

/// The C callback cannot capture context, so frames go through this sink.
private nonisolated(unsafe) let multitouchFrameCallback: MTContactCallback = { _, touches, count, timestamp, _ in
    var contacts: [TrackpadContact] = []
    if count > 0, let touches {
        let buffer = touches.assumingMemoryBound(to: MTTouch.self)
        contacts.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let touch = buffer[index]
            contacts.append(TrackpadContact(identifier: Int(touch.identifier),
                                            x: Double(touch.normalized.position.x),
                                            y: Double(touch.normalized.position.y)))
        }
    }
    let frame = contacts
    // The callback runs on a framework thread; hop before touching app state.
    DispatchQueue.main.async {
        MainActor.assumeIsolated { MultitouchBridge.shared.onFrame?(frame, timestamp) }
    }
    return 0
}
