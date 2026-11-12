import SwiftUI
import ArrangementCore

struct TrackpadEdgeSettingsView: View {
    @ObservedObject var controller: TrackpadEdgeController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: $controller.enabled) {
                            Label("トラックパッドの端で明るさ・音量を操作する", systemImage: "hand.draw")
                                .font(.headline)
                        }.disabled(!controller.available)
                        Text(controller.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("端の細い帯に指を置いてから上下にスライドします。帯の外から入ってきた指や、2本以上の指には反応しません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox {
                    VStack(spacing: 14) {
                        trackpad
                        Text(controller.contactCount == 0
                             ? "トラックパッドに触れると位置を表示します"
                             : String(format: "指 %d本  x=%.2f  y=%.2f", controller.contactCount, controller.touchX, controller.touchY))
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        Text("上にスライドして明るさ・音量が下がる場合は「スライド方向を反転」をオンにしてください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(18).frame(maxWidth: .infinity)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("左右を入れ替える（現在：左＝\(controller.target(for: .left))／右＝\(controller.target(for: .right))）",
                               isOn: $controller.swapped)
                        Toggle("明るさの端を使う", isOn: $controller.brightnessEdgeEnabled)
                        Toggle("音量の端を使う", isOn: $controller.volumeEdgeEnabled)
                        Toggle("スライド方向を反転", isOn: $controller.reversed)
                        Toggle("細かく調整する（1目盛りを1/4の幅で変える）", isOn: $controller.fineControl)
                        Toggle("端をなぞっている間はポインタを止める", isOn: $controller.suppressPointer)
                        HStack {
                            Text("キー入力後の待ち時間")
                            Slider(value: $controller.typingGuard, in: 0...2, step: 0.1)
                            Text(controller.typingGuard == 0 ? "なし" : String(format: "%.1f秒", controller.typingGuard))
                                .monospacedDigit().frame(width: 52)
                        }
                        Text(controller.typingBlocked
                             ? "キー入力中のため、いまは反応しません。"
                             : "タイピング中に端へ触れても反応しないよう、最後のキー入力からこの時間が過ぎるまで待ちます。待っている間に置いた指は、いったん離すまで操作になりません。")
                            .font(.caption).foregroundStyle(controller.typingBlocked ? Color.accentColor : .secondary)
                        HStack {
                            Text("帯の幅")
                            Slider(value: $controller.zoneWidth, in: 0.04...0.2, step: 0.01)
                            Text("\(Int(controller.zoneWidth * 100))%").monospacedDigit().frame(width: 42)
                        }
                        HStack {
                            Text("1目盛りの移動量")
                            Slider(value: $controller.stepDistance, in: 0.02...0.12, step: 0.005)
                            Text("\(Int(controller.stepDistance * 100))%").monospacedDigit().frame(width: 42)
                        }
                        Text("移動量を小さくすると、短いスライドで大きく変わります。設定は保存され、次回の起動時も有効なままです。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                GroupBox("明るさ・音量の確認") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("明るさ −") { controller.test(.brightnessDown) }
                            Button("明るさ ＋") { controller.test(.brightnessUp) }
                            Divider().frame(height: 16)
                            Button("音量 −") { controller.test(.volumeDown) }
                            Button("音量 ＋") { controller.test(.volumeUp) }
                        }
                        Text(controller.lastAction).font(.caption).monospacedDigit()
                        Text("キーボードの明るさ・音量キーと同じ操作を送ります。macOS標準の表示が出ます。変化しない場合は、アクセシビリティの許可を確認してください。外部モニターの明るさはMacのキーでは変えられないことがあります。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(26)
        }
    }

    /// A small trackpad picture that shows both strips and the live finger position.
    private var trackpad: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5))
                RoundedRectangle(cornerRadius: 12).stroke(.tertiary)
                zone(.left, width: width, height: height)
                zone(.right, width: width, height: height)
                if controller.contactCount > 0 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 16, height: 16)
                        .position(x: controller.touchX * width, y: (1 - controller.touchY) * height)
                }
            }
        }.frame(height: 150).frame(maxWidth: 320)
    }

    private func zone(_ edge: TrackpadEdge, width: CGFloat, height: CGFloat) -> some View {
        let zoneWidth = width * controller.zoneWidth
        return RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(controller.insideZone == edge ? 0.45 : 0.18))
            .frame(width: zoneWidth, height: height)
            .overlay {
                Text(controller.target(for: edge))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize().rotationEffect(.degrees(-90))
            }
            .offset(x: edge == .left ? 0 : width - zoneWidth)
    }
}
