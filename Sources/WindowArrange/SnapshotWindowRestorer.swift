import AppKit
import ApplicationServices
import ArrangementCore

@MainActor
enum SnapshotWindowRestorer {
    /// Shared by the app and development checks; returns whether display geometry was adapted.
    static func restore(_ saved: WindowRecord, snapshot: Snapshot, window: LiveWindow,
                        accessibility: AccessibilityService, spaces: NativeSpaces) async throws -> Bool {
        let useSpaces = snapshot.backend == .nativeSpaces
        let currentSpaces = useSpaces ? try spaces.spaces() : []
        let space = currentSpaces.first { $0.record.id == saved.spaceID }
        if useSpaces && space == nil { throw ArrangeError("保存先のSpaceが削除されたか接続されていません") }
        let displays = accessibility.displays()
        guard let fallback = displays.first else { throw ArrangeError("ディスプレイがありません") }
        let destination = (useSpaces ? displays.first { $0.id == space?.record.displayID } : nil)
            ?? displays.first { $0.id == saved.displayID } ?? fallback
        let oldDisplay = snapshot.displays.first { $0.id == saved.displayID }
        let adapted = destination.id != saved.displayID || oldDisplay?.visibleFrame != destination.visibleFrame
        let frame = oldDisplay.map { Layout.remap(saved.frame, from: $0.visibleFrame, to: destination.visibleFrame) } ?? saved.frame
        guard !AX.bool(window.element, "AXFullScreen") else { throw ArrangeError("フルスクリーンを解除してください") }
        let originallyMinimized = AX.bool(window.element, kAXMinimizedAttribute)
        do {
            if originallyMinimized { try AX.setBool(window.element, kAXMinimizedAttribute, false) }
            let client = try AccessibilityPlacementClient(element: window.element, accessibility: accessibility, spaces: useSpaces ? spaces : nil)
            try await WindowPlacementRestorer.restore(
                to: WindowPlacementTarget(frame: frame, displayID: destination.id, spaceID: useSpaces ? saved.spaceID : nil), using: client)
            if AX.bool(window.element, kAXMinimizedAttribute) != saved.minimized { try AX.setBool(window.element, kAXMinimizedAttribute, saved.minimized) }
            if useSpaces, let nativeID = window.record.nativeID, spaces.spaceForWindow(nativeID)?.record.id != saved.spaceID {
                throw ArrangeError("復元後のSpaceが一致しません")
            }
            return adapted
        } catch {
            if AX.bool(window.element, kAXMinimizedAttribute) != originallyMinimized {
                try? AX.setBool(window.element, kAXMinimizedAttribute, originallyMinimized)
            }
            throw error
        }
    }
}
