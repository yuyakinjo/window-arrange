import Foundation
import Testing
@testable import ArrangementCore

struct DisplayProfileTests {
    private func display(_ id: String, builtin: Bool = false, name: String = "Monitor", width: CGFloat = 1000) -> DisplayRecord {
        DisplayRecord(id: id, name: name, frame: CGRect(x: 0, y: 0, width: width, height: 800),
                      visibleFrame: .zero, isBuiltin: builtin)
    }
    private let open = DisplayProfile(mode: .openWithExternal, displayIDs: ["builtin", "home"])
    private let closed = DisplayProfile(mode: .clamshell, displayIDs: ["home"])

    @Test func detectsThreeLaptopModesAndDesktopFallback() {
        let builtin = display("builtin", builtin: true), external = display("home")
        #expect(DisplayProfile.detect(displays: [builtin], lidClosed: false)?.mode == .builtinOnly)
        #expect(DisplayProfile.detect(displays: [external, builtin], lidClosed: false) == open)
        #expect(DisplayProfile.detect(displays: [external], lidClosed: true) == closed)
        #expect(DisplayProfile.detect(displays: [external], lidClosed: nil)?.mode == .externalOnly)
        // An explicitly disabled built-in panel is not proof that the lid is closed.
        #expect(DisplayProfile.detect(displays: [external], lidClosed: false)?.mode == .openWithExternal)
    }

    @Test func transientAndUnknownDisplaysAreNotAssignedAProfile() {
        #expect(DisplayProfile.detect(displays: [], lidClosed: true) == nil)
        #expect(DisplayProfile.detect(displays: [display("builtin", builtin: true), display("home")], lidClosed: true) == nil)
        #expect(DisplayProfile.detect(displays: [display("")], lidClosed: false) == nil)
        #expect(DisplayProfile.detect(displays: [display("home"), display("home")], lidClosed: false) == nil)
        let old = DisplayRecord(id: "home", name: "Monitor", frame: .zero, visibleFrame: .zero)
        #expect(DisplayProfile.detect(displays: [old], lidClosed: nil) == nil)
    }

    @Test func identityIgnoresOrderNamesAndResolutionButDistinguishesHardwareAndMode() {
        let first = DisplayProfile.detect(displays: [display("builtin", builtin: true), display("home")], lidClosed: false)
        let reordered = DisplayProfile.detect(displays: [display("home", name: "Renamed", width: 2000), display("builtin", builtin: true)], lidClosed: false)
        #expect(first == reordered)
        #expect(first != DisplayProfile.detect(displays: [display("builtin", builtin: true), display("office")], lidClosed: false))
        #expect(closed != DisplayProfile(mode: .openWithExternal, displayIDs: ["home"]))
        #expect(closed != DisplayProfile(mode: .clamshell, displayIDs: ["home", "second"]))
    }

    @Test func insertRejectsDuplicateProfileWithoutChangingData() throws {
        var data = AppData()
        let first = Snapshot(name: "仕事", backend: .accessibility, displays: [], windows: [], profile: open)
        try data.saveSnapshot(first)
        let before = try JSONEncoder().encode(data)
        let duplicate = Snapshot(name: "別名", backend: .accessibility, displays: [], windows: [], profile: open)
        #expect(throws: ProfileSaveError.self) { try data.saveSnapshot(duplicate) }
        #expect(data.snapshots.count == 1)
        #expect(data.selectedSnapshotID == first.id)
        #expect(try JSONDecoder().decode(AppData.self, from: before).snapshots.first?.id == data.snapshots.first?.id)
    }

    @Test func updatePreservesIdentityAndNameAndReplacesLayout() throws {
        var data = AppData()
        var original = Snapshot(name: "自宅の仕事", backend: .accessibility, displays: [], windows: [], profile: open)
        original.createdAt = Date(timeIntervalSince1970: 100)
        try data.saveSnapshot(original)
        let window = WindowRecord(appID: "app", appName: "App", title: "Document", frame: .zero, displayID: "home")
        var replacement = Snapshot(name: "自動生成名", backend: .nativeSpaces, displays: [display("home")], windows: [window], profile: open)
        replacement.createdAt = Date(timeIntervalSince1970: 200)
        let id = try data.saveSnapshot(replacement, replacing: original.id)
        #expect(id == original.id)
        #expect(data.snapshots.count == 1)
        let saved = try #require(data.snapshots.first)
        #expect(saved.name == original.name && saved.createdAt == original.createdAt)
        #expect(saved.updatedAt == replacement.createdAt)
        #expect(saved.backend == .nativeSpaces && saved.windows.first?.id == window.id)
        #expect(data.selectedSnapshotID == original.id)
    }

