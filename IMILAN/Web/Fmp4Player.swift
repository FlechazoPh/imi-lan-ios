import Foundation
import AVFoundation

/// fMP4 + VideoToolbox 高清路（TODO 占位，Phase 2）。
///
/// 背景（见 ARCHITECTURE.md §7.1）：
///  - H.265 主码流在 WKWebView/WebRTC 里解不出来（stock WebRTC 无 HEVC 编解码器）。
///  - 正确路径是 go2rtc 的 /api/stream.mp4（fMP4 passthrough，H.265 保持 H.265），
///    Swift 侧增量 demux 成 CMSampleBuffer，用 VideoToolbox 硬解，
///    AVSampleBufferDisplayLayer 显示。CrumbVMS 已用这条路跑通 iOS/macOS。
///  - 注意 hev1 vs hvc1：ffmpeg -c copy 打的 hev1 样条 AVFoundation 拒解，需转 hvc1。
///
/// 本文件目前只有接口占位，不实现 demux/解码，避免假装高清已解决。
/// TODO (Phase 2): 实现 Fmp4Demuxer（增量解析 moof/mdat）+ VideoToolbox 解码 +
/// AVSampleBufferDisplayLayer 渲染，并在真机上验证 V-06。
final class Fmp4Player: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var lastError: String?

    /// TODO: 接入 go2rtc /api/stream.mp4?src=<camera>
    func play(streamURL: URL) {
        lastError = "fMP4 高清路尚未实现（TODO，见 VALIDATION.md V-06）"
        isPlaying = false
    }

    func stop() { isPlaying = false }
}
