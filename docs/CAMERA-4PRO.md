# 目标机型 — 小米智能摄像机 4 Pro（Phase 2）

> 状态：**miot model ID 已验证：`xiaomi.camera.091ac1`（2026-11-22 经 IMI-LAN Windows 版 `/api/xiaomi` 拿到，流已出）。subtype 与云台已验证（2026-11-22 Windows 实测，见 §5–§6）：4K = subtype 0 与 3，流畅 = subtype 1（848×480 H.265，非 H.264），默认 = 无 subtype = 1080p H.265；云台上下左右全部能动（MISS 0x112）。**
> 本文件是 Phase 2 的机型基线，后续验证（VALIDATION.md V-17…V-20）都以它为准。

## 1. 已确认的规格（公开资料）

| 项 | 值 | 来源 |
|---|---|---|
| 产品名 | 小米智能摄像机 4 Pro | 小米说明书 / 新闻稿 |
| 产品型号（硬件型号） | **MJSXJ36CM** | 说明书基本参数表：产品型号 MJSXJ36CM，分辨率 3840×2160，CMIIT ID 26J316Y6T827 |
| 发售 | 2026-10-13，首发价 329 元 | 新浪科技 2026-11-04 报道 |
| 传感器 / 分辨率 | 800 万像素 4K 传感器，**3840×2160**，4P 光学镜片，f/1.6 大光圈 | 同上 |
| 视频编码 | **H.265**（小米历代云台机同款编码；4 Pro 官方未在说明书里单独列编码项，按同系 + 4K 定位推断为 H.265，**主码流编码以 go2rtc probe 结果为准**，见 §3） | 同系 MJSXJ06CM 说明书标 H.265；4 Pro 4K 录像/延时均走 H.265 压缩路线 |
| 云台 | 双电机，**水平 360° / 垂直 106°**，全景巡航 / 定时巡航 / 重点区域定点巡航，兼容倒装 | 新浪科技 / 手机鼠报道 |
| 网络 | **2.4 GHz + 5 GHz 双频 Wi-Fi 6**（802.11ax），蓝牙 5.4 配网，一键换网，备用 Wi-Fi | 说明书：Wi-Fi IEEE 802.11a/b/g/n/ac/ax 2.4GHz/5GHz，蓝牙 5.4 |
| 尺寸 / 供电 | 82×82×130 mm，5V⎓1A，工作温度 -10℃~45℃ | 说明书基本参数表 |
| 存储 | 云存储 / microSD 卡（16–512 GB）/ NAS 三种 | 新闻稿 |
| 其他功能 | 实体通话按键、一键微信通话、OK 手势呼叫、新一代 HDR、超微光全彩、10 颗 940nm 无红曝红外（夜视 10 米）、本地 AI（人形追踪/人脸识别/宠物追踪/宝宝哭声等）、镜头物理遮蔽、米家安全芯片 EAL 5+ | 新闻稿 / 说明书 |
| 厂商 | 上海创米（小米生态链）系产品线，与 IMI-LAN 已验证的 `chuangmi.camera.*` 同系 | — |

## 2. 关键未知点 — miot model ID（已验证，2026-11-22）

**已确认：`xiaomi.camera.091ac1`**——2026-11-22 经 IMI-LAN Windows v1.0.3 `/api/xiaomi` 设备列表拿到（`sources[0].url` 里 `model=xiaomi.camera.091ac1`），不是之前猜的 `chuangmi.camera.*` 系。`Camera.swift` 里 4 Pro 的 `model` 占位 `unknown (MJSXJ36CM)` 应更新为此值。

这意味着：

- **不要写任何猜测的 model ID 进代码、配置或文档。**`Camera.swift` 里 4 Pro 的 `model` 字段目前填 `unknown (MJSXJ36CM)`，是占位，不是真实 ID。
- go2rtc 的流地址格式是 `xiaomi://{account}:{region}@{IP}?did=<did>&model=<model>`，`model` 错了可能导致取流走错协议分支（miss / CS2 / TUTK）或画质映射（`subtype`）错。
- IMI-LAN 桌面版/网关对未收录型号是“默认显示云台开关”，所以 model 未知不等于一定不能用，但必须先拿到真实值再验证。

