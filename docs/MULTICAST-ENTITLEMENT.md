# Multicast Entitlement — 申请与验证（Phase 2）

> 状态：**流程已按公开资料写清，未申请、未获批、未验证。**
> 用户已有 Apple 开发者账号，这是 Phase 1 时没有的前提条件——V-03 的“若必需即堵死”
> 在 Phase 2 已解堵为“可申请，待 Apple 审批”。

## 1. 为什么需要它

- iOS 14 起，向任意 IP 组播组发送 / 加入组播组，被一道单独的、须 Apple 批准的
  entitlement 挡住：`com.apple.developer.networking.multicast`。
  它不是默认授予的，也不能自己签名绕过（App Store / TestFlight 构建都一样）。
- IMI-LAN 的局域网发现走 **UDP 32108**（CS2 发现 / `0x41` punch），属于组播/广播流量。
  没有这个 entitlement，iOS 14.6+ 上组播/广播收发会被系统拦住。
- 只影响 **iOS**。安卓用 `CHANGE_WIFI_MULTICAST_STATE` + `WifiManager.MulticastLock` 即可，
  不需要向 Google 申请。

## 2. 没有它会怎样（验证方法见 §5）

| 场景 | 预期表现 |
|---|---|
| 只有 `NSLocalNetworkUsageDescription`（已在 Info.plist 里），无 multicast entitlement | 首次发 UDP 广播时能弹出“本地网络”权限框，用户点允许后，**单播**（已知 IP 直连）可能通，但**组播发现**（UDP 32108 发现新摄像头、mDNS 浏览任意 Bonjour 类型）会被拦，表现为“手动填 IP 能连，自动发现找不到设备” |
| 有 entitlement 且已在 App ID 上启用 + 描述文件已再生 | 组播发现应能通（仍需真机验证，V-03） |
| 模拟器 | **无法验证**：entitlement 在模拟器上不生效，必须真机 + 真实 Wi-Fi + 摄像头在同一局域网 |

注意：Apple 官方论坛的说明是——iOS 14 当时对 BSD Sockets 客户端尚未强制执行，
但 iOS 14.6 起已强制。iOS 27 上应按“强制”来准备，不要赌“不申请也能用”。

## 3. 申请流程（须由开发者账号的 Account Holder 提交）

申请入口（Apple 官方表单）：

- https://developer.apple.com/contact/request/networking-multicast

步骤：

1. **用 Account Holder 的 Apple ID 登录**开发者网站（不是普通开发者角色——
   申请须由账号持有人提交，见 esptouch_flutter 的平台要求文档）。
2. 打开上面表单，填写：
   - Developer Information：姓名 / 团队 / Team ID（**不要写进仓库**，只在表单里填）
   - App Information：App 名 `IMI-LAN`、Bundle ID `imi.lan.ios`（与 `Info.plist` / `project.pbxproj` 一致，
     必须是**显式 App ID**，不能用通配符 `*`）
   - **为什么需要组播/广播**：写具体协议与用户可见功能，不要写笼统的“需要本地网络”。
     建议英文表述（Apple 回复曾要求用英文再描述一遍），可参考以下模板，按实情改写后提交：

     > IMI-LAN is a local-network viewer for the user's own Xiaomi cameras.
     > It discovers cameras on the same Wi-Fi by sending UDP broadcast/multicast
     > to port 32108 (Xiaomi CS2 discovery, `0x41` punch) and then connects
     > directly over the LAN. Video never goes through our server.
     > Without multicast, automatic discovery fails and the user must type the
     > camera IP manually. Bonjour alone cannot discover these cameras because
     > they do not advertise a Bonjour service.

     关键点：**写明协议、IP/端口、交换的消息、为什么 Bonjour 替代不了**。
     Apple 曾回信追问过“具体用哪个组播/广播协议（IP 地址和端口）、设备之间交换什么消息、
     为什么不用 Bonjour”，提前写清楚能少走一轮。
3. 提交后页面只显示 “Thank you for your submission. We will review your request…”，
   **没有确认邮件**，不要反复重提。
4. 等 Apple 邮件回复。公开案例：有用户周末提交、周五下午获批（约 5 个工作日）；
   也有案例称“通常几周内”。**以 Apple 实际回复为准，不要承诺时限。**
5. 若 Apple 回信要求补充细节，按 §3 第 2 步的模板用英文补具体协议/端口/消息，不要只复述“需要本地网络”。

## 4. 获批后怎么配（Xcode + 描述文件）

按 Apple 论坛的 New Process（Xcode 12.4+ / iOS 14.4+ 的流程，至今仍适用）：

1. **开发者网站 → Certificates, Identifiers & Profiles → Identifiers → 选 `imi.lan.ios` 的 App ID**
   → 滑到最下 **Additional Capabilities → Multicast Networking → 勾选 → 保存**。
