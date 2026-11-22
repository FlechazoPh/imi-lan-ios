# IMI-LAN iOS 独立版 — 架构设计（Phase 1 调研 + 骨架，Phase 2 验证设计）

> 状态：**调研 + 骨架 + Phase 2 验证设计，未验证，未出可安装 IPA。**
> 本文件所有结论来自浏览器公开资料（见 §9 来源），未使用 `/tmp/imi-lan` 的克隆内容，
> 未在本机运行、构建或复制上游代码。所有新代码均为本项目从零手写。
> 目标机：iPhone 18 Pro Max，iOS 27.0.1；目标：iOS 17+，arm64 only。
> 目标机型：**小米智能摄像机 4 Pro（MJSXJ36CM，3840×2160 H.265）**，详见 `docs/CAMERA-4PRO.md`。
> 用户：**已有 Apple 开发者账号**，用开发者账号侧载使用；坚持**独立 App（引擎装进 iPhone）**，
> 不转回瘦客户端/外接引擎方案（Phase 1 的过渡版建议已按用户决定作废，见 §1 与 §3 末尾）。

---

## 1. 结论先行

| 问题 | 结论 |
|---|---|
| 独立版是否可行 | **有条件可行，但不是“把安卓版直译成 iOS”**。壳 + 网页 + 扫码可以先行；引擎内嵌是最大堵点，必须单独验证 |
| 最大堵点 | **① go2rtc 不能像安卓那样跑独立二进制；② H.265 在 WKWebView/WebRTC 里解不出来**。这两点不过，独立版只能看 H.264 子码流（流畅），高清主码流要走原生 fMP4 + VideoToolbox。4 Pro 主码流是 3840×2160 H.265，堵点 ② 对它是满格影响 |
| 推荐路径 | **独立版一条路走到底**（用户已定）：先攻 V-01/V-02（Go c-archive 库化 + 补丁生效，见 `docs/GO-ENGINE-C-ARCHIVE.md`），再验 V-05/V-06（流畅→4K 高清），最后验 V-19/V-20（4 Pro 云台 + 4K）。Phase 1 的“先做过渡版”建议已作废，不再作为推荐路径 |
| Phase 2 已解堵 | **multicast entitlement 可申请**（用户有开发者账号，见 `docs/MULTICAST-ENTITLEMENT.md`）；**签名侧载可走开发者账号**（见 `docs/SIGNING.md`，默认仍未签名） |
| 4 Pro | 规格见 `docs/CAMERA-4PRO.md`；**miot model ID 未知**，支持概率中等偏高（约 60–70% 走通流畅码流），新机未验证是主要风险 |
| 不要走的路 | Swift 从零重写 miss/CS2/TUTK（工作量数月，且 IMI-LAN 的补丁逻辑、云台命令、cs2 缓冲排空都在 go2rtc 补丁里）；gomobile build 整 App（会丢掉 SwiftUI/无障碍/系统字体）；直接把 go2rtc 二进制塞进 App 包里再 `exec`（iOS 沙箱禁止执行包内二进制，审核/侧载都会被拦） |

---

## 2. 安卓版是怎么做的（研读总结）

来源：`android/README.md`、`android/build.py`、`fpk/README.md`、`fpk/gateway/qr.go`（浏览器阅读）。

### 2.1 安卓独立版 = 引擎 + 网关 + 网页，三件套全在手机里

```
┌─────────────────────────────────────────────────┐
│ Android App (io.github.imilan)                  │
│  ┌──────────────┐  ┌──────────────┐  ┌────────┐ │
│  │ go2rtc       │  │ imi-gateway  │  │ WebView│ │
│  │ (libgo2rtc)  │  │ (libimi-     │  │ web/   │ │
│  │              │  │  gateway)    │  │        │ │
│  └──────┬───────┘  └──────┬───────┘  └───┬────┘ │
│         │ 127.0.0.1:      │ 127.0.0.1:19841   │ │
│         │ 20000-29999     │ (固定, imi_app)   │ │
│         │ 随机, BasicAuth │ Cookie 认证       │ │
│  前台服务拉起两个进程，异常退出自动拉起           │
└─────────────────────────────────────────────────┘
        │ LAN (UDP 32108 发现 / CS2 / MISS)
        ▼
   米家摄像头 (xiaomi://user:cn@IP?did=&model=)
        ▲ 每次建连先向小米云端拿一次本地密钥
        │ (miss_get_vendor → vendor/CS2/TUTK, NaCl/Curve25519 + ChaCha20)
   account.xiaomi.com / sts.api.io.mi.com (仅登录/取密钥时)
```

关键点：

