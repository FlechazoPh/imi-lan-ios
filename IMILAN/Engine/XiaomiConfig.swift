import Foundation

/// go2rtc.yaml 里的小米凭据读写（Swift 原生实现）。
///
/// 写入方式：按行编辑，只动 `xiaomi:` 与 `xiaomi-credentials:` 两个顶级段，
/// 其余段（api/rtsp/webrtc/log/streams 等）原样保留；写临时文件再 rename，
/// 写前把原文件备份为 go2rtc.yaml.bak；最终文件权限 0600。
/// 令牌只存这个文件里，不进 Keychain、不进 UserDefaults（见 KeychainStore 注释）。
enum XiaomiConfig {
    static let userIDDefaultsKey = "xiaomiUserID"

    struct Credentials {
        var passToken: String
        var serviceToken: String
        var ssecurity: String   // base64 文本（存 yaml 时不解码）
        var cUserId: String
    }

    enum ConfigError: LocalizedError {
        case readFailed(String)
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .readFailed(let msg): return "读取 go2rtc.yaml 失败：\(msg)"
            case .writeFailed(let msg): return "写入 go2rtc.yaml 失败：\(msg)"
            }
        }
    }

    /// 保存登录凭据：xiaomi: 段写 {userID: passToken}；
    /// serviceToken 与 ssecurity 齐全时，xiaomi-credentials: 段写
    /// {userID: {"serviceToken":..,"ssecurity":..,"cUserId":..,"passToken":..}}；
    /// 不齐全时删掉该用户在 xiaomi-credentials: 段的旧条目，避免引擎
    /// 用过期会话。userID 同时存 UserDefaults。
    static func saveToken(userID: String, credentials: Credentials) throws {
        _ = GoEngineBridge.ensureConfig()
        let path = GoEngineBridge.configPath
        let original: String
        do {
            original = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ConfigError.readFailed(error.localizedDescription)
        }
        // 写前备份（0600）。
        do {
            try original.write(toFile: path + ".bak", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + ".bak")
        } catch {
            throw ConfigError.writeFailed("备份失败：\(error.localizedDescription)")
        }

        var lines = splitLines(original)
        let eol = original.contains("\r\n") ? "\r\n" : "\n"

        // xiaomi: 段（flat）：upsert userID -> passToken。
        if upsertFlat(lines: &lines, header: "xiaomi:", userID: userID, value: credentials.passToken) == false {
            insertSection(lines: &lines, header: "xiaomi:",
                          entry: "  \(jsonQuoted(userID)): \(jsonQuoted(credentials.passToken))")
        }

        // xiaomi-credentials: 段（nested JSON）：齐全则 upsert，否则删旧条目。
        if !credentials.serviceToken.isEmpty && !credentials.ssecurity.isEmpty {
            let fields = "{\"serviceToken\":\(jsonQuoted(credentials.serviceToken))"
                + ",\"ssecurity\":\(jsonQuoted(credentials.ssecurity))"
                + ",\"cUserId\":\(jsonQuoted(credentials.cUserId))"
                + ",\"passToken\":\(jsonQuoted(credentials.passToken))}"
            if upsertFlat(lines: &lines, header: "xiaomi-credentials:", userID: userID, value: fields, rawValue: true) == false {
                insertSection(lines: &lines, header: "xiaomi-credentials:",
                              entry: "  \(jsonQuoted(userID)): \(fields)")
            }
        } else {
            removeEntry(lines: &lines, header: "xiaomi-credentials:", userID: userID)
        }

        try writeAtomically(lines: lines, eol: eol, path: path)
        UserDefaults.standard.set(userID, forKey: userIDDefaultsKey)
    }

    /// 读当前保存的 userID（扫码登录后写入；未登录返回 nil）。
    static func savedUserID() -> String? {
        UserDefaults.standard.string(forKey: userIDDefaultsKey)
    }

    // MARK: - 行编辑（顶级段 = 行首非空白、形如 `name:` 的行）

    /// 把文本按行拆开（去掉 BOM；行内统一用 \n，写回时再按原 eol 拼）。
    private static func splitLines(_ text: String) -> [String] {
        let stripped = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        return stripped.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// 判断一行是否为给定的顶级段头（`xiaomi:` 或 `xiaomi: # 注释`）。
    private static func isHeader(_ line: String, _ header: String) -> Bool {
        if line == header { return true }
        guard line.hasPrefix(header) else { return false }
        let rest = line.dropFirst(header.count)
        return rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t") || rest.hasPrefix("#")
    }

    /// 在段内 upsert 一条 `  "userID": value`；段不存在返回 false。
    /// value 为普通字符串时加 JSON 引号；rawValue=true 时 value 已是 JSON 文本，直接写。
    @discardableResult
    private static func upsertFlat(lines: inout [String], header: String, userID: String, value: String, rawValue: Bool = false) -> Bool {
        guard let range = lines.firstIndex(where: { isHeader($0, header) }).flatMap({ start -> Range<Int>? in
            var end = lines.count
            for j in (start + 1)..<lines.count {
                let l = lines[j]
                if let first = l.first, first != " ", first != "\t", !l.isEmpty {
                    end = j
                    break
                }
            }
            return start..<end
        }) else { return false }

        let rendered = rawValue ? value : jsonQuoted(value)
        var order: [String] = []
        var values: [String: String] = [:]
        for line in lines[(range.lowerBound + 1)..<range.upperBound] {
            guard let (key, val) = parseEntry(line) else { continue }
            // flat 段（xiaomi:）只认普通字符串值；nested 段（xiaomi-credentials:，
            // rawValue=true）的值是 `{...}` JSON 文本，整体保留。
            if !rawValue, val.hasPrefix("{") { continue }
            if !order.contains(key) { order.append(key) }
            values[key] = val
        }
        if !order.contains(userID) { order.append(userID) }
        values[userID] = rendered

        var block: [String] = [lines[range.lowerBound]]
        for key in order {
            block.append("  \(jsonQuoted(key)): \(values[key]!)")
        }
        lines.replaceSubrange(range, with: block)
        return true
    }

    /// 删掉段内指定用户的条目；段不存在或无此用户时什么都不做。
    /// 删空后整个段一并去掉（不留空头）。
    private static func removeEntry(lines: inout [String], header: String, userID: String) {
        guard let start = lines.firstIndex(where: { isHeader($0, header) }) else { return }
        var end = lines.count
        for j in (start + 1)..<lines.count {
            let l = lines[j]
            if let first = l.first, first != " ", first != "\t", !l.isEmpty {
                end = j
                break
            }
        }
        var kept: [String] = []
        for line in lines[(start + 1)..<end] {
            if let (key, _) = parseEntry(line), key == userID { continue }
            kept.append(line)
        }
        if kept.isEmpty {
            lines.replaceSubrange(start..<end, with: [])
        } else {
            lines.replaceSubrange(start..<end, with: [lines[start]] + kept)
        }
    }

    /// 段不存在时新建：插在 `streams:` 行之前（没有 streams: 则追加到文件尾）。
    private static func insertSection(lines: inout [String], header: String, entry: String) {
        let idx = lines.firstIndex(where: { $0 == "streams:" || $0.hasPrefix("streams: ") }) ?? lines.count
        var block = [header, entry]
        if idx < lines.count { block.append("") }
        lines.insert(contentsOf: block, at: idx)
    }

    /// 解析一行 `  "key": value` 或 `  key: value`；解析不到返回 nil。
    /// value 去掉行尾注释前的空白；引号包裹的 key/value 做 JSON 反引号还原。
    private static func parseEntry(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let rawKey = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        var rawValue = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // 行尾注释：只在 value 不是引号字符串时按 ` #` 切（引号内的 # 不动）。
        if !rawValue.hasPrefix("\""), let hash = rawValue.range(of: " #") {
            rawValue = String(rawValue[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (unquoteYAML(rawKey), rawValue)
    }

    /// 去掉一层双引号（JSON 转义按 JSON 解析还原）；无引号则原样返回。
    private static func unquoteYAML(_ v: String) -> String {
        guard v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\""),
              let data = v.data(using: .utf8),
              let out = try? JSONSerialization.jsonObject(with: data) as? String else { return v }
        return out
    }

    /// 用 JSON 编码器给字符串加双引号（转义由编码器处理）。
    private static func jsonQuoted(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let out = String(data: data, encoding: .utf8) else { return "\"\"" }
        return out
    }

    /// 写临时文件再 rename（原子替换），权限 0600。
    private static func writeAtomically(lines: [String], eol: String, path: String) throws {
        let tmp = "\(path).\(ProcessInfo.processInfo.processIdentifier).tmp"
        let text = lines.joined(separator: eol)
        do {
            try text.write(toFile: tmp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                     withItemAt: URL(fileURLWithPath: tmp))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            throw ConfigError.writeFailed(error.localizedDescription)
        }
    }
}
