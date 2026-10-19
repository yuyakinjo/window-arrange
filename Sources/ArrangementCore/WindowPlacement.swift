import Foundation
import CoreGraphics

public struct WindowPlacementState {
    public let frame: CGRect
    public let displayID: String?
    public let spaceID: String?
    public init(frame: CGRect, displayID: String?, spaceID: String?) {
        self.frame = frame; self.displayID = displayID; self.spaceID = spaceID
    }
}

public struct WindowPlacementTarget {
    public let frame: CGRect
    public let displayID: String
    public let spaceID: String?
    public init(frame: CGRect, displayID: String, spaceID: String? = nil) {
        self.frame = frame; self.displayID = displayID; self.spaceID = spaceID
    }
}

@MainActor
public protocol WindowPlacementClient {
    func readPlacement() -> WindowPlacementState?
    func setFrame(_ frame: CGRect) throws
    func moveToSpace(_ spaceID: String) async throws
}

public enum WindowPlacementError: LocalizedError {
    case unreadable, displayTransferFailed, didNotSettle
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "ウィンドウの現在位置を取得できませんでした。"
        case .displayTransferFailed: return "保存先のディスプレイへ移動できませんでした。モニターの接続とアプリの移動制約を確認してください。"
        case .didNotSettle: return "復元後のモニター・Space・位置・サイズが一致しません。アプリのサイズ制約や画面切り替えの影響が考えられます。"
        }
    }
}

/// A Space move is reliable only after the window physically reaches its display.
/// Coordinate changes can also update Space membership asynchronously, so require
/// multiple consecutive complete observations before reporting restoration success.
@MainActor
public enum WindowPlacementRestorer {
    public static func restore(
        to target: WindowPlacementTarget,
        using client: any WindowPlacementClient,
        pause: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async throws {
        guard let original = client.readPlacement() else { throw WindowPlacementError.unreadable }
        if original.displayID != target.displayID {
            try client.setFrame(target.frame)
            guard try await wait(using: client, consecutive: 2, pause: pause, matches: { $0.displayID == target.displayID }) else {
                throw WindowPlacementError.displayTransferFailed
            }
        }
        if let space = target.spaceID { try await client.moveToSpace(space) }
        try client.setFrame(target.frame)
        guard try await wait(using: client, consecutive: 3, pause: pause, matches: {
            $0.displayID == target.displayID && Layout.close($0.frame, target.frame)
                && (target.spaceID == nil || $0.spaceID == target.spaceID)
        }) else { throw WindowPlacementError.didNotSettle }
    }
    private static func wait(
        using client: any WindowPlacementClient, consecutive: Int,
        pause: @MainActor () async throws -> Void,
        matches: (WindowPlacementState) -> Bool
    ) async throws -> Bool {
        var stable = 0
        for _ in 0..<20 {
            try Task.checkCancellation()
            try await pause()
            if let state = client.readPlacement(), matches(state) { stable += 1 } else { stable = 0 }
            if stable >= consecutive { return true }
        }
        return false
    }
}
