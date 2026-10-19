import Foundation
import CoreGraphics

public enum LayoutRepeatMode: String, Codable, CaseIterable, Identifiable {
    case none, cycle
    // Keep the persisted value so existing rotation selections remain valid.
    case displays = "rotation"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "None（デフォルト）"
        case .cycle: return "Cycle 1/2, 2/3, and 1/3"
        case .displays: return "Cycle Displays"
        }
    }
}

extension Layout {
    /// Infer the next step from the actual frame, so switching windows, manual
    /// resizing and failed placement never leave a stale cycle counter behind.
    public static func target(for action: WindowAction, window: CGRect, displays: [DisplayRecord],
                              repeatMode: LayoutRepeatMode = .none) -> WindowPlacementTarget? {
        guard let display = display(for: window, in: displays),
              let index = displays.firstIndex(where: { $0.id == display.id }) else { return nil }
        if action == .nextDisplay {
            guard displays.count > 1 else { return nil }
            let next = displays[(index + 1) % displays.count]
            return WindowPlacementTarget(frame: remap(window, from: display.visibleFrame, to: next.visibleFrame), displayID: next.id)
        }
        guard repeatMode != .none, [.left, .right, .top, .bottom].contains(action) else {
            return frame(for: action, window: window, screen: display.visibleFrame).map {
                WindowPlacementTarget(frame: $0, displayID: display.id)
            }
        }
        let half = fractionalFrame(for: action, screen: display.visibleFrame, fraction: 1.0 / 2)
        if repeatMode == .cycle {
            let twoThirds = fractionalFrame(for: action, screen: display.visibleFrame, fraction: 2.0 / 3)
            let third = fractionalFrame(for: action, screen: display.visibleFrame, fraction: 1.0 / 3)
            if close(window, half) { return WindowPlacementTarget(frame: twoThirds, displayID: display.id) }
            if close(window, twoThirds) { return WindowPlacementTarget(frame: third, displayID: display.id) }
            return WindowPlacementTarget(frame: half, displayID: display.id)
        }
        if close(window, half), displays.count > 1 {
            // Crossing an edge enters the facing half of the adjacent screen.
            // The next press then reaches the requested edge on that screen.
            let horizontal = action == .left || action == .right
            let ordered = displays.sorted { a, b in
                let aPrimary = horizontal ? a.frame.minX : a.frame.minY
                let bPrimary = horizontal ? b.frame.minX : b.frame.minY
                if aPrimary != bPrimary { return aPrimary < bPrimary }
                let aSecondary = horizontal ? a.frame.minY : a.frame.minX
                let bSecondary = horizontal ? b.frame.minY : b.frame.minX
                if aSecondary != bSecondary { return aSecondary < bSecondary }
                return a.id < b.id
            }
            let current = ordered.firstIndex(where: { $0.id == display.id })!
            let step = action == .left || action == .top ? -1 : 1
            let next = ordered[(current + step + ordered.count) % ordered.count]
            let opposite: WindowAction
            switch action {
            case .left: opposite = .right
            case .right: opposite = .left
            case .top: opposite = .bottom
            case .bottom: opposite = .top
            default: preconditionFailure("Only edge placements cycle displays")
            }
            return WindowPlacementTarget(frame: fractionalFrame(for: opposite, screen: next.visibleFrame, fraction: 1.0 / 2), displayID: next.id)
        }
        return WindowPlacementTarget(frame: half, displayID: display.id)
    }

    private static func fractionalFrame(for action: WindowAction, screen: CGRect, fraction: CGFloat) -> CGRect {
        switch action {
        case .left: return CGRect(x: screen.minX, y: screen.minY, width: screen.width * fraction, height: screen.height)
        case .right: return CGRect(x: screen.maxX - screen.width * fraction, y: screen.minY, width: screen.width * fraction, height: screen.height)
        case .top: return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height * fraction)
        case .bottom: return CGRect(x: screen.minX, y: screen.maxY - screen.height * fraction, width: screen.width, height: screen.height * fraction)
        default: preconditionFailure("Only edge placements support fractional sizing")
        }
    }
}
