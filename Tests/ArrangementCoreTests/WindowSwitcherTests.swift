import Testing
import Foundation
@testable import ArrangementCore

struct WindowSwitcherTests {
    let context = SwitcherContext(activeApp: "a", activeWindow: "a1", cursorApp: "b", cursorWindows: ["a1", "b1"], visibleSpaces: [1, 3], screenID: "left")
    var windows: [SwitcherWindow] { [
        SwitcherWindow(id: "a1", appID: "a", appName: "Alpha", title: "First", screenID: "left", spaces: [1], spaceIndex: 1, focused: 10, created: 1),
        SwitcherWindow(id: "a2", appID: "a", appName: "Alpha", title: "Second", screenID: "right", spaces: [2], spaceIndex: 2, minimized: true, focused: 9, created: 3),
        SwitcherWindow(id: "b1", appID: "b", appName: "Beta", title: "Third", screenID: "left", spaces: [1, 2], spaceIndex: 1, hidden: true, focused: 7, created: 2),
        SwitcherWindow(id: "b2", appID: "b", appName: "Beta", title: "Full", screenID: "right", spaces: [3], spaceIndex: 3, fullscreen: true, focused: 8, created: 4),
        SwitcherWindow(id: "c", appID: "c", appName: "Gamma", windowless: true, focused: 11, created: 5)
    ] }
    func ids(_ settings: SwitcherSettings) -> [String] { SwitcherList.windows(windows, settings: settings, context: context).map(\.id) }
    @Test func defaultIncludesAllStatesAndPlacesWindowlessAtEnd() {
        #expect(ids(SwitcherSettings()) == ["a1", "a2", "b2", "b1", "c"])
    }
    @Test(arguments: SwitcherApps.allCases) func applicationFilters(_ filter: SwitcherApps) {
        var settings = SwitcherSettings(); settings.apps = filter
        let expected: Set<String>
        switch filter { case .all: expected = ["a1", "a2", "b1", "b2", "c"]; case .active: expected = ["a1", "a2"]
        case .other: expected = ["b1", "b2", "c"]; case .underCursor: expected = ["a1", "b1"]; case .appUnderCursor: expected = ["b1", "b2"] }
        #expect(Set(ids(settings)) == expected)
    }
    @Test func spacesIncludeStickyWindowsOnlyWhenTheirSpaceIsVisible() {
        var settings = SwitcherSettings(); settings.spaces = .visible
        #expect(ids(settings) == ["a1", "b2", "b1"])
        settings.spaces = .other
        #expect(ids(settings) == ["a2"])
    }
    @Test func unknownSpaceIsNotMisclassifiedAsAnotherDesktop() {
        var settings = SwitcherSettings(); settings.spaces = .other
        let unknown = SwitcherWindow(id: "unknown")
        #expect(SwitcherList.windows([unknown], settings: settings, context: context).isEmpty)
    }
    @Test func screenAndStateFiltersCompose() {
        var settings = SwitcherSettings(); settings.screens = .switcher; settings.hidden = .hide
        #expect(ids(settings) == ["a1"])
        settings.screens = .all; settings.minimized = .hide; settings.fullscreen = false; settings.windowless = .hide
        #expect(ids(settings) == ["a1"])
    }
    @Test func trailingStateTakesPrecedenceOverMostRecentAndNameOrder() {
        var settings = SwitcherSettings(); settings.minimized = .last; settings.hidden = .last
        #expect(ids(settings) == ["a1", "b2", "c", "a2", "b1"])
        settings.order = .alphabetical
        #expect(ids(settings) == ["a1", "b2", "a2", "b1", "c"])
    }
    @Test func allSortOrdersAreDeterministic() {
        var settings = SwitcherSettings(); settings.order = .created
        #expect(ids(settings) == ["b2", "a2", "b1", "a1", "c"])
        settings.order = .alphabetical
        #expect(ids(settings) == ["a1", "a2", "b2", "b1", "c"])
        settings.order = .space
        #expect(ids(settings) == ["a1", "b1", "a2", "b2", "c"])
    }
    @Test func appRepresentativeUsesMRURatherThanAlphabeticalWindowTitle() {
        var settings = SwitcherSettings(); settings.onePerApp = true; settings.order = .alphabetical
        #expect(ids(settings) == ["a1", "b2", "c"])
    }
    @Test func tabsCollapseOnlyExplicitGroupsAndRespectFilterBeforeGrouping() {
        var candidates = windows
        candidates[0].tabGroup = "group"; candidates[1].tabGroup = "group"
        var settings = SwitcherSettings()
        #expect(SwitcherList.windows(candidates, settings: settings, context: context).map(\.id) == ["a1", "b2", "b1", "c"])
        settings.separateTabs = true
        #expect(SwitcherList.windows(candidates, settings: settings, context: context).count == 5)
        settings.separateTabs = false; settings.spaces = .other
        #expect(SwitcherList.windows(candidates, settings: settings, context: context).map(\.id) == ["a2"])
    }
    @Test func selectionStartsAfterCurrentAndWrapsBothWays() {
        var selection = SwitcherSelection()
        selection.open(ids: ["a", "b", "c"], current: "a", backwards: false)
        #expect(selection.selected == "b")
        selection.move(2); #expect(selection.selected == "a")
        selection.move(-1); #expect(selection.selected == "c")
        selection.open(ids: ["a", "b", "c"], current: "a", backwards: true)
        #expect(selection.selected == "c")
    }
    @Test func selectionWhenCurrentFilteredOutAndOnlyOneCandidate() {
        var selection = SwitcherSelection()
        selection.open(ids: ["a", "b"], current: "missing", backwards: false); #expect(selection.selected == "a")
        selection.open(ids: ["a", "b"], current: "missing", backwards: true); #expect(selection.selected == "b")
        selection.open(ids: ["only"], current: "only", backwards: true)
        selection.move(-4); #expect(selection.selected == "only")
    }
    @Test func liveClosePreservesWindowIdentityOrChoosesNearbySurvivor() {
        var selection = SwitcherSelection()
        selection.open(ids: ["a", "b", "c"], current: "a", backwards: false)
        selection.reconcile(ids: ["c", "b", "a"]); #expect(selection.selected == "b")
        selection.reconcile(ids: ["c", "a"]); #expect(selection.selected == "a")
        selection.reconcile(ids: []); selection.move(1); #expect(selection.selected == nil)
    }
    @Test func shortcutConflictIncludesHeldModifiersAndAutomaticSummonNext() {
        let settings = SwitcherSettings()
        #expect(settings.conflict(for: settings.previous, command: .previous) == nil)
        #expect(settings.conflict(for: Shortcut(keyCode: 48, modifiers: 2048, label: "same as next"), command: .confirm) != nil)
        #expect(settings.conflict(for: settings.cancel, command: .previous) == .cancel)
        #expect(settings.conflict(for: Shortcut(keyCode: 48, modifiers: 256, label: "CmdTab"), command: .summon) == nil)
        #expect(settings.conflict(for: Shortcut(keyCode: 48, modifiers: 256 | 512, label: "CmdShiftTab"), command: .summon) != nil)
    }
    @Test func oldSavedDataGetsDefaultsWithoutLosingSnapshotsOrLayoutShortcuts() throws {
        var old = AppData(); old.shortcuts["left"] = Shortcut(keyCode: 123, modifiers: 256, label: "left")
        let encoded = try JSONEncoder().encode(old)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); json.removeValue(forKey: "switcher")
        let restored = try JSONDecoder().decode(AppData.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.switcher == SwitcherSettings()); #expect(restored.shortcuts == old.shortcuts)
    }
    @Test func switcherSettingsRoundTripAllFiltersAndCustomKeys() throws {
        var data = AppData(); data.switcher.apps = .underCursor; data.switcher.spaces = .other
        data.switcher.theme = .dark; data.switcher.style = .icons; data.switcher.release = .hold
        data.switcher.separateTabs = true; data.switcher.onePerApp = true
        data.switcher.previous = Shortcut(keyCode: 123, modifiers: 0, label: "←")
        let decoded = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        #expect(decoded.switcher == data.switcher)
    }
}

