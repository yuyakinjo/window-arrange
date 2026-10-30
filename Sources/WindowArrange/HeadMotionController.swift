import AppKit
import ApplicationServices
import CoreMotion
import SwiftUI
import ArrangementCore
import OSLog

enum HeadMotionMode: String, CaseIterable {
    case turn, tilt

    var title: String { self == .turn ? "素早く左右を向く" : "左右に傾ける" }
}

@MainActor
final class HeadMotionController: ObservableObject {
    @Published private(set) var monitoring = false
    @Published private(set) var receiving = false
    @Published private(set) var enabled = false
    @Published private(set) var calibrated = false
    @Published private(set) var degrees: Double = 0
    @Published private(set) var status = "AirPodsをMacに接続して、装着してください。"
    @Published private(set) var lastAction = "まだ操作していません"
    @Published private(set) var gestureStatus = "切り替えはオフです"
    @Published var mode: HeadMotionMode {
        didSet {
            defaults.set(mode.rawValue, forKey: "headMotionMode")
            invalidatePose()
            if receiving { status = "操作方法を変更しました。画面を正面に見て、正面を登録し直してください。" }
        }
    }
    @Published var turnThreshold: Double {
        didSet { defaults.set(turnThreshold, forKey: "headTurnThreshold"); resetGestures() }
    }
    @Published var turnSpeed: Double {
        didSet { defaults.set(turnSpeed, forKey: "headTurnSpeed"); resetGestures() }
    }
    @Published var threshold: Double {
        didSet { defaults.set(threshold, forKey: "headTiltThreshold"); resetGestures() }
    }
    @Published var reversed: Bool {
        didSet { defaults.set(reversed, forKey: "headTiltReversed"); resetGestures() }
    }
    var isBusy: () -> Bool = { false }
    private let defaults: UserDefaults
    private let manager = CMHeadphoneMotionManager()
    private var gesture = HeadTiltGesture()
    private var turnGesture = HeadTurnGesture()
    private var neutral: Double?
    private var latestRoll: Double?
    private var latestYaw: Double?
    private var latestArrival: TimeInterval?
    private var latestSensorTime: TimeInterval?
    private var lastDisplayTime: TimeInterval = 0
    private var watchdog: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var session = UUID()
    private var loggedFirstSample = false
    private var menuTracking = false

