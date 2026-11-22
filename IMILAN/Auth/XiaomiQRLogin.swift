import Foundation

/// 小米扫码登录（Swift 原生实现，按 IMI-LAN fpk/gateway/qr.go 的流程重写）。
///
/// 流程：
///   1. GET account.xiaomi.com/longPolling/loginUrl 拿二维码（JSONP）；
///   2. GET 二维码图片地址取图，界面真实显示；
///   3. 每 1 秒轮询 lp，扫码后 location+userId 非空即进入 handleScan；
///   4. 手动跟随 location 链（最多 12 跳），沿途收 Cookie 与
///      Extension-Pragma 头里的 ssecurity；passToken 有但 ssecurity 为空时
///      兜底走 serviceLogin；
///   5. 凭据写回 go2rtc.yaml（XiaomiConfig），调 IMISetXiaomiToken 热更新；
///   6. 成功后发 `IMILoginDidSucceed` 通知。
///
/// 会话管理：ephemeral URLSession，httpShouldSetCookies=false，
/// 自己拼 Cookie 头；不自动跟随重定向（delegate 里一律拦截），手动跟随。
/// 所有失败都在界面显示真实错误文案，不留占位。
@MainActor
final class XiaomiQRLogin: NSObject, ObservableObject, URLSessionTaskDelegate {
    enum Phase: Equatable {
        case idle        // 未开始
        case loading     // 正在取二维码
        case waiting     // 等待扫码（二维码已显示）
        case scanned     // 已扫码，请在手机上确认
        case success     // 登录成功
        case expired     // 二维码过期
        case canceled    // 已取消
        case error       // 失败（看 errorMessage）
    }

    static let loginDidSucceedNotification = Notification.Name("IMILoginDidSucceed")
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var qrImageData: Data?
    @Published private(set) var statusMessage = "正在获取二维码…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var expiresIn = 0
    @Published private(set) var deviceCount: Int?

    private var session: URLSession!
    private var pollTask: Task<Void, Never>?
    private var sessionGeneration = 0
    private var expiresAt: Date?
    private var canceled = false

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 25
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - URLSessionTaskDelegate（拦截一切自动重定向，手动跟随）

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // MARK: - 入口

    /// 开始一次新的登录会话（取二维码 + 启动轮询）。已在跑时直接返回。
    func start() {
        guard pollTask == nil else { return }
        canceled = false
        sessionGeneration += 1
        let generation = sessionGeneration
        pollTask = Task { await runSession(generation: generation) }
    }

    /// 取消当前轮询并开新会话（刷新二维码按钮用）。
    func refresh() {
        cancel()
        start()
    }

    /// 取消当前会话（关闭页面 / 点取消时调用）。
    func cancel() {
        canceled = true
        pollTask?.cancel()
        pollTask = nil
        if phase != .success {
            phase = .canceled
            statusMessage = "已取消"
        }
    }

    // MARK: - 会话主流程

    private func runSession(generation: Int) async {
        phase = .loading
        statusMessage = "正在获取二维码…"
        errorMessage = nil
        qrImageData = nil
        deviceCount = nil
        let jar = CookieJar()
        do {
            let (lp, qrURL, timeout) = try await fetchLoginURL(jar: jar)
            let image = try await fetchQRImage(url: qrURL, jar: jar)
            qrImageData = image
            expiresAt = Date().addingTimeInterval(TimeInterval(timeout))
            expiresIn = timeout
            phase = .waiting
            statusMessage = "等待扫码"
            try await pollScan(lp: lp, jar: jar)
        } catch is CancellationError {
            // Task 被取消：cancel() 已置状态，这里不再覆盖。
        } catch {
            if canceled || Task.isCancelled { return }
            phase = .error
            errorMessage = error.localizedDescription
            statusMessage = "登录失败"
        }
        // 只清自己的引用：刷新时旧任务收尾不能把新会话的 pollTask 置空。
        if generation == sessionGeneration { pollTask = nil }
    }

