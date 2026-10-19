import Foundation
import CoreGraphics

public enum LayoutRepeatMode: String, Codable, CaseIterable, Identifiable {
    case none, cycle, rotation
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "None（デフォルト）"
        case .cycle: return "cycle 1/2, 1/3"
        case .rotation: return "rotation 1/2, 1/3"
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
        let third = fractionalFrame(for: action, screen: display.visibleFrame, fraction: 1.0 / 3)
        if close(window, half) { return WindowPlacementTarget(frame: third, displayID: display.id) }
        if repeatMode == .rotation, close(window, third) {
            let next = displays[(index + 1) % displays.count]
            return WindowPlacementTarget(frame: fractionalFrame(for: action, screen: next.visibleFrame, fraction: 1.0 / 2), displayID: next.id)
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
