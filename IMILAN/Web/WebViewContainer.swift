import SwiftUI
import WebKit

/// WKWebView 壳（Phase 1 骨架）。
///
/// 复用思路（见 ARCHITECTURE.md §2）：
///  - 安卓用 WebView + web/ 前端；fnOS 用浏览器访问 http://<主机>:1984。
///  - iOS 侧同样用 WKWebView 加载本地网关页面，不自己重写播放器。
///  - 页面级缩放已关闭（与安卓 WebView setSupportZoom(false) 同义）；
///    只有点开“放大镜”后才能对当前画面双指捏合、单指拖动（SingleCameraView）。
///
/// H.265 注意：WKWebView 内 WebRTC 解不了 H.265 主码流（见 §7.1），
/// 高清路要走 Fmp4Player（TODO），本壳默认只保证 H.264 子码流（流畅）。
struct WebViewContainer: UIViewRepresentable {
    /// 要加载的网关地址。独立版为 http://127.0.0.1:19841/，过渡版为用户填的局域网地址。
    var url: URL
    var onMessage: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 注入 imi_app Cookie 由 LocalGateway 在加载前完成（见 LocalGateway.swift）。
        // JS 桥名与安卓的 IMIAndroid 对应，iOS 侧叫 IMIShell，避免与网页的旧桥混淆。
        config.userContentController.add(context.coordinator, name: "IMIShell")
        let view = WKWebView(frame: .zero, configuration: config)
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        // 禁止页面级双指缩放：网页侧再用 touch-action: manipulation 禁双击缩放（与安卓一致）。
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard uiView.url != url else { return }
        uiView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onMessage: ((String) -> Void)?
        init(onMessage: ((String) -> Void)?) { self.onMessage = onMessage }

        /// JS 桥消息：截图 / 录像 / 全屏 / 画中画 / 分享。
        /// TODO (Phase 2): 接 PhotoKit（截图/录像写相册）与 AVPictureInPictureController。
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "IMIShell",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            onMessage?(action)
        }
    }
}

/// 单路画面的 Web 播放占位：Phase 1 先用 WebViewContainer 整页加载，
/// Phase 2 再按需把单路抽成独立 WKWebView（便于 PiP 与原生播放器切换）。
struct CameraWebView: View {
    var camera: Camera
    var gatewayURL: URL

    var body: some View {
        WebViewContainer(url: gatewayURL) { action in
            // TODO (Phase 2): 处理来自网页的 IMIShell 消息。
            print("[IMIShell] \(action) (TODO)")
        }
    }
}