## 3. 如何从用户侧拿到真实 model / did（请用户按下面抄回来）

按优先级排序，拿到其中任意一条能确定 model 的即可，最好三条都拿：

### 方法 A — 米家 App 设备信息（最简单，先做这个）

1. 米家 App → 点开“小米智能摄像机 4 Pro”这台设备 → 右上角 `…` / 设置 → 设备信息 / 关于。
2. 抄回以下字段（有哪个抄哪个，没有就写“无此项”）：
   - 设备名称（昵称）
   - **型号 / Model**（如 `chuangmi.camera.xxxxx` 形式——注意：App 里显示的可能是 `MJSXJ36CM`，那是硬件型号，不是 miot model；两个都要抄）
   - 固件版本
   - 设备 ID / did（一串数字/字母，如有）
   - 局域网 IP（路由器里看，或 App 设备信息里的 IP）
   - MAC 地址（后 4 位即可，不要发完整 MAC 到公开 issue）

### 方法 B — IMI-LAN Windows 版“添加摄像头”列表（最准）

如果用户电脑上有 IMI-LAN Windows 版（或愿意临时装一次）：

1. 打开 IMI-LAN → 添加摄像头 → 二维码登录（米家 App 扫码）→ 设备列表。
2. 列表里 4 Pro 那一行通常会直接显示 `model`（`chuangmi.camera.xxx`）和 `did`。
3. 把那一行的 **model、did、IP、昵称** 原样抄回来。

### 方法 C — go2rtc 日志里的 xiaomi:// URL（最准，适合已跑通 Windows 版的用户）

1. Windows 版打开 `http://127.0.0.1:19840/api/log`，或看 `go2rtc.yaml` 的 `streams:` 段。
2. 找到 4 Pro 对应的行，形如：
   `xiaomi://<account>:cn@192.168.x.x?did=<did>&model=<model>`
3. **只抄 `did=` 和 `model=` 两个参数的值**，不要把整行（含账号）发出来；账号部分打码。

> 隐私提醒：did / IP / 账号属于设备隐私，只发给本项目验证用，不要贴到公开 issue / 群聊。
> 拿到 model 后，第一件事是更新 `Camera.swift` 的 4 Pro 条目和 `docs/CAMERA-4PRO.md` §2，
> 再跑 VALIDATION.md V-17（型号确认）。

## 4. 支持概率判断（Phase 2，已验证出流）

**判断已更新：出流已验证，不再是概率判断。默认码流、4K、流畅、云台四路均已在 Windows 上实测通过（2026-11-22，见 §5–§6）。**

原 Phase 2 判断（已过时，留作记录）：中等偏高（约 60–70% 能走通流畅码流），但 4K 高清与云台是两个独立风险点，不能打包票。

依据（有利）：

- IMI-LAN README 明确写：**“2020 年以后的小米摄像头大多使用统一的 `miss` 协议，支持概率较高”**，其他型号只要 go2rtc 支持也会自动出现在设备列表里。4 Pro 是 2026-10-13 的新机，同系创米产品线，沿用 miss/CS2 的概率高。
- 4 Pro 是插电云台机（非电池门铃），不存在门铃休眠唤醒那类问题；双频 Wi-Fi 6、5 GHz 频段下局域网带宽更充裕。
- IMI-LAN 桌面版对未收录型号默认显示云台开关，不用等代码更新才有云台入口。

风险（不利）：

- **新机未验证**：4 Pro 发售不到 2 个月，go2rtc / IMI-LAN 社区尚无公开的 4 Pro 成功案例；小米可能在新固件里改了取密钥 / 握手细节（miss_get_vendor、签名、CS2 握手任一环节变了都会失败）。
- **model 未知**：在拿到真实 model 之前，无法确定它走 miss 还是 TUTK，也无法确定 `subtype` 映射（高清/流畅各对应哪个 subtype）。
- **4K + H.265**：主码流是 3840×2160 H.265，见 §5，这是独立的播放风险，与协议通不通无关。