    /// 第 b 步：取 loginUrl（JSONP），返回（轮询地址，二维码地址，有效秒数）。
    private func fetchLoginURL(jar: CookieJar) async throws -> (lp: String, qr: String, timeout: Int) {
        var components = URLComponents(string: "https://account.xiaomi.com/longPolling/loginUrl")!
        // 注意：qs 的值本身就是一次百分号编码后的文本
        //（"%3Fsid%3Dxiaomiio%26_json%3Dtrue"）；URLComponents 会再编码一次
        //（% → %25），与 qr.go 里 url.Values.Encode() 的行为一致。
        components.queryItems = [
            URLQueryItem(name: "_qrsize", value: "480"),
            URLQueryItem(name: "qs", value: "%3Fsid%3Dxiaomiio%26_json%3Dtrue"),
            URLQueryItem(name: "callback", value: "https://sts.api.io.mi.com/sts"),
            URLQueryItem(name: "_hasLogo", value: "false"),
            URLQueryItem(name: "sid", value: "xiaomiio"),
            URLQueryItem(name: "serviceParam", value: ""),
            URLQueryItem(name: "_locale", value: "zh_CN"),
            URLQueryItem(name: "_dc", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        guard let url = components.url else { throw QRLoginError.invalidResponse("loginUrl 地址构造失败") }
        let (data, response) = try await requestFollow(url, jar: jar)
        guard response.statusCode == 200 else {
            throw QRLoginError.httpStatus(response.statusCode, "获取二维码失败")
        }
        let ticket = try parseJSONP(data)
        let code = stringValue(ticket["code"])
        if !code.isEmpty, code != "0" {
            throw QRLoginError.server("loginUrl code=\(code)")
        }
        let lp = stringValue(ticket["lp"])
        guard !lp.isEmpty else { throw QRLoginError.server("loginUrl 未返回长轮询地址") }
        let qr = stringValue(ticket["qr"])
        guard !qr.isEmpty else { throw QRLoginError.server("loginUrl 未返回二维码地址") }
        let timeout = Int(stringValue(ticket["timeout"])) ?? 0
        return (lp, qr, timeout > 0 ? timeout : 300)
    }

    /// 第 c 步：取二维码图片。
    private func fetchQRImage(url: String, jar: CookieJar) async throws -> Data {
        guard let qrURL = URL(string: url) else { throw QRLoginError.invalidResponse("二维码地址无效") }
        let (data, response) = try await requestFollow(qrURL, jar: jar)
        guard response.statusCode == 200 else {
            throw QRLoginError.httpStatus(response.statusCode, "二维码图片请求失败")
        }
        guard !data.isEmpty else { throw QRLoginError.server("二维码图片为空") }
        return data
    }

    /// 第 d 步：每 1 秒轮询 lp，直到扫码、过期或取消。
    private func pollScan(lp: String, jar: CookieJar) async throws {
        guard let lpURL = URL(string: lp) else { throw QRLoginError.invalidResponse("长轮询地址无效") }
        while true {
            try Task.checkCancellation()
            if canceled { return }
            if let exp = expiresAt, Date() > exp {
                phase = .expired
                statusMessage = "二维码已过期，请刷新"
                return
            }
            if let exp = expiresAt {
                expiresIn = max(0, Int(exp.timeIntervalSinceNow))
            }
            do {
                let (data, response) = try await requestFollow(lpURL, jar: jar)
                if response.statusCode == 200, let obj = try? parseJSONP(data) {
                    let location = stringValue(obj["location"])
                    let userId = stringValue(obj["userId"])
                    if !location.isEmpty && !userId.isEmpty {
                        await handleScan(userId: userId, location: location, jar: jar)
                        return
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 单次轮询失败（网络抖动等）不报错，下一秒继续轮询；只在过期时结束。
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// 第 e 步：已扫码，跟 location 链、收凭据、兜底、保存、热更新。
    private func handleScan(userId: String, location: String, jar: CookieJar) async {
        phase = .scanned
        statusMessage = "已扫码，请在手机上确认"
        do {
            var ssecurity = ""
            var current = location
            // 手动跟随 location 链，最多 12 跳。
            for _ in 0..<12 {
                guard let url = URL(string: current) else { break }
                let (_, response) = try await requestOnce(url, jar: jar)
                if let ext = response.value(forHTTPHeaderField: "Extension-Pragma"),
                   let data = ext.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let s = obj["ssecurity"] as? String, !s.isEmpty {
                    ssecurity = s
                }
                guard let next = response.value(forHTTPHeaderField: "Location"),
                      let nextURL = URL(string: next, relativeTo: url)?.absoluteURL else { break }
                current = nextURL.absoluteString
            }

            var passToken = jar["passToken"] ?? ""
            var serviceToken = jar["serviceToken"] ?? ""
            var cUserId = jar["cUserId"] ?? ""

            // 兜底：有 passToken 但没拿到 ssecurity 时，走一次完整 serviceLogin。
            if !passToken.isEmpty && ssecurity.isEmpty {
                let (fallback, fallbackSsecurity) = try await cloudLogin(userId: userId, passToken: passToken)
                ssecurity = fallbackSsecurity
                for (name, value) in fallback { jar.set(name, value) }
                passToken = jar["passToken"] ?? passToken
                serviceToken = jar["serviceToken"] ?? ""
                cUserId = jar["cUserId"] ?? ""
            }

            guard !passToken.isEmpty else {
                throw QRLoginError.server("登录成功但没拿到 passToken，请重试")
            }

            // 第 f 步：保存凭据（写 go2rtc.yaml + UserDefaults）。
            let creds = XiaomiConfig.Credentials(passToken: passToken, serviceToken: serviceToken,
                                                 ssecurity: ssecurity, cUserId: cUserId)
            try XiaomiConfig.saveToken(userID: userId, credentials: creds)

            // 第 g 步：让运行中的引擎立即生效，不重启 App。
            let hotApplied = GoEngineBridge.setXiaomiToken(userID: userId, passToken: passToken)
            if hotApplied {
                // 继续拉设备列表，验证新 token 真能取到设备。
                let count = await fetchDeviceCount(userID: userId)
                deviceCount = count
                if let count {
                    statusMessage = "登录成功，已发现 \(count) 台设备"
                } else {
                    statusMessage = "登录成功（设备列表暂未拉取到）"
                }
            } else {
                statusMessage = "登录成功，凭据已保存，请重启 App 后生效"
            }
            phase = .success
            NotificationCenter.default.post(name: Self.loginDidSucceedNotification,
                                            object: nil, userInfo: ["userID": userId])
        } catch is CancellationError {
            // 取消不覆盖状态。
        } catch {
            if canceled || Task.isCancelled { return }
            phase = .error
            errorMessage = error.localizedDescription
            statusMessage = "登录失败"
        }
    }

    /// 兜底 cloudLogin：带 userId/passToken Cookie 调 serviceLogin，
    /// 返回（合并回主 jar 的 Cookie，ssecurity base64 文本）。
    private func cloudLogin(userId: String, passToken: String) async throws -> ([String: String], String) {
        let jar = CookieJar()
        jar.set("userId", userId)
        jar.set("passToken", passToken)
        guard let url = URL(string: "https://account.xiaomi.com/pass/serviceLogin?_json=true&sid=xiaomiio") else {
            throw QRLoginError.invalidResponse("serviceLogin 地址无效")
        }
        let (data, response) = try await requestFollow(url, jar: jar)
        guard response.statusCode == 200 else {
            throw QRLoginError.httpStatus(response.statusCode, "serviceLogin 请求失败")
        }
        let obj = try parseJSONP(data)
        if stringValue(obj["code"]) == "70016" {
            throw QRLoginError.server("小米账号需要验证")
        }
        let location = stringValue(obj["location"])
        guard !location.isEmpty else { throw QRLoginError.server("登录令牌已失效，请重新扫码") }
        let ssecurity = stringValue(obj["ssecurity"])
        guard !ssecurity.isEmpty else { throw QRLoginError.server("小米云端未返回 ssecurity") }
        guard let locURL = URL(string: location) else { throw QRLoginError.invalidResponse("serviceLogin 返回的地址无效") }
        _ = try await requestFollow(locURL, jar: jar)
        for name in ["userId", "cUserId", "serviceToken"] {
            guard let v = jar[name], !v.isEmpty else {
                throw QRLoginError.server("小米云端登录不完整")
            }
        }
        return (["cUserId": jar["cUserId"] ?? "", "serviceToken": jar["serviceToken"] ?? "",
                 "passToken": jar["passToken"] ?? ""], ssecurity)
    }

    /// 热更新后验证：GET /api/xiaomi?id=<uid>&region=cn，数 sources 条数。
    /// 引擎未运行或请求失败时返回 nil（不因此判登录失败）。
    private func fetchDeviceCount(userID: String) async -> Int? {
        var components = URLComponents(string: GoEngineBridge.engineBaseURL + "/api/xiaomi")!
        components.queryItems = [
            URLQueryItem(name: "id", value: userID),
            URLQueryItem(name: "region", value: "cn"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sources = obj["sources"] as? [[String: Any]] else { return nil }
            return sources.count
        } catch {
            return nil
        }
    }

    // MARK: - HTTP 基础（手动 Cookie + 手动重定向）

    /// 单次 GET，不跟随重定向；返回（body, 响应），并把 Set-Cookie 存进 jar。
    private func requestOnce(_ url: URL, jar: CookieJar) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let cookie = jar.headerValue() {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QRLoginError.invalidResponse("非 HTTP 响应")
        }
        jar.store(from: http, url: url)
        return (data, http)
    }

    /// GET 并手动跟随重定向，最多 6 跳；返回最终的（body, 响应）。
    private func requestFollow(_ url: URL, jar: CookieJar, maxHops: Int = 6) async throws -> (Data, HTTPURLResponse) {
        var current = url
        var last: (Data, HTTPURLResponse)?
        for _ in 0..<maxHops {
            let (data, response) = try await requestOnce(current, jar: jar)
            last = (data, response)
            if (300..<400).contains(response.statusCode),
               let loc = response.value(forHTTPHeaderField: "Location"),
               let next = URL(string: loc, relativeTo: current)?.absoluteURL {
                current = next
                continue
            }
            return (data, response)
        }
        guard let last else { throw QRLoginError.invalidResponse("重定向跟随失败") }
        return last
    }

    // MARK: - JSONP / 取值

    /// 去掉 `&&&START&&&` 前缀后解析 JSON。
    private func parseJSONP(_ data: Data) throws -> [String: Any] {
        guard var text = String(data: data, encoding: .utf8) else {
            throw QRLoginError.invalidResponse("响应不是 UTF-8 文本")
        }
        if let range = text.range(of: "&&&START&&&") {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw QRLoginError.invalidResponse("JSONP 解析失败")
        }
        return obj
    }

    private func stringValue(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case nil: return ""
        default: return "\(v!)"
        }
    }

    enum QRLoginError: LocalizedError {
        case httpStatus(Int, String)
        case server(String)
        case invalidResponse(String)
        var errorDescription: String? {
            switch self {
            case .httpStatus(let code, let msg): return "\(msg)（HTTP \(code)）"
            case .server(let msg): return msg
            case .invalidResponse(let msg): return msg
            }
        }
    }
}

/// 手动管理的 Cookie 容器：只存 name → value，不做域名/路径/过期匹配
///（登录流程的 Cookie 全是同站会话 Cookie，与 qr.go 的 httpSession 同款）。
private final class CookieJar {
    private var cookies: [String: String] = [:]

    subscript(name: String) -> String? { cookies[name] }

    func set(_ name: String, _ value: String) {
        guard !value.isEmpty else { return }
        cookies[name] = value
    }

    func headerValue() -> String? {
        guard !cookies.isEmpty else { return nil }
        return cookies.keys.sorted().map { "\($0)=\(cookies[$0]!)" }.joined(separator: "; ")
    }

    /// 从响应头收 Cookie：用 HTTPCookie 解析 Set-Cookie（含 Expires 里的逗号），
    /// 空值或 EXPIRED 表示删除。
    func store(from response: HTTPURLResponse, url: URL) {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            if let s = value as? String {
                fields[name] = s
            } else if let arr = value as? [String] {
                fields[name] = arr.joined(separator: ", ")
            }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            if cookie.value.isEmpty || cookie.value == "EXPIRED" {
                cookies.removeValue(forKey: cookie.name)
            } else {
                cookies[cookie.name] = cookie.value
            }
        }
    }
}
