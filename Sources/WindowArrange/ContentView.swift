import SwiftUI
import ArrangementCore

private let accent = Color(red: 0.10, green: 0.48, blue: 0.43)
private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
// Resolve the property-wrapper type explicitly on SDKs that also export a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if !model.trusted { permissionBanner }
                if model.section == "shortcuts" { ShortcutsView() }
                else if model.section == "settings" { SettingsView() }
                else { SnapshotsView() }
                Divider()
                HStack(spacing: 7) {
                    Circle().fill(model.trusted ? accent : .orange).frame(width: 6, height: 6)
                    Text(model.busy ? model.progress : model.trusted ? "ウィンドウ操作の準備ができています" : "アクセシビリティの許可が必要です")
                    Spacer()
                    if model.busy { ProgressView().controlSize(.mini) }
                    Text("SWIFT / macOS").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1)
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 26).padding(.vertical, 12)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .sheet(item: $model.recording, onDismiss: { model.recording = nil }) { action in
            VStack(spacing: 20) {
                Image(systemName: "command.square").font(.system(size: 38, weight: .light)).foregroundStyle(accent)
                Text(action.title).font(.title2.bold())
                Text("割り当てるキーを押してください").font(.headline)
                Text("⌘ または ⌃ を含む組み合わせ\nEscでキャンセル").multilineTextAlignment(.center).foregroundStyle(.secondary)
                ShortcutRecorder { shortcut in
                    if let shortcut { model.setShortcut(shortcut, action: action) } else { model.recording = nil }
                }.frame(width: 1, height: 1).accessibilityLabel("ショートカットキー入力")
                Button("キャンセル") { model.recording = nil }.keyboardShortcut(.cancelAction)
            }.padding(36).frame(width: 390)
        }
        .sheet(item: $model.report) { report in
            VStack(alignment: .leading, spacing: 16) {
                Text(report.title).font(.title2.bold())
                Text(report.message).textSelection(.enabled)
                if !report.details.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(report.details.enumerated()), id: \.offset) { _, detail in Text(detail).font(.callout).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 260).padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack { Spacer(); Button("閉じる") { model.report = nil }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 520)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group.fill").font(.system(size: 24)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Window").font(.system(size: 17, weight: .bold))
                    Text("Arrange").font(.system(size: 17, weight: .bold)).foregroundStyle(accent)
                }
            }.padding(.top, 48).padding(.bottom, 36)
            Text("WORKSPACE").font(.system(size: 10, weight: .semibold)).tracking(1.7).foregroundStyle(.tertiary).padding(.bottom, 12)
            nav("snapshots", "Snapshots", "square.stack.3d.up", count: model.data.snapshots.count)
            nav("shortcuts", "ショートカット", "command")
            nav("settings", "設定", "slider.horizontal.3")
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(accent)
                Text("いつもの配置へ、\nワンアクション。").font(.callout.weight(.medium)).lineSpacing(4)
                Text("ローカルに保存。\n外部アプリは不要です。").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            #if DEBUG
            if CommandLine.arguments.contains("--development") {
                Label("開発モード", systemImage: "hammer").font(.caption2).foregroundStyle(accent).padding(.top, 16)
            }
            #endif
            Text("Window Arrange  \(appVersion)").font(.caption2).foregroundStyle(.tertiary).padding(.top, 16)
        }
        .padding(.horizontal, 20).padding(.bottom, 20).frame(width: 205)
        .background(.regularMaterial)
    }
    private func nav(_ id: String, _ title: String, _ icon: String, count: Int? = nil) -> some View {
        Button { model.section = id } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 18)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                if let count { Text("\(count)").font(.caption2).foregroundStyle(.secondary) }
            }.padding(.horizontal, 12).padding(.vertical, 12)
                .foregroundStyle(model.section == id ? accent : Color.primary)
                .background(model.section == id ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).padding(.bottom, 5)
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.section == "snapshots" ? "Snapshots" : model.section == "shortcuts" ? "ショートカット" : "設定").font(.system(size: 27, weight: .bold))
                Text(model.section == "snapshots" ? "作業環境を記録して、好きなときに呼び戻す。" : model.section == "shortcuts" ? "指先から、ウィンドウを思いどおりに。" : "自分のMacに合わせて、使いやすく。").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.capture() } } label: { Label("Snapshotを保存", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || !model.trusted || !model.storageAvailable)
        }.padding(.horizontal, 28).padding(.top, 37).padding(.bottom, 24)
    }
    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised").font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("はじめに、ウィンドウ操作を許可してください").font(.callout.weight(.semibold))
                Text("システム設定 → プライバシーとセキュリティ → アクセシビリティ").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("設定を開く") { model.accessibility.requestAccess() }
        }.padding(15).background(Color.orange.opacity(0.08)).overlay(alignment: .bottom) { Divider() }
    }
}

