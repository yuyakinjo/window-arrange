import SwiftUI

struct HeadMotionSettingsView: View {
    @ObservedObject var controller: HeadMotionController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label(controller.receiving ? "AirPodsから受信中" : "AirPodsの接続", systemImage: "airpodspro")
                                .font(.headline)
                            Spacer()
                            Button(controller.monitoring ? "接続を停止" : "接続を開始") {
                                if controller.monitoring { controller.stop() } else { controller.start() }
                            }
                        }
                        Text(controller.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("AirPodsをこのMacに接続して装着してください。初回はモーションの利用を許可します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox {
                    VStack(spacing: 16) {
                        HStack {
                            Text("左").foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 52, weight: .light))
                                .rotationEffect(.degrees(controller.receiving ? controller.degrees : 0))
                                .foregroundStyle(controller.receiving ? Color.accentColor : .secondary)
                            Spacer()
                            Text("右").foregroundStyle(.secondary)
                        }.padding(.horizontal, 55)
                        Text(controller.receiving ? String(format: "%+.1f°", controller.degrees) : "—")
                            .font(.system(size: 28, weight: .medium, design: .monospaced))
                        Text(controller.calibrated ? "登録した正面からの傾き" : "正面の位置を登録してください")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("今の姿勢を正面にする") { controller.calibrate() }
                            .disabled(!controller.receiving)
                    }.padding(18).frame(maxWidth: .infinity)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("頭の傾きでデスクトップを切り替える", isOn: Binding(
                            get: { controller.enabled }, set: { controller.setEnabled($0) }
                        )).disabled(!controller.calibrated || !controller.receiving)
                        Text(controller.gestureStatus).font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Text("反応する角度")
                            Slider(value: $controller.threshold, in: 10...40, step: 1)
                            Text("\(Int(controller.threshold))°").monospacedDigit().frame(width: 38)
                        }
                        Toggle("左右を反転", isOn: $controller.reversed)
                        Text("左右に傾けて少し保つと1回移動します。正面に戻してから次の操作をしてください。キーボードの修飾キーを押している間は反応しません。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("起動時・再接続時は切り替えが無効になります。角度と左右反転の設定は保存されます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                GroupBox("デスクトップ切り替えの確認") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("← 左へ移動") { controller.testSwitch(.left) }
                            Button("右へ移動 →") { controller.testSwitch(.right) }
                        }
                        Text(controller.lastAction).font(.caption).monospacedDigit()
                        Text("Macで設定済みの切り替えキーを使います。移動しない場合は、デスクトップが2つ以上あることと、システム設定 → キーボード → キーボードショートカット → Mission Controlの「左／右の操作スペースに移動」が有効なことを確認してください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(26)
        }
    }
}
