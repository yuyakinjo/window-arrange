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
    @Test(arguments: SwitcherApps.allCases) func excludedAppsOverrideEveryApplicationFilter(_ filter: SwitcherApps) {
        var settings = SwitcherSettings(); settings.apps = filter
        settings.excludedApps = [SwitcherExcludedApp(id: "b", name: "Beta")]
        #expect(!ids(settings).contains("b1"))
        #expect(!ids(settings).contains("b2"))
        settings.excludedApps.append(SwitcherExcludedApp(id: "c", name: "Gamma"))
        #expect(!ids(settings).contains("c"))
        settings.excludedApps.removeAll()
        var defaults = SwitcherSettings(); defaults.apps = filter
        #expect(ids(settings) == ids(defaults))
    }
    @Test func exclusionMatchesAppIdentityRatherThanNameAndSurvivesNewWindows() {
        var settings = SwitcherSettings()
        settings.excludedApps = [SwitcherExcludedApp(id: "a", name: "Old Name")]
        let candidates = [SwitcherWindow(id: "new", appID: "a", appName: "New Name"),
                          SwitcherWindow(id: "different", appID: "different", appName: "Old Name")]
        #expect(SwitcherList.windows(candidates, settings: settings, context: context).map(\.id) == ["different"])
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
    @Test func verticalNavigationKeepsColumnAndWrapsAtTopAndBottom() {
        var selection = SwitcherSelection()
        selection.open(ids: (0..<12).map(String.init), current: nil, backwards: false)
        selection.select("2")
        selection.moveVertically(1, columns: 4); #expect(selection.selected == "6")
        selection.moveVertically(1, columns: 4); #expect(selection.selected == "10")
        selection.moveVertically(1, columns: 4); #expect(selection.selected == "2")
        selection.moveVertically(-1, columns: 4); #expect(selection.selected == "10")
        selection.moveVertically(-1, columns: 4); #expect(selection.selected == "6")
    }
    @Test func verticalNavigationClampsShortLastRowAndHandlesOneRowOrEmptyList() {
        var selection = SwitcherSelection()
        selection.open(ids: (0..<6).map(String.init), current: nil, backwards: false)
        selection.select("3")
        selection.moveVertically(1, columns: 4); #expect(selection.selected == "5")
        selection.moveVertically(-1, columns: 4); #expect(selection.selected == "1")
        selection.select("0")
        selection.moveVertically(-1, columns: 4); #expect(selection.selected == "4")
        selection.reconcile(ids: ["0", "1", "2"]); selection.select("2")
        selection.moveVertically(1, columns: 3); #expect(selection.selected == "2")
        selection.moveVertically(-1, columns: 3); #expect(selection.selected == "2")
        selection.reconcile(ids: [])
        selection.moveVertically(1, columns: 4); #expect(selection.selected == nil)
    }
    @Test func shortcutConflictIncludesHeldModifiersAndAutomaticSummonNext() {
        let settings = SwitcherSettings()
        #expect(settings.conflict(for: settings.previous, command: .previous) == nil)
        #expect(settings.conflict(for: Shortcut(keyCode: 48, modifiers: 256, label: "same as next"), command: .confirm) != nil)
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
        data.switcher.titlePosition = .top
        data.switcher.separateTabs = true; data.switcher.onePerApp = true
        data.switcher.windowScale = 1.35
        data.switcher.excludedApps = [SwitcherExcludedApp(id: "com.example.editor", name: "Editor")]
        data.switcher.previous = Shortcut(keyCode: 123, modifiers: 0, label: "←")
        let decoded = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        #expect(decoded.switcher == data.switcher)
    }
    @Test func savedSettingsWithoutSizeKeepFiltersAndShortcuts() throws {
        var data = AppData()
        data.switcher.apps = .active; data.switcher.style = .icons; data.switcher.theme = .dark
        data.switcher.summon = Shortcut(keyCode: 49, modifiers: 2048, label: "⌥Space")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(data)) as? [String: Any])
        var switcher = try #require(json["switcher"] as? [String: Any])
        switcher.removeValue(forKey: "windowScale"); json["switcher"] = switcher
        let decoded = try JSONDecoder().decode(AppData.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.switcher == data.switcher)
        #expect(decoded.switcher.windowScale == 1)
    }
    @Test func savedSettingsWithoutExcludedAppsKeepExistingPreferences() throws {
        var settings = SwitcherSettings(); settings.apps = .active; settings.theme = .dark
        settings.next = Shortcut(keyCode: 125, modifiers: 0, label: "↓")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "excludedApps")
        let decoded = try JSONDecoder().decode(SwitcherSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == settings)
        #expect(decoded.excludedApps.isEmpty)
    }
    @Test func savedSettingsWithoutTitlePositionKeepExistingPreferences() throws {
        var settings = SwitcherSettings(); settings.apps = .active; settings.theme = .dark
        settings.windowScale = 1.35
        settings.excludedApps = [SwitcherExcludedApp(id: "com.example.editor", name: "Editor")]
        settings.summon = Shortcut(keyCode: 49, modifiers: 2048, label: "⌥Space")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "titlePosition")
        let decoded = try JSONDecoder().decode(SwitcherSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == settings)
        #expect(decoded.titlePosition == .bottom)
    }
    @Test(arguments: [-10.0, 10.0]) func savedSizeIsLimitedToSliderRange(value: Double) throws {
        var settings = SwitcherSettings(); settings.windowScale = value
        let decoded = try JSONDecoder().decode(SwitcherSettings.self, from: JSONEncoder().encode(settings))
        #expect(SwitcherSettings.windowScaleRange.contains(decoded.windowScale))
    }
}