1. **交叉编译，不是源码直跑**：`build.py` 复用 `fpk/.build` 里已打补丁的 go2rtc 1.9.15 源码
   （按 `xiaomi-login.patch` → `xiaomi-control.patch` 顺序打补丁，哈希变了就重解包），
   再 `GOOS=linux GOARCH=arm64` 编出 `libgo2rtc.so` / `libimi-gateway.so`，
   以 `jniLibs/<abi>/lib*.so` 的名字放进 APK。
   Android 只有 `nativeLibraryDir` 允许应用直接执行文件，所以必须
   `useLegacyPackaging=true` + `extractNativeLibs="true"`。
2. **网关是安全边界**：Android 的 `127.0.0.1` 是所有应用共享的，所以 go2rtc 模板默认开
   `api.local_auth: true`，账号 `imi`、密码首次启动随机生成（存 App 私有 prefs）。
   网关反代 `/api` 时自动注入 Basic Auth；网关另带 `-app-token`，
   WebView 通过 `CookieManager` 写 `imi_app=<随机令牌>`，API 只经网关代理，
   同机其他应用拿不到小米 token。`/health` 免令牌。
3. **扫码登录不用 Node**：`fpk/gateway/qr.go` 是从 `qr-login.js` 移植的 Go 实现。
   流程（`qr.go` 头注释）：① 向 `account.xiaomi.com` 申请二维码并长轮询扫码结果；
   ② 把扫码那一刻的完整云端凭据（`serviceToken/ssecurity/cUserId/passToken`）
   写回 `go2rtc.yaml` 的 `xiaomi-credentials` 段，`passToken` 另存 `xiaomi:` 段；
   ③ 通过 go2rtc `/api/restart` 重启引擎；④ `/rooms` 只做只读云端查询。
   注释原话：*“安卓版需要这一段是因为手机上无法运行 Node。fnOS 版仍可使用原来的 [qr-login.js]”*。
4. **安卓特有的坑**：没有 `/etc/resolv.conf`，Engine 从 `ConnectivityManager` 读当前 DNS，
   用 `IMI_DNS` 环境变量传给引擎；用 APK 内置 `ca.pem` 作 `SSL_CERT_FILE`，
   否则 Go 的 x509 找不到系统根证书。
5. **播放**：WebView 壳 + `web/`（`index.html/app.js/style.css/video-rtc.js/video-stream.js`）。
   安卓 WebView 对 H.265 支持参差，网页检测到 `IMIAndroid.preferSD()` 后默认走「流畅」子码流，
   导入时直接把地址落成子码流。截图/录像不走 `<a download>`，而是经 `IMIAndroid` JS 桥
   分块 base64 写系统相册 `Pictures/IMI-LAN`、`Movies/IMI-LAN`。
6. **端口/数据**：网页网关 `127.0.0.1:19841` 固定；go2rtc API 与 RTSP/WebRTC 在
   `127.0.0.1:20000–29999` 首次启动随机；配置在 App 私有目录 `files/engine/go2rtc.yaml`，
   日志 `engine.log` / `gateway.log`。RTSP 对回环免认证是残留风险（同机其他应用扫到端口就能拉流，
   拿不到云端 token；后续版本拟改 unix socket 或关 RTSP）。
7. **fnOS 版对照**：引擎是交叉编译的 Linux 版（同补丁），`1984/tcp` 是唯一对外 HTTP 端口
   （网页/API/WebRTC 信令/扫码助手合并），`8555/tcp+udp` 是 WebRTC 音视频，
   内部 `127.0.0.1:1985` 扫码助手、`1986` go2rtc API、`8554` RTSP 不对外。

### 2.2 web/ 是怎么播放的

- go2rtc 是 AlexxIT 的 Go 流媒体网关：拉一次流（`xiaomi://{account}:{region}@{IP}?did=&model=`），
  再以 WebRTC（低延迟，默认 8555）、MSE/MP4、HLS、MJPEG、RTSP 多种形式分发。
  默认 API 1984，RTSP 8554，WebRTC 8555。
- IMI-LAN 的网页用 `video-rtc.js`（取自 go2rtc 播放器，MIT）做 WebRTC，失败自动退回 MSE；
  卡片右下角显示 `RTC` 或 `MSE`。高清/流畅按型号映射 `subtype`（`web/app.js` 的 `QUALITY_BY_MODEL`）。
- 云台不走云端，复用视频连接里的命令通道（`miss` 的 `cmdMotorReq = 0x112`），
  桌面版由打了 `xiaomi-control` 补丁的 go2rtc 提供 `/ptz` 与 `/ptz/spec`。
  另有一个已修的坑：命令通道登录后没人读，`cs2` 接收缓冲（10 条）会被填满导致连接失效，
  表现为部分机型（如 C700）约每 110 秒断流一次、日志刷 `cs2: pop buffer is full`，
  客户端需常驻排空该通道。

