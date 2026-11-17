import Testing
@testable import ArrangementCore

struct SpaceSwitchPlanTests {
    @Test func countsSwipesInBothDirections() {
        let order: [UInt64] = [4, 5, 9, 12]
        #expect(SpaceSwitchPlan.steps(order: order, current: 5, target: 4) == -1)
        #expect(SpaceSwitchPlan.steps(order: order, current: 4, target: 12) == 3)
        #expect(SpaceSwitchPlan.steps(order: order, current: 9, target: 9) == 0)
    }

    @Test func rejectsSpacesOutsideTheDisplay() {
        #expect(SpaceSwitchPlan.steps(order: [4, 5], current: 4, target: 7) == nil)
        #expect(SpaceSwitchPlan.steps(order: [4, 5], current: 0, target: 5) == nil)
    }
}
