import Testing
import Foundation
import CoreGraphics
@testable import ArrangementCore

@MainActor
private final class PlacementFixture: WindowPlacementClient {
    enum FixtureError: Error { case crossDisplaySpaceMoveRefused }
    enum Operation: Equatable { case frame(CGRect), space(String) }
    let displays = [
        DisplayRecord(id: "macbook", name: "MacBook", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 949)),
        DisplayRecord(id: "external", name: "External", frame: CGRect(x: 1512, y: -458, width: 3440, height: 1440), visibleFrame: CGRect(x: 1512, y: -428, width: 3440, height: 1410))
    ]
    let spaceDisplays = ["macbook-1": "macbook", "external-1": "external", "external-2": "external"]
    var state: WindowPlacementState
    var operations: [Operation] = []
    var refuseDisplayTransfer = false
    var coordinateDelay = 0
    var pending: (WindowPlacementState, Int)?
    var reads = 0
    var onRead: ((Int, WindowPlacementState) -> WindowPlacementState)?
    init(state: WindowPlacementState) { self.state = state }
    func readPlacement() -> WindowPlacementState? {
        reads += 1
        if let pending {
            if pending.1 <= 0 { state = pending.0; self.pending = nil }
            else { self.pending = (pending.0, pending.1 - 1) }
        }
        return onRead?(reads, state) ?? state
    }
    func setFrame(_ frame: CGRect) throws {
        operations.append(.frame(frame))
        guard !refuseDisplayTransfer else { return }
        let display = Layout.display(for: frame, in: displays)?.id
        let space = display == state.displayID ? state.spaceID : (display == "macbook" ? "macbook-1" : "external-1")
        let newState = WindowPlacementState(frame: frame, displayID: display, spaceID: space)
        if coordinateDelay > 0 { pending = (newState, coordinateDelay) } else { state = newState }
    }
    func moveToSpace(_ spaceID: String) async throws {
        operations.append(.space(spaceID))
        // Reproduces WindowServer refusing a return to a Space on another display.
        guard spaceDisplays[spaceID] == state.displayID else { throw FixtureError.crossDisplaySpaceMoveRefused }
        state = WindowPlacementState(frame: state.frame, displayID: state.displayID, spaceID: spaceID)
    }
}

@MainActor
struct WindowPlacementTests {
    private let macFrame = CGRect(x: 0, y: 33, width: 1512, height: 949)
    private let monitorFrame = CGRect(x: 1512, y: -428, width: 1720, height: 1410)
    @Test func macBookSnapshotReturnsFromExternalSecondDesktop() async throws {
        let client = PlacementFixture(state: WindowPlacementState(frame: monitorFrame, displayID: "external", spaceID: "external-2"))
        try await WindowPlacementRestorer.restore(to: WindowPlacementTarget(frame: macFrame, displayID: "macbook", spaceID: "macbook-1"), using: client, pause: {})
        #expect(client.state.displayID == "macbook")
        #expect(client.state.spaceID == "macbook-1")
        #expect(client.state.frame == macFrame)
        #expect(client.operations.first == .frame(macFrame))
    }
    @Test func externalFirstDesktopSnapshotStillReturnsFromSecondDesktop() async throws {
        let client = PlacementFixture(state: WindowPlacementState(frame: monitorFrame, displayID: "external", spaceID: "external-2"))
        try await WindowPlacementRestorer.restore(to: WindowPlacementTarget(frame: monitorFrame, displayID: "external", spaceID: "external-1"), using: client, pause: {})
        #expect(client.state.spaceID == "external-1")
        #expect(client.operations.first == .space("external-1"))
    }
    @Test func externalSecondDesktopSnapshotReturnsFromMacBook() async throws {
        let client = PlacementFixture(state: WindowPlacementState(frame: macFrame, displayID: "macbook", spaceID: "macbook-1"))
        try await WindowPlacementRestorer.restore(to: WindowPlacementTarget(frame: monitorFrame, displayID: "external", spaceID: "external-2"), using: client, pause: {})
        #expect(client.state.displayID == "external")
        #expect(client.state.spaceID == "external-2")
        #expect(client.state.frame == monitorFrame)
    }
    @Test func asynchronousDisplayTransferCompletesBeforeSpaceMove() async throws {
        let client = PlacementFixture(state: WindowPlacementState(frame: monitorFrame, displayID: "external", spaceID: "external-2"))
        client.coordinateDelay = 3
        try await WindowPlacementRestorer.restore(to: WindowPlacementTarget(frame: macFrame, displayID: "macbook", spaceID: "macbook-1"), using: client, pause: {})
        #expect(client.state.spaceID == "macbook-1")
        #expect(client.state.displayID == "macbook")
    }
    @Test func failedPhysicalTransferDoesNotAttemptCrossDisplaySpaceMove() async {
        let client = PlacementFixture(state: WindowPlacementState(frame: monitorFrame, displayID: "external", spaceID: "external-2"))
        client.refuseDisplayTransfer = true
        await #expect(throws: WindowPlacementError.self) {
            try await WindowPlacementRestorer.restore(to: WindowPlacementTarget(frame: macFrame, displayID: "macbook", spaceID: "macbook-1"), using: client, pause: {})
        }
        #expect(!client.operations.contains(.space("macbook-1")))
    }
    @Test func transientCorrectSpaceDoesNotCountAsRestorationSuccess() async {
        let client = PlacementFixture(state: WindowPlacementState(frame: monitorFrame, displayID: "external", spaceID: "external-2"))
        client.onRead = { count, state in
            count < 3 ? state : WindowPlacementState(frame: state.frame, displayID: state.displayID, spaceID: "external-2")
        }
        await #expect(throws: WindowPlacementError.self) {
            try await WindowPlacementRestorer.restore(to: WindowPlacementTarget(frame: monitorFrame, displayID: "external", spaceID: "external-1"), using: client, pause: {})
        }
    }
    @Test func positionOnlySnapshotMovesAcrossDisplaysWithoutChangingSpaceExplicitly() async throws {
        let client = PlacementFixture(state: WindowPlacementState(frame: monitorFrame, displayID: "external", spaceID: "external-2"))
        try await WindowPlacementRestorer.restore(to: WindowPlacementTarget(frame: macFrame, displayID: "macbook"), using: client, pause: {})
        #expect(client.state.frame == macFrame)
        #expect(!client.operations.contains { if case .space = $0 { return true }; return false })
    }
}
