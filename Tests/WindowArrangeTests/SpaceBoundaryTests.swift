import Testing
@testable import WindowArrange

struct SpaceBoundaryTests {
    private func display(_ id: String, _ spaces: [UInt64], current: UInt64) -> [String: Any] {
        ["Display Identifier": id, "Spaces": spaces.map { ["id64": $0] }, "Current Space": ["id64": current]]
    }

    @Test func checksBothEdgesAndAdjacentSpaces() {
        let displays = [display("Main", [1, 2, 3], current: 1)]
        func check(_ right: Bool, _ current: UInt64) -> Bool? {
            NativeSpaces.hasAdjacentSpace(toRight: right, displayID: nil, displays: displays) { _ in current }
        }
        #expect(check(false, 1) == false)
        #expect(check(true, 1) == true)
        #expect(check(false, 2) == true)
        #expect(check(true, 2) == true)
        #expect(check(false, 3) == true)
        #expect(check(true, 3) == false)
    }

    @Test func usesTheDisplayUnderThePointer() {
        let displays = [display("A", [1, 2], current: 1), display("B", [3, 4], current: 4)]
        #expect(NativeSpaces.hasAdjacentSpace(toRight: true, displayID: "a", displays: displays) { _ in nil } == true)
        #expect(NativeSpaces.hasAdjacentSpace(toRight: true, displayID: "B", displays: displays) { _ in nil } == false)
        #expect(NativeSpaces.hasAdjacentSpace(toRight: true, displayID: "unknown", displays: displays) { _ in nil } == nil)
    }

    @Test func unknownOrIncompleteStateDoesNotPretendToBeAnEdge() {
        #expect(NativeSpaces.hasAdjacentSpace(toRight: false, displayID: nil, displays: []) { _ in nil } == nil)
        #expect(NativeSpaces.hasAdjacentSpace(toRight: true, displayID: nil, displays: [display("Main", [1], current: 9)]) { _ in nil } == nil)
        let incomplete: [[String: Any]] = [["Display Identifier": "Main", "Spaces": [["id64": 1], [:]]]]
        #expect(NativeSpaces.hasAdjacentSpace(toRight: true, displayID: nil, displays: incomplete) { _ in 1 } == nil)
        #expect(NativeSpaces.hasAdjacentSpace(toRight: false, displayID: nil, displays: [display("Main", [1], current: 1)]) { _ in nil } == false)
    }
}
