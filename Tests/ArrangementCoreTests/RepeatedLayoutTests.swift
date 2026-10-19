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
    func cycleRepeatsThreeSizesOnTheSameDisplay(action: WindowAction) throws {
        let displays = [external, builtIn]
        let half = try #require(Layout.target(for: action, window: initial, displays: displays, repeatMode: .cycle))
        #expect(half.frame == Layout.frame(for: action, window: initial, screen: external.visibleFrame))
        let twoThirds = try #require(Layout.target(for: action, window: half.frame, displays: displays, repeatMode: .cycle))
        #expect(twoThirds.displayID == external.id)
        #expect(external.visibleFrame.contains(twoThirds.frame))
        if action == .left || action == .right {
            #expect(abs(twoThirds.frame.width - external.visibleFrame.width * 2 / 3) < 0.001)
        } else {
            #expect(abs(twoThirds.frame.height - external.visibleFrame.height * 2 / 3) < 0.001)
        }
        let third = try #require(Layout.target(for: action, window: twoThirds.frame, displays: displays, repeatMode: .cycle))
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
    func displayCyclingVisitsBothHalvesAndWraps(action: WindowAction) throws {
        let displays = [external, builtIn]
        var window = initial
        var targets: [WindowPlacementTarget] = []
        for _ in 0..<5 {
            let target = try #require(Layout.target(for: action, window: window, displays: displays, repeatMode: .displays))
            targets.append(target); window = target.frame
        }
        #expect(targets.map(\.displayID) == [external.id, builtIn.id, builtIn.id, external.id, external.id])
        let opposite: WindowAction = action == .left ? .right : action == .right ? .left : action == .top ? .bottom : .top
        #expect(targets[1].frame == Layout.frame(for: opposite, window: initial, screen: builtIn.visibleFrame))
        #expect(targets[2].frame == Layout.frame(for: action, window: initial, screen: builtIn.visibleFrame))
        #expect(targets[3].frame == Layout.frame(for: opposite, window: initial, screen: external.visibleFrame))
        #expect(targets[4].frame == targets[0].frame)
    }

    @Test(arguments: [LayoutRepeatMode.none, .cycle, .displays])
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

    @Test func singleDisplayDoesNotCycleSizesOrFlipHalves() throws {
        let half = try #require(Layout.target(for: .right, window: initial, displays: [external], repeatMode: .displays))
        let repeated = try #require(Layout.target(for: .right, window: half.frame, displays: [external], repeatMode: .displays))
        #expect(repeated.frame == half.frame)
        #expect(repeated.displayID == external.id)
        #expect(Layout.target(for: .nextDisplay, window: half.frame, displays: [external]) == nil)
    }

    @Test func manualResizeAndOtherWindowsStartAtHalf() throws {
        let half = try #require(Layout.target(for: .left, window: initial, displays: [external, builtIn], repeatMode: .displays))
        var resized = half.frame; resized.size.width += 80
        #expect(Layout.target(for: .left, window: resized, displays: [external, builtIn], repeatMode: .displays)?.frame == half.frame)
        let other = CGRect(x: 100, y: 100, width: 700, height: 500)
        #expect(Layout.target(for: .left, window: other, displays: [external, builtIn], repeatMode: .displays)?.frame
                == Layout.frame(for: .left, window: other, screen: builtIn.visibleFrame))
    }

    @Test func disconnectedDisplayIsNotUsed() throws {
        let half = try #require(Layout.frame(for: .left, window: initial, screen: external.visibleFrame))
        let target = try #require(Layout.target(for: .left, window: half, displays: [builtIn], repeatMode: .displays))
        #expect(target.displayID == builtIn.id)
        #expect(builtIn.visibleFrame.contains(target.frame))
        #expect(Layout.target(for: .left, window: initial, displays: [], repeatMode: .displays) == nil)
    }

    @Test func roundingDoesNotBreakTheCycle() throws {
        let half = try #require(Layout.target(for: .left, window: initial, displays: [external], repeatMode: .cycle))
        var rounded = half.frame; rounded.size.width += 1; rounded.origin.y += 1
        let target = try #require(Layout.target(for: .left, window: rounded, displays: [external], repeatMode: .cycle))
        #expect(target.frame.width == external.visibleFrame.width * 2 / 3)
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

    @Test func existingRotationSettingLoadsAsCycleDisplays() throws {
        let decoded = try JSONDecoder().decode(LayoutRepeatMode.self, from: Data("\"rotation\"".utf8))
        #expect(decoded == .displays)
        #expect(decoded.title == "Cycle Displays")
        #expect(try JSONEncoder().encode(decoded) == Data("\"rotation\"".utf8))
    }

    @Test func rightHalfMatchesObservedRaycastFrames() throws {
        // Recorded using Raycast Cycle Displays on the built-in and Dell screens.
        let laptop = DisplayRecord(id: "laptop", name: "MacBook", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                    visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 949))
        let dell = DisplayRecord(id: "dell", name: "Dell", frame: CGRect(x: 1512, y: -458, width: 3440, height: 1440),
                                 visibleFrame: CGRect(x: 1512, y: -428, width: 3440, height: 1410))
        let expected = [CGRect(x: 756, y: 33, width: 756, height: 949),
                        CGRect(x: 1512, y: -428, width: 1720, height: 1410),
                        CGRect(x: 3232, y: -428, width: 1720, height: 1410),
                        CGRect(x: 0, y: 33, width: 756, height: 949)]
        var window = CGRect(x: 200, y: 200, width: 700, height: 482)
        for frame in expected {
            let target = try #require(Layout.target(for: .right, window: window, displays: [dell, laptop], repeatMode: .displays))
            #expect(target.frame == frame)
            window = target.frame
        }
    }

    @Test func threeDisplaysFollowDirectionRegardlessOfEnumerationOrder() throws {
        let right = DisplayRecord(id: "right", name: "Right", frame: CGRect(x: 1500, y: 0, width: 1200, height: 900),
                                  visibleFrame: CGRect(x: 1500, y: 30, width: 1200, height: 870))
        let displays = [right, external, builtIn]
        let window = CGRect(x: 100, y: 100, width: 600, height: 600)
        let cases: [(WindowAction, [String])] = [(.right, [builtIn.id, right.id, right.id, external.id, external.id, builtIn.id, builtIn.id]),
                                                (.left, [builtIn.id, external.id, external.id, right.id, right.id, builtIn.id, builtIn.id])]
        for (action, expectedIDs) in cases {
            var current = window
            for id in expectedIDs {
                let target = try #require(Layout.target(for: action, window: current, displays: displays, repeatMode: .displays))
                #expect(target.displayID == id)
                current = target.frame
            }
        }
    }

    @Test func verticalDisplaysFollowTopAndBottomDirection() throws {
        let top = DisplayRecord(id: "top", name: "Top", frame: CGRect(x: 0, y: -1000, width: 1500, height: 1000),
                                visibleFrame: CGRect(x: 0, y: -970, width: 1500, height: 970))
        let bottom = DisplayRecord(id: "bottom", name: "Bottom", frame: CGRect(x: 0, y: 1000, width: 1500, height: 1000),
                                   visibleFrame: CGRect(x: 0, y: 1030, width: 1500, height: 970))
        let window = CGRect(x: 100, y: 100, width: 600, height: 600)
        for (action, id) in [(WindowAction.top, top.id), (.bottom, bottom.id)] {
            let half = try #require(Layout.target(for: action, window: window, displays: [bottom, builtIn, top], repeatMode: .displays))
            let next = try #require(Layout.target(for: action, window: half.frame, displays: [bottom, builtIn, top], repeatMode: .displays))
            #expect(next.displayID == id)
        }
    }

    @Test func switchingFromSizeCyclingToDisplaysStartsAtHalf() throws {
        let half = try #require(Layout.target(for: .left, window: initial, displays: [external, builtIn], repeatMode: .cycle))
        let twoThirds = try #require(Layout.target(for: .left, window: half.frame, displays: [external, builtIn], repeatMode: .cycle))
        let target = try #require(Layout.target(for: .left, window: twoThirds.frame, displays: [external, builtIn], repeatMode: .displays))
        #expect(target.frame == half.frame)
        #expect(target.displayID == external.id)
    }
}
