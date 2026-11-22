import SwiftUI

/// 扫码登录 UI（接 XiaomiQRLogin 真实流程）。
///
/// 流程（与安卓 fpk/gateway/qr.go 同款，Swift 原生重写）：
///   1. 向 account.xiaomi.com 申请二维码并显示；
///   2. 用米家 App 右上角「＋ → 扫一扫」扫码；
///   3. 每 1 秒轮询扫码结果，扫码后在手机上确认；
///   4. 凭据写回 go2rtc.yaml，热更新到运行中的引擎；
///   5. 成功后显示“登录成功”并自动关闭本页。
struct QRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var login = XiaomiQRLogin()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let data = login.qrImageData, let uiImage = UIImage(data: data) {
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
                                if login.phase == .error {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 48))
                                        .foregroundStyle(.red)
                                    Text("获取二维码失败")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ProgressView()
                                    Text("正在获取二维码…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                }

                Text(login.statusMessage)
                    .font(.headline)
                if login.phase == .waiting, login.expiresIn > 0 {
                    Text("二维码有效期还剩 \(login.expiresIn) 秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = login.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Text("用米家 App 右上角「＋ → 扫一扫」扫描上方二维码")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Text("提示：小米账号若开了两步验证，密码登录会报 404，优先用扫码；扫码成功后凭据立即生效，无需重启 App。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Button("刷新二维码") {
                    login.refresh()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(login.phase == .loading || login.phase == .scanned)
            }
            .padding()
            .navigationTitle("扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        login.cancel()
                        dismiss()
                    }
                }
            }
            .task {
                login.start()
            }
            .onDisappear {
                login.cancel()
            }
            .onChange(of: login.phase) { _, newPhase in
                if newPhase == .success {
                    Task {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        dismiss()
                    }
                }
            }
        }
    }
}
