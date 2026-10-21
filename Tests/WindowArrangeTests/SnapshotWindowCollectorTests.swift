import ArrangementCore
import Foundation
import Testing
@testable import WindowArrange

@MainActor
struct SnapshotWindowCollectorTests {
    private func desktop(_ index: Int, display: String = "external") -> SpaceRecord {
        SpaceRecord(id: "\(display)-\(index)", index: index, label: "デスクトップ \(index)", displayID: display)
    }
    private func window(_ id: UInt32, on space: SpaceRecord, session: String = "session") -> WindowRecord {
        WindowRecord(appID: "test.editor", appName: "Editor", title: "project \(id)", session: session,
                     nativeID: id, frame: CGRect(x: 0, y: 0, width: 640, height: 480), displayID: space.displayID, spaceID: space.id)
    }

    @Test func capturesBothDesktopsOnOneExternalMonitorWithoutCachedReferences() async throws {
        let first = desktop(1), second = desktop(2)
        var current = first.id
        var visits: [String] = []
        let result = try await SnapshotWindowCollector.collect(desktops: [first, second], activeSpaces: { [first] },
            activate: { current = $0; visits.append($0) }, scan: {
                // Only the currently visible desktop exposes AX windows; every
                // scan creates fresh record UUIDs, as AccessibilityService does.
                let space = current == first.id ? first : second
                return .init(windows: [window(current == first.id ? 1 : 2, on: space)], skipped: 1)
            }, pause: {})
        #expect(Set(result.windows.compactMap(\.spaceID)) == [first.id, second.id])
        #expect(result.windows.count == 2)
        #expect(result.skipped == 1)
        #expect(visits == [first.id, second.id, first.id])
        #expect(current == first.id)
    }

    @Test func waitsForDelayedAXEnumerationAndKeepsWindowsOmittedInLaterScans() async throws {
        let first = desktop(1), second = desktop(2)
        var current = first.id
        var reads = 0, pauses = 0
        let result = try await SnapshotWindowCollector.collect(desktops: [first, second], activeSpaces: { [first] },
            activate: { current = $0; reads = 0 }, scan: {
                reads += 1
                return .init(windows: current == second.id && reads == 2 ? [window(2, on: second)] : [], skipped: 0)
            }, pause: { pauses += 1 })
        #expect(result.windows.count == 1)
        #expect(result.windows.first?.spaceID == second.id)
        #expect(pauses == 6)
    }

    @Test func returnsToEveryDisplaysOriginalSpaceIncludingFullscreen() async throws {
        let external = desktop(1), externalSecond = desktop(2), builtin = desktop(3, display: "builtin")
        let fullscreen = SpaceRecord(id: "fullscreen", index: 4, label: "フルスクリーン 4", displayID: "builtin")
        var visits: [String] = []
        _ = try await SnapshotWindowCollector.collect(desktops: [external, externalSecond, builtin],
            activeSpaces: { [externalSecond, fullscreen] }, activate: { visits.append($0) },
            scan: { .init(windows: [], skipped: 0) }, pause: {})
        #expect(visits.suffix(2) == [externalSecond.id, fullscreen.id])
    }

    @Test func activationFailureRestoresOriginalDesktopAndFailsCapture() async {
        let first = desktop(1), second = desktop(2)
        var visits: [String] = []
        var failed = false
        do {
            _ = try await SnapshotWindowCollector.collect(desktops: [first, second], activeSpaces: { [first] },
                activate: { id in
                    visits.append(id)
                    if id == second.id { throw ArrangeError("activation failed") }
                }, scan: { .init(windows: [window(1, on: first)], skipped: 0) }, pause: {})
        } catch { failed = error.localizedDescription == "activation failed" }
        #expect(failed)
        #expect(visits == [first.id, second.id, first.id])
    }

    @Test func scanFailureStillRestoresAllOriginalDisplaysAndReportsCleanupFailure() async {
        let first = desktop(1), other = desktop(2, display: "builtin")
        var visits: [String] = []
        var message = ""
        do {
            _ = try await SnapshotWindowCollector.collect(desktops: [first], activeSpaces: { [first, other] },
                activate: { id in
                    visits.append(id)
                    if visits.count == 2 { throw ArrangeError("return failed") }
                }, scan: { throw ArrangeError("scan failed") }, pause: {})
        } catch { message = error.localizedDescription }
        #expect(visits == [first.id, first.id, other.id])
        #expect(message.contains("scan failed"))
        #expect(message.contains("return failed"))
    }

    @Test func reusedWindowIDInNewAppSessionIsNotDeduplicated() async throws {
        let first = desktop(1)
        var reads = 0
        let result = try await SnapshotWindowCollector.collect(desktops: [first], activeSpaces: { [first] },
            activate: { _ in }, scan: {
                reads += 1
                return .init(windows: [window(1, on: first, session: reads == 1 ? "old" : "new")], skipped: 0)
            }, pause: {})
        #expect(result.windows.count == 2)
    }
}