private struct SnapshotsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var renameID: UUID?
    @ViewState private var name = ""
    @ViewState private var deleteID: UUID?
    var body: some View {
        Group {
            if model.data.snapshots.isEmpty { empty }
            else {
                HSplitView {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            HStack { Text("保存したレイアウト").font(.caption.weight(.medium)).foregroundStyle(.secondary); Spacer() }.padding(.bottom, 4)
                            ForEach(model.data.snapshots) { snapshot in snapshotRow(snapshot) }
                        }.padding(18)
                    }.frame(minWidth: 245, idealWidth: 280, maxWidth: 340)
                    if let snapshot = model.selected {
                        SnapshotDetail(snapshot: snapshot).frame(minWidth: 380, maxWidth: .infinity)
                    } else { Text("Snapshotを選択してください").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }
        }
        .alert("Snapshotの名前", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("名前", text: $name)
            Button("キャンセル", role: .cancel) { renameID = nil }
            Button("保存") { if let id = renameID { model.rename(id, to: name) }; renameID = nil }
        }
        .alert("このSnapshotを削除しますか？", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button("キャンセル", role: .cancel) { deleteID = nil }
            Button("削除", role: .destructive) { if let id = deleteID { model.delete(id) }; deleteID = nil }
        } message: { Text("保存したレイアウトが削除されます。") }
    }
    private var empty: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 25).fill(accent.opacity(0.06)).frame(width: 190, height: 136)
                RoundedRectangle(cornerRadius: 6).stroke(accent.opacity(0.5), lineWidth: 1.5).frame(width: 126, height: 80)
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.7)).frame(width: 54, height: 62)
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.25)).frame(width: 54, height: 28)
                        RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.4)).frame(width: 54, height: 29)
                    }
                }
            }.padding(.bottom, 6)
            Text("この配置を、いつもの配置に。").font(.title2.bold())
            Text("アプリを使いやすい位置に並べて、Snapshotを保存。\nあとからウィンドウの位置とサイズをまとめて復元できます。")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary).lineSpacing(5)
            Button { Task { await model.capture() } } label: { Label("最初のSnapshotを保存", systemImage: "camera") }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 8)
                .disabled(!model.trusted || model.busy || !model.storageAvailable)
            Label(model.data.spacesEnabled ? "Spacesの所属も記録 · 実験機能" : "位置・サイズを記録", systemImage: "square.3.layers.3d")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func snapshotRow(_ snapshot: Snapshot) -> some View {
        Button { model.select(snapshot.id) } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Image(systemName: "rectangle.3.group").foregroundStyle(accent)
                    Spacer()
                    if model.selectedID == snapshot.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                }
                Text(snapshot.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text("\(Set(snapshot.windows.map(\.appID)).count)アプリ · \(snapshot.windows.count)ウィンドウ").font(.caption).foregroundStyle(.secondary)
                Text(snapshot.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.tertiary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(model.selectedID == snapshot.id ? accent.opacity(0.06) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.selectedID == snapshot.id ? accent.opacity(0.6) : Color.primary.opacity(0.08)))
        }.buttonStyle(.plain).contextMenu {
            Button("名前を変更") { name = snapshot.name; renameID = snapshot.id }
            Button("削除", role: .destructive) { deleteID = snapshot.id }
        }
    }
}

