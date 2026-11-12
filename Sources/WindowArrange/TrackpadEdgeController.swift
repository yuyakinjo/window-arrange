import AppKit
import ApplicationServices
import ArrangementCore
import SwiftUI

@MainActor
final class TrackpadEdgeController: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var deviceCount = 0
    @Published private(set) var status = "オフです。トラックパッドの端を使うには有効にしてください。"
    @Published private(set) var lastAction = "まだ操作していません"
    /// Live readout, so the strip and the slide direction can be checked on the real device.
    @Published private(set) var contactCount = 0
    @Published private(set) var touchX: Double = 0
    @Published private(set) var touchY: Double = 0
    @Published private(set) var insideZone: TrackpadEdge?

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: "trackpadEdgeEnabled")
            if enabled { start() } else { stop() }
        }
    }
    @Published var zoneWidth: Double {
        didSet { defaults.set(zoneWidth, forKey: "trackpadEdgeZoneWidth"); gesture.zoneWidth = zoneWidth; gesture.reset() }
    }
    @Published var stepDistance: Double {
        didSet { defaults.set(stepDistance, forKey: "trackpadEdgeStepDistance"); applyDistances() }
    }
    /// Left edge controls brightness by default; swapping moves it to the right edge.
    @Published var swapped: Bool {
        didSet { defaults.set(swapped, forKey: "trackpadEdgeSwapped"); applyEdges() }
    }
    /// Set when sliding toward the far edge should lower the value instead of raising it.
    @Published var reversed: Bool {
        didSet { defaults.set(reversed, forKey: "trackpadEdgeReversed"); gesture.reset() }
    }
    @Published var fineControl: Bool {
        didSet { defaults.set(fineControl, forKey: "trackpadEdgeFineControl") }
    }
    @Published var brightnessEdgeEnabled: Bool {
        didSet { defaults.set(brightnessEdgeEnabled, forKey: "trackpadEdgeBrightnessEnabled"); applyEdges() }
    }
    @Published var volumeEdgeEnabled: Bool {
        didSet { defaults.set(volumeEdgeEnabled, forKey: "trackpadEdgeVolumeEnabled"); applyEdges() }
    }

    var isBusy: () -> Bool = { false }
    private let defaults: UserDefaults
    private let bridge = MultitouchBridge.shared
    private var gesture = TrackpadEdgeSlide()
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var lastReadout: TimeInterval = 0

    var available: Bool { bridge.available }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "trackpadEdgeEnabled")
        let savedZone = defaults.double(forKey: "trackpadEdgeZoneWidth")
        zoneWidth = (0.04...0.2).contains(savedZone) ? savedZone : 0.09
        let savedStep = defaults.double(forKey: "trackpadEdgeStepDistance")
        stepDistance = (0.02...0.12).contains(savedStep) ? savedStep : 0.045
        swapped = defaults.bool(forKey: "trackpadEdgeSwapped")
        reversed = defaults.bool(forKey: "trackpadEdgeReversed")
        fineControl = defaults.bool(forKey: "trackpadEdgeFineControl")
        brightnessEdgeEnabled = defaults.object(forKey: "trackpadEdgeBrightnessEnabled") as? Bool ?? true
        volumeEdgeEnabled = defaults.object(forKey: "trackpadEdgeVolumeEnabled") as? Bool ?? true
        gesture.zoneWidth = zoneWidth
        applyDistances()
        applyEdges()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.suspendForSleep() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Devices lose their callbacks across sleep, so attach again on wake.
            Task { @MainActor in if self?.enabled == true { self?.start() } }
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
    }

    /// Starts listening if the feature was left on. Safe to call on every launch.
    func startIfEnabled() {
        guard enabled else { return }
        start()
    }

    func start() {
        guard bridge.available else {
            running = false
            status = "このmacOSではトラックパッドの生データを取得できません。機能を利用できません。"
            return
        }
        gesture.reset()
        bridge.onFrame = { [weak self] contacts, time in
            MainActor.assumeIsolated { self?.receive(contacts: contacts, time: time) }
        }
        deviceCount = bridge.start()
        running = bridge.running
        guard running else {
            status = "トラックパッドが見つかりません。内蔵トラックパッドかMagic Trackpadを接続してください。"
            return
        }
        status = AXIsProcessTrusted()
            ? "トラックパッドの端を見ています。"
            : "アクセシビリティの許可が必要です。許可すると明るさ・音量を操作できます。"
    }

    func stop() {
        bridge.stop()
        bridge.onFrame = nil
        running = false
        deviceCount = 0
        contactCount = 0
        insideZone = nil
        gesture.reset()
        status = "オフです。トラックパッドの端を使うには有効にしてください。"
    }

    func test(_ key: MediaKey) {
        perform(key)
    }

    /// Which control each edge drives, after the swap setting.
    func target(for edge: TrackpadEdge) -> String {
        brightnessEdge == edge ? "明るさ" : "音量"
    }

    private var brightnessEdge: TrackpadEdge { swapped ? .right : .left }

    private func applyEdges() {
        var edges: Set<TrackpadEdge> = []
        if brightnessEdgeEnabled { edges.insert(brightnessEdge) }
        if volumeEdgeEnabled { edges.insert(brightnessEdge == .left ? .right : .left) }
        gesture.enabledEdges = edges
        gesture.reset()
    }

    private func applyDistances() {
        gesture.stepDistance = stepDistance
        gesture.activationDistance = max(0.02, stepDistance * 0.8)
        gesture.reset()
    }

    private func suspendForSleep() {
        bridge.stop()
        running = false
        contactCount = 0
        insideZone = nil
        gesture.reset()
        status = "スリープ中は停止しています。復帰すると自動で再開します。"
    }

    private func receive(contacts: [TrackpadContact], time: TimeInterval) {
        guard running else { return }
        updateReadout(contacts)
        let steps = gesture.update(contacts: contacts, time: time)
        guard !steps.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            status = "アクセシビリティの許可が必要です。システム設定の「プライバシーとセキュリティ」で許可してください。"
            return
        }
        // Option with a volume or brightness key opens System Settings instead of adjusting.
        guard SpaceSwitchEvents.heldModifiers.isEmpty else {
            lastAction = "キーボードの修飾キーを離してから操作してください"
            return
        }
        guard !isBusy() else { return }
        for step in steps { perform(key(for: step)) }
    }

    private func key(for step: TrackpadEdgeStep) -> MediaKey {
        let up = reversed ? step.direction < 0 : step.direction > 0
        if step.edge == brightnessEdge { return up ? .brightnessUp : .brightnessDown }
        return up ? .volumeUp : .volumeDown
    }

    private func perform(_ key: MediaKey) {
        guard MediaKeyEvents.post(key, fine: fineControl) else {
            lastAction = "キー操作を作成できませんでした"
            return
        }
        let time = Date().formatted(date: .omitted, time: .standard)
        lastAction = "\(time)  \(key.title)"
    }

    private func updateReadout(_ contacts: [TrackpadContact]) {
        let zone: TrackpadEdge? = contacts.first.flatMap { contact in
            contact.x <= zoneWidth ? .left : contact.x >= 1 - zoneWidth ? .right : nil
        }
        if zone != insideZone { insideZone = zone }
        // Redraw at most ten times a second; the device reports about 125 frames.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReadout >= 0.1 || contacts.isEmpty != (contactCount == 0) else { return }
        lastReadout = now
        contactCount = contacts.count
        if let contact = contacts.first {
            touchX = contact.x
            touchY = contact.y
        }
    }
}
