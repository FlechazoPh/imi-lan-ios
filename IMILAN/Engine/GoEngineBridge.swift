import Foundation

/// Swift 侧 Go 引擎桥接（Phase 1B：已接入 libgo2rtc.a）。
///
/// Go 侧用 `//export` 导出 C 函数（见 engine/libimi/main.go），
/// 由 go build -buildmode=c-archive 生成 libgo2rtc.a + libgo2rtc.h。
/// 桥接头 IMILAN/Engine/GoEngineBridge.h 包含生成的 libgo2rtc.h
/// （构建时由 scripts/build-go-engine.sh 交接到 Engine/vendor/）。
///
/// 启动是异步的：IMIStartEngine 返回 0 只表示“已接受启动请求”，
/// 真正的运行状态由 IMIEngineStatus 查询；失败原因写进日志文件与状态 JSON。
enum GoEngineBridge {
    /// go2rtc API 根地址（本机引擎只监听回环地址）。
    static let engineBaseURL = "http://127.0.0.1:1984"

    /// 配置与日志的沙箱路径（与安卓的 files/engine/ 对应）。
    static var configPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("engine", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("go2rtc.yaml").path
    }

    static var logPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("engine", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine.log").path
    }

    /// 默认 go2rtc 配置（只在配置文件不存在时写入一次）。
    /// 监听全部绑回环地址；streams 为空，设备由扫码登录后经
    /// /api/xiaomi 拉取、再写入配置。
    static let defaultConfig = """
        api:
          listen: 127.0.0.1:1984
        rtsp:
          listen: 127.0.0.1:8554
        webrtc:
          listen: 127.0.0.1:8555
        log:
          level: info
        streams: {}
        """

    /// 确保默认配置文件存在。文件已存在时绝不覆盖——里面可能已有
    /// 扫码登录写回的 xiaomi: / xiaomi-credentials: 凭据。
    /// 新写的文件权限 0600（配置里含登录令牌）。
    static func ensureConfig() -> Result<Void, Error> {
        let path = configPath
        if FileManager.default.fileExists(atPath: path) { return .success(()) }
        do {
            try defaultConfig.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return .success(())
        } catch {
            return .failure(BridgeError.configFailed(error.localizedDescription))
        }
    }

    /// 引擎状态（IMIEngineStatus 返回的 JSON，如 {"running":true,"error":""}）。
    static func status() -> [String: Any] {
        guard let cStr = IMIEngineStatus() else { return ["running": false] }
        defer { free(cStr) }
        let json = String(cString: cStr)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["running": false, "error": "bad status JSON: \(json)"] }
        return obj
    }

    /// 轮询 IMIEngineStatus 直到 running==true 或超时。
    /// 返回 (是否就绪, 失败原因)。失败原因优先取状态 JSON 的 error，
    /// 取不到时为“引擎 X 秒内未就绪”。
    static func waitUntilRunning(timeout: TimeInterval) async -> (Bool, String?) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: String?
        while Date() < deadline {
            let s = status()
            if (s["running"] as? Bool) == true { return (true, nil) }
            if let e = s["error"] as? String, !e.isEmpty { lastError = e }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let s = status()
        if (s["running"] as? Bool) == true { return (true, nil) }
        if let e = s["error"] as? String, !e.isEmpty { lastError = e }
        return (false, lastError ?? "引擎 \(Int(timeout)) 秒内未就绪")
    }

    /// 启动本机引擎。成功返回 .success；失败返回 .failure，原因来自状态 JSON。
    /// 注意：返回成功只表示“已接受启动请求”，就绪与否由 waitUntilRunning 确认。
    static func start() -> Result<Void, Error> {
        let rc = configPath.withCString { cCfg in
            logPath.withCString { cLog in
                IMIStartEngine(UnsafeMutablePointer(mutating: cCfg),
                               UnsafeMutablePointer(mutating: cLog))
            }
        }
        guard rc == 0 else {
            let err = (status()["error"] as? String) ?? ""
            let msg = err.isEmpty ? "IMIStartEngine failed (code \(rc))" : err
            return .failure(BridgeError.startFailed(msg))
        }
        return .success(())
    }

    /// 停止本机引擎（幂等：未在运行也返回成功）。
    /// 注意：只关 done chan；HTTP/RTSP/WebRTC 监听是否真停、端口是否释放，
    /// go2rtc 没有公开的 Stop API，实测前不声称已释放。
    static func stop() -> Result<Void, Error> {
        _ = IMIStopEngine()
        return .success(())
    }

    /// 热更新小米登录令牌（扫码登录后调用，无需重启引擎/App）。
    /// 返回 true 表示 Go 侧已接受新 token（IMISetXiaomiToken 返回 0）。
    static func setXiaomiToken(userID: String, passToken: String) -> Bool {
        userID.withCString { cUID in
            passToken.withCString { cToken in
                IMISetXiaomiToken(UnsafeMutablePointer(mutating: cUID),
                                  UnsafeMutablePointer(mutating: cToken)) == 0
            }
        }
    }

    enum BridgeError: LocalizedError {
        case startFailed(String)
        case configFailed(String)
        var errorDescription: String? {
            switch self {
            case .startFailed(let msg): return "本机引擎启动失败：\(msg)"
            case .configFailed(let msg): return "写默认配置失败：\(msg)"
            }
        }
    }
}