### 2.3 目标机型：小米智能摄像机 4 Pro（Phase 2 新增）

详见 `docs/CAMERA-4PRO.md`，这里只记架构层面的结论：

- **硬件型号 MJSXJ36CM，3840×2160 8MP 4K，H.265，双频 Wi-Fi 6，云台水平 360°/垂直 106°，2026-10-13 发售。**
- **miot model ID 未知**：公开搜索未找到，IMI-LAN 已验证列表里也没有它。`Camera.swift` 里 4 Pro 的
  `model` 填 `unknown (MJSXJ36CM)` 是占位，不是真实 ID；拿到真实值之前无法确定协议分支与 `subtype` 映射。
- **支持概率**：中等偏高（约 60–70% 走通流畅码流）。依据是 IMI-LAN README 的“2020 年后大多走统一 miss 协议”；
  风险是新机未验证、model 未知、4K 高清待验。三步独立验证：流畅 → 4K 高清 → 云台，不要混在一起判断。
- **播放影响**：流畅（H.264 子码流）走 WKWebView WebRTC，预期可行；高清（H.265 3840×2160）走 WKWebView WebRTC
  预期不行，必须走原生 fMP4 + VideoToolbox（`Fmp4Player.swift`），且首版默认画质应为“流畅”，不要默认全开 4K。
- **云台**：`miss cmdMotorReq=0x112` 预期适用，但未验证；IMI-LAN 对未收录型号默认显示云台开关，
  有开关不等于按了会转（见 `docs/CAMERA-4PRO.md` §6）。
- **不在范围内**：微信通话 / OK 手势呼叫、全天超省录制、4K 延时摄影是米家 App 的功能，不在本 App 实现。

### 2.4 iOS 能复用的部分 vs 不能复用的部分

| 部分 | 能否复用 | 说明 |
|---|---|---|
| go2rtc 协议逻辑（miss/CS2/TUTK、xiaomi-login/control 补丁、取密钥流程） | ✅ 逻辑复用，形式要改 | 协议本身与平台无关；但不能复用“编成独立二进制再 exec”的部署形式 |
| `web/` 前端（布局、画质映射、重连、云台 UI） | ✅ 大部分复用 | 需做 iPhone 适配：竖屏、触摸目标 ≥44pt、safe-area、灵动岛、禁止页面级缩放（见 §6）。`web/` 本身不在本仓库里，Phase 2 才从上游取（需用户确认来源/版本） |
| 网关鉴权思路（随机 app token + Cookie、API 只经网关、local_auth） | ✅ 思路复用 | iOS 上 `127.0.0.1` 同样是全机共享，必须保留这层；token 改存 Keychain，不存 UserDefaults/plist |
| Go 版扫码登录（`qr.go` 的流程） | ✅ 流程复用 | 若走 Go 内嵌路线，直接复用同一份 Go 代码是最顺的；若走 Swift 原生，需用 URLSession 重写同款流程（见 §5） |
| 安卓的“前台服务常驻 + 通知栏重启/停止” | ❌ 机制不同 | iOS 没有 Android 前台服务；只能用 Background Modes（audio / fetch / processing）+ 后台任务，且随时可能被系统杀掉，见 §7 |
| 安卓的 `jniLibs/*.so` + `exec` 拉起 | ❌ iOS 禁止 | 见 §4 |
| 安卓的 DNS/CA  workaround | ⚠️ 部分类似 | iOS 上 Go 的 x509/DNS 同样要处理：需显式传系统 CA 或用 `SSL_CERT_FILE` 思路的等价物，待验证（VALIDATION 清单 V-08） |
| 截图/录像经 JS 桥写相册 | ✅ 思路复用，API 不同 | iOS 用 `WKScriptMessageHandler` + PhotoKit（`PHPhotoLibrary`，需 `NSPhotoLibraryAddUsageDescription`） |

---

## 3. iOS 独立版架构（本骨架采用的设计）