    @Test func changedOrDeletedReplacementCannotOverwriteAnotherProfile() throws {
        var data = AppData()
        let existing = Snapshot(name: "Home", backend: .accessibility, displays: [], windows: [], profile: open)
        try data.saveSnapshot(existing)
        let new = Snapshot(name: "Closed", backend: .accessibility, displays: [], windows: [], profile: closed)
        #expect(throws: ProfileSaveError.self) { try data.saveSnapshot(new, replacing: existing.id) }
        #expect(throws: ProfileSaveError.self) { try data.saveSnapshot(new, replacing: UUID()) }
        #expect(data.snapshots.first?.profile == open)
    }

    @Test func manualCopiesAndDifferentProfilesCoexistWithoutAutomaticAmbiguity() throws {
        var data = AppData()
        for profile in [open, closed, nil, nil] {
            try data.saveSnapshot(Snapshot(name: "Same name", backend: .accessibility, displays: [], windows: [], profile: profile))
        }
        #expect(data.snapshots.count == 4)
        #expect(data.automaticSnapshot(for: open)?.profile == open)
        #expect(data.automaticSnapshot(for: closed)?.profile == closed)
        #expect(data.automaticSnapshot(for: DisplayProfile(mode: .builtinOnly, displayIDs: ["builtin"])) == nil)
    }

    @Test func ambiguousImportedProfilesRequireExplicitUpdateAndKeepOtherLayouts() throws {
        var data = AppData()
        let first = Snapshot(name: "First", backend: .accessibility, displays: [], windows: [], profile: open)
        let second = Snapshot(name: "Second", backend: .accessibility, displays: [], windows: [], profile: open)
        data.snapshots = [first, second]
        #expect(data.automaticSnapshot(for: open) == nil)
        try data.saveSnapshot(first, replacing: second.id)
        #expect(data.snapshots.count == 2)
        #expect(data.snapshots[0].id == first.id && data.snapshots[0].profile == nil)
        #expect(data.automaticSnapshot(for: open)?.id == second.id)
    }

    @Test func profilesSettingsAndUpdatedDateRoundTrip() throws {
        var data = AppData()
        data.automaticProfilesEnabled = true
        var snapshot = Snapshot(name: "Home", backend: .accessibility,
                                displays: [display("builtin", builtin: true), display("home")], windows: [], profile: open)
        snapshot.updatedAt = Date(timeIntervalSince1970: 500)
        data.snapshots = [snapshot]
        let decoded = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        #expect(decoded.automaticProfilesEnabled)
        #expect(decoded.snapshots.first?.profile == open)
        #expect(decoded.snapshots.first?.updatedAt == snapshot.updatedAt)
        #expect(decoded.snapshots.first?.displays.first?.isBuiltin == true)
    }

    @Test func oldStateLoadsAsManualWithoutEnablingAutomaticRestore() throws {
        var data = AppData()
        data.snapshots = [Snapshot(name: "Legacy", backend: .accessibility, displays: [display("home")], windows: [])]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(data)) as? [String: Any])
        json.removeValue(forKey: "automaticProfilesEnabled")
        var snapshots = try #require(json["snapshots"] as? [[String: Any]])
        snapshots[0].removeValue(forKey: "profile")
        snapshots[0].removeValue(forKey: "updatedAt")
        var displays = try #require(snapshots[0]["displays"] as? [[String: Any]])
        displays[0].removeValue(forKey: "isBuiltin")
        snapshots[0]["displays"] = displays; json["snapshots"] = snapshots
        let decoded = try JSONDecoder().decode(AppData.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.automaticProfilesEnabled)
        #expect(decoded.snapshots.first?.profile == nil)
        #expect(decoded.snapshots.first?.displays.first?.isBuiltin == nil)
        #expect(decoded.snapshots.first?.id == data.snapshots.first?.id)
    }
}