private struct SnapshotDetail: View {
    @EnvironmentObject var model: AppModel
    let snapshot: Snapshot
    @ViewState private var filterSpace: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snapshot.name).font(.title2.bold()).textSelection(.enabled)
                        Text(snapshot.backend == .nativeSpaces ? "Spacesを含むレイアウト · 実験機能" : "ウィンドウの位置・サイズ").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await model.restore(snapshot) } } label: { Label("復元", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.borderedProminent).disabled(model.busy || !model.trusted)
                }
                if snapshot.backend == .nativeSpaces {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            spaceButton("すべて", id: nil)
                            ForEach(snapshot.spaces.filter { space in snapshot.windows.contains { $0.spaceID == space.id } }) { space in
                                spaceButton(space.label, id: space.id)
                            }
                        }
                    }
                }
                LayoutPreview(displays: snapshot.displays, windows: filtered).frame(height: 210)
                    .background(accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
                HStack {
                    Text("記録したウィンドウ").font(.headline)
                    Spacer()
                    Text("\(filtered.count) WINDOWS").font(.system(size: 10, design: .monospaced)).tracking(1).foregroundStyle(.tertiary)
                }
                VStack(spacing: 0) {
                    ForEach(filtered) { window in
                        HStack(spacing: 11) {
                            AppIcon(bundleID: window.appID)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(window.title.isEmpty ? window.appName : window.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text(window.appName + (window.minimized ? " · 最小化" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("\(Int(window.frame.width)) × \(Int(window.frame.height))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                if let space = snapshot.spaces.first(where: { $0.id == window.spaceID }) { Text(space.label).font(.caption2).foregroundStyle(accent) }
                            }
                        }.padding(.vertical, 11)
                        if window.id != filtered.last?.id { Divider() }
                    }
                }
                Text("開いているウィンドウを照合して復元します。閉じたアプリや書類は開き直しません。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(26)
        }.id(snapshot.id)
    }
    private var filtered: [WindowRecord] { snapshot.windows.filter { filterSpace == nil || $0.spaceID == filterSpace } }
    private func spaceButton(_ title: String, id: String?) -> some View {
        Button { filterSpace = id } label: {
            Text(title).font(.caption.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 6)
                .background(filterSpace == id ? accent.opacity(0.12) : Color.primary.opacity(0.04), in: Capsule())
                .foregroundStyle(filterSpace == id ? accent : .secondary)
        }.buttonStyle(.plain)
    }
}

private struct LayoutPreview: View {
    let displays: [DisplayRecord]
    let windows: [WindowRecord]
    private let colors: [Color] = [accent, .blue, .purple, .orange, .pink]
    var body: some View {
        Canvas { context, size in
            let bounds = displays.reduce(CGRect.null) { $0.union($1.frame) }
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
            let scale = min((size.width - 36) / bounds.width, (size.height - 40) / bounds.height)
            let offset = CGPoint(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
            func rect(_ r: CGRect) -> CGRect { CGRect(x: (r.minX - bounds.minX) * scale + offset.x, y: (r.minY - bounds.minY) * scale + offset.y, width: r.width * scale, height: r.height * scale) }
            for display in displays {
                let r = rect(display.frame)
                context.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(Color(nsColor: .controlBackgroundColor)))
                context.stroke(Path(roundedRect: r, cornerRadius: 5), with: .color(.secondary.opacity(0.35)), lineWidth: 1)
            }
            for (index, window) in windows.enumerated() {
                let r = rect(window.frame).insetBy(dx: 2, dy: 2)
                guard r.width > 0, r.height > 0 else { continue }
                let color = colors[index % colors.count]
                context.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(color.opacity(window.minimized ? 0.1 : 0.18)))
                context.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(color.opacity(0.65)), lineWidth: 1)
                if r.width > 55 && r.height > 25 {
                    let label = Text(String(window.appName.prefix(max(2, Int(r.width / 7))))).font(.system(size: 9, weight: .medium)).foregroundColor(color)
                    context.draw(label, at: CGPoint(x: r.minX + 7, y: r.minY + 11), anchor: .leading)
                }
            }
        }.accessibilityLabel("保存したモニターとウィンドウの配置プレビュー")
    }
}

private struct AppIcon: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
        } else { Image(systemName: "macwindow").frame(width: 30, height: 30).foregroundStyle(.secondary) }
    }
}

