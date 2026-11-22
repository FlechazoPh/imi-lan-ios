# 验证清单 — IMI-LAN iOS 独立版（Phase 2）

> 全部未验证。每一项都要在真机（iPhone 18 Pro Max，iOS 27.0.1）或 MacBook 上实测通过后才能打勾。
> 不要凭推测把任何一项标成已通过。
>
> Phase 2 更新（2026-11-22）：
> - 目标机型已定：**小米智能摄像机 4 Pro（MJSXJ36CM）**，见 `docs/CAMERA-4PRO.md`。
> **model 已验证：`xiaomi.camera.091ac1`**（2026-11-22 经 IMI-LAN Windows v1.0.3
> `/api/xiaomi` 拿到，默认码流 H.265 1080p 首帧 0.66 秒出流成功；4K/fluent
> subtype 待另一路验证，不等它，先按默认码流推进）。
> - 用户已有 **Apple 开发者账号**：V-03 的 multicast 不再是“无账号即堵死”，改成“可申请、待审批”；
> 新增 V-18（multicast 申请与配置）、V-21（开发者账号签名）。
> - 用户坚持**独立 App**：V-16（过渡版）已作废，不再作为必经验证；V-01 失败时的兜底才重新讨论它。
> - **本机 Linux 未验证**：本机上无 Go/Swift/Xcode，V-01/V-02/V-14/V-15 的
> 构建类验证一律须在 MacBook / macOS runner 上跑，本机只做文件齐全检查
> （`scripts/check.sh`），不要把“check 通过”当成“构建通过”。

## 0. 前置：先拿到的东西（不做完不要开 V-01 之后的真机验证）

- [x] **V-00a 4 Pro 的 model / did 已抄回**：2026-11-22 已验证——
model `xiaomi.camera.091ac1`（非 `chuangmi.*` 系），IP 192.168.1.100（示例地址，真实局域网 IP 不公开），
固件 5.3.4_0934，默认码流 H.265 1080p 出流成功。`Camera.swift` 的 4 Pro
条目已同步为此 model。4K/fluent subtype 仍待验证，不阻塞 V-01/V-02。
- [] **V-00b 开发者账号可用**：Xcode → Settings → Accounts 里已登录开发者账号，
能选 Team（Team ID 不要发聊天，只在本地终端 / GitHub Secrets 里填，见 `docs/SIGNING.md`）。
- [] **V-00c MacBook 验证环境就绪**：Xcode 16+、Go（版本以 go2rtc `go.mod` 为准，
`scripts/build-go-engine.sh` Step 1 会对照打印）、
`xcodebuild -version` 与 `go version` 均能输出（本机 Linux 上两者均不存在，已确认，勿在本机跑）。

## 1. 引擎内嵌（最大堵点）

