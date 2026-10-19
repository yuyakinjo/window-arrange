import AppKit
import ArrangementCore

/// Read-only diagnosis of saved layouts. Does not move windows, open apps or save state.
@MainActor
enum RestoreDiagnostics {
    static func run() async throws {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowArrange/state.json")
        let data = try DataStore(url: url).load()
        let service = AccessibilityService()
        try service.requireAccess()
        let spaces = NativeSpaces()
        var results: [[String: Any]] = []
        for snapshot in data.snapshots {
            let live = try await service.windows(spaces: snapshot.backend == .nativeSpaces ? spaces : nil).windows.map(\.record)
            let matches = WindowMatcher.match(saved: snapshot.windows, live: live)
            let destinations = snapshot.backend == .nativeSpaces ? try spaces.spaces().map { $0.record.id } : []
            let apps = Set(snapshot.windows.map(\.appID)).sorted().map { app in
                let saved = snapshot.windows.filter { $0.appID == app }
                return ["appID": app, "saved": saved.count, "live": live.filter { $0.appID == app }.count,
                        "matched": saved.filter { matches[$0.id] != nil }.count] as [String: Any]
            }
            results.append(["snapshot": snapshot.name, "apps": apps,
                            "missingSpaces": snapshot.spaces.filter { !destinations.contains($0.id) }.count])
        }
        let json = try JSONSerialization.data(withJSONObject: ["snapshots": results], options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: json, as: UTF8.self))
    }
}
