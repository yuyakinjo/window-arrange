import Testing
import Foundation
import CoreGraphics
@testable import ArrangementCore

struct RepeatedLayoutTests {
    let external = DisplayRecord(id: "external", name: "External", frame: CGRect(x: -2400, y: -600, width: 2400, height: 1500),
                                 visibleFrame: CGRect(x: -2400, y: -570, width: 2400, height: 1440))
    let builtIn = DisplayRecord(id: "builtin", name: "MacBook", frame: CGRect(x: 0, y: 0, width: 1500, height: 1000),
                                visibleFrame: CGRect(x: 0, y: 30, width: 1500, height: 930))
    let initial = CGRect(x: -2100, y: -400, width: 900, height: 700)

    @Test(arguments: [WindowAction.left, .right, .top, .bottom])
    func cycleAlternatesTwoSizesOnTheSameDisplay(action: WindowAction) throws {
        let displays = [external, builtIn]
        let half = try #require(Layout.target(for: action, window: initial, displays: displays, repeatMode: .cycle))
        #expect(half.frame == Layout.frame(for: action, window: initial, screen: external.visibleFrame))
        let third = try #require(Layout.target(for: action, window: half.frame, displays: displays, repeatMode: .cycle))
        #expect(third.displayID == external.id)
        #expect(external.visibleFrame.contains(third.frame))
        if action == .left || action == .right {
            #expect(third.frame.width == external.visibleFrame.width / 3)
            #expect(third.frame.height == external.visibleFrame.height)
        } else {
            #expect(third.frame.height == external.visibleFrame.height / 3)
            #expect(third.frame.width == external.visibleFrame.width)
        }
        if action == .right { #expect(third.frame.maxX == external.visibleFrame.maxX) }
        if action == .bottom { #expect(third.frame.maxY == external.visibleFrame.maxY) }
        let repeated = try #require(Layout.target(for: action, window: third.frame, displays: displays, repeatMode: .cycle))
        #expect(repeated.frame == half.frame)
        #expect(repeated.displayID == external.id)
    }

    @Test(arguments: [WindowAction.left, .right, .top, .bottom])
    func rotationIncludesMacBookAndWrapsToFirstDisplay(action: WindowAction) throws {
        let displays = [external, builtIn]
        var window = initial
        var targets: [WindowPlacementTarget] = []
        for _ in 0..<5 {
            let target = try #require(Layout.target(for: action, window: window, displays: displays, repeatMode: .rotation))
            targets.append(target); window = target.frame
        }
        #expect(targets.map(\.displayID) == [external.id, external.id, builtIn.id, builtIn.id, external.id])
        #expect(targets[2].frame == Layout.frame(for: action, window: initial, screen: builtIn.visibleFrame))
        #expect(builtIn.visibleFrame.contains(targets[3].frame))
        #expect(targets[4].frame == targets[0].frame)
    }

    @Test(arguments: [LayoutRepeatMode.none, .cycle, .rotation])
    func unrelatedActionsKeepTheirExistingBehavior(mode: LayoutRepeatMode) {
        for action in [WindowAction.topLeft, .topRight, .bottomLeft, .bottomRight, .fill, .center] {
            let target = Layout.target(for: action, window: initial, displays: [external, builtIn], repeatMode: mode)
            #expect(target?.frame == Layout.frame(for: action, window: initial, screen: external.visibleFrame))
            #expect(target?.displayID == external.id)
        }
        let next = Layout.target(for: .nextDisplay, window: initial, displays: [external, builtIn], repeatMode: mode)
        #expect(next?.displayID == builtIn.id)
        #expect(next?.frame == Layout.remap(initial, from: external.visibleFrame, to: builtIn.visibleFrame))
    }

    @Test func noneAlwaysPlacesAtHalf() throws {
        let half = try #require(Layout.target(for: .left, window: initial, displays: [external]))
        #expect(Layout.target(for: .left, window: half.frame, displays: [external])?.frame == half.frame)
    }

    @Test func singleDisplayRotationCyclesLocally() throws {
        let half = try #require(Layout.target(for: .right, window: initial, displays: [external], repeatMode: .rotation))
        let third = try #require(Layout.target(for: .right, window: half.frame, displays: [external], repeatMode: .rotation))
        let repeated = try #require(Layout.target(for: .right, window: third.frame, displays: [external], repeatMode: .rotation))
        #expect(repeated.frame == half.frame)
        #expect(repeated.displayID == external.id)
        #expect(Layout.target(for: .nextDisplay, window: half.frame, displays: [external]) == nil)
    }

    @Test func manualResizeAndOtherWindowsStartAtHalf() throws {
        let half = try #require(Layout.target(for: .left, window: initial, displays: [external, builtIn], repeatMode: .rotation))
        var resized = half.frame; resized.size.width += 80
        #expect(Layout.target(for: .left, window: resized, displays: [external, builtIn], repeatMode: .rotation)?.frame == half.frame)
        let other = CGRect(x: 100, y: 100, width: 700, height: 500)
        #expect(Layout.target(for: .left, window: other, displays: [external, builtIn], repeatMode: .rotation)?.frame
                == Layout.frame(for: .left, window: other, screen: builtIn.visibleFrame))
    }

    @Test func disconnectedDisplayIsNotUsed() throws {
        let half = try #require(Layout.frame(for: .left, window: initial, screen: external.visibleFrame))
        let third = try #require(Layout.target(for: .left, window: half, displays: [external, builtIn], repeatMode: .rotation))
        let target = try #require(Layout.target(for: .left, window: third.frame, displays: [builtIn], repeatMode: .rotation))
        #expect(target.displayID == builtIn.id)
        #expect(builtIn.visibleFrame.contains(target.frame))
        #expect(Layout.target(for: .left, window: initial, displays: [], repeatMode: .rotation) == nil)
    }

    @Test func roundingDoesNotBreakTheCycle() throws {
        let half = try #require(Layout.target(for: .left, window: initial, displays: [external], repeatMode: .cycle))
        var rounded = half.frame; rounded.size.width += 1; rounded.origin.y += 1
        let target = try #require(Layout.target(for: .left, window: rounded, displays: [external], repeatMode: .cycle))
        #expect(target.frame.width == external.visibleFrame.width / 3)
    }

    @Test func repeatModeDefaultsAndRoundTripsWithoutLosingExistingData() throws {
        var data = AppData()
        data.snapshots = [Snapshot(name: "仕事", backend: .accessibility, displays: [external], windows: [])]
        data.shortcuts["left"] = Shortcut(keyCode: 123, modifiers: 6144, label: "⌃⌥←")
        data.selectedSnapshotID = data.snapshots[0].id
        for mode in LayoutRepeatMode.allCases {
            data.repeatMode = mode
            let decoded = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
            #expect(decoded.repeatMode == mode)
            #expect(decoded.snapshots[0].name == "仕事")
            #expect(decoded.shortcuts == data.shortcuts)
            #expect(decoded.selectedSnapshotID == data.selectedSnapshotID)
        }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(data)) as! [String: Any]
        json.removeValue(forKey: "repeatMode")
        let legacy = try JSONDecoder().decode(AppData.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.repeatMode == .none)
        #expect(legacy.snapshots[0].name == "仕事")
        #expect(legacy.shortcuts == data.shortcuts)
    }
}
