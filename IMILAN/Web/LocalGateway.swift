import Foundation
import WebKit

/// 本地网关占位（Phase 1）。
///
/// 安卓版网关（fpk/gateway，Go）的职责，本项目在 iOS 上同样需要：
///  1. 只监听 127.0.0.1:19841（独立版固定），反代 go2rtc /api 时自动注入 Basic Auth；
///  2. 提供 /qr/new、/qr/status、/rooms（扫码登录，见 Auth/QRLoginView）；
///  3. 校验 imi_app Cookie（随机令牌），/health 免令牌。
///
/// 本文件目前只定义地址与 Cookie 注入，不启动真实网关进程——
/// 网关本身是 Go 代码，随引擎一起以 c-archive 内嵌（见 ARCHITECTURE.md §4.1）。
enum LocalGateway {
    static let loopbackHost = "127.0.0.1"
    static let port = 19841
    static var baseURL: URL { URL(string: "http://\(loopbackHost):\(port)/")! }

    /// 把 Keychain 里的 app token 以 Cookie 形式注入 WKWebView。
    /// TODO (Phase 2): 在 WebViewContainer 加载前调用，确保首屏不 401。
    static func injectAppToken(into store: WKWebsiteDataStore) async {
        let token = KeychainStore.shared.appToken()
        let cookie = HTTPCookie(properties: [
            .domain: loopbackHost,
            .path: "/",
            .name: "imi_app",
            .value: token,
            .secure: "FALSE",
            .expires: Date(timeIntervalSinceNow: 365 * 24 * 3600),
        ])
        if let cookie {
            // WKWebsiteDataStore 本身没有 setCookie；Cookie 属于
            // WKHTTPCookieStore（经 dataStore.httpCookieStore 访问）。
            // 用 completion-handler 版包一层 continuation，兼容各 SDK。
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.httpCookieStore.setCookie(cookie) { cont.resume() }
            }
        }
    }

    /// 健康检查：GET http://127.0.0.1:1984/api/streams，5 秒超时，
    /// 200 返回 true，其余状态或网络错误返回 false。
    static func healthCheck() async -> Bool {
        guard let url = URL(string: GoEngineBridge.engineBaseURL + "/api/streams") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
