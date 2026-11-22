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

/// 摄像头列表（B 路）：启动时读上次保存的设备，引擎 running 后从
/// go2rtc /api/xiaomi 刷新；播放地址由 streamURL(for:quality:) 生成。
/// 保存的设备只含 name/model/did/ip，不含任何令牌。
final class CameraStore: ObservableObject {
    @Published var cameras: [Camera] = []
    @Published var selectedID: Camera.ID?
    @Published var lastError: String?

    private static let savedCamerasKey = "savedCameras"

    /// 持久化用的设备快照：只存 name/model/did/ip，不含任何令牌。
    private struct SavedCamera: Codable {
        var name: String
        var model: String
        var did: String
        var ip: String
    }

    private struct SourcesResponse: Decodable {
        var sources: [Source]
        struct Source: Decodable {
            var name: String?
            var info: String?
            var url: String
        }
    }

    init() {
        loadSavedCameras()
    }

    private func loadSavedCameras() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedCamerasKey),
              let saved = try? JSONDecoder().decode([SavedCamera].self, from: data) else { return }
        cameras = saved.map { item in
            Camera(id: item.did, name: item.name, model: item.model, ip: item.ip,
                   isPTZ: !Self.isCateye(model: item.model),
                   isBattery: Self.isCateye(model: item.model))
        }
    }

    private func persistCameras() {
        let saved = cameras.map { SavedCamera(name: $0.name, model: $0.model, did: $0.id, ip: $0.ip) }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.savedCamerasKey)
        }
    }

    /// 门铃类（cateye）是电池设备、可能休眠；其余型号按云台机处理。
    private static func isCateye(model: String) -> Bool {
        model.lowercased().contains("cateye")
    }

    /// 从引擎拉设备列表：GET /api/xiaomi 取用户 ID 数组（取第一个），再
    /// GET /api/xiaomi?id=<uid>&region=cn 取 sources。
    /// 失败时 lastError 写真实原因，cameras 保持旧值。
    @MainActor
    func refreshFromEngine() async {
        let base = GoEngineBridge.engineBaseURL
        do {
            guard let listURL = URL(string: base + "/api/xiaomi") else {
                lastError = "拉取设备列表失败：地址无效 \(base)/api/xiaomi"
                return
            }
            let (listData, listResponse) = try await URLSession.shared.data(from: listURL)
            guard let listHTTP = listResponse as? HTTPURLResponse else {
                lastError = "拉取设备列表失败：服务器未返回 HTTP 响应"
                return
            }
            guard listHTTP.statusCode == 200 else {
                lastError = "拉取设备列表失败：HTTP \(listHTTP.statusCode)"
                return
            }
            guard let userIDs = try? JSONDecoder().decode([String].self, from: listData),
                  let userID = userIDs.first, !userID.isEmpty else {
                lastError = "未找到小米账号：/api/xiaomi 返回空（请先扫码登录）"
                return
            }
            var components = URLComponents(string: base + "/api/xiaomi")
            components?.queryItems = [
                URLQueryItem(name: "id", value: userID),
                URLQueryItem(name: "region", value: "cn"),
            ]
            guard let sourcesURL = components?.url else {
                lastError = "拉取设备列表失败：地址无效 \(base)/api/xiaomi?id=\(userID)"
                return
            }
            let (sourcesData, sourcesResponse) = try await URLSession.shared.data(from: sourcesURL)
            guard let sourcesHTTP = sourcesResponse as? HTTPURLResponse else {
                lastError = "拉取设备列表失败：服务器未返回 HTTP 响应"
                return
            }
            if sourcesHTTP.statusCode == 404 {
                let text = String(data: sourcesData.prefix(200), encoding: .utf8) ?? ""
                lastError = "该账号下没有设备：HTTP 404" + (text.isEmpty ? "" : " \(text)")
                return
            }
            guard sourcesHTTP.statusCode == 200 else {
                lastError = "拉取设备列表失败：HTTP \(sourcesHTTP.statusCode)"
                return
            }
            let decoded = try JSONDecoder().decode(SourcesResponse.self, from: sourcesData)
            var fresh: [Camera] = []
            for source in decoded.sources {
                // source.url 即完整 xiaomi URL：xiaomi://<uid>:cn@<ip>?did=&model=。
                guard let xiaomi = URLComponents(string: source.url),
                      xiaomi.scheme == "xiaomi",
                      let did = xiaomi.queryItems?.first(where: { $0.name == "did" })?.value,
                      let model = xiaomi.queryItems?.first(where: { $0.name == "model" })?.value,
                      let ip = xiaomi.host,
                      !did.isEmpty, !model.isEmpty, !ip.isEmpty else { continue }
                fresh.append(Camera(id: did,
                                    name: source.name ?? did,
                                    model: model,
                                    ip: ip,
                                    isPTZ: !Self.isCateye(model: model),
                                    isBattery: Self.isCateye(model: model)))
            }
            cameras = fresh
            persistCameras()
            lastError = nil
        } catch {
            lastError = "拉取设备列表失败：\(error.localizedDescription)"
        }
    }

    /// 拼 go2rtc 播放地址：xiaomi://<uid>:cn@<ip>?did=<did>&model=<model>[&subtype=N]，
    /// 再包成 http://127.0.0.1:1984/api/stream.mp4?src=<上面那个 URL>。
    /// 未登录（UserDefaults 里无 xiaomiUserID）返回 nil。
    func streamURL(for camera: Camera, quality: StreamQuality) -> URL? {
        guard let source = xiaomiSourceURL(for: camera, quality: quality) else { return nil }
        var components = URLComponents(string: GoEngineBridge.engineBaseURL + "/api/stream.mp4")
        components?.queryItems = [URLQueryItem(name: "src", value: source)]
        return components?.url
    }

    /// 云台 /ptz 的 name 参数用的完整流名（就是播放时用的 xiaomi URL 全文）。
    func xiaomiSourceURL(for camera: Camera, quality: StreamQuality) -> String? {
        guard let userID = XiaomiConfig.savedUserID(), !userID.isEmpty else { return nil }
        var source = "xiaomi://\(userID):cn@\(camera.ip)?did=\(camera.id)&model=\(camera.model)"
        if let subtype = quality.subtype4Pro {
            source += "&subtype=\(subtype)"
        }
        return source
    }
}
