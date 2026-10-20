import Foundation
import CoreGraphics
import Testing
import ArrangementCore
@testable import WindowArrange

struct NativeCommandTabTests {
    private final class Fixture {
        let suite = "WindowArrangeTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        var enabled: [UInt32: Bool] = [1: true, 2: true]
        var failDisabling: UInt32?
        var failRestoring = false
        init() { defaults = UserDefaults(suiteName: suite)! }
        func makeOverride() -> NativeCommandTab {
            NativeCommandTab(isEnabled: { [self] in enabled[$0] ?? false }, setEnabled: { [self] id, value in
                if (!value && failDisabling == id) || (value && failRestoring) { return .failure }
                enabled[id] = value; return .success
            }, defaults: defaults)
        }
        deinit { defaults.removePersistentDomain(forName: suite) }
    }

    @Test func onlyNativeAppSwitcherChordsNeedAnOverride() {
        #expect(NativeCommandTab.hotKeyIDs(for: Shortcut(keyCode: 48, modifiers: 256, label: "")) == [1, 2])
        #expect(NativeCommandTab.hotKeyIDs(for: Shortcut(keyCode: 48, modifiers: 256 | 512, label: "")) == [2])
        #expect(NativeCommandTab.hotKeyIDs(for: Shortcut(keyCode: 48, modifiers: 2048, label: "")) == [])
        #expect(NativeCommandTab.hotKeyIDs(for: Shortcut(keyCode: 48, modifiers: 256 | 2048, label: "")) == [])
        #expect(NativeCommandTab.hotKeyIDs(for: Shortcut(keyCode: 0, modifiers: 256, label: "")) == [])
    }

    @Test func replacingAndReleasingRestoresTheOriginalStates() throws {
        let fixture = Fixture(); fixture.enabled[2] = false
        let native = fixture.makeOverride()
        try native.replace([1, 2])
        #expect(fixture.enabled == [1: false, 2: false])
        #expect(fixture.defaults.dictionary(forKey: "nativeCommandTabRecovery") != nil)
        native.restore()
        #expect(fixture.enabled == [1: true, 2: false])
        #expect(fixture.defaults.dictionary(forKey: "nativeCommandTabRecovery") == nil)
    }

    @Test func changingShortcutsAndDisablingReleasesThePreviousOverride() throws {
        let fixture = Fixture(), native = fixture.makeOverride()
        try native.replace([1, 2]); try native.replace([2])
        #expect(fixture.enabled == [1: true, 2: false])
        try native.replace([])
        #expect(fixture.enabled == [1: true, 2: true])
    }

    @Test func partialFailureRestoresAlreadyChangedHotKeys() {
        let fixture = Fixture(); fixture.failDisabling = 2
        let native = fixture.makeOverride()
        #expect(throws: (any Error).self) { try native.replace([1, 2]) }
        #expect(fixture.enabled == [1: true, 2: true])
        #expect(fixture.defaults.dictionary(forKey: "nativeCommandTabRecovery") == nil)
    }

    @Test func failedRestoreRetainsRecoveryStateAndCanBeRetried() throws {
        let fixture = Fixture(), native = fixture.makeOverride()
        try native.replace([1, 2]); fixture.failRestoring = true
        native.restore()
        #expect(fixture.defaults.dictionary(forKey: "nativeCommandTabRecovery") != nil)
        #expect(throws: (any Error).self) { try native.replace([]) }
        fixture.failRestoring = false; native.restore()
        #expect(fixture.enabled == [1: true, 2: true])
        #expect(fixture.defaults.dictionary(forKey: "nativeCommandTabRecovery") == nil)
    }

    @Test func unsupportedSystemDoesNotChangeNativeKeys() {
        let fixture = Fixture()
        let native = NativeCommandTab(isEnabled: nil, setEnabled: nil, defaults: fixture.defaults)
        #expect(throws: (any Error).self) { try native.replace([1, 2]) }
        #expect(fixture.defaults.dictionary(forKey: "nativeCommandTabRecovery") == nil)
    }

    @Test func startupRecoversOnlyPreviouslyEnabledKeysAfterAForcedTermination() {
        let fixture = Fixture(); fixture.enabled = [1: false, 2: false]
        fixture.defaults.set(["pid": Int32.max, "enabled": [UInt32(1)]], forKey: "nativeCommandTabRecovery")
        let native = fixture.makeOverride()
        #expect(fixture.enabled == [1: true, 2: false])
        #expect(fixture.defaults.dictionary(forKey: "nativeCommandTabRecovery") == nil)
        native.restore()
    }

    @Test func startupLeavesALiveOwnersOverrideAlone() {
        let fixture = Fixture(); fixture.enabled = [1: false, 2: false]
        fixture.defaults.set(["pid": ProcessInfo.processInfo.processIdentifier, "enabled": [UInt32(1), 2]], forKey: "nativeCommandTabRecovery")
        let native = fixture.makeOverride()
        #expect(fixture.enabled == [1: false, 2: false])
        #expect(fixture.defaults.dictionary(forKey: "nativeCommandTabRecovery") != nil)
        native.restore()
    }
}
