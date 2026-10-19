import Testing
import Foundation
import CoreGraphics
@testable import ArrangementCore

final class LayoutTests {
    let screen = CGRect(x: -1600, y: -400, width: 1600, height: 1000)
    let window = CGRect(x: -1400, y: -200, width: 700, height: 500)
    @Test func testTilingUsesGlobalCoordinatesOnDisplayAboveAndLeft() {
        #expect((Layout.frame(for: .left, window: window, screen: screen)) == (CGRect(x: -1600, y: -400, width: 800, height: 1000)))
        #expect((Layout.frame(for: .bottomRight, window: window, screen: screen)) == (CGRect(x: -800, y: 100, width: 800, height: 500)))
        #expect((Layout.frame(for: .topRight, window: window, screen: screen)) == (CGRect(x: -800, y: -400, width: 800, height: 500)))
    }
    @Test func testCenterKeepsSizeAndClampsOversizedWindows() {
        #expect((Layout.frame(for: .center, window: window, screen: screen)) == (CGRect(x: -1150, y: -150, width: 700, height: 500)))
        #expect((Layout.frame(for: .center, window: CGRect(x: 0, y: 0, width: 2000, height: 1800), screen: screen)) == (screen))
    }
    @Test func testDisplayChosenByIntersectionRatherThanOrigin() {
        let displays = [DisplayRecord(id: "a", name: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), visibleFrame: .zero),
                        DisplayRecord(id: "b", name: "B", frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000), visibleFrame: .zero)]
        #expect((Layout.display(for: CGRect(x: 900, y: 0, width: 600, height: 600), in: displays)?.id) == ("b"))
        #expect((Layout.display(for: window, in: [])) == nil)
    }
    @Test func testResolutionChangeScalesPositionAndSize() {
        let result = Layout.remap(CGRect(x: 100, y: 50, width: 500, height: 400), from: CGRect(x: 0, y: 0, width: 1000, height: 800), to: CGRect(x: -2000, y: -500, width: 2000, height: 1600))
        #expect((result) == (CGRect(x: -1800, y: -400, width: 1000, height: 800)))
    }
    @Test func testDisconnectedDisplayFallbackKeepsWindowReachable() {
        let target = CGRect(x: 0, y: 25, width: 800, height: 575)
        let result = Layout.remap(CGRect(x: 1800, y: 1100, width: 500, height: 400), from: CGRect(x: 0, y: 0, width: 2000, height: 1200), to: target)
        #expect(target.contains(result))
    }
    @Test func testUnchangedDisplayPreservesExactPartlyOffscreenFrame() {
        let frame = CGRect(x: -1700, y: -450, width: 600, height: 500)
        #expect((Layout.remap(frame, from: screen, to: screen)) == (frame))
    }
    @Test func testZeroSourceDoesNotDivideByZero() {
        #expect((Layout.remap(window, from: .zero, to: screen)) == (window))
    }
}

final class MatcherTests {
    func window(_ title: String, identifier: String = "", app: String = "app", nativeID: UInt32? = nil, session: String = "") -> WindowRecord {
        WindowRecord(appID: app, appName: app, title: title, identifier: identifier, session: session, nativeID: nativeID, frame: CGRect(x: 0, y: 0, width: 500, height: 500), displayID: "display")
    }
    @Test func testReorderedWindowsMatchTitlesAndNeverReuseCandidates() {
        let saved = [window("A"), window("B")], live = [window("B"), window("A")]
        let matches = WindowMatcher.match(saved: saved, live: live)
        #expect((matches[saved[0].id]) == (live[1].id))
        #expect((matches[saved[1].id]) == (live[0].id))
    }
    @Test func testLiveNativeIDMatchesAfterTitleChanges() {
        let saved = [window("Old", nativeID: 8, session: "1:launch"), window("Other", nativeID: 9, session: "1:launch")]
        let live = [window("New", nativeID: 8, session: "1:launch"), window("Other", nativeID: 9, session: "1:launch")]
        #expect((WindowMatcher.match(saved: saved, live: live)[saved[0].id]) == (live[0].id))
    }
    @Test func testRecycledNativeIDFromAnotherProcessSessionDoesNotWin() {
        let saved = [window("A", nativeID: 8, session: "old"), window("B", nativeID: 9, session: "old")]
        let live = [window("B", nativeID: 8, session: "new"), window("A", nativeID: 9, session: "new")]
        #expect((WindowMatcher.match(saved: saved, live: live)[saved[0].id]) == (live[1].id))
    }
    @Test func testIdentifierTakesPriorityOverChangingTitles() {
        let saved = [window("A", identifier: "document1"), window("B", identifier: "document2")]
        let live = [window("A", identifier: "document2"), window("B", identifier: "document1")]
        #expect((WindowMatcher.match(saved: saved, live: live)[saved[0].id]) == (live[1].id))
    }
    @Test func testAmbiguousDuplicateTitlesAreSkipped() {
        #expect(WindowMatcher.match(saved: [window("Untitled"), window("Untitled")], live: [window("Untitled"), window("Untitled")]).isEmpty)
        #expect(WindowMatcher.match(saved: [window("Untitled"), window("Untitled")], live: [window("Untitled")]).isEmpty)
    }
    @Test func testChangingMultiwindowTitlesAreNotMatchedByOrder() {
        #expect(WindowMatcher.match(saved: [window("A"), window("B")], live: [window("C"), window("D")]).isEmpty)
    }
    @Test func testMissingAppsDoNotMatchIdenticalTitles() {
        #expect(WindowMatcher.match(saved: [window("A", app: "one")], live: [window("A", app: "two")]).isEmpty)
    }
}

