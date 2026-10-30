import Foundation

public enum HeadTiltDirection: Sendable {
    case left, right
}

/// One gesture per deliberate tilt. A stable neutral pose is required to rearm.
public struct HeadTiltGesture {
    public enum Phase { case waitingForNeutral, coolingDown, ready, holdingTilt }
    public private(set) var phase: Phase = .waitingForNeutral
    public var threshold: Double = 20
    public var holdDuration: TimeInterval = 0.18
    public var neutralDuration: TimeInterval = 0.2
    public var cooldown: TimeInterval = 0.8
    public var maximumSampleGap: TimeInterval = 0.5
    private var previousTime: TimeInterval?
    private var neutralSince: TimeInterval?
    private var candidate: HeadTiltDirection?
    private var candidateSince: TimeInterval?
    private var lastTrigger: TimeInterval?
    private var armed = false

    public init() {}

    public var neutralTolerance: Double { max(5, max(8, threshold) * 0.5) }

    public mutating func reset() {
        previousTime = nil
        neutralSince = nil
        candidate = nil
        candidateSince = nil
        lastTrigger = nil
        armed = false
        phase = .waitingForNeutral
    }

    public static func relativeDegrees(angle: Double, neutral: Double) -> Double {
        atan2(sin(angle - neutral), cos(angle - neutral)) * 180 / .pi
    }

    public mutating func update(degrees: Double, time: TimeInterval) -> HeadTiltDirection? {
        guard degrees.isFinite, time.isFinite else { reset(); return nil }
        if let previousTime, time <= previousTime || time - previousTime > maximumSampleGap { reset() }
        previousTime = time
        let triggerThreshold = max(8, threshold)
        let cooledDown = lastTrigger.map { time - $0 >= cooldown } ?? true
        if abs(degrees) <= neutralTolerance {
            candidate = nil
            candidateSince = nil
            if neutralSince == nil { neutralSince = time }
            // Remember a neutral return even while the minimum interval is running.
            if time - (neutralSince ?? time) >= neutralDuration { armed = true }
            phase = armed ? (cooledDown ? .ready : .coolingDown) : .waitingForNeutral
            return nil
        }
        neutralSince = nil
        guard armed, abs(degrees) >= triggerThreshold else {
            candidate = nil
            candidateSince = nil
            phase = armed ? (cooledDown ? .ready : .coolingDown) : .waitingForNeutral
            return nil
        }
        phase = cooledDown ? .holdingTilt : .coolingDown
        let direction: HeadTiltDirection = degrees < 0 ? .left : .right
        if candidate != direction {
            candidate = direction
            candidateSince = time
            return nil
        }
        guard cooledDown, time - (candidateSince ?? time) >= holdDuration else { return nil }
        armed = false
        phase = .waitingForNeutral
        lastTrigger = time
        candidate = nil
        candidateSince = nil
        return direction
    }
}
