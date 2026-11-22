import Foundation
import Combine

/// 引擎生命周期管理。
///
/// 真实引擎是 Go 的 go2rtc（已打 xiaomi-login / xiaomi-control /
/// imi-ios-xiaomi-token 补丁），在 iOS 上以 c-archive 静态库跑在
/// App 进程内（见 ARCHITECTURE.md §4.1），不能像安卓那样 exec 独立二进制。
///
/// 启动语义（本机模式）：
///   ensureConfig → bridge.start（只表示“已接受请求”）→
///   轮询 waitUntilRunning(15 秒)，就绪才置 .running；
///   失败置 .failed，lastError 写状态 JSON 的 error 或超时原因。
/// 外接模式做真实健康检查：GET {remoteAddress}/api/streams，5 秒超时，
/// 200 才算 running。
final class EngineManager: ObservableObject {
    @Published var mode: EngineMode = .local   // 独立版默认本机引擎
    @Published var state: EngineState = .stopped
    @Published var logLines: [String] = []
    @Published var lastError: String?

    /// 过渡版用的局域网引擎地址，例如 http://192.168.1.50:1984
    /// TODO (Phase 1): 由 SettingsView 填写，存 UserDefaults（不含 token）。
    @Published var remoteAddress: String = ""

    /// 正在跑的启动/健康检查 Task；stop() 时取消，避免它事后把状态写回 running。
    private var startTask: Task<Void, Never>?

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    /// 已在运行或启动中时直接返回（避免重复启动把状态打回 failed：
    /// IMIStartEngine 在进程内只允许启动一次）。
    func startIfNeeded() {
        guard state != .running && state != .starting else { return }
        start()
    }

    func start() {
        guard state != .running && state != .starting else { return }
        switch mode {
        case .remote:
            guard !remoteAddress.isEmpty else {
                lastError = "请先在设置里填外接引擎地址（例如 http://192.168.1.50:1984）"
                state = .failed
                return
            }
            state = .starting
            lastError = nil
            let address = remoteAddress
            log("外接模式：健康检查 \(address)/api/streams（5 秒超时）…")
            startTask = Task {
                let (ok, err) = await Self.checkRemote(address: address)
                if Task.isCancelled { return }
                await MainActor.run {
                    if Task.isCancelled { return }
                    if ok {
                        self.state = .running
                        self.log("外接引擎健康检查通过：\(address)")
                    } else {
                        self.state = .failed
                        self.lastError = err ?? "外接引擎无响应"
                        self.log("外接引擎健康检查失败：\(self.lastError ?? "")")
                    }
                }
            }
        case .local:
            state = .starting
            lastError = nil
            log("本机模式：启动内嵌 go2rtc 引擎…")
            switch GoEngineBridge.ensureConfig() {
            case .failure(let error):
                state = .failed
                lastError = error.localizedDescription
                log("本机引擎启动失败：\(error.localizedDescription)")
                return
            case .success:
                break
            }
            switch GoEngineBridge.start() {
            case .success:
                log("引擎已接受启动请求，等待就绪（最多 15 秒）…")
            case .failure(let error):
                state = .failed
                lastError = error.localizedDescription
                log("本机引擎启动失败：\(error.localizedDescription)")
                return
            }
            startTask = Task {
                let (ok, err) = await GoEngineBridge.waitUntilRunning(timeout: 15)
                if Task.isCancelled { return }
                await MainActor.run {
                    if Task.isCancelled { return }
                    if ok {
                        self.state = .running
                        self.log("本机引擎已就绪（go2rtc，api 127.0.0.1:1984）")
                    } else {
                        self.state = .failed
                        self.lastError = err ?? "引擎 15 秒内未就绪"
                        self.log("本机引擎未就绪：\(self.lastError ?? "")")
                    }
                }
            }
        }
    }

    /// 外接引擎健康检查：GET {address}/api/streams，5 秒超时，200 才算通。
    /// 返回 (是否通, 失败原因：HTTP 状态或网络错误描述)。
    private static func checkRemote(address: String) async -> (Bool, String?) {
        let base = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/streams") else {
            return (false, "外接地址无效：\(address)")
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "外接引擎返回了非 HTTP 响应")
            }
            guard http.statusCode == 200 else {
                return (false, "外接引擎 HTTP \(http.statusCode)")
            }
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        if mode == .local {
            _ = GoEngineBridge.stop()
        }
        state = .stopped
        log("引擎已停止")
    }

    func restart() {
        log("重启引擎")
        stop()
        start()
    }
}
