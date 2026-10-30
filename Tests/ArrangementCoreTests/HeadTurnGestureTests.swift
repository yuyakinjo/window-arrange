import Foundation
import Testing
@testable import ArrangementCore

struct HeadTurnGestureTests {
    private func arm(_ gesture: inout HeadTurnGesture, at time: Double = 0) {
        for step in 0...6 {
            #expect(gesture.update(degrees: 0, time: time + Double(step) * 0.05) == nil)
        }
    }

    @Test func quickTurnsFireWithoutHoldingInBothDirections() {
        for sign in [-1.0, 1.0] {
            var gesture = HeadTurnGesture()
            arm(&gesture)
            #expect(gesture.phase == .ready)
            #expect(gesture.update(degrees: sign * 10, time: 0.35) == nil)
            #expect(gesture.update(degrees: sign * 20, time: 0.4) == (sign < 0 ? .left : .right))
            #expect(gesture.phase == .waitingForNeutral)
        }
    }

    @Test func requiresNeutralBeforeStartingAndRejectsReturnAndOvershoot() {
        var gesture = HeadTurnGesture()
        #expect(gesture.update(degrees: 10, time: 0) == nil)
        #expect(gesture.update(degrees: 25, time: 0.05) == nil)
        arm(&gesture, at: 0.1)
        #expect(gesture.update(degrees: 10, time: 0.45) == nil)
        #expect(gesture.update(degrees: 20, time: 0.5) == .right)
        for (angle, time) in [(30.0, 0.55), (20, 0.6), (0, 0.65), (-10, 0.7), (-25, 0.75)] {
            #expect(gesture.update(degrees: angle, time: time) == nil)
        }
    }

    @Test func slowTurnsAndSmallFastMovementsDoNotFire() {
        var slow = HeadTurnGesture()
        arm(&slow)
        for step in 1...20 {
            #expect(slow.update(degrees: Double(step) * 2, time: 0.3 + Double(step) * 0.05) == nil)
        }
        var small = HeadTurnGesture()
        arm(&small)
        #expect(small.update(degrees: 10, time: 0.35) == nil)
        #expect(small.update(degrees: 12, time: 0.4) == nil)
        #expect(small.update(degrees: 0, time: 0.45) == nil)
    }

    @Test func rejectsSingleSampleSpikeAndStaleFastMovement() {
        var gesture = HeadTurnGesture()
        arm(&gesture)
        #expect(gesture.update(degrees: 30, time: 0.35) == nil)
        #expect(gesture.update(degrees: 0, time: 0.4) == nil)
        arm(&gesture, at: 0.45)
        #expect(gesture.update(degrees: 10, time: 0.8) == nil)
        for step in 1...10 {
            #expect(gesture.update(degrees: 10 + Double(step), time: 0.8 + Double(step) * 0.05) == nil)
        }
    }

    @Test func cooldownDoesNotQueueATurn() {
        var gesture = HeadTurnGesture()
        arm(&gesture)
        _ = gesture.update(degrees: 10, time: 0.35)
        #expect(gesture.update(degrees: 20, time: 0.4) == .right)
        arm(&gesture, at: 0.45)
        #expect(gesture.phase == .coolingDown)
        #expect(gesture.update(degrees: -10, time: 0.8) == nil)
        for step in 0...10 {
            #expect(gesture.update(degrees: -20, time: 0.85 + Double(step) * 0.05) == nil)
        }
        arm(&gesture, at: 1.4)
        #expect(gesture.update(degrees: -10, time: 1.75) == nil)
        #expect(gesture.update(degrees: -20, time: 1.8) == .left)
    }

    @Test func neutralDuringCooldownIsRemembered() {
        var gesture = HeadTurnGesture()
        arm(&gesture)
        _ = gesture.update(degrees: 10, time: 0.35)
        #expect(gesture.update(degrees: 20, time: 0.4) == .right)
        arm(&gesture, at: 0.45)
        for step in 0...10 { _ = gesture.update(degrees: 0, time: 0.8 + Double(step) * 0.05) }
        #expect(gesture.update(degrees: -10, time: 1.35) == nil)
        #expect(gesture.update(degrees: -20, time: 1.4) == .left)
    }

    @Test func invalidSamplesGapsAndResetRequireNeutralAgain() {
        for invalid in [(20.0, 1.0), (20, 0.3), (Double.nan, 0.4), (20, Double.infinity)] {
            var gesture = HeadTurnGesture()
            arm(&gesture)
            _ = gesture.update(degrees: 10, time: 0.35)
            #expect(gesture.update(degrees: invalid.0, time: invalid.1) == nil)
            #expect(gesture.update(degrees: 30, time: 1.05) == nil)
        }
        var gesture = HeadTurnGesture()
        arm(&gesture)
        _ = gesture.update(degrees: 10, time: 0.35)
        gesture.reset()
        #expect(gesture.update(degrees: 20, time: 0.4) == nil)
    }

    @Test func respectsAngleAndSpeedSettings() {
        var gesture = HeadTurnGesture()
        gesture.threshold = 30
        gesture.speedThreshold = 150
        arm(&gesture)
        #expect(gesture.update(degrees: 15, time: 0.35) == nil)
        #expect(gesture.update(degrees: 25, time: 0.4) == nil)
        #expect(gesture.update(degrees: 35, time: 0.45) == .right)
        var slower = HeadTurnGesture()
        slower.speedThreshold = 200
        arm(&slower)
        #expect(slower.update(degrees: 8, time: 0.4) == nil)
        #expect(slower.update(degrees: 19, time: 0.5) == nil)
    }

    @Test func yawWrapNearPiStillProducesASmallTurn() {
        let neutral = 175.0 * Double.pi / 180
        var gesture = HeadTurnGesture()
        arm(&gesture)
        // Normalize positive yaw to a left turn, just as the controller does.
        let first = -HeadTiltGesture.relativeDegrees(angle: -175 * .pi / 180, neutral: neutral)
        let second = -HeadTiltGesture.relativeDegrees(angle: -165 * .pi / 180, neutral: neutral)
        #expect(gesture.update(degrees: first, time: 0.35) == nil)
        #expect(gesture.update(degrees: second, time: 0.4) == .left)
    }
}
