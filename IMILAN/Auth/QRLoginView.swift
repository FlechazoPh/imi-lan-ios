import SwiftUI

/// 扫码登录 UI（Phase 1 骨架，占位）。
///
/// 流程（与安卓 fpk/gateway/qr.go 同款，见 ARCHITECTURE.md §5）：
///  1. 向网关 GET /qr/new 拿二维码图片；
///  2. 用米家 App 右上角「＋ → 扫一扫」扫码；
///  3. 轮询 /qr/status 到 done；
///  4. 网关把完整云端凭据写回 go2rtc.yaml，调 /api/restart，画面断 1–2 秒后恢复。
///
/// iOS 上无法运行 Node，所以 Node 版 qr-login.js 不能直接用；
/// 首选复用 Go 版（随引擎内嵌），备选 Swift 原生重写（URLSession）。
/// 本视图目前只做 UI + 轮询占位，不发起真实请求。
struct QRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var stateText = "等待扫码"
    @State private var qrImageData: Data?   // TODO: 从 /qr/new 取回的图片
    @State private var isPolling = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let data = qrImageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 240, height: 240)
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 48))
                                Text("二维码占位（TODO）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                }

                Text(stateText)
                    .font(.headline)
                Text("用米家 App 右上角「＋ → 扫一扫」扫描上方二维码")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Text("提示：小米账号若开了两步验证，密码登录会报 404，优先用扫码；扫码成功后引擎会重启，画面断 1–2 秒属正常。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Button("刷新二维码") {
                    // TODO (Phase 2): GET /qr/new，重置轮询。
                    stateText = "等待扫码（TODO：未接网关）"
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .navigationTitle("扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                // TODO (Phase 2): 启动轮询 /qr/status，state 到 done 后 dismiss。
                isPolling = true
            }
        }
    }
}
