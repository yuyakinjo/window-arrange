import Foundation

/// A quick outward yaw from a stable neutral pose, followed by a neutral return.
/// Angles are in degrees, with negative values meaning left.
public struct HeadTurnGesture {
    public enum Phase { case waitingForNeutral, coolingDown, ready, turning }
    public private(set) var phase: Phase = .waitingForNeutral
    public var threshold: Double = 18
    public var speedThreshold: Double = 90
    public var neutralDuration: TimeInterval = 0.2
    public var cooldown: TimeInterval = 0.8
    public var maximumSampleGap: TimeInterval = 0.15
    public var maximumTurnDuration: TimeInterval = 0.35
    public var minimumTurnDuration: TimeInterval = 0.04
    public var neutralTolerance: Double { max(5, threshold * 0.4) }

    private var previous: (degrees: Double, time: TimeInterval)?
    private var neutralSince: TimeInterval?
    private var turnSince: TimeInterval?
    private var direction: HeadTiltDirection?
    private var peakSpeed: Double = 0
    private var lastTrigger: TimeInterval?
    private var armed = false

    public init() {}

    public mutating func reset() {
        previous = nil
        neutralSince = nil
        turnSince = nil
        direction = nil
        peakSpeed = 0
        lastTrigger = nil
        armed = false
        phase = .waitingForNeutral
    }

    public mutating func update(degrees: Double, time: TimeInterval) -> HeadTiltDirection? {
        guard degrees.isFinite, time.isFinite else { reset(); return nil }
        if let previous, time <= previous.time || time - previous.time > maximumSampleGap { reset() }
        let prior = previous
        previous = (degrees, time)
        let cooledDown = lastTrigger.map { time - $0 >= cooldown } ?? true

        if abs(degrees) <= neutralTolerance {
            turnSince = nil
            direction = nil
            peakSpeed = 0
            if neutralSince == nil { neutralSince = time }
            if time - (neutralSince ?? time) >= neutralDuration { armed = true }
            phase = armed ? (cooledDown ? .ready : .coolingDown) : .waitingForNeutral
            return nil
        }
        neutralSince = nil
        guard armed, let prior else { phase = .waitingForNeutral; return nil }
        // A turn attempted during cooldown is consumed, never queued for later.
        guard cooledDown else { armed = false; phase = .coolingDown; return nil }

        let currentDirection: HeadTiltDirection = degrees < 0 ? .left : .right
        let delta = HeadTiltGesture.relativeDegrees(angle: degrees * .pi / 180, neutral: prior.degrees * .pi / 180)
        let outwardSpeed = delta / (time - prior.time) * (degrees < 0 ? -1 : 1)
        if turnSince == nil {
            turnSince = prior.time
            direction = currentDirection
        }
        let duration = time - (turnSince ?? time)
        guard direction == currentDirection, outwardSpeed > 0, duration <= maximumTurnDuration else {
            armed = false
            phase = .waitingForNeutral
            return nil
        }
        peakSpeed = max(peakSpeed, outwardSpeed)
        phase = .turning
        // Require multiple samples so a single sensor jump cannot trigger a switch.
        guard abs(prior.degrees) > neutralTolerance,
              abs(degrees) >= threshold, peakSpeed >= speedThreshold,
              duration >= minimumTurnDuration else { return nil }
        armed = false
        lastTrigger = time
        phase = .waitingForNeutral
        return currentDirection
    }
}
