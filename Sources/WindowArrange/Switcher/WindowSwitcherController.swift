import AppKit
import SwiftUI
import ApplicationServices
import ArrangementCore

@MainActor
final class WindowSwitcherController: ObservableObject {
    @Published private(set) var windows: [TrackedSwitcherWindow] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var settings = SwitcherSettings()
    @Published private(set) var isOpen = false
    @Published private(set) var loading = false
    @Published private(set) var shortcutError: String?
    @Published private(set) var previewWindows: [TrackedSwitcherWindow] = []
    @Published private(set) var previewLoading = false
    @Published private(set) var previewAppName: String?
    let thumbnails = SwitcherThumbnails()
    let previewThumbnails = SwitcherThumbnails()
    private let tracker = SwitcherWindowTracker()
    private let keyboard = SwitcherKeyboard()
    private let spaces = NativeSpaces()
    private let focusWorker = DispatchQueue(label: "local.windowarrange.switcher.focus", qos: .userInitiated)
    private var started = false
    private var panel: SwitcherPanel?
    private var selection = SwitcherSelection()
    private var context = SwitcherContext()
    private var previewContext = SwitcherContext()
    private var settingsPreviewVisible = false
    private var initialSelection = false
    private var backwards = false
    private var pendingMoves = 0
    private var pendingCommit = false
    private var focusTask: Task<Void, Never>?
    private var focusRequest = SwitcherFocusRequest()
    private var session = UUID()
    var onError: ((Error) -> Void)?
    var requestAccessibility: (() -> Void)?
    var isBusy: (() -> Bool)?

