# IMI-LAN iOS 独立版 — 骨架 + Phase 2 验证设计

> **状态：调研 + 骨架 + Phase 2 验证设计，未验证，未出可安装 IPA。不要向用户承诺已完成可安装的 App。**
>
> 本仓库所有代码均为从零手写，未复制上游 IMI-LAN / go2rtc 的代码文件。
> 研读只用了浏览器公开资料（见 `ARCHITECTURE.md` §9），未使用 `/tmp/imi-lan` 的克隆内容。
>
> 目标：iPhone 18 Pro Max，iOS 27.0.1；工程目标 iOS 17+，arm64 only。
> 目标机型：**小米智能摄像机 4 Pro（MJSXJ36CM，3840×2160 H.265）**，见 `docs/CAMERA-4PRO.md`。
> 用户已有 **Apple 开发者账号**，用开发者账号侧载使用；坚持**独立 App（引擎装进 iPhone）**，
> 不转回瘦客户端/外接引擎方案（Phase 1 的过渡版建议已按用户决定作废，仅作 V-01 失败时的兜底记录在案）。

## 这是什么

IMI-LAN（`pigstrong9/IMI-LAN`）是“米家摄像头局域网直连”工具：
原版走小米公网 P2P 中转会卡，它用 go2rtc 实现小米 `miss` / `CS2` / `TUTK` 协议，
每次建连先向小米云端拿一次本地密钥，音视频只走局域网，浏览器用 WebRTC/MSE 播放，延迟 0.3–2 秒。

官方已有 Windows / macOS / 飞牛 fnOS / 安卓版，**没有 iOS 版**。
本项目是 iOS 独立版的第一阶段：调研安卓版怎么嵌引擎，设计 iOS 架构，搭一个 SwiftUI 骨架。

## 结论（详见 ARCHITECTURE.md）

- **可行，但有条件**：壳 + 网页 + 扫码可以先行；引擎内嵌是最大堵点。
- **最大堵点 ①**：go2rtc 在 iOS 上不能像安卓那样跑独立二进制（iOS 沙箱禁止执行包内二进制），
  必须走 **Go c-archive 静态库内嵌进 App 进程**（首选）或 gomobile bind（备选）。
  Swift 重写 miss/CS2/TUTK 不推荐。最小验证设计见 `docs/GO-ENGINE-C-ARCHIVE.md`。
- **最大堵点 ②**：**H.265 主码流在 WKWebView/WebRTC 里解不出来**，H.264 子码流（流畅）可行，
  高清要走原生 **fMP4 + VideoToolbox**（`Fmp4Player.swift` 为 TODO 占位）。
  4 Pro 主码流是 **3840×2160 H.265**，高清是独立风险点，见 `docs/CAMERA-4PRO.md` §5。
- **Phase 2 已解堵的两点**：① multicast entitlement 可申请（用户有开发者账号，
  流程见 `docs/MULTICAST-ENTITLEMENT.md`）；② 签名侧载可走开发者账号
  （Xcode 直装 / 本地导出 / Actions 出已签名包，见 `docs/SIGNING.md`，默认仍为未签名）。
- **4 Pro 支持概率**：中等偏高（约 60–70% 能走通流畅码流），依据是 2020 年后 miss 协议统一；
  风险是新机未验证 + miot model ID 未知 + 4K 高清待验。详见 `docs/CAMERA-4PRO.md` §4。
- **用户已定**：独立 App，不做过渡版。Phase 1 的“先做壳 + 外接引擎”建议已作废，
  仅在 V-01 被证明不可行时才作为兜底重新讨论。

## 骨架里有什么

```
IMILAN/IMILANApp.swift        App 入口
IMILAN/ContentView.swift      根视图：网格 / 单画面 / 设置
IMILAN/Models/Camera.swift    Camera / EngineStatus / StreamQuality
IMILAN/Engine/EngineManager.swift   引擎生命周期占位（start/stop/restart）
IMILAN/Engine/GoEngineBridge.*      c-archive 桥接占位（待 libgo2rtc.a）
IMILAN/Web/WebViewContainer.swift   WKWebView 壳 + IMIShell JS 桥 + Cookie 注入
IMILAN/Web/LocalGateway.swift       本地网关占位（127.0.0.1:19841）
IMILAN/Web/Fmp4Player.swift         TODO: fMP4 + VideoToolbox 高清路
IMILAN/Auth/KeychainStore.swift     Keychain：app token / gateway password
IMILAN/Auth/QRLoginView.swift       扫码登录 UI + 轮询占位
IMILAN/Views/CameraGridView.swift   1列/2列/横屏3列网格
IMILAN/Views/CameraCardView.swift   卡片：信号/画质切换/PiP/截图
IMILAN/Views/SingleCameraView.swift 单画面：手势/云台方向盘占位
IMILAN/Views/SettingsView.swift     设置：引擎地址/画质/后台/日志
IMILAN/Views/EngineLogView.swift    日志查看占位
```