```
┌──────────────────────────────────────────────────────────────────┐
│ IMI-LAN iOS App (SwiftUI, iOS 17+, arm64, Bundle: imi.lan.ios)   │
│                                                                  │
│  ┌────────────────── SwiftUI 层 ──────────────────────────────┐  │
│  │ ContentView: 竖屏网格 (1列/2列) · 单画面 · 设置 · 日志      │  │
│  │ CameraGridView / CameraCardView / SingleCameraView          │  │
│  │ SettingsView (引擎地址/扫码登录占位/画质/后台)              │  │
│  └──────────────────┬──────────────────────────────────────────┘  │
│                     │ WKScriptMessageHandler (IMIShell)          │
│  ┌──────────────────▼──────────────────────────────────────────┐  │
│  │ WKWebView 壳 (WebViewContainer)                             │  │
│  │  · 加载本地网关 http://127.0.0.1:19841/ (TODO: 待引擎接入)  │  │
│  │  · 注入 imi_app Cookie / 随机令牌 (Keychain)                 │  │
│  │  · JS 桥: 截图/录像/全屏/画中画/分享 → Swift (PhotoKit 等)   │  │
│  │  · H.264 子码流: WebRTC (WKWebView 内) — 可行                │  │
│  │  · H.265 主码流: 见 §7 — WKWebView WebRTC 不解，需原生通道   │  │
│  └──────────────────┬──────────────────────────────────────────┘  │
│                     │ http://127.0.0.1:19841 (网关, TODO)        │
│  ┌──────────────────▼──────────────────────────────────────────┐  │
│  │ 本地网关 (Go, 与安卓同款 fpk/gateway 思路 — TODO: 内嵌)      │  │
│  │  · 反代 go2rtc /api (自动注入 Basic Auth)                    │  │
│  │  · /qr/new · /qr/status · /rooms (扫码登录, Go 版)           │  │
│  │  · 只监听 127.0.0.1, 随机 app token, /health 免令牌           │  │
│  └──────────────────┬──────────────────────────────────────────┘  │
│                     │ 127.0.0.1:随机端口 (TODO)                  │
│  ┌──────────────────▼──────────────────────────────────────────┐  │
│  │ go2rtc 引擎 (Go, 已打 xiaomi-login/control 补丁 — TODO)      │  │
│  │  · 以 c-archive 静态库内嵌进 App 进程内运行 (见 §4, 首选)    │  │
│  │  · 配置: App 沙箱 Application Support/engine/go2rtc.yaml     │  │
│  │  · 日志: engine.log / gateway.log (EngineLogView 查看)        │  │
│  └──────────────────┬──────────────────────────────────────────┘  │
│                     │ LAN: UDP 32108 发现 / CS2 / MISS           │
│                     ▼                                            │
│              米家摄像头 (同安卓)                                 │
└──────────────────────────────────────────────────────────────────┘
```

**过渡版（Phase 1A，已作废，用户已定独立版）**：把图中“本地网关 + go2rtc 引擎”两层先放在家里 MacBook
（或 Windows，改监听为局域网地址）上跑，iPhone 只跑上半部分（SwiftUI + WKWebView）。
Phase 1 时曾推荐先用它验证播放/H.265/适配；**Phase 2 用户已明确坚持独立 App，不再走这条路**，
本段仅作记录：若 V-01 被证明不可行，才作为兜底重新讨论。
骨架里的 `EngineManager.mode = .remote` 就是为这一步留的开关，`SettingsView` 有“引擎地址”一栏，
独立版模式下默认 `mode = .local`。

---

## 4. go2rtc 在 iOS 上必须走的路 — 三条路线评估

### 4.0 为什么不能照搬安卓

- iOS 沙箱**禁止执行 App 包内的独立二进制**（没有 `execve` 可执行权限的出路；
  即使把 Mach-O 塞进包里，签名/沙箱也会拦，侧载也一样）。
- iOS 也没有 Android 的 `nativeLibraryDir` + 前台服务那套“拉起两个进程”的机制。
- 所以引擎必须**跑在 App 进程内**，以库的形式被 Swift 调用，而不是以子进程的形式被拉起。

### 4.1 路线 A（首选）：Go 编成 c-archive 静态库，内嵌进 App 进程

- 做法：参考 Go 官方 `c-archive` / `c-shared` 机制与 rogchap 的做法：
  `CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC=<clangwrap.sh>`，
  用 `xcrun --sdk iphoneos --find clang` 做交叉编译器，
  `go build -buildmode=c-archive -o libgo2rtc.a ./cmd/libimi`，
  再用 `lipo` 合并 arm64（真机）与 arm64-simulator（模拟器，如需）；
  在 Go 侧用 `//export` 导出 `IMIStartEngine(configPath, logPath) / IMIStopEngine() / IMIEngineStatus()`，
  Swift 侧经 Objective-C Bridging Header 调用。
