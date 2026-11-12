import AppKit
import ApplicationServices
import SwiftUI
import ArrangementCore

struct OperationReport: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var details: [String] = []
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var data = AppData()
    @Published var selectedID: UUID?
    @Published var section = "snapshots"
    @Published var busy = false
    @Published var progress = ""
    @Published var trusted = false
    @Published var report: OperationReport?
    @Published var recording: WindowAction? {
        didSet {
            if recording != nil { hotKeys.suspend(); switcher.suspend(true) }
            else { resumeHotKeys() }
        }
    }
    var openMainWindow: (() -> Void)?
    @Published private(set) var shortcutFailures: [String] = []
    @Published private(set) var storageAvailable = true
    @Published private(set) var currentProfileLabel = "画面構成を確認中…"
    @Published private(set) var automaticProfileStatus = ""
    @Published private(set) var automaticProfileReport: OperationReport?
    let accessibility = AccessibilityService()
    let nativeSpaces = NativeSpaces()
    let switcher = WindowSwitcherController()
    let loginItem = LoginItemController()
    let headMotion = HeadMotionController()
    let trackpadEdge = TrackpadEdgeController()
    private let hotKeys = HotKeyManager()
    private let store: DataStore
    private var timer: Timer?
    private var automaticRestoreTask: Task<Void, Never>?
    private lazy var profileMonitor = DisplayProfileMonitor(
        read: { [weak self] in self?.displayEnvironment() ?? DisplayEnvironment(profile: nil, geometry: [], label: "") },
        enabled: { [weak self] in self?.data.automaticProfilesEnabled == true },
        ready: { [weak self] in self?.automaticRestoreReady == true },
        changed: { [weak self] environment in
            self?.currentProfileLabel = environment.label
            self?.automaticProfileStatus = ""
            self?.automaticProfileReport = nil
        },
        restore: { [weak self] profile in self?.restoreAutomaticProfile(profile) },
        interrupt: { [weak self] in self?.automaticRestoreTask?.cancel() })
    var selected: Snapshot? { data.snapshots.first { $0.id == selectedID } }

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = DataStore(url: root.appendingPathComponent("WindowArrange/state.json"))
        do { data = try store.load() }
        catch {
            storageAvailable = false
            report = OperationReport(title: "保存データを読み込めません", message: "既存データを保護するため保存を停止しました。\(store.url.path) を確認してからアプリを再起動してください。", details: [error.localizedDescription])
        }
        selectedID = data.snapshots.contains { $0.id == data.selectedSnapshotID } ? data.selectedSnapshotID : data.snapshots.first?.id
        trusted = accessibility.trusted
        hotKeys.onTrigger = { [weak self] action in
            Task { @MainActor in await self?.perform(action) }
        }
        switcher.onError = { [weak self] error in self?.show(error); self?.openMainWindow?() }
        switcher.requestAccessibility = { [weak self] in self?.accessibility.requestAccess() }
        switcher.isBusy = { [weak self] in self?.busy == true || self?.recording != nil }
        headMotion.isBusy = { [weak self] in
            self?.busy == true || self?.recording != nil || self?.switcher.isOpen == true
        }
        trackpadEdge.isBusy = { [weak self] in self?.recording != nil }
        resumeHotKeys()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                if trusted != self.trusted { self.trusted = trusted; self.switcher.permissionsChanged() }
            }
        }
    }
    func update(_ transform: (inout AppData) throws -> Void) throws {
        guard storageAvailable else { throw ArrangeError("保存データの読み込みエラーを解決してから再起動してください。") }
        var next = data; try transform(&next)
        try store.save(next)
        data = next
    }
    func select(_ id: UUID?) {
        selectedID = id
        do { try update { $0.selectedSnapshotID = id } } catch { show(error) }
    }
    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do { try update { data in if let i = data.snapshots.firstIndex(where: { $0.id == id }) { data.snapshots[i].name = name } } }
        catch { show(error) }
    }
    func delete(_ id: UUID) {
        do {
            try update { data in
                data.snapshots.removeAll { $0.id == id }
                if data.selectedSnapshotID == id { data.selectedSnapshotID = data.snapshots.first?.id }
            }
            if selectedID == id { selectedID = data.snapshots.first?.id }
        } catch { show(error) }
    }
    func setSpacesEnabled(_ enabled: Bool) { do { try update { $0.spacesEnabled = enabled } } catch { show(error) } }
    func startProfileMonitoring() { profileMonitor.start() }
    func stopProfileMonitoring() { profileMonitor.stop() }
    func setAutomaticProfilesEnabled(_ enabled: Bool) {
        do {
            try update { $0.automaticProfilesEnabled = enabled }
            profileMonitor.reset()
            automaticProfileStatus = ""; automaticProfileReport = nil
        } catch { show(error) }
    }
    private func displayEnvironment() -> DisplayEnvironment { .read(displays: accessibility.displays()) }
    private var automaticRestoreReady: Bool {
        !busy && recording == nil && report == nil && accessibility.trusted
            && storageAvailable && !switcher.isOpen && NSApp.modalWindow == nil
            && !NSApp.windows.contains { $0.attachedSheet != nil }
    }

    private func restoreAutomaticProfile(_ profile: DisplayProfile) {
        guard let snapshot = data.automaticSnapshot(for: profile) else {
            automaticProfileStatus = data.snapshots(for: profile).isEmpty
                ? "この構成のSnapshotは未保存です。" : "同じ構成のSnapshotが複数あります。保存し直して更新先を確定してください。"
            return
        }
        automaticRestoreTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.data.automaticProfilesEnabled,
                  self.displayEnvironment().profile == profile else { return }
            // User input can start another operation between polling and this task running.
            guard self.automaticRestoreReady else { self.profileMonitor.reset(); return }
            await self.restore(snapshot, automatically: true)
        }
    }
    func setRepeatMode(_ mode: LayoutRepeatMode) { do { try update { $0.repeatMode = mode } } catch { show(error) } }
    func setShortcut(_ shortcut: Shortcut?, action: WindowAction) {
        do {
            if let shortcut {
                var reverse = data.switcher.summon; reverse.modifiers |= 512
                if data.switcher.enabled && (shortcut.conflicts(with: data.switcher.summon) || shortcut.conflicts(with: reverse)) {
                    throw ArrangeError("ウィンドウ切替の呼び出しキーと重複しています。")
                }
                if let duplicate = data.shortcuts.first(where: { $0.key != action.rawValue && $0.value.conflicts(with: shortcut) }) {
                    throw ArrangeError("このキーは「\(WindowAction(rawValue: duplicate.key)?.title ?? duplicate.key)」に割り当て済みです。")
                }
                // Probe the OS registration before persisting the binding.
                try hotKeys.register(shortcut, for: action)
            }
            try update { $0.shortcuts[action.rawValue] = shortcut }
        } catch { show(error) }
        recording = nil
        resumeHotKeys()
    }
    func resumeHotKeys() {
        shortcutFailures = hotKeys.configure(data.shortcuts)
        switcher.suspend(false)
        switcher.configure(data.switcher)
    }
    func suspendForSwitcherRecording() { hotKeys.suspend(); switcher.suspend(true) }
    func resumeAfterSwitcherRecording() { resumeHotKeys() }
    func setSwitcherSettings(_ settings: SwitcherSettings) {
        var reverse = settings.summon; reverse.modifiers |= 512
        if settings.enabled && data.shortcuts.values.contains(where: { $0.conflicts(with: settings.summon) || $0.conflicts(with: reverse) }) {
            show(ArrangeError("ウィンドウ切替の呼び出しキーが配置ショートカットと重複しています。")); return
        }
        do { try update { $0.switcher = settings }; switcher.configure(settings) } catch { show(error) }
    }
    func setSwitcherShortcut(_ shortcut: Shortcut, command: SwitcherCommand) throws {
        if command == .summon {
            guard shortcut.modifiers & (256 | 2048 | 4096) != 0 else { throw ArrangeError("呼び出しキーには⌥・⌘・⌃のいずれかを含めてください。") }
            var reverse = shortcut; reverse.modifiers |= 512
            if let action = data.shortcuts.first(where: { $0.value.conflicts(with: shortcut) || $0.value.conflicts(with: reverse) }) {
                throw ArrangeError("「\(WindowAction(rawValue: action.key)?.title ?? action.key)」の配置ショートカットと重複しています。")
            }
        }
        if let conflict = data.switcher.conflict(for: shortcut, command: command) { throw ArrangeError("「\(conflict.title)」とキーが重複しています。") }
        if command == .summon { try switcher.validateSummon(shortcut) }
        var settings = data.switcher; settings[command] = shortcut
        try update { $0.switcher = settings }
    }
    func show(_ error: Error) { report = OperationReport(title: "操作を完了できませんでした", message: error.localizedDescription) }

    func perform(_ action: WindowAction) async {
        guard !busy, recording == nil else { return }
        if action == .snapshot { await capture(); return }
        if action == .restore {
            guard let selected else { show(ArrangeError("復元するSnapshotを選択してください。")); return }
            await restore(selected); return
        }
        busy = true; defer { busy = false }
        do { try await accessibility.perform(action, repeatMode: data.repeatMode) } catch { show(error) }
    }
    func capture(manual: Bool = false) async {
        guard !busy else { return }
        busy = true; progress = "ウィンドウを記録中…"; defer { busy = false; progress = "" }
        do {
            try accessibility.requireAccess()
            let environment = displayEnvironment()
            let detectedProfile = environment.profile
            guard manual || detectedProfile != nil else {
                throw ArrangeError("画面構成を判定できません。モニターの接続が落ち着いてから再試行してください。")
            }
            var profile: DisplayProfile? = manual ? nil : detectedProfile
            var replacingID: UUID?
            let matches = profile.map { data.snapshots(for: $0) } ?? []
            if !matches.isEmpty {
                let existing = matches.first { $0.id == selectedID } ?? matches[0]
                let alert = NSAlert()
                alert.messageText = "この構成のSnapshotを更新しますか？"
                alert.informativeText = "\(environment.label)\n「\(existing.name)」の配置を現在の配置で更新します。"
                    + (matches.count > 1 ? "\n同じ構成のほかのSnapshotは手動復元用として残します。" : "")
                alert.addButton(withTitle: "更新")
                alert.addButton(withTitle: "キャンセル").keyEquivalent = "\u{1b}"
                alert.addButton(withTitle: "手動用として別保存")
                NSApp.activate(ignoringOtherApps: true)
                switch alert.runModal() {
                case .alertFirstButtonReturn: replacingID = existing.id
                case .alertThirdButtonReturn: profile = nil
                default: return
                }
                if replacingID == nil { self.progress = "手動用Snapshotを記録中…" }
            }
            guard displayEnvironment() == environment else { throw ArrangeError("確認中に画面構成が変わりました。もう一度保存してください。") }
            let spaces = data.spacesEnabled ? try nativeSpaces.spaces().map(\.record) : []
            let result = try await accessibility.snapshotWindows(spaces: data.spacesEnabled ? nativeSpaces : nil, desktops: spaces) { self.progress = $0 }
            guard !result.windows.isEmpty else { throw ArrangeError("記録できる通常ウィンドウがありません。アプリのウィンドウを開いてから再試行してください。") }
            guard displayEnvironment() == environment else { throw ArrangeError("保存中に画面構成が変わりました。もう一度保存してください。") }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.dateFormat = "M/d HH:mm"
            let snapshot = Snapshot(name: profile?.label(displays: accessibility.displays()) ?? "レイアウト \(formatter.string(from: Date()))",
                                    backend: data.spacesEnabled ? .nativeSpaces : .accessibility,
                                    displays: accessibility.displays(), spaces: spaces, windows: result.windows, profile: profile)
            try update { try $0.saveSnapshot(snapshot, replacing: replacingID) }
            selectedID = data.selectedSnapshotID; section = "snapshots"
            if let detectedProfile { profileMonitor.markHandled(detectedProfile) }
            automaticProfileStatus = ""; automaticProfileReport = nil
            report = OperationReport(title: replacingID == nil ? "Snapshotを保存しました" : "Snapshotを更新しました", message: "\(snapshot.windows.count)ウィンドウを保存しました。" + (result.skipped > 0 ? " フルスクリーン・所属不明など\(result.skipped)件は対象外です。" : ""))
        } catch { show(error) }
    }
    func restore(_ snapshot: Snapshot, automatically: Bool = false) async {
        guard !busy else { return }
        busy = true; progress = "復元を準備中…"; defer { busy = false; progress = "" }
        do {
            try accessibility.requireAccess()
            func validateAutomaticRestore() throws {
                guard automatically else { return }
                try Task.checkCancellation()
                guard data.automaticProfilesEnabled, let profile = snapshot.profile,
                      displayEnvironment().profile == profile else { throw CancellationError() }
            }
            try validateAutomaticRestore()
            let useSpaces = snapshot.backend == .nativeSpaces
            let live = try await accessibility.restorationWindows(for: snapshot, spaces: useSpaces ? nativeSpaces : nil)
            try validateAutomaticRestore()
            let matches = WindowMatcher.match(saved: snapshot.windows, live: live.map(\.record))
            var restored = 0, adjusted = 0, issues: [String] = []
            for (index, saved) in snapshot.windows.enumerated() {
                try validateAutomaticRestore()
                progress = "復元中 \(index + 1) / \(snapshot.windows.count)"
                let label = "\(saved.appName) · \(saved.title.isEmpty ? "名称なし" : saved.title)"
                guard let id = matches[saved.id], let window = live.first(where: { $0.record.id == id }) else {
                    let candidates = live.filter { $0.record.appID == saved.appID }
                    issues.append("\(label)：" + (candidates.isEmpty ? "アプリのウィンドウが見つかりません" : "ウィンドウを特定できません。保存したプロジェクト・書類を開いてください。同じプロジェクトの候補が複数ある場合は自動選択しません。")); continue
                }
                do {
                    let adapted = try await SnapshotWindowRestorer.restore(saved, snapshot: snapshot, window: window, accessibility: accessibility, spaces: nativeSpaces)
                    restored += 1
                    if adapted { adjusted += 1 }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    issues.append("\(label)：\(error.localizedDescription)")
                }
                await Task.yield()
            }
            try validateAutomaticRestore()
            let result = OperationReport(title: issues.isEmpty ? "復元が完了しました" : "復元結果", message: "\(snapshot.windows.count)件中\(restored)件を復元しました。" + (adjusted > 0 ? " \(adjusted)件は現在のモニター構成に合わせて座標を調整しました。" : ""), details: issues)
            if automatically {
                automaticProfileStatus = "「\(snapshot.name)」：\(result.message)"
                automaticProfileReport = result
                select(snapshot.id)
            } else {
                report = result
                if let profile = displayEnvironment().profile { profileMonitor.markHandled(profile) }
            }
        } catch is CancellationError {
            if automatically { automaticProfileStatus = "画面構成の変更などにより、自動復元を中断しました。" }
        } catch {
            if automatically {
                automaticProfileStatus = "自動復元を完了できませんでした。"
                automaticProfileReport = OperationReport(title: automaticProfileStatus, message: error.localizedDescription)
            } else { show(error) }
        }
    }
}