所有带 `TODO (Phase 1)` 的地方都是**未验证的占位**，不要当成已跑通。

## 在 MacBook 上本地构建（未验证）

```bash
# 1. 用 Xcode 打开工程（需 Xcode 16+，macOS 15+）
open IMILAN.xcodeproj

# 2. 未签名 IPA（默认，见 scripts/build-ipa-local.sh）
./scripts/build-ipa-local.sh
# 产物：build/IMI-LAN-iOS-unsigned.ipa

# 3. 已签名 IPA（开发者账号模式，见 docs/SIGNING.md §2）
IMILAN_TEAM_ID="<你的 Team ID，只在本地终端里填>" ./scripts/build-ipa-local.sh --signed
# 产物：build/IMI-LAN-iOS-signed.ipa
```

本机 Linux 上没有 Xcode / Swift / Go，**不要**在这里尝试构建（`swift`、`go` 均不存在，已确认）。

## GitHub Actions 打 IPA（未验证）

见 `.github/workflows/build-ipa.yml`：macos runner 上**先编 Go 引擎（c-archive），再编 Xcode**。
签名由 `workflow_dispatch` 的 `signing_mode` 控制，默认 `unsigned`（未签名）；
选 `developer` 时须配好 5 个签名 secret（见 `docs/SIGNING.md` §3），缺任一 secret 直接报错，
不静默回退未签名。Team ID 等真实值一律取自 Secrets，workflow 里不写死。

```bash
# 触发：push tag v*（默认 unsigned），或手动 workflow_dispatch 选 signing_mode
git tag v0.2.0-phase2 && git push origin v0.2.0-phase2
```

注意：workflow 里的 Go 引擎步骤在 `engine/libimi/main.go` 填好之前会按预期失败
（见 `docs/GO-ENGINE-C-ARCHIVE.md` §3），这是 Phase 2 的设计，不是 CI 配错了。

## Phase 2 新增文档

```
docs/CAMERA-4PRO.md              4 Pro 规格 / model 未知 / 如何抄回 model-did / 支持概率 / H.265 4K 影响
docs/MULTICAST-ENTITLEMENT.md   com.apple.developer.networking.multicast 申请流程、Xcode 配置、验证方法
docs/SIGNING.md                  开发者账号签名：Xcode 直装 / 本地导出 / Actions（secret 占位名，不含真实值）
docs/GO-ENGINE-C-ARCHIVE.md     V-01/V-02 最小验证设计：前置、cmd/libimi 改造、交叉编译步骤、失败速查
engine/libimi/main.go.template   库入口模板草稿（须在 Mac 上按 go2rtc 源码填好才能用）
scripts/clangwrap-ios.sh         Go c-archive 交叉编译的 clang 包装脚本
IMILAN/IMILAN.entitlements       multicast entitlement 文件（获批前不要强制签名引用）
```

## 自检（Linux 可跑，不构建）

```bash
./scripts/check.sh
# 检查：文件齐全、TODO 数量、ARCHITECTURE/VALIDATION 是否齐全
```

## 下一步需要用户提供（Phase 2）

1. **4 Pro 的真实 model / did**：按 `docs/CAMERA-4PRO.md` §3 抄回来——
   首选米家 App 设备信息（型号、固件版本、IP），最好再补 IMI-LAN Windows 版“添加摄像头”列表
   或 go2rtc 日志里的 `did=` / `model=` 两个参数。**不要发完整账号、完整 MAC、整行 xiaomi:// URL。**
2. **是否愿意在 MacBook 上跑一次验证脚本**：`./scripts/build-go-engine.sh`
   （须 Xcode 16+、Go 1.23+；先按 `docs/GO-ENGINE-C-ARCHIVE.md` §3 把
   `engine/libimi/main.go.template` 填好并改名成 `main.go`，再跑；跑通后把
   `go version` / `lipo -info` / `nm` 输出贴回来）。
3. **multicast 申请**：是否已按 `docs/MULTICAST-ENTITLEMENT.md` §3 提交申请，
   或希望先不申请、用“手动填 IP 单播”绕过发现环节再补申请。
4. **Team ID**：**不要在聊天里发**。只在以下二选一的地方填：① MacBook 本地终端的环境变量
   `IMILAN_TEAM_ID`；② GitHub 仓库 Secrets 里的 `IOS_TEAM_ID`。填好后告诉一声“已填”，不用贴值。
5. 侧载偏好：Xcode 直装真机，还是 Actions 出已签名 IPA 再装（决定 `docs/SIGNING.md` 走 §1 还是 §3）。