final class PersistenceTests {
    var directory: URL!
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    @Test func testRoundTripPreservesSpacesAndShortcuts() throws {
        let store = DataStore(url: directory.appendingPathComponent("nested/state.json"))
        var data = AppData()
        let window = WindowRecord(appID: "app", appName: "アプリ", title: "書類", documentURL: "file:///tmp/document.txt", frame: CGRect(x: -700, y: -300, width: 600, height: 400), displayID: "display-uuid", spaceID: "space-uuid", minimized: true)
        data.snapshots = [Snapshot(name: "仕事", backend: .nativeSpaces, displays: [], spaces: [SpaceRecord(id: "space-uuid", index: 2, label: "デスクトップ 2")], windows: [window])]
        data.selectedSnapshotID = data.snapshots[0].id
        data.shortcuts["left"] = Shortcut(keyCode: 123, modifiers: 6144, label: "⌃⌥←")
        try store.save(data)
        let decoded = try store.load()
        #expect((decoded.snapshots[0].windows[0].spaceID) == ("space-uuid"))
        #expect((decoded.snapshots[0].windows[0].frame) == (window.frame))
        #expect(decoded.snapshots[0].windows[0].minimized)
        #expect(decoded.snapshots[0].windows[0].documentURL == window.documentURL)
        #expect((decoded.selectedSnapshotID) == (data.selectedSnapshotID))
        #expect((decoded.shortcuts["left"]) == (data.shortcuts["left"]))
    }
    @Test func testMissingFileCreatesEmptyState() throws {
        #expect(try DataStore(url: directory.appendingPathComponent("state.json")).load().snapshots.isEmpty)
    }
    @Test func testCorruptDataThrowsAndIsNotOverwritten() throws {
        let url = directory.appendingPathComponent("state.json"), corrupt = Data("broken".utf8)
        try corrupt.write(to: url)
        #expect(throws: (any Error).self) { try DataStore(url: url).load() }
        #expect((try Data(contentsOf: url)) == (corrupt))
    }
    @Test func testUnsupportedSchemaThrows() throws {
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var data = AppData(); data.version = 99
        try store.save(data)
        #expect(throws: (any Error).self) { try store.load() }
    }
    @Test func testLegacySnapshotWithoutDocumentURLStillLoads() throws {
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var data = AppData()
        let window = WindowRecord(appID: "com.microsoft.VSCode", appName: "Code", title: "sample-project — Work (Offline)", frame: .zero, displayID: "display")
        data.snapshots = [Snapshot(name: "以前のSnapshot", backend: .accessibility, displays: [], windows: [window])]
        try store.save(data)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        var snapshots = json["snapshots"] as! [[String: Any]]
        var windows = snapshots[0]["windows"] as! [[String: Any]]
        windows[0].removeValue(forKey: "documentURL")
        snapshots[0]["windows"] = windows; json["snapshots"] = snapshots
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)
        let decoded = try store.load()
        #expect(decoded.snapshots[0].windows[0].documentURL == nil)
        #expect(decoded.snapshots[0].windows[0].title == window.title)
    }
    @Test func testShortcutConflictUsesKeysRatherThanDisplayLabels() {
        #expect(Shortcut(keyCode: 123, modifiers: 1, label: "left").conflicts(with: Shortcut(keyCode: 123, modifiers: 1, label: "←")))
        #expect(!(Shortcut(keyCode: 123, modifiers: 1, label: "←").conflicts(with: Shortcut(keyCode: 123, modifiers: 2, label: "←"))))
    }
}