- [x] **V-01 Go c-archive 库化（构建部分已通过，真机调用待 V-02）**：2026-11-22
Actions 第 5 轮（runs/44998301043）成功：`libgo2rtc.a` 编出（`lipo` 含 arm64，
`nm` 找到三个导出函数）、Swift 侧已链接并调用 `IMIStartEngine`（桥接头通过，
`-lresolv` 已补）。IPA 已出（见下）。**未验证的仍是真机上的事**：引擎在真机上
是否真能启动、端口是否监听、多次启停与 `IMIStopEngine` 是否释放端口，须真机实测。
  - **验收标准（全部满足才算通过）**：
    1. `lipo -info build/libgo2rtc.a` 含 `arm64`；
    2. `nm -g build/libgo2rtc.a` 能找到 `IMIStartEngine / IMIStopEngine / IMIEngineStatus`；
    3. `libgo2rtc.h` 里有三者声明；
    4. Swift 侧能链接、能调用 `IMIStartEngine` 且返回的不是“未接入”错误；
    5. `IMIStopEngine` 幂等（未运行也返回 0）。
    通过标准只是“库能编出、能链接、能调用”，不是“能看画面”，更不是“可多次启停”。
  - **前置（见 docs/GO-ENGINE-C-ARCHIVE.md §2 P-0…P-6）**：MacBook/macOS runner、
    Xcode 16+、Go（版本以 go2rtc `go.mod` 为准）、go2rtc 1.9.15 源码、
    两个补丁、`engine/libimi/main.go` 已按模板 §A 填好（无 `TODO`、无 `RunUntilSignal`）。
  - **关键事实（已按 1.9.15 源码纠正）**：go2rtc 没有单一 `Run()`/`Start()` 入口；
    入口是根 `main.go` 的模块列表（`app.Init` → **45 个** `Init()`，
    libimi 保留 42 个，排除 exec、ffmpeg、onvif → 阻塞式信号等待，
    **1.9.15 没有 `streams.SetReady()` 调用**）。libimi 把该列表原样抄过来，
    换掉最后的信号等待，见 `engine/libimi/main.go` 文件头注释。
  - **多次启停未验证**：`flag.Parse()` 与各模块 `Init()` 大概率不是幂等的；
    首版只保证单次启动 + 幂等停止，第二次启动必须返回错误，不要谎报成功。
    只有实测证明可重入、且 `IMIStopEngine` 真能释放监听端口之后，才补标“可多次启停”。
  - **在 MacBook 上跑的逐条命令（仓库根目录，先跑第一条）**：
    ```bash
    ./scripts/build-go-engine.sh
    # 预期：Step 0 预检通过 → Step 1 打印 go.mod 的 go 版本与本机 go version →
    # Step 1b/2 补丁 dry-run 通过 → Step 3 要求 engine/libimi/main.go 已填好 →
    # Step 4 编出 build/libgo2rtc-arm64.a → Step 6 lipo/nm 校验通过 → Step 7 交接 vendor/。
    # 首次跑之前先填模板：cp engine/libimi/main.go.template engine/libimi/main.go
    # 再按模板 §A 的 grep 清单在 build/go2rtc-src/ 里核对并填好。
    # 补丁缺失时默认报错；要自动取补丁才加 FETCH_PATCHES=1（并核对打印的 commit SHA）。
    # 模拟器库另加：./scripts/build-go-engine.sh --simulator
    ```
    本机 Linux 上跑同一条命令会在 Step 0 预检退出（`go: command not found`），
    这是预期的，**不是** V-01 失败。
- [] **V-02 补丁在 iOS 上同样生效**：
`xiaomi-login.patch` + `xiaomi-control.patch` 打到 go2rtc 1.9.15 源码上后，
库版引擎扫码登录不报 `401`，且 `/ptz` 与 `/ptz/spec` 接口存在。
  - **验收标准**：① 同源码编的 macOS 版作对照，扫码登录不报 `401`；
    ② 库版引擎同样不报 `401` 且能拿到 4 Pro（`xiaomi.camera.091ac1`）的密钥；
    ③ `GET /ptz/spec` 与 `POST /ptz` 存在（404 即补丁未生效）；
    ④ `/api/streams` 里 4 Pro 的流在列表里。
  - **验证顺序**见 `docs/GO-ENGINE-C-ARCHIVE.md` §7（先在 Mac 上用同源码编的 macOS 版对照，再上真机）。
  - 另须验证 cs2 缓冲排空：命令通道常驻读，4 Pro 不出现约 110 秒断流、`cs2: pop buffer is full`。
  - 注意：`api/restart` 在库版里必须禁掉（它会重执行二进制），以源码 grep 为准，不要猜。
- [] **V-03 LAN 发现与 CS2**：UDP 32108 发现、`0x41` punch、`0x42/0x43` ready
在 iOS 沙箱内能通；`NSLocalNetworkUsageDescription` 已弹框并点“好”。
multicast entitlement 是否必需、是否已获批，见 V-18；
**区分两种失败**：手动填 IP 能连、自动发现找不到 = 组播被拦（查 V-18）；
手动填 IP 也不通 = 先查 IP/供电/Wi-Fi/Mesh/物理遮蔽（见 `docs/CAMERA-4PRO.md` §7），不要先归因到 entitlement。
另注意 4 Pro 在 5 GHz Wi-Fi 6 下与 iPhone 是否同频段、同网段。
- [] **V-04 引擎长时间运行**：App 前台 1 小时 + 切后台 10 分钟，引擎不被 Jetsam 杀掉；
`ProcessInfo.thermalState` 变化时降画质逻辑生效；4K 高清连续播放 30 分钟发热可接受
（手感温热而非烫手，电池掉电速度在可接受范围，具体数值以实测为准，不要预填）。