2. **重新生成所有用这个 App ID 的描述文件**：获批后旧描述文件会变无效（Invalid），
   逐个打开 → Edit → Save → Download，下载后双击安装到 Mac。
   （GitHub Actions 走签名模式时，见 `docs/SIGNING.md`，要用新下载的描述文件重新生成
   `PROVISION_PROFILE_BASE64` secret。）
3. **Xcode 里加 Capability**：打开 `IMILAN.xcodeproj` → 选 target `IMILAN` →
   Signing & Capabilities → `+ Capability` → **Multicast Networking**。
   Xcode 会生成/更新 `IMILAN/IMILAN.entitlements`（本仓库 Phase 2 已预置该文件，内容只有这一项）。
4. **确认 entitlements 文件被引用**：target 的 Build Settings 里
   `CODE_SIGN_ENTITLEMENTS = IMILAN/IMILAN.entitlements`。
   本仓库的 `project.pbxproj` 已把 `IMILAN.entitlements` 加进工程组；
   **未签名模式（默认）下不要强制设这个值**，否则未签名打包会报错——
   只在开发者账号签名模式下由 `scripts/build-ipa-local.sh --signed` /
   GitHub Actions `signing_mode=developer` 传入。
5. **首次触发本地网络弹框**：App 首次发送 UDP 广播前，先发一次 UDP 包触发系统弹框，
   让用户点“好”允许访问本地网络；只收广播不发包的场景可不处理这一步。
   （`NSLocalNetworkUsageDescription` 已在 Info.plist 里，文案见该文件。）

`IMILAN/IMILAN.entitlements` 内容（Phase 2 预置）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.networking.multicast</key>
    <true/>
</dict>
</plist>
```

> 注意：**没有获批就加这个 entitlement，打包/安装会失败**。
> 在获批之前，本地构建与 Actions 都应走未签名 / 无 multicast 的默认分支；
> 获批之后再切到开发者账号签名分支（见 `docs/SIGNING.md`）。

## 5. 验证方法（V-03）

必须真机 + 真实 Wi-Fi + 4 Pro 在同一局域网，模拟器无效：

1. iPhone 与 4 Pro 连同一 Wi-Fi（建议先连 5 GHz，与摄像头同一频段）。
2. 打开 App → 添加摄像头 → 自动发现。
3. **通过**：4 Pro 出现在发现列表（无需手动填 IP）。
4. **失败但单播通**：手动填 4 Pro 的 IP 能出画面，自动发现找不到——
   说明组播被拦，先查：① entitlement 是否获批；② App ID 上是否已启用；
   ③ 描述文件是否已再生；④ Xcode 里 Capability 是否已加；⑤ 是否点了本地网络弹框的“好”。
5. **失败且单播也不通**：先查 IP/供电/Wi-Fi、路由器 Mesh 漫游代理、物理遮蔽（见 `docs/CAMERA-4PRO.md` §7），
   不要先归因到 entitlement。

辅助验证（MacBook，获批后）：

```bash
# 看 App 的签名里是否带 multicast entitlement
codesign -d --entitlements - /path/to/IMILAN.app
# 应输出 com.apple.developer.networking.multicast = true
# 看描述文件是否含该 entitlement
security cms -D -i /path/to/xxx.mobileprovision | grep -A2 multicast
```

## 6. 来源

- Apple 官方申请表单：https://developer.apple.com/contact/request/networking-multicast
- Apple 开发者论坛 Quinn “The Eskimo!”《Using the Multicast Special Entitlement》
  （New Process：显式 App ID → App ID 上启用 Multicast Networking → 工程里启用 entitlement；
  旧描述文件会失效，需再生）
- NuvioMobile-Ultra `docs/ios-multicast-entitlement.md`（iOS 14 起组播须 Apple 批准，
  不能自签名；获批后在 Developer Portal 启用、再生描述文件、加 `.entitlements`、
  `CODE_SIGN_ENTITLEMENTS` 指向它；模拟器无法测试）
- Xojo 论坛《iOS Multicast Setup & Best Known Methods》（申请约 5 个工作日获批的案例；
  获批后 App ID 的 Additional Capabilities 里出现 Multicast Networking；
  Xcode 里 + Capability → Multicast Networking）
- esptouch_flutter 平台要求（DeepWiki）：须 Account Holder 提交申请，审批数日到数周；
  iOS 14.6+ 强制要求该 entitlement
- 博客园《iOS 14 UDP收不到广播处理》（Apple 回信追问具体协议/IP/端口/消息、为什么不用 Bonjour 的案例；
  首次发 UDP 广播触发本地网络弹框）