struct SwitcherKeyboardRoutingTests {
    func key(_ code: UInt32, _ modifiers: UInt32 = 0) -> Shortcut { Shortcut(keyCode: code, modifiers: modifiers, label: "") }
    @Test func heldAndReleasedModifierSessionsRouteTheSameLocalActions() {
        let settings = SwitcherSettings()
        #expect(SwitcherKeyRouting.command(key: key(48, 2048), settings: settings, heldModifiers: 2048) == .next)
        #expect(SwitcherKeyRouting.command(key: key(48, 2048 | 512), settings: settings, heldModifiers: 2048) == .previous)
        #expect(SwitcherKeyRouting.command(key: key(36, 2048), settings: settings, heldModifiers: 2048) == .confirm)
        #expect(SwitcherKeyRouting.command(key: key(53), settings: settings, heldModifiers: 0) == .cancel)
        #expect(SwitcherKeyRouting.command(key: key(48), settings: settings, heldModifiers: 0) == .next)
        #expect(SwitcherKeyRouting.command(key: key(48, 512), settings: settings, heldModifiers: 0) == .previous)
    }
    @Test func customKeysAndUnrelatedModifiersAreDistinguished() {
        var settings = SwitcherSettings(); settings.next = key(124); settings.previous = key(123)
        #expect(SwitcherKeyRouting.command(key: key(124, 2048), settings: settings, heldModifiers: 2048) == .next)
        #expect(SwitcherKeyRouting.command(key: key(123, 2048), settings: settings, heldModifiers: 2048) == .previous)
        #expect(SwitcherKeyRouting.command(key: key(124, 256), settings: settings, heldModifiers: 0) == nil)
        #expect(SwitcherKeyRouting.command(key: key(48, 2048), settings: settings, heldModifiers: 2048) == .next)
        #expect(SwitcherKeyRouting.command(key: key(0), settings: settings, heldModifiers: 2048) == nil)
    }
}
