import SwiftUI

/// 单画面查看：Fmp4PlayerView 真实播放（独立播放器实例，与卡片同一路流）。
///
/// 手势（与安卓一致）：
///  - 单击画面：隐藏/显示顶部和底部控件；
///  - 双击：退出单画面（点开“放大镜”时双击只复位缩放）；
///  - 双指捏合/单指拖动：只有点开“放大镜”后才启用，页面级缩放已关闭。
/// 云台：默认关闭，点开关才在左下角显示方向盘；按住发 move，松手发 stop
/// （miss 的 cmdMotorReq = 0x112，operation 语义是“保持朝这个方向转”；
/// 轻点约 0.9 秒后停，另加 1 秒安全自动 stop）。
/// 双击退出、捏合缩放仍是 TODO（见 VALIDATION），不假装已实现。
struct SingleCameraView: View {
    var camera: Camera
    @EnvironmentObject private var store: CameraStore
    @EnvironmentObject private var engine: EngineManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = Fmp4Player()
    @State private var controlsHidden = false
    @State private var showPTZ = false
    @State private var magnifier = false
    @State private var activePTZ: String?
    @State private var ptzError: String?
    @State private var autoStopTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Fmp4PlayerView(player: player)
                .ignoresSafeArea()
            if let error = player.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(24)
            } else if !player.isPlaying {
                Text(engine.state == .running ? "正在连接画面…" : "引擎未运行")
                    .foregroundStyle(.white.opacity(0.7))
            }
            if showPTZ {
                // 云台方向盘：上下左右四向，无斜向（协议只有四个取值）。
                VStack(spacing: 8) {
                    ptzButton("up", label: "▲")
                    HStack(spacing: 24) {
                        ptzButton("left", label: "◀")
                        ptzButton("right", label: "▶")
                    }
                    ptzButton("down", label: "▼")
                    if let ptzError = ptzError {
                        Text(ptzError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(6)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .font(.title)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(24)
            }
        }
        .overlay(alignment: .top) {
            if !controlsHidden {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                    }
                    Spacer()
                    Text(camera.name).foregroundStyle(.white)
                    Spacer()
                    Button { magnifier.toggle() } label: {
                        Image(systemName: "magnifyingglass").frame(minWidth: 44, minHeight: 44)
                    }
                }
                .padding(.horizontal)
                .background(Color.black.opacity(0.4))
            }
        }
        .overlay(alignment: .bottom) {
            if !controlsHidden && camera.isPTZ {
                Button(showPTZ ? "收起云台" : "云台控制") { showPTZ.toggle() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .padding(.bottom, 24)
            }
        }
        .onTapGesture { controlsHidden.toggle() }
        .onAppear { startPlaybackIfReady() }
        .onDisappear {
            player.stop()
            cancelAutoStop()
            // 离开时若云台还在转，补发 stop（尽力，不阻塞退出）。
            if activePTZ != nil {
                Task { await sendPTZ("stop") }
                activePTZ = nil
            }
        }
        // TODO (Phase 2): 双击退出、捏合缩放（仅放大镜模式）。
    }

    /// 云台方向键：按住发 move、松手发 stop；1 秒安全自动 stop。
    private func ptzButton(_ direction: String, label: String) -> some View {
        Text(label)
            .frame(width: 64, height: 64)
            .background(activePTZ == direction ? Color.white.opacity(0.35) : Color.white.opacity(0.15))
            .clipShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard activePTZ != direction else { return }
                        activePTZ = direction
                        ptzError = nil
                        Task { await sendPTZ(direction) }
                        scheduleAutoStop()
                    }
                    .onEnded { _ in
                        cancelAutoStop()
                        activePTZ = nil
                        Task { await sendPTZ("stop") }
                    }
            )
    }

    @MainActor
    private func scheduleAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await sendPTZ("stop")
            activePTZ = nil
        }
    }

    @MainActor
    private func cancelAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    /// GET /ptz?name=<完整 xiaomi URL>&move=<left|right|up|down|stop>。
    /// name 就是播放时用的完整 src（xiaomi URL 全文），URLQueryItem 会编码。
    /// 流必须正在播放，否则引擎报错；失败时 ptzError 写真实原因。
    @MainActor
    private func sendPTZ(_ move: String) async {
        guard let source = store.xiaomiSourceURL(for: camera, quality: camera.quality) else {
            ptzError = "云台失败：未登录小米账号"
            return
        }
        var components = URLComponents(string: GoEngineBridge.engineBaseURL + "/ptz")
        components?.queryItems = [
            URLQueryItem(name: "name", value: source),
            URLQueryItem(name: "move", value: move),
        ]
        guard let url = components?.url else {
            ptzError = "云台失败：地址无效"
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                ptzError = "云台失败：服务器未返回 HTTP 响应"
                return
            }
            guard http.statusCode == 200 else {
                let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
                ptzError = "云台失败：HTTP \(http.statusCode)" + (text.isEmpty ? "" : " \(text)")
                return
            }
            if move != "stop" {
                ptzError = nil
            }
        } catch {
            ptzError = "云台失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func startPlaybackIfReady() {
        guard engine.state == .running else { return }
        guard let url = store.streamURL(for: camera, quality: camera.quality) else {
            player.lastError = "未登录小米账号：请先扫码登录"
            return
        }
        player.play(streamURL: url)
    }
}
