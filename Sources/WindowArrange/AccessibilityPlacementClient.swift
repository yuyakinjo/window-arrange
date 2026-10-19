import AppKit
import ApplicationServices
import ArrangementCore

@MainActor
final class AccessibilityPlacementClient: WindowPlacementClient {
    private let element: AXUIElement
    private let accessibility: AccessibilityService
    private let spaces: NativeSpaces?
    private let windowID: UInt32?

    init(element: AXUIElement, accessibility: AccessibilityService, spaces: NativeSpaces?) throws {
        self.element = element; self.accessibility = accessibility; self.spaces = spaces
        windowID = spaces?.windowID(element)
        if spaces != nil && windowID == nil { throw ArrangeError("Space移動用のウィンドウIDを取得できませんでした。") }
    }
    func readPlacement() -> WindowPlacementState? {
        guard let frame = AX.frame(element) else { return nil }
        return WindowPlacementState(frame: frame,
                                    displayID: Layout.display(for: frame, in: accessibility.displays())?.id,
                                    spaceID: windowID.flatMap { spaces?.spaceForWindow($0)?.record.id })
    }
    func setFrame(_ frame: CGRect) throws { try AX.setFrame(element, frame) }
    func moveToSpace(_ spaceID: String) async throws {
        guard let spaces, let windowID else { throw ArrangeError("Spaces操作の準備ができていません。") }
        try await spaces.move(window: windowID, to: spaceID)
    }
}
