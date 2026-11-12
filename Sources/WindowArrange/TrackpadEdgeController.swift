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
    /// True while a recent key press is holding the gesture off.
    @Published private(set) var typingBlocked = false

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
    /// Holds the pointer still while a finger is working the strip.
    @Published var suppressPointer: Bool {
        didSet {
            defaults.set(suppressPointer, forKey: "trackpadEdgeSuppressPointer")
            if !suppressPointer { releasePointer() }
        }
    }
    /// Seconds after the last key press during which edge slides are ignored.
    @Published var typingGuard: Double {
        didSet { defaults.set(typingGuard, forKey: "trackpadEdgeTypingGuard") }
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
    private var pin: CGPoint?

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
        suppressPointer = defaults.object(forKey: "trackpadEdgeSuppressPointer") as? Bool ?? true
        let savedGuard = defaults.object(forKey: "trackpadEdgeTypingGuard") as? Double
        typingGuard = (savedGuard.map { (0...2).contains($0) ? $0 : 0.8 }) ?? 0.8
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
        typingBlocked = false
        releasePointer()
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
        typingBlocked = false
        releasePointer()
        gesture.reset()
        status = "スリープ中は停止しています。復帰すると自動で再開します。"
    }

    private func receive(contacts: [TrackpadContact], time: TimeInterval) {
        guard running else { return }
        updateReadout(contacts)
        // Typing with a palm or a fingertip over the strip must never change anything.
        let typing = !contacts.isEmpty && typingGuard > 0
            && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < typingGuard
        if typing != typingBlocked { typingBlocked = typing }
        // Modifiers and a held button mean the finger is aiming the pointer, not the strip,
        // so the gesture stays out of the way instead of freezing the pointer for nothing.
        // Only a lone contact that is still a candidate can reach the gesture, so the
        // modifier and button queries stay off the hot path for every other frame.
        let candidate = contacts.count == 1 && gesture.phase != .waitingForLift
        let suppressed = candidate && (typing
            || !SpaceSwitchEvents.heldModifiers.isEmpty
            || CGEventSource.buttonState(.combinedSessionState, button: .left))
        let steps = gesture.update(contacts: contacts, time: time, suppressed: suppressed)
        updatePointer()
        guard !steps.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            status = "アクセシビリティの許可が必要です。システム設定の「プライバシーとセキュリティ」で許可してください。"
            return
        }
        guard !isBusy() else { return }
        for step in steps { perform(key(for: step)) }
    }

    /// Keeps the pointer where the gesture started. Dropping pointer events in an event
    /// tap does not work: the cursor is drawn before a tap sees the event, so it moves anyway.
    private func updatePointer() {
        guard suppressPointer else { return }
        switch gesture.phase {
        // Before the slide starts the finger may just be aiming the pointer, so hold it
        // only while the finger is still inside the strip itself.
        case .armed where insideZone != nil, .sliding:
            if pin == nil { pin = CGEvent(source: nil)?.location }
            if let pin { CGWarpMouseCursorPosition(pin) }
        default:
            releasePointer()
        }
    }

    private func releasePointer() {
        guard pin != nil else { return }
        pin = nil
        // Warping leaves the pointer briefly deaf to the device; this reconnects it at once.
        CGAssociateMouseAndMouseCursorPosition(1)
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
        if contacts.isEmpty && typingBlocked { typingBlocked = false }
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