- 关键改造（均未验证，见 VALIDATION）：
  1. go2rtc 的 `main()` 要改成可多次启动/停止的库入口：`main` 包不能直接 `os.Exit`，
     信号处理、全局单例、端口监听都要改成可重入；`go2rtc.yaml` 路径、日志路径要改成 App 沙箱路径。
  2. `pion/webrtc` + `miss/cs2` 的 UDP/TCP、mDNS 发现（UDP 32108）在 iOS 沙箱内是否受限，
     需真机验证；`Network` framework 的本地网络权限（`NSLocalNetworkUsageDescription`、
     `com.apple.developer.networking.multicast` entitlement）需要申请。
     **Phase 2 更新**：用户已有开发者账号，该 entitlement 已可申请（流程、Xcode 配置、
     验证方法见 `docs/MULTICAST-ENTITLEMENT.md`；`IMILAN/IMILAN.entitlements` 已预置，
     获批前不要强制签名引用）。
  3. Go runtime + cgo 在 iOS 上的线程/信号模型：Go 的 `SIGURG` 等信号与 iOS 的 Jetsam 交互，
     需验证长时间运行不被杀。
  4. 体积：go2rtc 二进制约 30MB，静态库 + Swift App 预计 40–60MB，可接受。
- 可行性：**中高**。这是 gomobile 底层也在用的机制，有公开先例（rogchap、gaitatzis），
  且安卓版已经证明“同一份 Go 代码 + 补丁”可以在移动端跑。
  但 go2rtc 不是一个小库，它带 HTTP server、WebRTC、RTSP、mDNS、ffmpeg 调用（iOS 上无 ffmpeg，
  需关掉转码兜底，只留原生解码），改造成本在“库化”这一步，不在协议本身。
- 风险：**高**。任何一个环节（库化、mDNS、UDP、后台被杀）失败，整条路都要回退到过渡版。

### 4.2 路线 B（备选）：gomobile bind 生成 XCFramework

- 做法：`gomobile bind -target=ios -o IMIEngine.xcframework ./engine`，生成 Obj-C 绑定，
  Swift 直接调 Go 的 struct/method。
- 优点：绑定代码自动生成，类型安全；与路线 A 同源，只是换了胶水层。
- 缺点：gomobile 是实验性项目（Go 官方文档自述 *experimental, use at your own risk*），
  对 `main` 包、全局状态、复杂类型（channel、callback）支持差；go2rtc 的体量下，
  bind 生成的接口会非常臃肿，且每次 go2rtc 升级都要重新验证绑定。
- 结论：**可作路线 A 的胶水替代，不作主路线**。若路线 A 的手写 `//export` 胶水太薄，
  再评估是否换 gomobile。

### 4.3 路线 C（不推荐）：Swift 从零重写 miss/CS2/TUTK

- 工作量：miss（命令层，`[BE u32][JSON]` + ChaCha20 + 8 字节 nonce）、CS2（PPPP 家族传输，
  UDP 32108 发现、`0x41` punch、`0x42/0x43` ready）、TUTK 会话、NaCl box Curve25519 共享密钥、
  云端签名（`miss_get_vendor`）、RDT 文件通道、云台 `cmdMotorReq=0x112`、
  cs2 接收缓冲排空（110 秒断流坑）——全部要在 Swift 里重写并与摄像头逐型号联调。
- 结论：**不推荐**。这是数月工作量，且 IMI-LAN 的价值恰恰在 go2rtc 补丁里，
  重写等于放弃上游。仅当路线 A/B 都被证明不可行时才考虑，且应先只做 CS2 单型号概念验证。

### 4.4 路线 D（过渡/兜底）：引擎留在家里电脑/NAS 上，iPhone 只做播放器

- 即 §3 的 Phase 1A。不是“独立版”，但能立即交付可用体验，且是验证播放/H.265/适配的必经之路。
- 若路线 A 最终失败，D 就是最终形态，iPhone 端仍有价值（原生播放器 + fMP4/VideoToolbox 高清路）。

---

## 5. 扫码登录在 iOS 上用什么替代

### 5.1 现状

- 桌面/fnOS：`qr-login.js`（Node，监听 `127.0.0.1:19841/1985`）。
- 安卓：`fpk/gateway/qr.go`（Go 移植，注释说“手机上无法运行 Node”）。
- iOS：**同样无法运行 Node**，所以 Node 版不能直接用。

### 5.2 推荐：复用 Go 版（与路线 A 同路）

- 若引擎走 Go c-archive，扫码登录就**直接复用同一份 Go 代码**（`qr.go` 的流程），
  由网关层提供 `/qr/new`（取二维码图片）、`/qr/status`（长轮询扫码结果）、`/rooms`。
- Swift 侧只做 UI：`QRLoginView` 显示二维码图片（`UIImage(data:)`）、轮询状态、
  成功后提示“已写入本机配置，引擎重启约 1–2 秒”。
- 优点：不用重写小米登录协议（`account.xiaomi.com` 的 JSONP、Cookie、签名、风控逻辑都在 Go 里），
  与安卓/fnOS 行为一致。

### 5.3 备选：Swift 原生重写（URLSession）