struct ProfileRestoreGateTests {
    private let a = DisplayProfile(mode: .builtinOnly, displayIDs: ["builtin"])
    private let b = DisplayProfile(mode: .clamshell, displayIDs: ["home"])

    @Test func waitsForStableConfigurationAndRunsOnlyOnce() {
        var gate = ProfileRestoreGate()
        #expect(gate.observe(a, now: 0, enabled: true, ready: true) == nil)
        #expect(gate.observe(a, now: 2, enabled: true, ready: true) == nil)
        #expect(gate.observe(a, now: 3, enabled: true, ready: true) == a)
        #expect(gate.observe(a, now: 30, enabled: true, ready: true) == nil)
        gate.invalidate()
        #expect(gate.observe(a, now: 31, enabled: true, ready: true) == nil)
        #expect(gate.observe(a, now: 35, enabled: true, ready: true) == nil)
    }

    @Test func rapidChangesAndEmptyScreenListRestartSettling() {
        var gate = ProfileRestoreGate()
        #expect(gate.observe(a, now: 0, enabled: true, ready: true) == nil)
        #expect(gate.observe(b, now: 2, enabled: true, ready: true) == nil)
        #expect(gate.observe(nil, now: 4, enabled: true, ready: true) == nil)
        #expect(gate.observe(b, now: 5, enabled: true, ready: true) == nil)
        #expect(gate.observe(b, now: 7, enabled: true, ready: true) == nil)
        #expect(gate.observe(b, now: 8, enabled: true, ready: true) == b)
    }

    @Test func busyOrMissingPermissionDefersWithoutConsumingRestore() {
        var gate = ProfileRestoreGate()
        #expect(gate.observe(a, now: 0, enabled: true, ready: false) == nil)
        #expect(gate.observe(a, now: 5, enabled: true, ready: false) == nil)
        #expect(gate.observe(a, now: 6, enabled: true, ready: true) == a)
    }

    @Test func disablingAndReenablingStartsFresh() {
        var gate = ProfileRestoreGate()
        #expect(gate.observe(a, now: 0, enabled: false, ready: true) == nil)
        #expect(gate.observe(a, now: 5, enabled: true, ready: true) == nil)
        #expect(gate.observe(a, now: 8, enabled: true, ready: true) == a)
        #expect(gate.observe(a, now: 9, enabled: false, ready: true) == nil)
        #expect(gate.observe(a, now: 10, enabled: true, ready: true) == nil)
        #expect(gate.observe(a, now: 13, enabled: true, ready: true) == a)
    }

    @Test func returningToAnEarlierConfigurationAndWakeRestoreAgain() {
        var gate = ProfileRestoreGate(settlingDelay: 1)
        #expect(gate.observe(a, now: 0, enabled: true, ready: true) == nil)
        #expect(gate.observe(a, now: 1, enabled: true, ready: true) == a)
        #expect(gate.observe(b, now: 2, enabled: true, ready: true) == nil)
        #expect(gate.observe(b, now: 3, enabled: true, ready: true) == b)
        #expect(gate.observe(a, now: 4, enabled: true, ready: true) == nil)
        #expect(gate.observe(a, now: 5, enabled: true, ready: true) == a)
        gate.invalidate(retry: true)
        #expect(gate.observe(a, now: 20, enabled: true, ready: true) == nil)
        #expect(gate.observe(a, now: 21, enabled: true, ready: true) == a)
    }

    @Test func savingOrManuallyRestoringSuppressesPendingAutomaticRestore() {
        var gate = ProfileRestoreGate()
        #expect(gate.observe(a, now: 0, enabled: true, ready: true) == nil)
        gate.markHandled(a)
        #expect(gate.observe(a, now: 5, enabled: true, ready: true) == nil)
        #expect(gate.observe(b, now: 6, enabled: true, ready: true) == nil)
        #expect(gate.observe(b, now: 9, enabled: true, ready: true) == b)
    }
}
