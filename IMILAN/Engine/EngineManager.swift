import Foundation
import Combine

/// 引擎生命周期管理（Phase 1 骨架，占位）。
///
/// 真实引擎是 Go 的 go2rtc（已打 xiaomi-login / xiaomi-control 补丁），
/// 在 iOS 上必须以 c-archive 静态库跑在 App 进程内（见 ARCHITECTURE.md §4.1），
/// 不能像安卓那样 exec 独立二进制。本文件目前只做状态机 + 日志占位，
/// 不调用任何 Go 代码。
final class EngineManager: ObservableObject {
    @Published var mode: EngineMode = .remote   // 默认外接，避免用户误以为本机已通
    @Published var state: EngineState = .stopped
    @Published var logLines: [String] = []
    @Published var lastError: String?

    /// 过渡版用的局域网引擎地址，例如 http://192.168.1.50:1984
    /// TODO (Phase 1): 由 SettingsView 填写，存 UserDefaults（不含 token）。
    @Published var remoteAddress: String = ""

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    func start() {
        switch mode {
        case .remote:
            guard !remoteAddress.isEmpty else {
                lastError = "请先在设置里填外接引擎地址（例如 http://192.168.1.50:1984）"
                state = .failed
                return
            }
            state = .starting
            log("外接模式：连接 \(remoteAddress)（TODO：待接 LocalGateway 健康检查）")
            // TODO (Phase 1): GET {remoteAddress}/health，成功才置 running。
            state = .running
            log("外接引擎已连接（占位，未真实校验）")
        case .local:
            // TODO (Phase 1B): 接 GoEngineBridge.IMIStartEngine(configPath:logPath:)
            // 前置验证见 VALIDATION.md V-01…V-04。
            state = .failed
            lastError = "本机引擎尚未验证：Go c-archive 库未接入（见 ARCHITECTURE.md §4.1）"
            log("本机引擎启动被拒绝：libgo2rtc.a 缺失")
        }
    }

    func stop() {
        // TODO (Phase 1B): 接 GoEngineBridge.IMIStopEngine()
        state = .stopped
        log("引擎已停止（占位）")
    }

    func restart() {
        log("重启引擎（占位）")
        stop()
        start()
    }
}
