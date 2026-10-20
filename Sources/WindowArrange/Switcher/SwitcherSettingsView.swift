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
                choice("Spaces", \.spaces)
                choice("ディスプレイ", \.screens)
                choice("最小化したウィンドウ", \.minimized)
                choice("非表示のアプリ", \.hidden)
                Toggle("フルスクリーンのウィンドウを表示", isOn: binding(\.fullscreen))
                choice("ウィンドウのないアプリ", \.windowless)
                Text("切替画面は使用中のウィンドウがある画面に表示します。Spaceの所属を取得できない場合、Spacesで絞り込む一覧からは除外します。")
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
                choice("テーマ", \.theme)
                LabeledContent("画面収録", value: thumbnails.permitted ? "許可済み" : "未許可 · アイコンで表示")
                Button(thumbnails.permitted ? "画面収録の設定を開く" : "サムネイルのための画面収録を許可") {
                    if thumbnails.permitted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                    else { thumbnails.requestPermission() }
                }
                Text("サムネイルは一覧を開いたときに取得し、メモリ上だけに保持します。最小化・非表示・保護されたウィンドウや、選択されていないタブは画像を取得できない場合があります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ショートカット") {
                ForEach(SwitcherCommand.allCases) { command in
                    LabeledContent(command.title) {
                        Button(model.data.switcher[command].label) { recordingError = nil; recording = command }
                            .font(.system(.body, design: .monospaced)).frame(minWidth: 100)
                    }
                }
                Text("呼び出しキーは⌥・⌘・⌃のいずれかを含む組み合わせです。Shift＋呼び出しキーで逆順に開始できます。切替画面内では←・→でも前後に移動できます。次へ・前へ・決定・キャンセルは切替画面内だけで動作します。")
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
