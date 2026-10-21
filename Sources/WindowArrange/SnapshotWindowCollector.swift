import ArrangementCore
import Foundation

/// AXWindows may omit windows on inactive Spaces, even with an empty reference cache.
/// Visit every desktop before saving, and always restore the user's visible Spaces.
@MainActor
enum SnapshotWindowCollector {
    struct Result {
        var windows: [WindowRecord]
        var skipped: Int
    }

    static func collect(
        desktops: [SpaceRecord],
        activeSpaces: () throws -> [SpaceRecord],
        activate: (String) async throws -> Void,
        scan: () async throws -> Result,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) },
        progress: (String) -> Void = { _ in }
    ) async throws -> Result {
        let previous = try activeSpaces()
        var windows: [WindowRecord] = []
        var indices: [WindowReferenceKey: Int] = [:]
        var skipped = 0
        var failure: Error?
        do {
            for desktop in desktops {
                progress("\(desktop.label)のウィンドウを記録中…")
                try await activate(desktop.id)
                // Space activation can finish before applications update AXWindows.
                // Read repeatedly and merge so a later omission cannot discard a window.
                for _ in 0..<3 {
                    try await pause()
                    let result = try await scan()
                    skipped = max(skipped, result.skipped)
                    for window in result.windows {
                        guard let nativeID = window.nativeID else { continue }
                        let key = WindowReferenceKey(appID: window.appID, session: window.session, windowID: nativeID)
                        if let index = indices[key] { windows[index] = window }
                        else { indices[key] = windows.count; windows.append(window) }
                    }
                }
            }
        } catch { failure = error }

        progress("元のデスクトップに戻しています…")
        for space in previous {
            do { try await activate(space.id) }
            catch {
                let message = "元の\(space.label)に戻せませんでした：\(error.localizedDescription)"
                failure = ArrangeError(failure.map { "\($0.localizedDescription)\n\(message)" } ?? message)
            }
        }
        if let failure { throw failure }
        return Result(windows: windows, skipped: skipped)
    }
}