    init() {
        keyboard.onSummon = { [weak self] reverse in MainActor.assumeIsolated { self?.show(backwards: reverse, holding: true) } }
        keyboard.onCommand = { [weak self] command in MainActor.assumeIsolated { self?.handle(command) } }
        keyboard.onRelease = { [weak self] in MainActor.assumeIsolated { self?.release() } }
        keyboard.onInputFailure = { [weak self] in MainActor.assumeIsolated { self?.dismiss() } }
        keyboard.onOutsideClick = { [weak self] point in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return false }
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                if !panel.frame.contains(CGPoint(x: point.x, y: top - point.y)) {
                    DispatchQueue.main.async { [weak self] in self?.dismiss() }; return true
                }
                return false
            }
        }
        tracker.onChange = { [weak self] in self?.inventoryChanged() }
        tracker.isSuspended = { [weak self] in self?.isBusy?() == true }
    }
    func start() { started = true; if settings.enabled { tracker.start() } }
    func stop() { started = false; endSettingsPreview(); dismiss(); cancelFocus(); tracker.stop(); keyboard.stop() }
    func configure(_ settings: SwitcherSettings) {
        dismiss(); cancelFocus(); self.settings = settings
        if started || settingsPreviewVisible {
            if settings.enabled || settingsPreviewVisible { tracker.start() } else { tracker.stop() }
        }
        do { try keyboard.configure(settings); shortcutError = nil }
        catch { shortcutError = error.localizedDescription }
        rebuildSettingsPreview()
    }
    func beginSettingsPreview() {
        settingsPreviewVisible = true
        previewLoading = AXIsProcessTrusted() && tracker.inventory.windows.isEmpty
        // Capture the pointer context once, so moving across settings controls does
        // not change the meaning of the under-cursor filters on every edit.
        previewContext.cursorApp = tracker.inventory.cursorApp
        previewContext.cursorWindows = tracker.inventory.cursorWindows
        rebuildSettingsPreview()
        tracker.start()
    }
    func endSettingsPreview() {
        settingsPreviewVisible = false
        previewThumbnails.cancel()
        if !started || !settings.enabled { tracker.stop() }
    }
    private func rebuildSettingsPreview() {
        guard settingsPreviewVisible else { return }
        let inventory = tracker.inventory
        let active = inventory.windows.first { $0.info.id == inventory.activeWindow }
            ?? inventory.windows.filter { !$0.info.windowless }.max { $0.info.focused < $1.info.focused }
        // The settings app itself is intentionally absent from the inventory.
        // Use the last application window while the user is editing settings.
        let front = NSWorkspace.shared.frontmostApplication
        let externalFront = front.flatMap { app in
            app.processIdentifier != getpid() && app.activationPolicy == .regular
                && inventory.windows.contains(where: { $0.app.processIdentifier == app.processIdentifier }) ? app : nil
        }
        previewContext.activeApp = externalFront.map { $0.bundleIdentifier ?? "pid.\($0.processIdentifier)" } ?? active?.info.appID
        previewContext.activeWindow = active?.info.id
        previewContext.visibleSpaces = inventory.visibleSpaces
        previewContext.screenID = active?.info.screenID ?? screenID(preferredScreen(inventory: inventory))
        previewAppName = externalFront?.localizedName ?? active?.info.appName
        let ordered = SwitcherList.windows(inventory.windows.map(\.info), settings: settings, context: previewContext)
        let byID = Dictionary(uniqueKeysWithValues: inventory.windows.map { ($0.info.id, $0) })
        previewWindows = ordered.compactMap { byID[$0.id] }
        if settings.style == .thumbnails { previewThumbnails.load(previewWindows) }
        else { previewThumbnails.cancel() }
    }
    func validateSummon(_ shortcut: Shortcut) throws { try keyboard.validateSummon(shortcut) }
    func beginShortcutRecording(_ receive: @escaping (Shortcut) -> Void) throws { try keyboard.beginShortcutRecording(receive) }
    func endShortcutRecording() { keyboard.endShortcutRecording() }
    func suspend(_ suspended: Bool) {
        dismiss(); cancelFocus(); keyboard.suspended = suspended
        do { try keyboard.configure(settings); shortcutError = nil }
        catch { shortcutError = error.localizedDescription }
    }
    func permissionsChanged() {
        configure(settings)
        if AXIsProcessTrusted() && settings.enabled { _ = keyboard.ensureEventTap(); tracker.schedule() }
        else { dismiss(); cancelFocus() }
        thumbnails.checkPermission()
    }
    private func cancelFocus() { focusRequest.cancel(); focusTask?.cancel() }

    func show(backwards: Bool = false, holding: Bool = false) {
        guard settings.enabled, isBusy?() != true else { return }
        if isOpen { move(backwards ? -1 : 1); return }
        guard AXIsProcessTrusted() else { requestAccessibility?(); return }
        guard keyboard.ensureEventTap() else { onError?(ArrangeError("切替キーを受信できません。アクセシビリティの許可を確認してください。")); return }
        cancelFocus(); focusRequest = SwitcherFocusRequest(); session = UUID()
        self.backwards = backwards; initialSelection = false; pendingMoves = 0; pendingCommit = false
        let inventory = tracker.inventory
        let front = NSWorkspace.shared.frontmostApplication
        let screen = preferredScreen(inventory: inventory)
        let mouse = CGEvent(source: nil)?.location ?? .zero
        let underCursor = inventory.windows.filter {
            !$0.info.windowless && !$0.info.hidden && !$0.info.minimized && $0.info.frame.contains(mouse)
                && ($0.info.spaces.isEmpty || !$0.info.spaces.isDisjoint(with: inventory.visibleSpaces))
        }
        context = SwitcherContext(activeApp: front?.bundleIdentifier ?? front.map { "pid.\($0.processIdentifier)" }, activeWindow: inventory.activeWindow,
            cursorApp: underCursor.first?.info.appID, cursorWindows: Set(underCursor.map(\.info.id)), visibleSpaces: inventory.visibleSpaces, screenID: screenID(screen))
        isOpen = true; loading = inventory.windows.isEmpty
        keyboard.begin(holding: holding)
        rebuild()
        if panel == nil {
            let panel = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isOpaque = false
            panel.backgroundColor = .clear; panel.hasShadow = true; panel.isReleasedWhenClosed = false
            self.panel = panel
        }
        resizePanel(on: screen)
        panel?.appearance = settings.theme == .system ? nil : NSAppearance(named: settings.theme == .dark ? .darkAqua : .aqua)
        panel?.makeKeyAndOrderFront(nil)
        updateThumbnails()
        Task { [weak self] in await self?.tracker.refresh() }
        if holding && keyboard.holdReleased { release() }
    }
    func dismiss() {
        isOpen = false; pendingCommit = false
        keyboard.end(); panel?.orderOut(nil); thumbnails.cancel()
    }
    func select(_ id: String) { selection.select(id); selectedID = selection.selected }
    func choose(_ id: String) { select(id); commit() }
    private func handle(_ command: SwitcherCommand) {
        guard isOpen else { return }
        switch command {
        case .summon, .next: move(1)
        case .previous: move(-1)
        case .confirm: commit()
        case .cancel: dismiss()
        }
    }
    private func move(_ delta: Int) {
        if !initialSelection { pendingMoves += delta; return }
        selection.move(delta); selectedID = selection.selected
    }
    private func release() { if isOpen && settings.release == .focus { commit() } }
    private func inventoryChanged() {
        if settingsPreviewVisible && previewLoading {
            previewContext.cursorApp = tracker.inventory.cursorApp
            previewContext.cursorWindows = tracker.inventory.cursorWindows
        }
        previewLoading = false
        rebuildSettingsPreview()
        guard isOpen else { return }
        loading = false
        if !initialSelection {
            context.activeWindow = tracker.inventory.activeWindow
            context.cursorApp = tracker.inventory.cursorApp; context.cursorWindows = tracker.inventory.cursorWindows
            context.visibleSpaces = tracker.inventory.visibleSpaces
        }
        rebuild(); updateThumbnails()
        if let screen = panel?.screen { resizePanel(on: screen) }
        if pendingCommit { commit() }
    }
    private func resizePanel(on screen: NSScreen) {
        guard let panel else { return }
        let layout = SwitcherLayout(windowCount: windows.count, maximumWidth: screen.visibleFrame.width - 40,
                                    requestedScale: settings.effectiveWindowScale)
        let width = layout.width
        let view: NSHostingView<SwitcherOverlay>
        if let existing = panel.contentView as? NSHostingView<SwitcherOverlay> {
            view = existing
            view.rootView = SwitcherOverlay(controller: self, thumbnails: thumbnails, layout: layout)
        } else {
            view = NSHostingView(rootView: SwitcherOverlay(controller: self, thumbnails: thumbnails, layout: layout))
            panel.contentView = view
        }
        let height = min(screen.visibleFrame.height - 60, 620 * layout.scale, view.fittingSize.height)
        panel.setFrame(CGRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.midY - height / 2,
            width: width, height: height), display: true)
    }
    private func rebuild() {
        let inventory = tracker.inventory
        let ordered = SwitcherList.windows(inventory.windows.map(\.info), settings: settings, context: context)
        let byID = Dictionary(uniqueKeysWithValues: inventory.windows.map { ($0.info.id, $0) })
        var ids = ordered.map(\.id)
        if initialSelection {
            let live = Set(ids), old = Set(selection.ids)
            ids = selection.ids.filter { live.contains($0) } + ids.filter { !old.contains($0) }
            selection.reconcile(ids: ids)
        } else if !ids.isEmpty {
            selection.open(ids: ids, current: context.activeWindow, backwards: backwards)
            selection.move(pendingMoves); pendingMoves = 0; initialSelection = true
        }
        windows = ids.compactMap { byID[$0] }; selectedID = selection.selected
    }
    private func updateThumbnails() {
        if settings.style == .thumbnails { thumbnails.load(windows) } else { thumbnails.cancel() }
    }
    private func commit() {
        guard isOpen else { return }
        if !initialSelection && loading { pendingCommit = true; return }
        guard let id = selection.selected, let target = windows.first(where: { $0.info.id == id }) else { dismiss(); return }
        let generation = session
        let request = focusRequest
        dismiss()
        // Defer activation until the panel's orderOut has reached WindowServer.
        focusTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.session == generation else { return }
            do {
                try await self.focus(target, generation: generation, request: request)
                guard !Task.isCancelled, self.session == generation else { return }
                self.tracker.recordFocus(id); self.tracker.schedule()
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, self.session == generation else { return }
                self.onError?(error)
            }
        }
    }
    private func focus(_ target: TrackedSwitcherWindow, generation: UUID, request: SwitcherFocusRequest) async throws {
        guard !request.cancelled else { throw CancellationError() }
        guard !target.app.isTerminated else { throw ArrangeError("選択したアプリは終了しています。") }
        target.app.unhide()
        if target.info.windowless { target.app.activate(options: []); return }
        if !target.info.spaces.isEmpty {
            let visible = Set(((try? spaces.activeSpaces(includeFullscreen: true)) ?? []).map(\.runtimeID))
            if target.info.spaces.isDisjoint(with: visible),
               let space = (try? spaces.spaces(includeFullscreen: true))?.first(where: { target.info.spaces.contains($0.runtimeID) }) {
                do { try await spaces.activate(space.record.id, includeFullscreen: true) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    // Older macOS releases may not expose the Space activation entry point.
                    // Activation/AXRaise below can still switch to the target's existing Space.
                }
            }
        }
        try Task.checkCancellation()
        guard session == generation else { throw CancellationError() }
        let worker = focusWorker
        let result: Bool = await withCheckedContinuation { continuation in
            worker.async {
                guard !request.cancelled else { continuation.resume(returning: false); return }
                let native = NativeSpaces()
                let axApp = AXUIElementCreateApplication(target.app.processIdentifier)
                AXUIElementSetMessagingTimeout(axApp, 0.2)
                let fresh = (AX.value(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []).first { native.windowID($0) == target.nativeID }
                guard let element = fresh ?? target.element, native.windowID(element) == target.nativeID else {
                    continuation.resume(returning: false); return
                }
                AXUIElementSetMessagingTimeout(element, 0.2)
                guard !request.cancelled else { continuation.resume(returning: false); return }
                target.app.activate(options: [])
                if AX.bool(element, kAXMinimizedAttribute) { _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
                guard !request.cancelled else { continuation.resume(returning: false); return }
                if let tab = target.tab { _ = AXUIElementPerformAction(tab, kAXPressAction as CFString) }
                _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
                continuation.resume(returning: raised)
            }
        }
        if request.cancelled { throw CancellationError() }
        guard result else { throw ArrangeError("「\(target.info.title)」のウィンドウを操作できませんでした。一覧を開き直して再試行してください。") }
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(80))
            guard session == generation else { throw CancellationError() }
            let verified: Bool = await withCheckedContinuation { continuation in
                worker.async {
                    let app = AXUIElementCreateApplication(target.app.processIdentifier)
                    AXUIElementSetMessagingTimeout(app, 0.15)
                    let focused = AX.element(app, kAXFocusedWindowAttribute)
                    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier
                    let exact: Bool
                    if let tab = target.tab { exact = (AX.value(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true }
                    else { exact = focused.flatMap { NativeSpaces().windowID($0) } == target.nativeID }
                    let native = NativeSpaces()
                    let visible = (try? native.activeSpaces(includeFullscreen: true)).map { Set($0.map(\.runtimeID)) }
                    let correctSpace = target.info.spaces.isEmpty || visible.map { !$0.isDisjoint(with: target.info.spaces) } != false
                    continuation.resume(returning: foreground && exact && correctSpace)
                }
            }
            if verified { return }
        }
        throw ArrangeError("macOSが「\(target.info.title)」への切替を完了しませんでした。対象のウィンドウを確認してください。")
    }
    #if DEBUG
    func integrationInventory() async -> [TrackedSwitcherWindow] {
        await tracker.refresh()
        return tracker.inventory.windows
    }
    func integrationFocus(_ target: TrackedSwitcherWindow) async throws {
        cancelFocus(); focusRequest = SwitcherFocusRequest(); session = UUID()
        try await focus(target, generation: session, request: focusRequest)
    }
    static func integrationPreview() throws {
        let controller = WindowSwitcherController()
        let app = NSRunningApplication.current
        controller.selectedID = "preview-1"
        for style in SwitcherStyle.allCases {
            controller.settings.style = style
            for theme in [SwitcherTheme.light, .dark] {
                controller.settings.theme = theme
                for count in [0, 1, 2, 3, 4, 5, 8, 9, 20] {
                    for scale in [0.7, 1.0, 1.5] {
                        let titles = ["作業メモ", "プロジェクト", "ターミナル"]
                        controller.windows = (0..<count).map { index in
                            TrackedSwitcherWindow(info: SwitcherWindow(id: "preview-\(index)", appName: "サンプルアプリ",
                                title: index < titles.count ? titles[index] : "ウィンドウ \(index + 1)"), app: app, nativeID: nil, element: nil)
                        }
                        let layout = SwitcherLayout(windowCount: count, maximumWidth: 1600, requestedScale: scale)
                        let view = NSHostingView(rootView: SwitcherOverlay(controller: controller, thumbnails: controller.thumbnails, layout: layout))
                        let bounds = CGRect(x: 0, y: 0, width: layout.width, height: min(620 * layout.scale, view.fittingSize.height))
                        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                        window.contentView = view
                        view.frame = bounds
                        view.layoutSubtreeIfNeeded()
                        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ArrangeError("Preview rendering failed") }
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ArrangeError("Preview encoding failed") }
                        let suffix = (count == 3 ? "" : "-\(count)") + (scale == 1 ? "" : "-\(Int((scale * 100).rounded()))pct")
                        try data.write(to: URL(fileURLWithPath: "/private/tmp/window-arrange-preview-\(style.rawValue)-\(theme.rawValue)\(suffix).png"))
                    }
                }
            }
        }
        controller.stop()
    }
    func integrationRender(to path: String) throws {
        guard let view = panel?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ArrangeError("Switcher view could not be rendered")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ArrangeError("PNG encoding failed") }
        try data.write(to: URL(fileURLWithPath: path))
    }
    #endif
    private func preferredScreen(inventory: SwitcherInventory) -> NSScreen {
        let displays = AccessibilityService().displays()
        let active = inventory.windows.first { $0.info.id == inventory.activeWindow }
        if let active, let index = displays.firstIndex(where: { $0.id == active.info.screenID }), NSScreen.screens.indices.contains(index) { return NSScreen.screens[index] }
        return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
    private func screenID(_ screen: NSScreen) -> String {
        guard let index = NSScreen.screens.firstIndex(of: screen) else { return "" }
        let displays = AccessibilityService().displays()
        return displays.indices.contains(index) ? displays[index].id : ""
    }
}