private struct ShortcutsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("showOnlyCustomizedShortcuts") private var showOnlyCustomizedShortcuts = false
    private var visibleActions: [WindowAction] {
        WindowAction.allCases.filter { !showOnlyCustomizedShortcuts || model.data.shortcuts[$0.rawValue] != nil }
    }
    var body: some View {
        let actions = visibleActions
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("前面のアプリのウィンドウを操作します", systemImage: "cursorarrow.rays").font(.callout).foregroundStyle(.secondary)
                RepeatModePicker()
                if !model.shortcutFailures.isEmpty {
                    Label("登録できなかった操作：" + model.shortcutFailures.joined(separator: "、"), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                Toggle("変更したショートカットのみ表示", isOn: $showOnlyCustomizedShortcuts)
                    .toggleStyle(.checkbox)
                    .help("キーを割り当てた項目だけ表示します。初期状態ではすべて未設定です。")
                VStack(spacing: 0) {
                    if actions.isEmpty {
                        VStack(spacing: 10) {
                            Text("変更したショートカットはありません。")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("すべて表示") { showOnlyCustomizedShortcuts = false }
                        }.frame(maxWidth: .infinity).padding(24)
                    }
                    ForEach(actions) { action in
                        HStack(spacing: 13) {
                            Image(systemName: action.symbol).foregroundStyle(accent).frame(width: 25)
                            Text(action.title).font(.callout)
                            Spacer()
                            Button { model.recording = action } label: {
                                Text(model.data.shortcuts[action.rawValue]?.label ?? "キーを設定")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced)).frame(minWidth: 104)
                            }.buttonStyle(.bordered)
                            Button { model.setShortcut(nil, action: action) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.plain).disabled(model.data.shortcuts[action.rawValue] == nil).help("割り当てを解除")
                                .accessibilityLabel("\(action.title)の割り当てを解除")
                        }.padding(.horizontal, 18).padding(.vertical, 11)
                        if action != actions.last { Divider().padding(.leading, 56) }
                    }
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                Text("⌘ または ⌃ を含むキーを設定できます。半分・¼の配置は標準のウィンドウ操作APIで座標を調整します。最小化・フルスクリーンはmacOSの機能を呼び出します。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(28)
        }.disabled(model.busy)
    }
}

private struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section("ウィンドウの操作") {
                LabeledContent("アクセシビリティ", value: model.trusted ? "許可済み" : "未許可")
                Button("システム設定を開く") { model.accessibility.requestAccess() }
            }
            Section("サイズの繰り返し") {
                RepeatModePicker()
            }
            Section("Snapshot") {
                Toggle("Spacesの所属も保存・復元する（実験機能）", isOn: Binding(get: { model.data.spacesEnabled }, set: { model.setSpacesEnabled($0) }))
                LabeledContent("システムAPI", value: model.nativeSpaces.available ? "検出済み · 動作保証なし" : "この環境では利用不可")
                Text("SpacesはmacOSの非公開APIをSwiftから直接呼び出します。外部アプリやプラグインのインストールは不要です。OSの更新で利用できなくなる可能性があり、Mac App Store向けの構成には適しません。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("SpaceをUUIDで照合します。削除したSpaceの再作成、Spacesの並び順変更、フルスクリーン／Split Viewの復元には対応しません。所属を確認できないウィンドウは記録の対象外です。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("この設定は新しく保存するSnapshotに適用されます。既存のSnapshotは保存時の方式で復元します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("データ") {
                LabeledContent("保存先", value: "このMacのみ")
                Text("~/Library/Application Support/WindowArrange/state.json").font(.caption.monospaced()).textSelection(.enabled)
                Text("記録するのはアプリ名、ウィンドウタイトル、書類URL（取得できる場合）、座標、サイズ、ディスプレイ・Space識別子です。画面画像や書類の内容は保存しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(model.busy)
    }
}

private struct RepeatModePicker: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("左右・上下の配置を繰り返す", selection: Binding(get: { model.data.repeatMode }, set: { model.setRepeatMode($0) })) {
                ForEach(LayoutRepeatMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.radioGroup)
            .disabled(!model.storageAvailable)
            Text("Cycle は同じ画面で 1/2 → 2/3 → 1/3 を繰り返します。Cycle Displays は半画面ずつ移動します。右半分なら「この画面の右 → 次の画面の左 → 右 → …」と巡回します。開いているMacBookの内蔵画面も対象です。None は半分に配置します。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
