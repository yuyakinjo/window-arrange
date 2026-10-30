import AppKit
import ArrangementCore

struct StatusMenuState {
    var busy = false
    var switcherEnabled = true
    var selected: Snapshot?
    var snapshots: [Snapshot] = []
    var motionMonitoring = false
    var motionEnabled = false
    var motionReady = false
}

enum StatusMenuAction: Equatable {
    case openWindow, switchWindows, openAirPods, toggleMotion, stopMotion, capture, quit
    case restore(UUID), select(UUID)
}

/// A fixed native menu during tracking: live SwiftUI motion updates never rebuild it.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Window Arrange")
    private var statusItem: NSStatusItem?
    private let state: () -> StatusMenuState
    private let perform: (StatusMenuAction) -> Void
    private let trackingChanged: (Bool) -> Void
    private var tracking = false

    init(installStatusItem: Bool = true, state: @escaping () -> StatusMenuState,
         perform: @escaping (StatusMenuAction) -> Void, trackingChanged: @escaping (Bool) -> Void) {
        self.state = state
        self.perform = perform
        self.trackingChanged = trackingChanged
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        // A status item needs a nonempty menu even before the first tracking callback.
        menuNeedsUpdate(menu)
        if installStatusItem {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Window Arrange")
            item.button?.image?.isTemplate = true
            item.button?.toolTip = "Window Arrange"
            item.menu = menu
            statusItem = item
        }
    }

    func stop() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        tracking = false
        trackingChanged(false)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu, !tracking else { return }
        let current = state()
        menu.removeAllItems()
        add("Window Arrangeを開く", .openWindow, to: menu)
        add("ウィンドウを切り替える", .switchWindows, to: menu, enabled: current.switcherEnabled)
        let airPods = submenu("AirPods操作", in: menu)
        add("AirPods操作の設定", .openAirPods, to: airPods)
        let toggle = add("デスクトップ切り替え", .toggleMotion, to: airPods, enabled: current.motionReady)
        toggle.state = current.motionEnabled ? .on : .off
        if current.motionMonitoring { add("AirPodsの接続を停止", .stopMotion, to: airPods) }
        menu.addItem(.separator())
        add("Snapshotを保存", .capture, to: menu, enabled: !current.busy)
        if let selected = current.selected {
            add("「\(selected.name)」を復元", .restore(selected.id), to: menu, enabled: !current.busy)
        }
        if !current.snapshots.isEmpty {
            let snapshots = submenu("Snapshotを選択", in: menu)
            for snapshot in current.snapshots {
                let item = add(snapshot.name, .select(snapshot.id), to: snapshots)
                item.state = snapshot.id == current.selected?.id ? .on : .off
            }
        }
        menu.addItem(.separator())
        let quit = add("終了", .quit, to: menu)
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        tracking = true
        trackingChanged(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        tracking = false
        trackingChanged(false)
    }

    @discardableResult
    private func add(_ title: String, _ action: StatusMenuAction, to menu: NSMenu, enabled: Bool = true) -> NSMenuItem {
        let item = StatusActionMenuItem(title: title, menuAction: action, perform: perform)
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = NSMenu(title: title)
        child.autoenablesItems = false
        item.submenu = child
        menu.addItem(item)
        return child
    }
}

@MainActor
final class StatusActionMenuItem: NSMenuItem {
    let menuAction: StatusMenuAction
    private let performAction: (StatusMenuAction) -> Void

    init(title: String, menuAction: StatusMenuAction, perform: @escaping (StatusMenuAction) -> Void) {
        self.menuAction = menuAction
        performAction = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc func invoke() {
        let action = menuAction
        let perform = performAction
        // Finish menu tracking before activating a window or starting an operation.
        DispatchQueue.main.async { perform(action) }
    }
}
