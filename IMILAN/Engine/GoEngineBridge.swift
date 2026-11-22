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

    /// 启动本机引擎。成功返回 .success；失败返回 .failure，原因来自状态 JSON。
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

    enum BridgeError: LocalizedError {
        case startFailed(String)
        var errorDescription: String? {
            switch self {
            case .startFailed(let msg): return "本机引擎启动失败：\(msg)"
            }
        }
    }
}
