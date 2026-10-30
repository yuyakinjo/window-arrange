import Testing
import Foundation
@testable import ArrangementCore

struct HeadTiltGestureTests {
    private func arm(_ gesture: inout HeadTiltGesture, at time: Double = 0) {
        #expect(gesture.update(degrees: 0, time: time) == nil)
        #expect(gesture.update(degrees: 0, time: time + 0.25) == nil)
    }

    @Test func requiresNeutralBeforeFirstTilt() {
        var gesture = HeadTiltGesture()
        for step in 0..<20 { #expect(gesture.update(degrees: 30, time: Double(step) * 0.1) == nil) }
        arm(&gesture, at: 2)
        #expect(gesture.update(degrees: 25, time: 2.3) == nil)
        #expect(gesture.update(degrees: 25, time: 2.5) == .right)
    }

    @Test func sustainedTiltOnlyFiresOnceAndNeedsNeutralToRearm() {
        var gesture = HeadTiltGesture()
        arm(&gesture)
        #expect(gesture.update(degrees: -25, time: 0.3) == nil)
        #expect(gesture.update(degrees: -25, time: 0.5) == .left)
        for step in 6...20 { #expect(gesture.update(degrees: -25, time: Double(step) * 0.1) == nil) }
        // Crossing directly to the other extreme must not fire either.
        #expect(gesture.update(degrees: 25, time: 2.1) == nil)
        #expect(gesture.update(degrees: 25, time: 2.3) == nil)
        arm(&gesture, at: 2.4)
        #expect(gesture.update(degrees: 25, time: 2.7) == nil)
        #expect(gesture.update(degrees: 25, time: 2.9) == .right)
    }

    @Test func rejectsBriefSpikesAndAlternatingDirections() {
        var gesture = HeadTiltGesture()
        arm(&gesture)
        #expect(gesture.update(degrees: 25, time: 0.3) == nil)
        #expect(gesture.update(degrees: 10, time: 0.4) == nil)
        #expect(gesture.update(degrees: 25, time: 0.5) == nil)
        #expect(gesture.update(degrees: -25, time: 0.6) == nil)
        #expect(gesture.update(degrees: -25, time: 0.7) == nil)
        #expect(gesture.update(degrees: -25, time: 0.8) == .left)
    }

    @Test func rejectsGapsInvalidSamplesAndTimeReversal() {
        for invalidTime in [1.0, 0.1, Double.nan] {
            var gesture = HeadTiltGesture()
            arm(&gesture)
            #expect(gesture.update(degrees: 25, time: 0.3) == nil)
            #expect(gesture.update(degrees: 25, time: invalidTime) == nil)
            #expect(gesture.update(degrees: 25, time: 1.2) == nil)
        }
        var gesture = HeadTiltGesture()
        arm(&gesture)
        #expect(gesture.update(degrees: .infinity, time: 0.3) == nil)
        #expect(gesture.update(degrees: 25, time: 0.4) == nil)
        #expect(gesture.update(degrees: 25, time: 0.6) == nil)
    }

    @Test func cooldownPreventsRapidSwitching() {
        var gesture = HeadTiltGesture()
        arm(&gesture)
        _ = gesture.update(degrees: 25, time: 0.3)
        #expect(gesture.update(degrees: 25, time: 0.5) == .right)
        arm(&gesture, at: 0.6)
        #expect(gesture.update(degrees: -25, time: 0.9) == nil)
        #expect(gesture.update(degrees: -25, time: 1.1) == nil)
        arm(&gesture, at: 1.2)
        #expect(gesture.update(degrees: -25, time: 1.5) == nil)
        #expect(gesture.update(degrees: -25, time: 1.7) == .left)
    }

    @Test func respectsSensitivityAndReset() {
        var gesture = HeadTiltGesture()
        gesture.threshold = 30
        arm(&gesture)
        #expect(gesture.update(degrees: 25, time: 0.3) == nil)
        #expect(gesture.update(degrees: 25, time: 0.5) == nil)
        _ = gesture.update(degrees: 35, time: 0.6)
        gesture.reset()
        #expect(gesture.update(degrees: 35, time: 0.8) == nil)
        #expect(gesture.update(degrees: 35, time: 1.0) == nil)
    }

    @Test func remembersNeutralReturnDuringCooldown() {
        var gesture = HeadTiltGesture()
        arm(&gesture)
        _ = gesture.update(degrees: 25, time: 0.3)
        #expect(gesture.update(degrees: 25, time: 0.5) == .right)
        arm(&gesture, at: 0.6)
        #expect(gesture.phase == .coolingDown)
        #expect(gesture.update(degrees: -25, time: 0.9) == nil)
        #expect(gesture.update(degrees: -25, time: 1.1) == nil)
        // No second return to neutral should be necessary after cooldown expires.
        #expect(gesture.update(degrees: -25, time: 1.31) == .left)
        #expect(gesture.phase == .waitingForNeutral)
        #expect(gesture.update(degrees: -25, time: 1.6) == nil)
    }

    @Test func repeatsWithNaturalNeutralJitterAtLowThreshold() {
        var gesture = HeadTiltGesture()
        gesture.threshold = 11
        var triggers: [HeadTiltDirection] = []
        // Five complete neutral/tilt cycles with a slightly imperfect neutral pose.
        for cycle in 0..<5 {
            for step in 0..<50 {
                let neutral = step < 20
                let angle = neutral ? (step.isMultiple(of: 2) ? 4.5 : 4.8) : (cycle.isMultiple(of: 2) ? 15.0 : -15.0)
                if let direction = gesture.update(degrees: angle, time: Double(cycle) + Double(step) * 0.02) {
                    triggers.append(direction)
                }
            }
        }
        #expect(triggers == [.right, .left, .right, .left, .right])
    }

    @Test func wrapsAnglesAtPi() {
        let relative = HeadTiltGesture.relativeDegrees(angle: -.pi + 0.1, neutral: .pi - 0.1)
        #expect(abs(relative - 0.2 * 180 / .pi) < 0.0001)
    }
}
