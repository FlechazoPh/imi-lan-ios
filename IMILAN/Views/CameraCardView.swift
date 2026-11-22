import SwiftUI

/// 摄像头卡片（Phase 1 骨架）。
///
/// 画面本身由 WKWebView 壳渲染（见 Web/WebViewContainer），本卡片只做占位 UI：
///  Phase 1 先用色块 + 名称/型号/信号占位，Phase 2 再把真实视频层接进来。
///  触摸目标 ≥44pt，工具按钮用 .frame(minHeight: 44)。
struct CameraCardView: View {
    var camera: Camera
    @State private var quality: StreamQuality = .standard // 首版默认 1080p（无 subtype），已验证；见 Models/Camera.swift

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 画面占位：16:9，Phase 2 换成 CameraWebView / Fmp4Player 层。
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.85))
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "video.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                        Text("画面占位（TODO）")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Text(camera.name)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
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
    }
}
