import Foundation

/// 摄像头型号与画质映射：与上游 web/app.js 的 QUALITY_BY_MODEL 同义，
/// 但本文件为从零手写，未复制上游文件。
/// 高清/流畅不是固定编号，不同型号的 subtype 不同。
/// 4 Pro（xiaomi.camera.091ac1）已验证（2026-11-22 Windows 实测，见 docs/CAMERA-4PRO.md §5）：
/// 全部档位都是 H.265，没有 H.264 码流；默认（无 subtype）= 1080p H.265 = subtype 2。
enum StreamQuality: String, CaseIterable, Identifiable {
    case fluent = "fluent"   // 省流：subtype=1，848×480 H.265（已验证，非 H.264）
    case standard = "standard" // 默认：无 subtype，1920×1080 H.265（= subtype 2，已验证）
    case hd = "hd"           // 高清：subtype=0（3 也是 4K，首版只用 0），3840×2160 H.265

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fluent: return "流畅"
        case .standard: return "标清"
        case .hd: return "高清"
        }
    }

    /// 4 Pro 的 go2rtc subtype；nil = 不传 subtype（默认档）。其余型号未验证时返回 nil。
    var subtype4Pro: Int? {
        switch self {
        case .fluent: return 1
        case .standard: return nil
        case .hd: return 0
        }
    }
}

/// 4 Pro 画质映射（已验证）：QUALITY_BY_MODEL["xiaomi.camera.091ac1"] = { fluent: 1, standard: nil, hd: 0 }
/// 注意：hd 档 subtype=3 也是 4K，首版只用 0，不写 3。

struct Camera: Identifiable, Hashable {
    let id: String        // did
    var name: String      // 米家 App 里的昵称
    var model: String     // 如 chuangmi.camera.039c01
    var ip: String
    var isPTZ: Bool       // 云台机
    var isBattery: Bool   // 门铃等电池设备，可能休眠
    var quality: StreamQuality = .standard // 首版默认：无 subtype 1080p H.265（已验证），不是 480p 流畅档
    var isPaused: Bool = false

    /// go2rtc 流地址（概念）：xiaomi://{account}:{region}@{IP}?did=&model=
    /// TODO (Phase 1): 真实地址由网关/go2rtc.yaml 生成，这里只是展示格式。
    var streamURLDescription: String {
        "xiaomi://…@\(ip)?did=\(id)&model=\(model)"
    }

    // Phase 2 目标机型：小米智能摄像机 4 Pro（MJSXJ36CM，3840×2160 H.265，水平 360°/垂直 106°）。
    // 2026-11-22 Windows 实测：model = xiaomi.camera.091ac1（非 chuangmi.* 系），
    // 默认码流为 1080p H.265（非 4K）；subtype 已验证：4K=0/3，流畅=1（848×480 H.265），默认=无 subtype；
    // 云台上下左右已验证能动（MISS 0x112，左=1、右=2、上=3、下=4）。见 docs/CAMERA-4PRO.md §5–§6。
    static let camera4Pro = Camera(
        id: "sample-4pro", name: "小米智能摄像机 4 Pro", model: "xiaomi.camera.091ac1",
        ip: "192.168.1.100", isPTZ: true, isBattery: false)

    static let sample: [Camera] = [
        camera4Pro,
        Camera(id: "sample-1", name: "客厅摄像头", model: "chuangmi.camera.039c01",
               ip: "192.168.1.101", isPTZ: true, isBattery: false),
        Camera(id: "sample-2", name: "主卧摄像头", model: "chuangmi.camera.061a01",
               ip: "192.168.1.102", isPTZ: true, isBattery: false),
        Camera(id: "sample-3", name: "玄关摄像头", model: "chuangmi.camera.81ac1",
               ip: "192.168.1.103", isPTZ: true, isBattery: false),
        Camera(id: "sample-4", name: "门口门铃", model: "madv.cateye.mi3iot",
               ip: "192.168.1.104", isPTZ: false, isBattery: true),
    ]
}

enum EngineMode: String, CaseIterable, Identifiable {
    case local = "local"     // 独立版：引擎在 iPhone 内（TODO，未验证）
    case remote = "remote"   // 过渡版：引擎在家里 MacBook/Windows 上，iPhone 只做播放器

    var id: String { rawValue }
    var label: String {
        switch self {
        case .local: return "本机引擎（独立版）"
        case .remote: return "外接引擎（过渡版）"
        }
    }
}

enum EngineState: String {
    case stopped = "已停止"
    case starting = "启动中…"
    case running = "运行中"
    case failed = "启动失败"
}
