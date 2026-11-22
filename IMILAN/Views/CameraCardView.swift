import SwiftUI

/// 摄像头卡片：画面为 Fmp4PlayerView 真实播放（H.265 fMP4 + VideoToolbox）。
///
/// 引擎 running 且已登录（UserDefaults 有 xiaomiUserID）时自动播放；
/// 画质 Picker 切换时停掉旧流、用新 subtype 重播。
/// PiP / 截图仍是 TODO（按钮保留，不假装已实现）。
/// 触摸目标 ≥44pt，工具按钮用 .frame(minHeight: 44)。
struct CameraCardView: View {
    var camera: Camera
    @EnvironmentObject private var engine: EngineManager
    @EnvironmentObject private var store: CameraStore
    @StateObject private var player = Fmp4Player()
    @State private var quality: StreamQuality = .standard // 首版默认 1080p（无 subtype），已验证；见 Models/Camera.swift

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.85))
                    .aspectRatio(16 / 9, contentMode: .fit)
                Fmp4PlayerView(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if let error = player.lastError {
                    // 播放失败时显示真实错误文案（HTTP 状态 / 引擎报错 / 视频层报错）。
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                } else if !player.isPlaying {
                    VStack(spacing: 6) {
                        Image(systemName: "video.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                        Text(engine.state == .running ? "正在连接画面…" : "引擎未运行")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Text(camera.name)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(camera.name).font(.subheadline).bold()
                    Text(camera.model).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // 信号占位：后续按下载速率（Mbps）算 1–5 格（与上游卡片同义）。
                Label("信号", systemImage: "signal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            HStack(spacing: 8) {
                Picker("画质", selection: $quality) {
                    ForEach(StreamQuality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 140)

                Spacer()

                Button { /* TODO: PiP，见 VALIDATION V-07 */ } label: {
                    Image(systemName: "pip.enter")
                }
                .frame(minWidth: 44, minHeight: 44)
                .help("画中画（TODO）")

                Button { /* TODO: 截图，PhotoKit */ } label: {
                    Image(systemName: "camera")
                }
                .frame(minWidth: 44, minHeight: 44)
                .help("截图（TODO）")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onAppear { startPlaybackIfReady() }
        .onDisappear { player.stop() }
        .onChange(of: engine.state) { _, newState in
            if newState == .running {
                startPlaybackIfReady()
            } else {
                player.stop()
            }
        }
        .onChange(of: quality) { _, _ in
            // 画质切换：停掉旧流，用新 subtype 重播。
            player.stop()
            startPlaybackIfReady()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("IMILoginDidSucceed"))) { _ in
            startPlaybackIfReady()
        }
    }

    private func startPlaybackIfReady() {
        guard engine.state == .running else { return }
        guard let url = store.streamURL(for: camera, quality: quality) else {
            player.lastError = "未登录小米账号：请先扫码登录"
            return
        }
        player.play(streamURL: url)
    }
}