**结论**：先验证“流畅（H.264 子码流）能不能出画面”，再验证“4K 高清能不能硬解”，最后验证“云台转不转”。三步是独立的，不要混在一起判断。

## 5. subtype 对照表（已验证，2026-11-22 Windows 实测）

方法：每次改 `go2rtc.yaml` 流地址行的 `subtype=N` + 杀 go2rtc 进程（IMI-LAN 看门狗 45 秒内自动拉起）后实测；`ffprobe rtsp://127.0.0.1:8554/cam_sample`（示例流名，真实流名含设备 did，不公开）+ go2rtc producer 双重确认；`GET /api/frame.jpeg` 均 200。**注意：本版补丁 go2rtc 的 `PUT /api/streams` 返回 200 但不应用新 src，改流必须改 yaml + 重启引擎。**

| subtype | 视频 | 分辨率 | 音频 | 出流 |
|---|---|---|---|---|
| 默认（无 subtype） | H.265 (hevc) | 1920×1080 | Opus 48kHz 立体声 | ✅，首帧 0.66 秒 |
| 0 | H.265 (hevc) | **3840×2160 (4K)** | Opus 48kHz 立体声 | ✅，frame 约 490KB |
| 1 | H.265 (hevc) | **848×480** | Opus 48kHz 立体声 | ✅，frame 约 47KB |
| 2 | H.265 (hevc) | 1920×1080 | Opus 48kHz 立体声 | ✅，与默认行为一致 |
| 3 | H.265 (hevc) | **3840×2160 (4K)** | Opus 48kHz 立体声 | ✅，frame 约 490KB |

关键结论（纠正旧假设）：

- **4K = subtype 0 与 subtype 3 两个**，两者都是 3840×2160 H.265；本次未区分两者帧率/码率差异，首版任选其一即可，建议用 0。
- **没有 H.264 码流**：四个 subtype 全部是 H.265。所谓“流畅”档是 **subtype=1 的 848×480 H.265，不是 H.264**。不要按“流畅=H.264”的假设写转码逻辑，也不要指望 WKWebView WebRTC 能解流畅档。
- **默认 = subtype=2**：都是 1080p H.265，行为一致。
- **iOS 首版默认画质：无 subtype（1080p H.265）**，与 Windows 默认一致，首帧已验证；VideoToolbox 原生硬解 H.265，无需转码。4K（subtype=0）作高清档可选，subtype=1 作省流档可选。

## 5a. H.265 对播放的影响（关键）

| 码流 | 编码 / 分辨率 | iOS 播放路径 | 状态 |
|---|---|---|---|
| 省流（subtype=1） | **H.265，848×480**（已验证，非 H.264） | WKWebView 内 WebRTC | ❌ **不行**（stock WebRTC 无 HEVC 编解码器，见 ARCHITECTURE.md §7.1）——须走原生 fMP4 + VideoToolbox |
| 默认（无 subtype） | **H.265，1920×1080** | WKWebView 内 WebRTC | ❌ **不行**，同上 |
| 高清（subtype=0/3） | **H.265，3840×2160** | WKWebView 内 WebRTC | ❌ **不行**，同上 |
| 任意档 | **H.265** | **原生 fMP4 + VideoToolbox 硬解**（`Fmp4Player.swift`） | ⚠️ 待验证（V-06 / V-20）。4K 硬解在 iPhone 18 Pro Max 上理论可行，但需真机测：解码功耗、发热、多路并发上限 |
| 任意档 | H.265 | 转码成 H.264（ffmpeg） | ❌ 独立版不走这条路：iOS 上无 ffmpeg，转码要软解再编码，功耗/延迟都不可接受；只在有服务器的过渡方案里才考虑 |

注意事项：

