import Foundation
import Security

/// Keychain 存储（Phase 1 已实现基础版，未在真机验证，见 VALIDATION.md V-12）。
///
/// 存什么、不存什么（见 ARCHITECTURE.md §6）：
///  - 存：app token（随机 32 字节，WebView Cookie imi_app）、网关 Basic Auth 密码（imi / 随机）。
///  - 不存：小米登录令牌明文（只存 go2rtc.yaml 里，文件权限 600）；不进 iCloud 钥匙串同步。
///  - 日志脱敏：uid 只记前 2 + **** + 后 2（与 qr.go 的 maskUID 一致）。
final class KeychainStore {
    static let shared = KeychainStore()
    private init() {}

    private let service = "imi.lan.ios"

    /// 首次启动随机生成 32 字节 app token，之后一直复用。
    func appToken() -> String {
        if let existing = read(account: "imi_app") { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        save(account: "imi_app", value: token)
        return token
    }

    func gatewayPassword() -> String {
        if let existing = read(account: "gateway-imi") { return existing }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let password = bytes.map { String(format: "%02x", $0) }.joined()
        save(account: "gateway-imi", value: password)
        return password
    }

    func save(account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    /// 脱敏账号：与 qr.go 的 maskUID 同款。
    static func maskUID(_ uid: String) -> String {
        guard uid.count > 4 else { return "****" }
        return uid.prefix(2) + "****" + uid.suffix(2)
    }
}