    func setMenuTracking(_ tracking: Bool) {
        menuTracking = tracking
        resetGestures()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = HeadMotionMode(rawValue: defaults.string(forKey: "headMotionMode") ?? "") ?? .turn
        let savedTurn = defaults.double(forKey: "headTurnThreshold")
        turnThreshold = savedTurn.isFinite && (10...40).contains(savedTurn) ? savedTurn : 18
        let savedSpeed = defaults.double(forKey: "headTurnSpeed")
        turnSpeed = savedSpeed.isFinite && (40...200).contains(savedSpeed) ? savedSpeed : 90
        let saved = defaults.double(forKey: "headTiltThreshold")
        threshold = saved.isFinite && (10...40).contains(saved) ? saved : 20
        reversed = defaults.bool(forKey: "headTiltReversed")
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
                self?.status = "スリープで停止しました。「接続を開始」で再開してください。"
            }
        }
    }

    deinit {
        watchdog?.invalidate()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    func start() {
        stop()
        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        guard authorization != .denied && authorization != .restricted else {
            status = "モーションの利用が許可されていません。システム設定の「プライバシーとセキュリティ」を確認してください。"
            return
        }
        guard manager.isDeviceMotionAvailable else {
            status = "モーションを利用できません。対応するAirPodsをMacに接続・装着して再試行してください。"
            return
        }
        monitoring = true
        loggedFirstSample = false
        status = "AirPodsからのデータを待っています…"
        let currentSession = session
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            // Core Motion invokes this on OperationQueue.main.
            MainActor.assumeIsolated {
                guard let self, self.monitoring, self.session == currentSession else { return }
                if let error {
                    self.stop()
                    self.status = "モーションを取得できませんでした：\(error.localizedDescription)"
                } else if let motion {
                    self.receive(roll: motion.attitude.roll, yaw: motion.attitude.yaw, timestamp: motion.timestamp)
                }
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.monitoring else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if let latest = self.latestArrival, now - latest > 0.75 {
                    self.invalidatePose()
                    self.receiving = false
                    self.status = "データが途切れました。接続・装着を確認し、復帰後に正面を登録し直してください。"
                } else if self.latestArrival == nil && now - started > 8 {
                    self.status = "データが届いていません。AirPodsの接続先と装着状態、モーションの許可を確認してください。"
                }
            }
        }
    }

    func stop() {
        session = UUID()
        manager.stopDeviceMotionUpdates()
        watchdog?.invalidate()
        watchdog = nil
        monitoring = false
        receiving = false
        latestArrival = nil
        latestSensorTime = nil
        latestRoll = nil
        latestYaw = nil
        invalidatePose()
        status = "停止中です。「接続を開始」で頭の動きを確認できます。"
    }

    func calibrate() {
        guard freshSample, let angle = mode == .turn ? latestYaw : latestRoll else { return }
        neutral = angle
        calibrated = true
        degrees = 0
        enabled = false
        resetGestures()
        status = "正面を登録しました。デスクトップ切り替えを有効にできます。"
    }

    func setEnabled(_ value: Bool) {
        resetGestures()
        if value {
            guard calibrated, freshSample else {
                enabled = false
                status = "AirPodsを接続し、正面の位置を登録してください。"
                return
            }
            guard AXIsProcessTrusted() else {
                enabled = false
                status = "デスクトップの操作にはアクセシビリティの許可が必要です。"
                return
            }
        }
        enabled = value
        gestureStatus = value ? "正面に戻してから操作してください" : "切り替えはオフです"
    }

    func testSwitch(_ direction: HeadTiltDirection) {
        // Manual buttons test macOS keyboard permissions independently of the sensor.
        postSwitch(direction)
    }

    private var freshSample: Bool {
        monitoring && receiving && latestArrival.map { ProcessInfo.processInfo.systemUptime - $0 < 0.5 } == true
    }

    private func invalidatePose() {
        enabled = false
        calibrated = false
        neutral = nil
        degrees = 0
        resetGestures()
        gestureStatus = "切り替えはオフです"
    }

    private func resetGestures() {
        gesture.reset()
        turnGesture.reset()
    }

    private func receive(roll: Double, yaw: Double, timestamp: TimeInterval) {
        guard roll.isFinite, yaw.isFinite, timestamp.isFinite else { invalidatePose(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if !loggedFirstSample {
            loggedFirstSample = true
            Logger(subsystem: "local.windowarrange.app", category: "HeadMotion").notice(
                "First sample: host=\(now, privacy: .public), sensor=\(timestamp, privacy: .public)"
            )
        }
        // Reject queued old samples and detect interruptions even if the watchdog was delayed.
        guard now - timestamp >= -0.1, now - timestamp < 0.5 else { return }
        if let previous = latestSensorTime {
            guard timestamp > previous else { return }
            if timestamp - previous > 0.5 { invalidatePose() }
        }
        let wasReceiving = receiving
        latestRoll = roll
        latestYaw = yaw
        latestArrival = now
        latestSensorTime = timestamp
        receiving = true
        if !wasReceiving { status = "頭の動きを受信しています。画面を正面に見て「今の姿勢を正面にする」を押してください。" }
        // Positive yaw is a left turn; normalize both modes to negative = left.
        let sourceAngle = mode == .turn ? yaw : roll
        let directionSign: Double = mode == .turn ? -1 : 1
        let angle = HeadTiltGesture.relativeDegrees(angle: sourceAngle, neutral: neutral ?? 0) * directionSign * (reversed ? -1 : 1)
        if now - lastDisplayTime >= 0.1 {
            degrees = angle
            lastDisplayTime = now
        }
        guard enabled, calibrated else { return }
        guard !menuTracking else {
            resetGestures()
            updateGestureStatus("メニューを閉じると操作を再開します")
            return
        }
        guard AXIsProcessTrusted() else {
            setEnabled(false)
            status = "アクセシビリティの許可が解除されたため、切り替えを停止しました。"
            return
        }
        guard !isBusy() else {
            resetGestures()
            updateGestureStatus("ほかのウィンドウ操作が終わるのを待っています")
            return
        }
        guard SpaceSwitchEvents.heldModifiers.isEmpty else {
            resetGestures()
            updateGestureStatus("キーボードの修飾キーを離してください")
            return
        }
        if mode == .turn {
            turnGesture.threshold = turnThreshold
            turnGesture.speedThreshold = turnSpeed
            if let direction = turnGesture.update(degrees: angle, time: timestamp) { postSwitch(direction) }
            switch turnGesture.phase {
            case .waitingForNeutral:
                updateGestureStatus(String(format: "正面に戻してください（±%.1f°以内）", turnGesture.neutralTolerance))
            case .coolingDown: updateGestureStatus("次の操作まで少し待っています")
            case .ready: updateGestureStatus("次の操作が可能です。素早く左右を向いてください")
            case .turning: updateGestureStatus("左右を向く動きを確認しています")
            }
            return
        }
        gesture.threshold = threshold
        if let direction = gesture.update(degrees: angle, time: timestamp) { postSwitch(direction) }
        switch gesture.phase {
        case .waitingForNeutral:
            updateGestureStatus(String(format: "正面に戻してください（±%.1f°以内）", gesture.neutralTolerance))
        case .coolingDown: updateGestureStatus("次の操作まで少し待っています")
        case .ready: updateGestureStatus("次の操作が可能です。左右に傾けてください")
        case .holdingTilt: updateGestureStatus("その傾きを少し保ってください")
        }
    }

    private func updateGestureStatus(_ value: String) {
        if gestureStatus != value { gestureStatus = value }
    }

    private func postSwitch(_ direction: HeadTiltDirection) {
        guard !isBusy() else { return }
        guard SpaceSwitchEvents.heldModifiers.isEmpty else {
            lastAction = "キーボードの修飾キーを離してから操作してください"
            return
        }
        guard AXIsProcessTrusted() else {
            lastAction = "アクセシビリティの許可が必要です"
            return
        }
        let shortcut: SpaceSwitchShortcut
        do {
            let domain = "com.apple.symbolichotkeys" as CFString
            CFPreferencesAppSynchronize(domain)
            let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any] ?? [:]
            shortcut = try SpaceSwitchShortcut.resolve(direction, hotKeys: hotKeys)
        } catch {
            lastAction = error.localizedDescription
            return
        }
        let releasedFlags = CGEventSource.flagsState(.hidSystemState).intersection(.maskAlphaShift)
        guard let events = SpaceSwitchEvents.make(shortcut, releasedFlags: releasedFlags) else {
            lastAction = "キー操作を作成できませんでした"
            return
        }
        for event in events { event.post(tap: .cghidEventTap) }
        let time = Date().formatted(date: .omitted, time: .standard)
        lastAction = "\(time)  \(direction == .left ? "← 左" : "右 →")への切り替えを送信"
    }
}