- **4K 不要默认全开**：首版默认画质应为无 subtype 的 1080p H.265，用户手动切“高清”时再走 fMP4 路；`Camera.swift` 的默认 `quality` 应对应 1080p 档，而非 480p 流畅档。
- **hev1 vs hvc1**：go2rtc 的 fMP4 passthrough 若打出 `hev1` 样条，AVFoundation 会拒解，需在 demux 层转 `hvc1`（见 ARCHITECTURE.md §7.1，V-06）。
- **单路 4K 即可占满验证**：V-20 只验 1 路 4K 高清；多路 4K 并发（2×2 全高清）是后续项，不要在首版强求。

## 6. 云台（miss 0x112）已验证（2026-11-22 Windows 实测）

- 接口：`GET /ptz?name=cam_sample&move=<dir|stop>`（示例流名，真实流名含设备 did，不公开；IMI-LAN 补丁 go2rtc 的 `/ptz`，前端 app.js 同款调用方式）；`/ptz/spec` 报 `supported:true`、MISS 0x112 motor。
- **上下左右全部能动**，每次均为轻点约 0.9 秒后立即 stop，未长时间/大幅度转。`operation` 取值：左=1、右=2、上=3、下=4；松手停为 `{"operation":-1001}`。
- 证据：帧差用 ffmpeg `blend=difference + signalstats` 算 YAVG（纯数值比对，未查看画面内容）。不动对照组（间隔 5 秒两帧）YAVG 2.4–2.7；移动后上 48.1、左 64.4、右 62.0，约 20 倍于基线，确认真实转动。go2rtc 日志级别为 info，未抓到含 `0x112`/`motor` 字样的行，PTZ 命令只体现在 `/ptz` 返回的 operation 码里。
- **已知遗留：多次轻点后摄像头当前取景与测试开始时相比仍有明显偏移**（与起点参照帧比 YAVG 约 53）。已用 0.5 秒/0.25 秒步进做有测量反馈的回位尝试，水平方向单步 0.5 秒曾从 60 改善到 52，但继续步进不再改善（步进粒度太粗），已停止盲调。建议用户在 IMI-LAN 里用方向盘自行摆回常用角度；云台本身工作正常。
- 另有 cs2 缓冲坑：命令通道登录后没人读，`cs2` 接收缓冲（10 条）会被填满导致约 110 秒断流，
  客户端需常驻排空该通道（IMI-LAN README 已修，iOS 侧同样要做，见 V-02）。

## 7. 其他 4 Pro 特有项（验证时注意）

- **微信通话 / OK 手势呼叫**：4 Pro 新增的实体通话键与微信通话是米家 App 的功能，
  **不在 IMI-LAN / 本 App 的范围内**，不要尝试实现。
- **全天超省录制 / 4K 延时摄影**：录像策略功能，不影响实时取流；回放仍走米家 App / SD 卡 / NAS。
- **5 GHz Wi-Fi 6**：iPhone 与摄像头应在同一频段/同一局域网段；若路由器开了“双频合一”或 Mesh 漫游代理，
  可能出现局域网 UDP 握手失败（IMI-LAN README 常见问题里有 Deco Mesh 的同类案例，V-03 验证时注意）。
- **物理遮蔽**：若米家 App 里开了物理遮蔽，镜头被遮挡，画面会是黑的——先排除这个再报“黑屏”。

## 8. 来源

- 小米智能摄像机 4 Pro 说明书（cdn.cnbj1.fds.api.mi-img.com，产品型号 MJSXJ36CM，
  分辨率 3840×2160，Wi-Fi 802.11a/b/g/n/ac/ax 2.4GHz/5GHz，蓝牙 5.4）
- 新浪科技 2026-11-04《支持一键微信通话：小米智能摄像机 4 Pro 329→252 元》（发售 2026-10-13，
  800 万像素 4K、双电机水平 360°/垂直 106°、双频 Wi-Fi 6）
- IMI-LAN README（browser）：支持情况列表、2020 年后 miss 协议统一、云台 `cmdMotorReq=0x112`、
  cs2 缓冲 110 秒断流、未收录型号默认显示云台开关
- 公开搜索（2026-11-22）：`MJSXJ36CM miot model chuangmi.camera` 无结果；
  `小米智能摄像机 4 Pro 编码 H.265` 无官方单独编码项，H.265 为同系推断，以 probe 为准