struct SwitcherKeyboardRoutingTests {
    func key(_ code: UInt32, _ modifiers: UInt32 = 0) -> Shortcut { Shortcut(keyCode: code, modifiers: modifiers, label: "") }
    @Test func defaultSummonIsCommandTab() {
        let settings = SwitcherSettings()
        #expect(settings.summon.keyCode == 48)
        #expect(settings.summon.modifiers == 256)
        #expect(settings.summon.label == "⌘⇥")
    }
    @Test func heldAndReleasedModifierSessionsRouteTheSameLocalActions() {
        let settings = SwitcherSettings()
        #expect(SwitcherKeyRouting.command(key: key(48, 256), settings: settings, heldModifiers: 256) == .next)
        #expect(SwitcherKeyRouting.command(key: key(48, 256 | 512), settings: settings, heldModifiers: 256) == .previous)
        #expect(SwitcherKeyRouting.command(key: key(36, 256), settings: settings, heldModifiers: 256) == .confirm)
        #expect(SwitcherKeyRouting.command(key: key(53), settings: settings, heldModifiers: 0) == .cancel)
        #expect(SwitcherKeyRouting.command(key: key(48), settings: settings, heldModifiers: 0) == .next)
        #expect(SwitcherKeyRouting.command(key: key(48, 512), settings: settings, heldModifiers: 0) == .previous)
    }
    @Test func customKeysAndUnrelatedModifiersAreDistinguished() {
        var settings = SwitcherSettings(); settings.next = key(124); settings.previous = key(123)
        #expect(SwitcherKeyRouting.command(key: key(124, 256), settings: settings, heldModifiers: 256) == .next)
        #expect(SwitcherKeyRouting.command(key: key(123, 256), settings: settings, heldModifiers: 256) == .previous)
        #expect(SwitcherKeyRouting.command(key: key(124, 256), settings: settings, heldModifiers: 0) == nil)
        #expect(SwitcherKeyRouting.command(key: key(48, 256), settings: settings, heldModifiers: 256) == .next)
        #expect(SwitcherKeyRouting.command(key: key(0), settings: settings, heldModifiers: 256) == nil)
    }
    @Test(arguments: [UInt32(0), 256, 2048])
    func arrowsNavigateWithDefaultKeysAndCustomSummon(heldModifiers: UInt32) {
        var settings = SwitcherSettings()
        if heldModifiers != 0 { settings.summon.modifiers = heldModifiers }
        #expect(SwitcherKeyRouting.command(key: key(123, heldModifiers), settings: settings, heldModifiers: heldModifiers) == .previous)
        #expect(SwitcherKeyRouting.command(key: key(124, heldModifiers), settings: settings, heldModifiers: heldModifiers) == .next)
        #expect(SwitcherKeyRouting.command(key: key(123, heldModifiers | 4096), settings: settings, heldModifiers: heldModifiers) == nil)
        #expect(SwitcherKeyRouting.command(key: key(124, heldModifiers | 512), settings: settings, heldModifiers: heldModifiers) == nil)
        #expect(SwitcherKeyRouting.command(key: key(125, heldModifiers), settings: settings, heldModifiers: heldModifiers) == .down)
        #expect(SwitcherKeyRouting.command(key: key(126, heldModifiers), settings: settings, heldModifiers: heldModifiers) == .up)
        #expect(SwitcherKeyRouting.command(key: key(125, heldModifiers | 512), settings: settings, heldModifiers: heldModifiers) == nil)
        #expect(SwitcherKeyRouting.command(key: key(126, heldModifiers | 4096), settings: settings, heldModifiers: heldModifiers) == nil)
    }
    @Test func explicitArrowBindingsTakePriorityOverNavigation() {
        var settings = SwitcherSettings(); settings.confirm = key(124); settings.cancel = key(123)
        #expect(SwitcherKeyRouting.command(key: key(124, 256), settings: settings, heldModifiers: 256) == .confirm)
        #expect(SwitcherKeyRouting.command(key: key(123), settings: settings, heldModifiers: 0) == .cancel)
        settings.confirm = key(125); settings.cancel = key(126)
        #expect(SwitcherKeyRouting.command(key: key(125, 256), settings: settings, heldModifiers: 256) == .confirm)
        #expect(SwitcherKeyRouting.command(key: key(126), settings: settings, heldModifiers: 0) == .cancel)
    }
}
