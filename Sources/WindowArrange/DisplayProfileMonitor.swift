import AppKit
import IOKit
import ArrangementCore

struct DisplayEnvironment: Equatable {
    struct Geometry: Equatable {
        let id: String
        let frame: CGRect
        let visibleFrame: CGRect
    }
    let profile: DisplayProfile?
    let geometry: [Geometry]
    let label: String

    @MainActor
    static func read(displays: [DisplayRecord]) -> DisplayEnvironment {
        let profile = DisplayProfile.detect(displays: displays, lidClosed: lidClosed())
        return DisplayEnvironment(profile: profile,
            geometry: displays.sorted { $0.id < $1.id }.map { Geometry(id: $0.id, frame: $0.frame, visibleFrame: $0.visibleFrame) },
            label: profile?.label(displays: displays) ?? "画面構成を確認中…")
    }

    private static func lidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        // Apple defines true = closed, false = open, absent = hardware without a lid.
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.boolValue
    }
}

@MainActor
final class DisplayProfileMonitor {
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var gate = ProfileRestoreGate()
    private var previous: DisplayEnvironment?
    private var sleeping = false
    private var screensSleeping = false
    private var sessionInactive = false
    private let read: () -> DisplayEnvironment
    private let enabled: () -> Bool
    private let ready: () -> Bool
    private let changed: (DisplayEnvironment) -> Void
    private let restore: (DisplayProfile) -> Void
    private let interrupt: () -> Void

    init(read: @escaping () -> DisplayEnvironment, enabled: @escaping () -> Bool, ready: @escaping () -> Bool,
         changed: @escaping (DisplayEnvironment) -> Void, restore: @escaping (DisplayProfile) -> Void,
         interrupt: @escaping () -> Void) {
        self.read = read; self.enabled = enabled; self.ready = ready
        self.changed = changed; self.restore = restore; self.interrupt = interrupt
    }

    func start() {
        guard timer == nil else { return }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.gate.invalidate() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.sleeping = true; $0.suspend() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.sleeping = false; $0.gate.invalidate(retry: true) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensSleeping = true; $0.suspend() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensSleeping = false; $0.gate.invalidate(retry: true) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true; $0.suspend() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false; $0.gate.invalidate(retry: true) }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        interrupt()
    }

    func reset() { gate.invalidate(retry: true); interrupt() }
    func markHandled(_ profile: DisplayProfile) { gate.markHandled(profile) }

    private func suspend() { gate.invalidate(retry: true); interrupt() }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (DisplayProfileMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    func poll(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !sleeping, !screensSleeping, !sessionInactive else { return }
        let environment = read()
        if environment != previous {
            let profileChanged = environment.profile != previous?.profile
            gate.invalidate(retry: profileChanged)
            if profileChanged { interrupt() }
            if profileChanged || environment.label != previous?.label { changed(environment) }
            previous = environment
        }
        if let profile = gate.observe(environment.profile, now: now,
                                      enabled: enabled(), ready: ready()) {
            restore(profile)
        }
    }
}
