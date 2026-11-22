import SwiftUI

/// IMI-LAN iOS — App 入口（Phase 1 骨架）
///
/// TODO (Phase 1): 引擎尚未内嵌。EngineManager 目前只管理状态机与占位日志，
/// 真正的 go2rtc 启动见 Engine/GoEngineBridge.swift 的 TODO。
@main
struct IMILANApp: App {
    @StateObject private var engine = EngineManager()
    @StateObject private var store = CameraStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(store)
                .onAppear {
                    // 首次启动：生成/读取 Keychain 里的 app token（见 Auth/KeychainStore）。
                    // TODO (Phase 1): 不在这里自动启动引擎，等用户在设置里选模式（本机/外接）后再启动。
                    _ = KeychainStore.shared.appToken()
                }
        }
    }
}

/// 内存里的摄像头列表（Phase 1：示例数据 + 本地占位，待接网关 /api/streams）。
/// TODO (Phase 1): 接入 LocalGateway 后，改为从 go2rtc.yaml / 网关读取真实设备。
final class CameraStore: ObservableObject {
    @Published var cameras: [Camera] = Camera.sample
    @Published var selectedID: Camera.ID?
}
