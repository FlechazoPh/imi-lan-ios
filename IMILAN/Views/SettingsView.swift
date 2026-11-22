import SwiftUI

/// 设置页（Phase 1 骨架）。
struct SettingsView: View {
    @EnvironmentObject private var engine: EngineManager
    @State private var showQRLogin = false
    @State private var showLog = false

    var body: some View {
        Form {
            Section("引擎模式") {
                Picker("模式", selection: $engine.mode) {
                    ForEach(EngineMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(engine.mode == .local
                     ? "本机引擎尚未验证（见 ARCHITECTURE.md §4.1），当前不可用。"
                     : "过渡版：引擎跑在家里 MacBook/Windows 上，iPhone 只做播放器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("外接引擎") {
                TextField("例如 http://192.168.1.50:1984", text: $engine.remoteAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                HStack {
                    Button(engine.state == .running ? "停止" : "启动") {
                        engine.state == .running ? engine.stop() : engine.start()
                    }
                    Spacer()
                    Text(engine.state.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                if let error = engine.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("账号") {
                Button("扫码登录（米家 App）") { showQRLogin = true }
                Button("查看引擎日志") { showLog = true }
            }

            Section("关于") {
                LabeledContent("版本", value: "0.1.0-skeleton（未验证）")
                LabeledContent("引擎", value: "go2rtc 1.9.15 + 小米补丁（TODO，未接入）")
                Text("非官方项目，与小米/米家无任何关联。请只在自己账号下、自己有权使用的设备上使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showQRLogin) { QRLoginView() }
        .sheet(isPresented: $showLog) { EngineLogView() }
    }
}