- 若 Go 内嵌失败、但仍想做独立版，才考虑。
- 需重写：`GET account.xiaomi.com` 申请二维码（`sid=xiaomiio`、`_qrsize=480` 等参数）、
  解析 JSONP（`&&&START&&&` 标记）、长轮询 `lp`、扫码成功后换 `serviceToken/ssecurity/cUserId/passToken`、
  写回 `go2rtc.yaml` 的 `xiaomi-credentials` / `xiaomi:` 段、调 `/api/restart`。
- 风险：小米风控（70016“需要验证”）与两步验证的处理都在这套流程里，重写容易踩坑；
  且 `qr.go` 里对 Cookie、重定向（最多 6 跳）、超时的处理都要逐一对齐。
- 结论：**备选，不作首选**。骨架里的 `QRLoginView` 已按“Swift UI + 后端接口”分层，
  后端是 Go 还是 Swift，对 UI 没有影响。

### 5.4 密码登录

- 保留“账号密码”入口作兜底，但 README 已注明：小米账号开两步验证时密码登录会报
  `xiaomi: 404 Not found`，需先在米家 App 里临时关闭两步验证，登录成功后再打开。
  骨架里已把这句提示写进 `QRLoginView`。

---

## 6. 本地网关鉴权 + token 存 Keychain

| 项 | 设计（骨架已实现/占位） |
|---|---|
| 网关地址 | `http://127.0.0.1:19841`（独立版，固定）；过渡版为用户在设置里填的局域网地址（`SettingsView.engineAddress`） |
| App 令牌 | 首次启动随机生成 32 字节（`SecRandomCopyBytes`），存 Keychain（`KeychainStore.appToken`），不存 UserDefaults；WebView 通过 Cookie `imi_app=<token>` 注入（`WebViewContainer`） |
| go2rtc API 认证 | 网关反代 `/api` 时自动注入 Basic Auth（账号 `imi`、密码首次启动随机生成，存 Keychain 的 `gatewayPassword` 项）；网页/扫码助手感知不到，与安卓一致 |
| 小米令牌 | 只存两处：① `go2rtc.yaml` 的 `xiaomi:` / `xiaomi-credentials` 段（App 沙箱 `Application Support/engine/`，文件权限 600）；② **不**在 Keychain 里再存一份明文 token（避免两处不同步）。Keychain 只存“网关密码 + app token” |
| 日志脱敏 | 日志里只记脱敏账号（`uid[:2] + "****" + uid[-2:]`，与 `qr.go` 的 `maskUID` 一致）；往外发日志前删掉配置绝对路径、摄像头 IP、设备 ID |
| 卸载 | 删 App 即删沙箱配置 + Keychain 项（Keychain 项用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不进 iCloud 钥匙串同步） |
| 待验证 | iOS 上 `127.0.0.1` 是否同样全机共享（与安卓同理，需验证其他 App 能否扫到端口；VALIDATION V-07）。若是，RTSP 必须默认关闭或只绑 unix socket（安卓 README 已标为残留风险） |

---

## 7. iOS 手机适配 + H.265 / 后台 / 发热限制

### 7.1 播放路径（关键结论）

| 码流 | 路径 | 状态 |
|---|---|---|
| H.264 子码流（流畅） | WKWebView 内 WebRTC（`video-rtc.js`） | ✅ 可行。iOS 原生 WebRTC 只硬件加速 H.264；WKWebView 的 WebRTC 栈对 H.264 支持成熟 |
| H.265 主码流（高清） | WKWebView 内 WebRTC | ❌ **不行**。公开资料一致：WebRTC 的 stock framework 不带 HEVC 编解码器；Safari/WebKit 虽已支持 HEVC WebRTC（需硬件），但 WKWebView 内嵌的 WebRTC 仍不可靠。CrumbVMS 的实测结论是：*“H.265/HEVC does not (no browser HEVC WebRTC decode)”*，所以他们为 H.265 另走了 fMP4 路 |
| H.265 主码流（高清） | **原生 fMP4 + VideoToolbox**（推荐） | ✅ 方向正确。go2rtc 提供 `/api/stream.mp4`（fMP4 passthrough，H.265 保持 H.265），Swift 侧增量 demux 成 `CMSampleBuffer`，用 VideoToolbox 硬解，`AVSampleBufferDisplayLayer` 显示。CrumbVMS 已用这条路跑通 iOS/macOS 全分辨率。需注意 `hev1` vs `hvc1`：ffmpeg `-c copy` 打的 `hev1` 样条 AVFoundation 拒解，需转 `hvc1` |
| H.265 主码流 | MSE/MP4 兜底 | ⚠️ 仅作兼容兜底，延迟与稳定性不如 WebRTC/fMP4 |

**骨架的取舍**：Phase 1 只实现 WKWebView 壳（H.264 路先通），`Fmp4Player` 以 TODO 占位文件列出，
不假装 H.265 已解决。`CameraCardView` 已有“高清/流畅”切换 UI，但高清在未验证前默认提示“待验证”。

