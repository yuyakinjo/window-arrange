import AppKit
import ArrangementCore

/// Read-only diagnosis of saved layouts. Does not move windows, open apps or save state.
@MainActor
enum RestoreDiagnostics {
    #if DEBUG
    /// Explicit development command for one saved window; no state file writes.
    static func restoreSavedWindow(_ id: UUID) async throws {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowArrange/state.json")
        let data = try DataStore(url: url).load()
        guard let snapshot = data.snapshots.first(where: { $0.windows.contains { $0.id == id } }),
              let saved = snapshot.windows.first(where: { $0.id == id }) else { throw ArrangeError("保存ウィンドウが見つかりません") }
        let service = AccessibilityService(), spaces = NativeSpaces()
        let live = try await service.restorationWindows(for: snapshot, spaces: snapshot.backend == .nativeSpaces ? spaces : nil)
        let matches = WindowMatcher.match(saved: snapshot.windows, live: live.map(\.record))
        guard let match = matches[saved.id], let window = live.first(where: { $0.record.id == match }) else { throw ArrangeError("対象ウィンドウを再取得できませんでした") }
        _ = try await SnapshotWindowRestorer.restore(saved, snapshot: snapshot, window: window, accessibility: service, spaces: spaces)
        print("PASS: requested saved window rediscovered and restored to saved display, Space and frame")
    }
    #endif
    static func run() async throws {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowArrange/state.json")
        let data = try DataStore(url: url).load()
        let service = AccessibilityService()
        try service.requireAccess()
        let spaces = NativeSpaces()
        var results: [[String: Any]] = []
        for snapshot in data.snapshots {
            let live = try await service.windows(spaces: snapshot.backend == .nativeSpaces ? spaces : nil, requireKnownSpace: false).windows.map(\.record)
            let matches = WindowMatcher.match(saved: snapshot.windows, live: live)
            let known = Set(live.compactMap(\.nativeID))
            let serverOnly = snapshot.backend == .nativeSpaces ? service.serverWindows(spaces: spaces).filter { !known.contains($0.nativeID ?? 0) } : []
            let completeMatches = WindowMatcher.match(saved: snapshot.windows, live: live + serverOnly)
            let destinations = snapshot.backend == .nativeSpaces ? try spaces.spaces().map { $0.record.id } : []
            let apps = Set(snapshot.windows.map(\.appID)).sorted().map { app in
                let saved = snapshot.windows.filter { $0.appID == app }
                return ["appID": app, "saved": saved.count, "live": live.filter { $0.appID == app }.count,
                        "matched": saved.filter { matches[$0.id] != nil }.count,
                        "serverOnly": serverOnly.filter { $0.appID == app }.count,
                        "matchedIncludingInactiveSpaces": saved.filter { completeMatches[$0.id] != nil }.count] as [String: Any]
            }
            results.append(["snapshot": snapshot.name, "apps": apps,
                            "missingSpaces": snapshot.spaces.filter { !destinations.contains($0.id) }.count])
        }
        let json = try JSONSerialization.data(withJSONObject: ["snapshots": results], options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: json, as: UTF8.self))
    }
}