## 2. 播放（4 Pro 是 4K H.265，分两路验）

- [] **V-05 H.264 子码流 WebRTC**：**已作废（2026-11-22 Windows 实测）**——4 Pro 四个 subtype 全是 H.265，没有 H.264 码流；流畅档（subtype=1，848×480）同样走 V-06 的 fMP4 路，不走 WebRTC。
- [] **V-06 H.265 主码流 fMP4 + VideoToolbox**：WKWebView WebRTC 预期失败
（已在 ARCHITECTURE.md §7.1 说明）；改走 fMP4（`/api/stream.mp4`）+ VideoToolbox 硬解能出画面；
`hev1` → `hvc1` 问题已处理：`Fmp4Player.swift` 不依赖 sample entry 类型，直接从 hvcC 的 VPS/SPS/PPS 建格式描述。**实现已完成（2026-11-22，B 路），真机出画面待验证**。
- [] **V-20 4K 高清单路**（Phase 2 新增，4 Pro 专属）：1 路 4 Pro 高清（3840×2160 H.265）
经 fMP4 路能稳定出画面 10 分钟以上；默认画质为标清 1080p（无 subtype），手动切“高清”才走 subtype=0 的 4K；
多路 4K 并发（2×2 全高清）**不在首版验证范围内**，单路通过即算 V-20 通过。
- [] **V-07 画中画**：`AVPictureInPictureController` 能从 WKWebView 的 `<video>` 拉起；
若不行，改走原生 `AVPlayerLayer` 路。
- [] **V-08 Go 在 iOS 上的 DNS/CA**：
引擎能否解析 `account.xiaomi.com`、能否校验 TLS；
是否需显式传系统 CA（安卓用 APK 内置 `ca.pem` + `SSL_CERT_FILE` 的等价物）。

## 3. 登录与安全