### 7.2 iPhone 适配（骨架已实现）

- 竖屏优先：单列（1×1）/双列（2×2）网格可切换，`LazyVGrid` + `GeometryReader` 自适应；
  横屏自动切 3 列（`CameraGridView` 按 `verticalSizeClass` 判断）。
- 安全区：`safeAreaInset` + `ignoresSafeArea(.container, edges: .bottom)` 只用在全屏播放，
  顶部用 `.toolbar` 而不用自定义顶栏顶到灵动岛；`CameraCardView` 的工具按钮 ≥44pt。
- 灵动岛 / 刘海：不把关键按钮放在顶部中央；全屏时用 `AVSampleBufferDisplayLayer` 的层级，
  不用 DOM 全屏（安卓 README 已注明 DOM 全屏会另起视图导致网页控件消失，iOS 同理）。
- 手势：单击隐藏/显示控件、双击退出单画面、双指捏合仅在“放大镜”模式下启用（与安卓一致），
  骨架里以 `SingleCameraView` 的手势占位实现。
- 画中画：入口已留（`CameraCardView` 的 PiP 按钮），实现需 `AVPictureInPictureController` +
  `AVPlayerLayer`，WKWebView 内的 `<video>` 需 `playsinline` + `webkit-playsinline`，
  待 Phase 2 验证（VALIDATION V-05）。
- 触摸目标：`style.css` 的 `@media (pointer: coarse)` 思路在 Swift 侧对应为
  `.frame(minHeight: 44)` + `.contentShape(Rectangle())`。

### 7.3 后台 / 发热 / 功耗

- iOS 没有 Android 前台服务：App 切后台 2 分钟后系统可能挂起网络（`URLSession` 后台任务除外），
  go2rtc 引擎在 App 进程内，切后台后若无 Background Mode 会被挂起/杀掉。
- 骨架已声明的 Background Modes（`Info.plist`）：`audio`（保持音频会话不断流）、
  `fetch`（后台拉取）、`processing`（后台处理）。**注意**：这些都不能保证“一直跑”，
  只是延长存活；真正的 7×24 监控仍需家里服务器常开，手机端只作“查看器”。
- 发热：H.265 硬解（VideoToolbox）发热可控；若误走软解（VP8/VP9/AV1 或 H.265 软解），
  CPU 与电池会明显上升。骨架的 `EngineManager` 已留 `thermalState` 监听占位，
  后续按 `ProcessInfo.thermalState` 降画质（高清→流畅）。
- 多路：同时 4 路 H.265 硬解在 iPhone 18 Pro Max 上理论上可行，但需真机测功耗与发热；
  骨架默认 2×2，上限 4 路，超过 4 路提示“先在过渡版上验证”。

---

## 8. 文件清单（骨架）

```
imi-lan-ios/
├── README.md                    # 项目说明 + 状态 + 快速开始（MacBook / Actions）
├── ARCHITECTURE.md              # 本文件
├── VALIDATION.md                # 验证清单（V-01…V-12，未验证项）
├── IMILAN.xcodeproj/
│   └── project.pbxproj          # 手写最小工程（未在 Xcode 打开验证，见 README）
├── IMILAN/
│   ├── IMILANApp.swift          # @main, App 入口, EngineManager 注入
│   ├── ContentView.swift        # 根视图：网格 / 单画面 / 设置 Tab
│   ├── Info.plist               # 权限：本地网络/相机(扫码)/相册/后台模式
│   ├── Models/Camera.swift      # Camera / EngineStatus / StreamQuality
│   ├── Engine/
│   │   ├── EngineManager.swift  # 引擎生命周期占位：start/stop/restart/status
│   │   ├── GoEngineBridge.h     # c-archive 桥接头占位（TODO: 待 libgo2rtc.a）
│   │   └── GoEngineBridge.swift # Swift 侧桥接占位（TODO）
│   ├── Web/
│   │   ├── WebViewContainer.swift  # WKWebView 壳 + IMIShell JS 桥 + Cookie 注入
│   │   ├── LocalGateway.swift      # 本地网关占位：127.0.0.1:19841, app token
│   │   └── Fmp4Player.swift        # TODO: fMP4 + VideoToolbox 高清路占位
│   ├── Auth/
│   │   ├── KeychainStore.swift  # Keychain: app token / gateway password
│   │   └── QRLoginView.swift    # 扫码登录 UI + 轮询占位 + 两步验证提示
│   ├── Views/
│   │   ├── CameraGridView.swift # 1列/2列/横屏3列网格
│   │   ├── CameraCardView.swift # 卡片：画面/信号/画质切换/PiP/截图
│   │   ├── SingleCameraView.swift # 单画面：手势/云台方向盘占位
│   │   ├── SettingsView.swift   # 设置：引擎地址/画质/后台/日志入口
│   │   └── EngineLogView.swift  # 日志查看（engine.log/gateway.log）
│   └── Resources/
│       └── Assets.xcassets/     # AppIcon 占位 + 颜色
├── scripts/
│   ├── build-ipa-local.sh       # MacBook 本地打包未签名 IPA（需 Xcode）
│   ├── build-go-engine.sh       # TODO: Go c-archive 交叉编译脚本（未验证，占位）
│   └── check.sh                 # 骨架自检：文件齐全/占位统计（Linux 可跑）
└── .github/workflows/
    └── build-ipa.yml            # GitHub Actions macos runner 打未签名 IPA
```

