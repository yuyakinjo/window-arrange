import Foundation
import Testing
@testable import ArrangementCore

struct TrackpadEdgeSlideTests {
    private func contact(_ x: Double, _ y: Double, id: Int = 1) -> TrackpadContact {
        TrackpadContact(identifier: id, x: x, y: y)
    }

    private func slide(_ gesture: inout TrackpadEdgeSlide, x: Double, from: Double, to: Double,
                       start time: Double = 0, id: Int = 1) -> [TrackpadEdgeStep] {
        var steps: [TrackpadEdgeStep] = []
        let frames = 20
        for frame in 0...frames {
            let y = from + (to - from) * Double(frame) / Double(frames)
            steps += gesture.update(contacts: [contact(x, y, id: id)], time: time + Double(frame) * 0.01)
        }
        return steps
    }

    @Test func slidingUpTheLeftEdgeProducesPositiveSteps() {
        var gesture = TrackpadEdgeSlide()
        let steps = slide(&gesture, x: 0.03, from: 0.2, to: 0.8)
        #expect(!steps.isEmpty)
        #expect(steps.allSatisfy { $0.edge == .left && $0.direction == 1 })
        #expect(gesture.phase == .sliding)
    }

    @Test func slidingDownTheRightEdgeProducesNegativeSteps() {
        var gesture = TrackpadEdgeSlide()
        let steps = slide(&gesture, x: 0.97, from: 0.8, to: 0.2)
        #expect(!steps.isEmpty)
        #expect(steps.allSatisfy { $0.edge == .right && $0.direction == -1 })
    }

    @Test func travelMapsToTheExpectedNumberOfSteps() {
        var gesture = TrackpadEdgeSlide()
        // The first notch costs activationDistance, the rest one stepDistance each.
        // The finger is sampled in frames, so the final notch may fall just past the end.
        let travel = gesture.activationDistance + gesture.stepDistance * 4
        let steps = slide(&gesture, x: 0.02, from: 0.1, to: 0.1 + travel)
        #expect((4...5).contains(steps.count))
        var longer = TrackpadEdgeSlide()
        #expect(slide(&longer, x: 0.02, from: 0.1, to: 0.1 + travel * 2).count > steps.count)
    }

    @Test func aShortTouchInTheZoneDoesNothing() {
        var gesture = TrackpadEdgeSlide()
        let steps = slide(&gesture, x: 0.02, from: 0.5, to: 0.5 + gesture.activationDistance * 0.6)
        #expect(steps.isEmpty)
        #expect(gesture.phase == .armed)
    }

    @Test func slidesAwayFromTheEdgeAreIgnored() {
        var gesture = TrackpadEdgeSlide()
        let steps = slide(&gesture, x: 0.5, from: 0.2, to: 0.9)
        #expect(steps.isEmpty)
        #expect(gesture.phase == .waitingForLift)
    }

    @Test func aSwipeDriftingIntoTheZoneCannotArmItself() {
        var gesture = TrackpadEdgeSlide()
        #expect(gesture.update(contacts: [contact(0.6, 0.5)], time: 0).isEmpty)
        let steps = slide(&gesture, x: 0.02, from: 0.2, to: 0.9, start: 0.01)
        #expect(steps.isEmpty)
        #expect(gesture.phase == .waitingForLift)
    }

    @Test func liftingAllFingersAllowsANewGesture() {
        var gesture = TrackpadEdgeSlide()
        #expect(gesture.update(contacts: [contact(0.6, 0.5)], time: 0).isEmpty)
        #expect(gesture.update(contacts: [], time: 0.01).isEmpty)
        #expect(gesture.phase == .idle)
        #expect(!slide(&gesture, x: 0.02, from: 0.2, to: 0.9, start: 0.02).isEmpty)
    }

    @Test func aSecondFingerCancelsUntilEveryFingerLifts() {
        var gesture = TrackpadEdgeSlide()
        _ = slide(&gesture, x: 0.02, from: 0.2, to: 0.5)
        #expect(gesture.update(contacts: [contact(0.02, 0.5), contact(0.3, 0.5, id: 2)], time: 0.3).isEmpty)
        #expect(gesture.phase == .waitingForLift)
        #expect(slide(&gesture, x: 0.02, from: 0.5, to: 0.9, start: 0.31).isEmpty)
        #expect(gesture.update(contacts: [], time: 0.6).isEmpty)
        #expect(!slide(&gesture, x: 0.02, from: 0.2, to: 0.9, start: 0.61).isEmpty)
    }

    @Test func leavingTheStripCancelsTheGesture() {
        var gesture = TrackpadEdgeSlide()
        _ = slide(&gesture, x: 0.02, from: 0.2, to: 0.5)
        #expect(gesture.phase == .sliding)
        #expect(gesture.update(contacts: [contact(0.4, 0.6)], time: 0.3).isEmpty)
        #expect(gesture.phase == .waitingForLift)
    }

    @Test func aDisabledEdgeNeverArms() {
        var gesture = TrackpadEdgeSlide()
        gesture.enabledEdges = [.right]
        #expect(slide(&gesture, x: 0.02, from: 0.2, to: 0.9).isEmpty)
        #expect(gesture.update(contacts: [], time: 1).isEmpty)
        #expect(!slide(&gesture, x: 0.98, from: 0.2, to: 0.9, start: 1.01).isEmpty)
    }

    @Test func anInterruptedStreamStartsOver() {
        var gesture = TrackpadEdgeSlide()
        _ = slide(&gesture, x: 0.02, from: 0.2, to: 0.5)
        #expect(gesture.phase == .sliding)
        // A gap longer than maximumSampleGap means the frames in between are unknown.
        #expect(gesture.update(contacts: [contact(0.02, 0.9)], time: 5).isEmpty)
        #expect(gesture.phase == .armed)
    }

    @Test func reversedSlowSlidesStillStepOnce() {
        var gesture = TrackpadEdgeSlide()
        var steps = slide(&gesture, x: 0.02, from: 0.5, to: 0.5 - gesture.activationDistance)
        #expect(steps.count == 1)
        #expect(steps.first?.direction == -1)
        // Reversing direction inside one gesture is allowed; the anchor follows the finger.
        steps = slide(&gesture, x: 0.02, from: 0.5 - gesture.activationDistance,
                      to: 0.5 - gesture.activationDistance + gesture.stepDistance, start: 0.3)
        #expect(steps.count == 1)
        #expect(steps.first?.direction == 1)
    }
}