private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct SwitcherLayout {
    let windowCount: Int
    let maximumWidth: CGFloat
    var requestedScale: CGFloat = 1
    let spacing: CGFloat = 12
    let outerPadding: CGFloat = 22
    let borderPadding: CGFloat = 1
    let gridPadding: CGFloat = 4
    private let maximumColumns = 4

    var columns: Int { min(maximumColumns, max(1, windowCount)) }
    private var insets: CGFloat { 2 * (outerPadding + borderPadding + gridPadding) }
    private var baseTileWidth: CGFloat { (1000 - insets - CGFloat(maximumColumns - 1) * spacing) / CGFloat(maximumColumns) }
    var scale: CGFloat {
        let requested = requestedScale.isFinite ? min(1.5, max(0.7, requestedScale)) : 1
        let available = (maximumWidth - insets - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        return max(0.1, min(requested, available / baseTileWidth))
    }
    var width: CGFloat {
        insets + CGFloat(columns) * baseTileWidth * scale + CGFloat(columns - 1) * spacing
    }
}

private struct SwitcherOverlay: View {
    @ObservedObject var controller: WindowSwitcherController
    @ObservedObject var thumbnails: SwitcherThumbnails
    let layout: SwitcherLayout
    private var columns: Int { layout.columns }
    private var spacing: CGFloat { layout.spacing }
    private var tileHeight: CGFloat { (controller.settings.style == .thumbnails ? 125 : 95) * layout.scale + 65 }
    private var gridHeight: CGFloat {
        let rows = max(1, (controller.windows.count + columns - 1) / columns)
        return CGFloat(rows) * tileHeight + CGFloat(rows - 1) * spacing + 8
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.windows.isEmpty {
                VStack(spacing: 12) {
                    if controller.loading { ProgressView(); Text("ウィンドウを取得中…") }
                    else { Image(systemName: "macwindow").font(.largeTitle); Text("表示条件に一致するウィンドウはありません") }
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: gridHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
                            ForEach(controller.windows, id: \.info.id) { window in
                                tile(window).id(window.info.id)
                            }
                        }.padding(layout.gridPadding)
                    }
                    .frame(minHeight: 0, idealHeight: gridHeight, maxHeight: gridHeight)
                    .onChange(of: controller.selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    .onAppear { if let id = controller.selectedID { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            if controller.settings.style == .thumbnails && !thumbnails.permitted {
                Text("サムネイルは「ウィンドウ切替」の設定で画面収録を許可すると表示できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = thumbnails.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(layout.outerPadding).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.12)))
        .padding(layout.borderPadding)
        .frame(width: layout.width)
        .preferredColorScheme(controller.settings.theme == .system ? nil : controller.settings.theme == .dark ? .dark : .light)
    }
    private func tile(_ window: TrackedSwitcherWindow) -> some View {
        let selected = controller.selectedID == window.info.id
        return Button { controller.choose(window.info.id) } label: {
            SwitcherWindowTile(window: window, image: thumbnails.images[window.info.id],
                               style: controller.settings.style, selected: selected, scale: layout.scale)
        }.buttonStyle(.plain)
            .accessibilityLabel("\(window.info.appName)、\(window.info.title)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct SwitcherWindowTile: View {
    let window: TrackedSwitcherWindow
    let image: NSImage?
    let style: SwitcherStyle
    var selected = false
    var compact = false
    var scale: CGFloat = 1
    private var imageHeight: CGFloat { (style == .thumbnails ? (compact ? 72 : 125) : (compact ? 52 : 95)) * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.04))
                if style == .thumbnails, let image = image {
                    Image(nsImage: image).resizable().scaledToFit().padding(4)
                } else { Image(nsImage: window.app.icon ?? NSImage(named: NSImage.applicationIconName)!).resizable().scaledToFit().padding(compact ? 12 : 24) }
            }.frame(height: imageHeight)
            HStack(spacing: 7) {
                Image(nsImage: window.app.icon ?? NSImage(named: NSImage.applicationIconName)!).resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.info.title.isEmpty ? window.info.appName : window.info.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(window.info.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }.padding(10).frame(height: imageHeight + 65)
            .background(selected ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : .primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// A queued AX operation must not activate an old selection after another switcher session starts.
private final class SwitcherFocusRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return invalidated }
    func cancel() { lock.lock(); invalidated = true; lock.unlock() }
}