---

## 9. 来源

- IMI-LAN README（浏览器）：`https://github.com/pigstrong9/IMI-LAN`
- IMI-LAN Releases 1.0.2 / 1.0.3（浏览器）：同仓库 `/releases`
- `android/README.md`（浏览器）：同仓库 `blob/main/android/README.md`
- `android/build.py`（浏览器）：同仓库 `blob/main/android/build.py`
- `fpk/README.md`（浏览器）：同仓库 `blob/main/fpk/README.md`
- `fpk/gateway/qr.go`（浏览器，头注释 + 流程）：同仓库 `blob/main/fpk/gateway/qr.go`
- go2rtc 官方文档 / README（搜索）：`AlexxIT/go2rtc`，默认 API 1984 / RTSP 8554 / WebRTC 8555，
  WebRTC/MSE/HLS/MJPEG/RTSP 多路分发；Xiaomi 源为 `xiaomi://` + `miss`/`legacy` 两路，
  云端只发签名、视频只走局域网（DeepWiki / privatehomelab / lazyharu 的 go2rtc Xiaomi 分析）
- Go c-archive / gomobile（搜索）：`rogchap.com`（`go build -buildmode=c-archive` + clangwrap.sh + lipo）、
  `go.dev/talks/2015/gophercon-go-on-mobile.slide`（gomobile experimental）、
  `pkg.go.dev/github.com/field-mouse/gomobile/cmd/gobind`
- iOS H.265 / WebRTC（搜索）：CrumbVMS `docs/IOS-APP-PLAN.md`（WKWebView WebRTC H.264 可行、H.265 不行，
  另走 fMP4 + VideoToolbox）、ForaSoft WebRTC iOS Guide 2026（原生 WebRTC 只硬件加速 H.264，
  HEVC 无编解码器）、WebKit HEVC WebRTC 相关讨论
- 小米智能摄像机 4 Pro（Phase 2，搜索 2026-11-22）：说明书（MJSXJ36CM、3840×2160、
  Wi-Fi 802.11a/b/g/n/ac/ax 2.4GHz/5GHz、蓝牙 5.4）、新浪科技 2026-11-04（发售 2026-10-13、
  800 万像素 4K、双电机水平 360°/垂直 106°、双频 Wi-Fi 6）；
  `MJSXJ36CM miot model chuangmi.camera` 公开搜索无结果（model ID 未知，见 `docs/CAMERA-4PRO.md` §2）
- Apple multicast entitlement（Phase 2，搜索 2026-11-22）：申请表单
  https://developer.apple.com/contact/request/networking-multicast；
  Apple 开发者论坛 Quinn《Using the Multicast Special Entitlement》（New Process）；
  NuvioMobile-Ultra `docs/ios-multicast-entitlement.md`；Xojo 论坛《iOS Multicast Setup & Best Known Methods》
- Go c-archive iOS（Phase 2，搜索 2026-11-22）：Tailscale libtailscale Makefile
  （`GOOS=ios GOARCH=arm64 CC=clangwrap-ios.sh`，模拟器 `lipo -create`）；
  v2ray-core Discussion #3171（`CC=$GOROOT/misc/ios/clangwrap.sh`）；
  gaitatzis《Compile GoLang as a Mobile Library》；Ikemen GO iOS 移植
- GitHub Actions iOS 签名（Phase 2，搜索 2026-11-22）：Project-Phoenix-MP `GITHUB_ACTIONS_SETUP.md`
  （`BUILD_CERTIFICATE_BASE64` / `P12_PASSWORD` / `PROVISION_PROFILE_BASE64` /
  `KEYCHAIN_PASSWORD` / `TEAM_ID` 五件套）；sasikanth.dev《Managing iOS signing certificates…》；
  andrewhoog.com《How to build an iOS app with GitHub Actions》

> 以上来源均为公开资料的浏览器阅读结果，未复制其代码文件。本骨架代码为从零手写。
