import AppKit
import ArrangementCore
import Testing
@testable import WindowArrange

@MainActor
struct StatusMenuControllerTests {
    @Test func menuRemainsStableWhileTrackingAndRefreshesOnNextOpen() throws {
        var state = StatusMenuState(motionMonitoring: true, motionEnabled: true, motionReady: true)
        var trackingEvents: [Bool] = []
        let controller = StatusMenuController(installStatusItem: false, state: { state }, perform: { _ in },
                                              trackingChanged: { trackingEvents.append($0) })
        #expect(controller.menu.item(withTitle: "Window Arrangeを開く") != nil)
        #expect(controller.menu.item(withTitle: "AirPods操作")?.submenu != nil)
        controller.menuNeedsUpdate(controller.menu)
        let parent = try #require(controller.menu.item(withTitle: "AirPods操作"))
        let child = try #require(parent.submenu)
        let toggle = try #require(child.item(withTitle: "デスクトップ切り替え"))
        #expect(toggle.state == .on && toggle.isEnabled)
        controller.menuWillOpen(controller.menu)
        state.motionEnabled = false
        state.motionReady = false
        state.motionMonitoring = false
        for _ in 0..<500 { controller.menuNeedsUpdate(controller.menu) }
        #expect(controller.menu.item(withTitle: "AirPods操作") === parent)
        #expect(parent.submenu === child)
        #expect(toggle.state == .on && toggle.isEnabled)
        controller.menuDidClose(controller.menu)
        controller.menuNeedsUpdate(controller.menu)
        let refreshed = try #require(controller.menu.item(withTitle: "AirPods操作")?.submenu)
        #expect(refreshed.item(withTitle: "デスクトップ切り替え")?.state == .off)
        #expect(refreshed.item(withTitle: "デスクトップ切り替え")?.isEnabled == false)
        #expect(refreshed.item(withTitle: "AirPodsの接続を停止") == nil)
        #expect(trackingEvents == [true, false])
    }

    @Test func snapshotSubmenuPreservesIdentityAndBusyState() throws {
        let first = Snapshot(name: "同名", backend: .accessibility, displays: [], spaces: [], windows: [])
        let second = Snapshot(name: "同名", backend: .accessibility, displays: [], spaces: [], windows: [])
        let state = StatusMenuState(busy: true, switcherEnabled: false, selected: second, snapshots: [first, second])
        let controller = StatusMenuController(installStatusItem: false, state: { state }, perform: { _ in }, trackingChanged: { _ in })
        controller.menuNeedsUpdate(controller.menu)
        let submenu = try #require(controller.menu.item(withTitle: "Snapshotを選択")?.submenu)
        let items = submenu.items.compactMap { $0 as? StatusActionMenuItem }
        #expect(items.map(\.menuAction) == [.select(first.id), .select(second.id)])
        #expect(items.map(\.state) == [.off, .on])
        #expect(controller.menu.item(withTitle: "Snapshotを保存")?.isEnabled == false)
        #expect(controller.menu.item(withTitle: "「同名」を復元")?.isEnabled == false)
        #expect(controller.menu.item(withTitle: "ウィンドウを切り替える")?.isEnabled == false)
    }

    @Test func actionRunsAfterMenuTrackingHasFinished() async {
        var invoked: [StatusMenuAction] = []
        let item = StatusActionMenuItem(title: "開く", menuAction: .openWindow, perform: { invoked.append($0) })
        item.invoke()
        #expect(invoked.isEmpty)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(invoked == [.openWindow])
    }
}
