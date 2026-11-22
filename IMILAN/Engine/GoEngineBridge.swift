import Foundation

/// Swift 侧 Go 引擎桥接（Phase 1 骨架，占位）。
///
/// 设计：Go 侧用 `//export` 导出 C 函数，Swift 经 Bridging Header 调用。
/// 本文件目前不链接任何 Go 库，所有方法都返回“未接入”，避免在骨架阶段
/// 假装引擎已跑通。
///
/// 待接入时（Phase 1B）：
///  1. 在 MacBook / Actions 上编出 libgo2rtc.a + libgo2rtc.h（见 scripts/build-go-engine.sh）
///  2. 把 .a / .h 拖进 Xcode target，Bridging Header 指向 GoEngineBridge.h
///  3. 把下面的 fatalError 占位换成真实调用，并处理 Go 的 char* / 错误码
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

    /// TODO (Phase 1B): 替换为真实的 IMIStartEngine(configPath, logPath) 调用。
    static func start() -> Result<Void, Error> {
        .failure(BridgeError.notLinked)
    }

    /// TODO (Phase 1B): 替换为真实的 IMIStopEngine() 调用。
    static func stop() -> Result<Void, Error> {
        .failure(BridgeError.notLinked)
    }

    enum BridgeError: LocalizedError {
        case notLinked
        var errorDescription: String? {
            "Go 引擎库未接入：libgo2rtc.a 缺失（见 ARCHITECTURE.md §4.1，验证 V-01）"
        }
    }
}
