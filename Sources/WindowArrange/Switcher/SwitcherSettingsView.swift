import SwiftUI
import ArrangementCore

// Resolve the property-wrapper type explicitly on SDKs that also export a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct SwitcherSettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: WindowSwitcherController
    @ObservedObject var thumbnails: SwitcherThumbnails
    @ViewState private var recording: SwitcherCommand?
    @ViewState private var recordingError: String?
    var body: some View {
        HStack(spacing: 0) {
            settingsForm.frame(minWidth: 380)
            Divider()
            SwitcherSettingsPreview(controller: controller, thumbnails: controller.previewThumbnails,
                                    trusted: model.trusted, canExclude: model.storageAvailable, onExclude: exclude)
                .frame(width: 310)
        }
        .onAppear { controller.beginSettingsPreview() }
        .onDisappear { controller.endSettingsPreview() }
    }

    private var settingsForm: some View {
        Form {
            Section("ウィンドウ切替") {
                Toggle("ウィンドウ切替を有効にする", isOn: binding(\.enabled))
                HStack {
                    Text("アプリの各ウィンドウを一覧から選択できます。")
                    Spacer()
                    Button("切替画面を開く") { controller.show() }.disabled(!model.data.switcher.enabled || !model.trusted)
                }
                choice("キーを離したとき", \.release)
                if let error = controller.shortcutError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Section("表示対象") {
                choice("アプリ", \.apps)
                    .help(model.data.switcher.apps.helpText)
                choice("Spaces", \.spaces)
                choice("ディスプレイ", \.screens)
                choice("最小化したウィンドウ", \.minimized)
                choice("非表示のアプリ", \.hidden)
                Toggle("フルスクリーンのウィンドウを表示", isOn: binding(\.fullscreen))
                choice("ウィンドウのないアプリ", \.windowless)
                Text("切替画面は使用中のウィンドウがある画面に表示します。ウィンドウのないアプリにはSpaces・ディスプレイの絞り込みを適用しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("除外アプリ") {
                if model.data.switcher.excludedApps.isEmpty {
                    Text("除外しているアプリはありません。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.data.switcher.excludedApps) { app in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name)
                                Text(app.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("解除") {
                                var settings = model.data.switcher
                                settings.excludedApps.removeAll { $0.id == app.id }
                                model.setSwitcherSettings(settings)
                            }
                            .accessibilityLabel("\(app.name)の除外を解除")
                        }
                    }
                }
                Text("プレビュー右上の−ボタンで、そのアプリのすべてのウィンドウを切替対象から除外します。除外設定は次回起動時も維持されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("並び順・まとめ方") {
                choice("並び順", \.order)
                Toggle("アプリごとに1件だけ表示", isOn: binding(\.onePerApp))
                Toggle("macOS標準のタブを個別に表示", isOn: binding(\.separateTabs))
                Text("タブはアプリがアクセシビリティで公開している場合に対応します。使用履歴と作成順はWindow Arrangeの起動後から記録します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("表示") {
                choice("表示形式", \.style)
                choice("形状", \.shape)
                choice("アイコン＋タイトルの位置", \.titlePosition)
                choice("テーマ", \.theme)
                LabeledContent("切替画面のサイズ") {
                    HStack {
                        Slider(value: binding(\.windowScale), in: SwitcherSettings.windowScaleRange, step: 0.05)
                            .accessibilityLabel("切替画面のサイズ")
                            .accessibilityValue("\(Int((model.data.switcher.effectiveWindowScale * 100).rounded()))%")
                        Text("\(Int((model.data.switcher.effectiveWindowScale * 100).rounded()))%")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                        Button("標準") { binding(\.windowScale).wrappedValue = 1 }
                            .disabled(model.data.switcher.windowScale == 1)
                    }
                    .accessibilityElement(children: .contain)
                }
                Text("切替画面とサムネイルの大きさを調整します。画面に収まるサイズが上限です。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("画面収録", value: thumbnails.permitted ? "許可済み" : "未許可 · アイコンで表示")
                Button(thumbnails.permitted ? "画面収録の設定を開く" : "サムネイルのための画面収録を許可") {
                    if thumbnails.permitted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                    else { thumbnails.requestPermission() }
                }
                Text("サムネイルは一覧やプレビューの表示中に取得し、メモリ上だけに保持します。最小化・非表示・保護されたウィンドウや、選択されていないタブは画像を取得できない場合があります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ショートカット") {
                ForEach(SwitcherCommand.allCases) { command in
                    LabeledContent(command.title) {
                        Button(model.data.switcher[command].label) { recordingError = nil; recording = command }
                            .font(.system(.body, design: .monospaced)).frame(minWidth: 100)
                    }
                }
                Text("呼び出しキーは⌥・⌘・⌃のいずれかを含む組み合わせです。Shift＋呼び出しキーで逆順に開始できます。切替画面内では←・→で前後、↑・↓で上下の行に移動できます。上下端では反対側の行に移動し、同じ列にウィンドウがなければ行の末尾を選びます。⌘Wで選択中のウィンドウを閉じ、⌘Qでそのアプリの終了を要求します。これらの操作は切替画面内だけで動作します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).disabled(!model.storageAvailable)
        .onAppear { thumbnails.checkPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in thumbnails.checkPermission() }
        .sheet(item: $recording, onDismiss: { controller.endShortcutRecording(); model.resumeAfterSwitcherRecording() }) { command in
            VStack(spacing: 18) {
                Image(systemName: "keyboard").font(.largeTitle)
                Text(command.title).font(.title2.bold())
                Text("割り当てるキーを押してください").font(.headline)
                Text(command == .summon ? "⌥・⌘・⌃のいずれかを含む組み合わせ" : "修飾キーなしでも設定できます。Escはキャンセル操作に割り当て可能です。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let error = recordingError { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                SwitcherShortcutRecorder(controller: controller, onError: { recordingError = $0.localizedDescription }) { shortcut in
                    do { try model.setSwitcherShortcut(shortcut, command: command); recording = nil }
                    catch { recordingError = error.localizedDescription }
                }.frame(width: 1, height: 1).accessibilityLabel("切替ショートカット入力")
                Button("キャンセル") { recording = nil }
            }.padding(30).frame(width: 430)
            .onAppear { model.suspendForSwitcherRecording() }
        }
    }
    private func exclude(_ window: SwitcherWindow) {
        var settings = model.data.switcher
        guard !settings.excludedApps.contains(where: { $0.id == window.appID }) else { return }
        settings.excludedApps.append(SwitcherExcludedApp(id: window.appID, name: window.appName))
        model.setSwitcherSettings(settings)
    }
    private func binding<Value>(_ key: WritableKeyPath<SwitcherSettings, Value>) -> Binding<Value> {
        Binding(get: { model.data.switcher[keyPath: key] }, set: { value in
            var settings = model.data.switcher; settings[keyPath: key] = value; model.setSwitcherSettings(settings)
        })
    }
    private func choice<Value: SwitcherChoice>(_ title: String, _ key: WritableKeyPath<SwitcherSettings, Value>) -> some View {
        Picker(title, selection: binding(key)) {
            ForEach(Array(Value.allCases)) { item in Text(item.title).tag(item) }
        }
    }
}

private struct SwitcherSettingsPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: WindowSwitcherController
    @ObservedObject var thumbnails: SwitcherThumbnails
    let trusted: Bool
    let canExclude: Bool
    var onExclude: (SwitcherWindow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("プレビュー").font(.headline)
                Spacer()
                if trusted && !controller.previewLoading {
                    Text("\(controller.previewWindows.count)件").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text("表示対象・並び順・見た目の変更をすぐに反映します。")
                .font(.caption).foregroundStyle(.secondary)
            if !trusted {
                placeholder("アクセシビリティを許可すると、実際のウィンドウを確認できます。", icon: "hand.raised")
            } else if controller.previewLoading {
                ProgressView("ウィンドウを取得中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.previewWindows.isEmpty {
                placeholder("表示条件に一致するウィンドウはありません", icon: "macwindow")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        ForEach(controller.previewWindows, id: \.info.id) { window in
                            VStack(alignment: .leading, spacing: 4) {
                                SwitcherWindowTile(window: window, image: thumbnails.images[window.info.id],
                                                   style: controller.settings.style, titlePosition: controller.settings.titlePosition,
                                                   shape: controller.settings.shape, compact: true,
                                                   scale: controller.settings.effectiveWindowScale)
                                    .overlay(alignment: .topTrailing) {
                                        Button { onExclude(window.info) } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .font(.system(size: 18, weight: .semibold))
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.primary, .background)
                                                .frame(width: 28, height: 28)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(!canExclude)
                                        .help("\(window.info.appName)のすべてのウィンドウを除外")
                                        .accessibilityLabel("\(window.info.appName)を切替対象から除外")
                                        .padding(4)
                                    }
                                Text(status(window.info)).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(2).padding(.horizontal, 6)
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }
                    .padding(controller.settings.shape == .circle ? 8 : 3)
                    .background {
                        if controller.settings.shape == .circle {
                            RoundedRectangle(cornerRadius: 44).fill(.primary.opacity(0.04))
                        }
                    }
                }
            }
            if let name = controller.previewAppName {
                Text("「現在のアプリ」の基準：\(name)").font(.caption).foregroundStyle(.secondary)
            }
            Text("カーソル下の対象は、この設定画面を開いた時点を基準にします。")
                .font(.caption).foregroundStyle(.secondary)
            if controller.settings.style == .thumbnails && !thumbnails.permitted {
                Text("画面収録が未許可のため、アイコンで表示しています。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = thumbnails.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(16)
        .background(.regularMaterial)
        .environment(\.colorScheme, controller.settings.theme == .system ? colorScheme : controller.settings.theme == .dark ? .dark : .light)
    }

    private func placeholder(_ text: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle)
            Text(text).font(.callout).multilineTextAlignment(.center)
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func status(_ window: SwitcherWindow) -> String {
        var labels: [String] = []
        if window.windowless { labels.append("ウィンドウなし") }
        if window.minimized { labels.append("最小化") }
        if window.hidden { labels.append("非表示") }
        if window.fullscreen { labels.append("フルスクリーン") }
        if !window.windowless && window.spaceIndex > 0 { labels.append("Space \(window.spaceIndex)") }
        return labels.joined(separator: " · ")
    }
}

private struct SwitcherShortcutRecorder: NSViewRepresentable {
    var controller: WindowSwitcherController
    var onError: (Error) -> Void
    var receive: (Shortcut) -> Void
    func makeNSView(context: Context) -> Capture {
        let view = Capture(); view.receive = receive; view.controller = controller; view.onError = onError
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: Capture, context: Context) { nsView.receive = receive }
    static func dismantleNSView(_ nsView: Capture, coordinator: ()) { nsView.stopRecording() }
    final class Capture: NSView {
        var receive: ((Shortcut) -> Void)?
        weak var controller: WindowSwitcherController?
        var onError: ((Error) -> Void)?
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopRecording()
            guard let window else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.startRecording() }
                },
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.controller?.endShortcutRecording() }
                }
            ]
            if window.isKeyWindow { startRecording() }
        }
        private func startRecording() {
            do {
                try controller?.beginShortcutRecording { [weak self] shortcut in
                    guard let self, self.window?.isKeyWindow == true else { return }
                    self.receive?(shortcut)
                }
            } catch { onError?(error) }
        }
        func stopRecording() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
            controller?.endShortcutRecording()
        }
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            let flags = event.modifierFlags
            var label = ""
            if flags.contains(.control) { label += "⌃" }
            if flags.contains(.option) { label += "⌥" }
            if flags.contains(.shift) { label += "⇧" }
            if flags.contains(.command) { label += "⌘" }
            let names: [UInt16: String] = [48: "⇥", 36: "↩", 76: "Enter", 53: "Esc", 49: "Space", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
                122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            label += names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            receive?(Shortcut(keyCode: UInt32(event.keyCode), modifiers: SwitcherKeyboard.modifiers(CGEventFlags(rawValue: UInt64(flags.rawValue))), label: label))
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { keyDown(with: event); return true }
    }
}