- [] **V-09 扫码登录全流程**：小米扫码（`longPolling/loginUrl` 取二维码 → 米家 App 扫码 → 轮询 `lp` 到扫码 → 跟 `location` 链取凭据）→
凭据写回 `go2rtc.yaml`（`xiaomi:` / `xiaomi-credentials:` 段）→ `IMISetXiaomiToken` 热更新运行中引擎（无需 `/api/restart`，iOS 库版调它会重执行进程）→
`GET /api/xiaomi` 拉设备列表。**实现已完成（2026-11-22，A 路，Swift 原生 + `engine/patches/imi-ios-xiaomi-token.patch`），真机全流程待验证**。
- [] **V-10 两步验证**：开两步验证的账号扫码是否仍可用；密码登录报 `404` 时的提示是否准确。
- [] **V-11 鉴权隔离**：同机其他 App 扫 `127.0.0.1:19841` / 随机 go2rtc 端口时，
无 `imi_app` Cookie / 无 Basic Auth 是否一律 401；RTSP 默认关闭或只绑 unix socket。
- [] **V-12 Keychain**：卸载重装后 token 是否清除；`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
在锁屏后首次解锁前引擎能否读到配置。

## 4. 适配与构建

- [] **V-13 iPhone 适配**：竖屏单列/双列、横屏 3 列、灵动岛不遮挡、底部手势不冲突、
触摸目标 ≥44pt、深色模式、Dynamic Type 放大后布局不破；4 Pro 单路时 4K 画面比例 16:9 不裁切。
- [] **V-14 Xcode 工程**：在 MacBook 上 `open IMILAN.xcodeproj` 能打开，
`xcodebuild -list` 能列出 target，`xcodebuild build` 能通过（当前 project.pbxproj 为手写最小工程，未验证）。
若 Xcode 报错，按 project.pbxproj 头注释用 `xcodegen` 或 Xcode 新建工程重建，不要手改 UUID。
- [] **V-15 GitHub Actions**：macos runner 上 `build-ipa.yml`
能出 IPA（默认 unsigned；`signing_mode=developer` 时出已签名包，见 V-21），
侧载到 iPhone 18 Pro Max 后能启动到首页（不要求引擎已通）。
**注意**：workflow 里 Go 引擎步骤在 `engine/libimi/main.go` 填好之前会按预期失败，
不要把它当成 CI 配错了。workflow 已改为：先取补丁（`Fetch IMI-LAN patches`，
打印上游 commit SHA）→ 再编 Go 引擎 → 再编 Xcode；补丁缺失或 dry-run 失败
都会直接报错停下，不会静默编没打补丁的库。
- [] **V-16 过渡版（Phase 1A）**：原“引擎跑 MacBook 上，iPhone 只做播放器”的验证，
Phase 2 用户已明确坚持独立 App，**不再作为必经验证**。仅在 V-01 被证明不可行时才作为兜底重新讨论。

## 5. 型号（4 Pro 专属）

- [] **V-17 型号确认**：model 已验证为 `xiaomi.camera.091ac1`（V-00a），
`Camera.swift` 与 `docs/CAMERA-4PRO.md` §2 已同步。`subtype` 映射已验证（2026-11-22 Windows 实测）：
4K=subtype 0/3、流畅=subtype 1（848×480 H.265）、默认=无 subtype（1080p H.265）；全部档位 H.265，无 H.264。
剩余待确认：流地址 `xiaomi://…?did=&model=` 能否在 iOS 库版上取到密钥（Windows 上默认码流已出）。
- [] **V-19 4 Pro 云台**（Phase 2 新增）：`miss cmdMotorReq=0x112` 在 4 Pro 上是否生效——
方向盘上下左右按住持续转、松手停（`{"operation":-1001}`），无斜向；
倒装时“方向反转”四档是否正确；轻点步长（小/中/大）是否符合预期。
若按了画面不动，先记“该型号 operation 取值可能不同”，不要当成补丁失败，也不要当成 App 坏了。
**实现已完成（2026-11-22，B 路，`GET /ptz?name=<完整 src>&move=…`，按住发 move、松手发 stop、1 秒安全自动停），真机待验证**；Windows 上云台已验证能动（左=1、右=2、上=3、下=4）。
- [] **V-18 multicast entitlement 申请与配置**（Phase 2 新增）：
① 用户已按 `docs/MULTICAST-ENTITLEMENT.md` §3 向 Apple 提交申请（Account Holder 提交，
写明 UDP 32108 / CS2 发现协议与“Bonjour 替代不了”的理由）；② Apple 邮件获批；
③ 开发者网站 App ID 上已启用 Multicast Networking，描述文件已再生；
④ Xcode 里已加 Capability，`CODE_SIGN_ENTITLEMENTS` 指向 `IMILAN/IMILAN.entitlements`；
⑤ 真机上自动发现能找到 4 Pro（见 V-03 的区分方法）。
在获批之前，构建一律走无 multicast 的默认分支，不要强行加 entitlement 签名。
获批后才改开关：本地 `./scripts/build-ipa-local.sh --signed --multicast`；
Actions 上 `workflow_dispatch` 传 `multicast_approved=true`。
未签名模式永远不传 entitlement。

## 6. 签名（Phase 2 新增）

- [] **V-21 开发者账号签名**（Phase 2 新增）：
① Xcode 直装：Automatically manage signing + 选 Team，iPhone 上能 Run 到首页
（见 `docs/SIGNING.md` §1）；② 本地导出：`IMILAN_TEAM_ID` 环境变量 +
`./scripts/build-ipa-local.sh --signed` 能出已签名 IPA（见 §2）；
③ Actions（可选）：5 个签名 secret 已配，`signing_mode=developer` 能出已签名 IPA，
缺 secret 时直接报错、不静默回退未签名（见 §3）。
Team ID、证书、描述文件一律不进仓库、不发聊天。
