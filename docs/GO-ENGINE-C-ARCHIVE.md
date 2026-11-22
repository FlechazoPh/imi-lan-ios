# go2rtc c-archive 最小验证设计（V-01 / V-02，Phase 2）

> 状态：**设计已写清，未验证。不要假装已跑通。**
> 本文件是 `scripts/build-go-engine.sh` 的配套说明：先读本文件，再跑脚本。
> 本机 Linux 上无 Go / Xcode / Swift（已确认 `go: command not found`），
> **本阶段未在本机做任何 Go 交叉编译**，所有步骤都标注“须在 MacBook / macOS runner 上跑”。

## 0. 目标（最小验证的定义）

V-01 / V-02 的“通过”标准不是“App 能看画面”，而是更小的一步：

- **V-01 通过**：在 MacBook（或 macOS runner）上，用已打补丁的 go2rtc 1.9.15 源码，
  编出 iOS arm64 的 `libgo2rtc.a` + `libgo2rtc.h`，且头文件里有
  `IMIStartEngine / IMIStopEngine / IMIEngineStatus` 三个导出函数，
  Swift 侧能链接、能调用、调用后返回的不是“未接入”错误。
- **V-02 通过**：用这个库版引擎跑起来后，扫码登录不报 `401`，且 `/ptz` 与 `/ptz/spec`
  接口存在（即两个补丁在 iOS 库版上同样生效）。
- 画面（V-05 / V-06）与 4 Pro（V-17…V-20）是 V-01/V-02 之后的步骤，
  不要在 V-01 未通过时跳过去验画面。

## 1. 为什么是 c-archive（不再展开，见 ARCHITECTURE.md §4.1）

- iOS 沙箱禁止执行包内独立二进制 → 引擎必须跑在 App 进程内 → 以库的形式被 Swift 调用。
- Go 官方机制：`go build -buildmode=c-archive` 把 `package main` 编成 `.a` + `.h`，
  `//export` 的函数变成 C 函数，Swift 经 Bridging Header 调用。
- 公开先例：Tailscale 的 `libtailscale`（`GOOS=ios GOARCH=arm64 CC=clangwrap-ios.sh`）、
  v2ray-core 的 iOS 插件讨论（`CC=$GOROOT/misc/ios/clangwrap.sh GOOS=ios GOARCH=arm64 CGO_ENABLED=1`）、
  Ikemen GO iOS 移植（`go build -buildmode=c-archive -o libengine.a`）。
  这些都证明“Go → c-archive → iOS”是走得通的机制，**但 go2rtc 本身体量与改造量是另一回事**，
  不能因为机制走得通就默认 go2rtc 一定能编过去。

## 2. 前置清单（跑脚本前逐项打勾）

| # | 前置 | 怎么确认 |
|---|---|---|
| P-0 | MacBook（Apple Silicon 或 Intel 均可，优先 Apple Silicon）或 macOS runner | `uname -m` |
| P-1 | Xcode 16+（含 iphoneos SDK） | `xcodebuild -version`；`xcrun --sdk iphoneos --show-sdk-path` 能输出路径 |
| P-2 | Go 版本以 go2rtc 1.9.15 源码的 `go.mod` 为准（脚本 Step 1 会打印 `go.mod` 的 `go` 行与本机 `go version` 对照；低于要求先升级 Go，不要改 `go.mod` 绕过） | `go version`；`grep '^go ' build/go2rtc-src/go.mod` |
| P-3 | go2rtc 1.9.15 源码（从上游 `AlexxIT/go2rtc` 取 tag / commit，**不要用官方 release 二进制**，那里面没有补丁） | `git -C <go2rtc-dir> describe --tags` 或看 `go.mod` |
| P-4 | IMI-LAN 的两个补丁：`fpk/patches/xiaomi-login.patch` → `fpk/patches/xiaomi-control.patch`（按此顺序） | 补丁文件来自 IMI-LAN 仓库 `fpk/patches/`；脚本里用 `patch -p1 --dry-run` 先试打，再正式打；补丁缺失时默认报错，`FETCH_PATCHES=1` 才自动从上游取（并打印 commit SHA） |
| P-5 | `cmd/libimi` 入口包（见 §3）：根 `main.go` 的模块列表抄过来的可重入库入口（无单一 `Run()`，无 `RunUntilSignal`，无 `os.Exit`） | 目录存在、能 `go vet ./cmd/libimi`（在 Mac 上）；`engine/libimi/main.go` 里无 `TODO` 且无 `RunUntilSignal`（脚本 Step 3 会检查） |
| P-6 | 磁盘空间：go2rtc 源码 + 构建缓存约 1–2 GB；产物 `libgo2rtc.a` 约 30 MB | `df -h` |

## 3. 最大改造：`cmd/libimi`（库入口）

这是 V-01 里工作量最大的一步，**不是“加个 main.go 就能编”**。

> **已核实的关键事实（2026-11-22，经浏览器读公开资料）：go2rtc 没有
> 一个可导出的单一 `Run()` / `Start()` 入口函数，不要编一个出来调。**
> 上游入口在仓库根 `main.go`（`package main`，不是 `cmd/go2rtc/main.go`）：
> `app.Init` → 约 53 个模块的 `Init()`（顺序固定，`api` / `ws` / `streams`
> 在前）→ `streams.SetReady()` → `shell.RunUntilSignal()`
> （`pkg/shell/shell.go`，阻塞等 `SIGINT` / `SIGTERM`；另有
> `api/exit` / `api/restart` 处理器也能结束进程）。
> `app.Init`（`internal/app/app.go` 27–90）做：flag 解析 `-c/--config`、
> `-d/--daemon`、`-v/--version`；`initConfig()`；`initLogger()`；
> 读 `app.modules` 填 `app.Modules`。`-d` daemon 模式会用 `os/exec.Command`
> 把自己重执行一次并退出父进程——iOS 库里绝对不能走这条路。
> `api/restart` 同样会重执行二进制（以源码为准，先 grep 确认），库版必须禁掉它。
> 填模板前先跑 `engine/libimi/main.go.template` §A 的 grep 清单。

go2rtc 上游的入口 `main()` 会：

- 解析命令行参数、读 `go2rtc.yaml`、启动 HTTP/RTSP/WebRTC 服务；
- 注册信号处理（`SIGINT` / `SIGTERM` 时优雅退出）；
- 出错时 `os.Exit(1)`。

改成库入口时，必须做到（每条都是未验证的改造点）：

1. **新建 `cmd/libimi/main.go`（`package main`，c-archive 要求入口包必须是 `main`）**，
   只放胶水代码，不复制 go2rtc 的业务逻辑；**把 `main.go` 的模块列表
   原样抄过来**（import 块 + `modules := []module{...}`，顺序不能换，
   以 1.9.15 源码为准），把最后的 `shell.RunUntilSignal()` 换成等
   `IMIStopEngine` 关掉的 `done` chan。`app.Init` 的命令行依赖要换成
   `IMIStartEngine` 传入的 `configPath`——先在 Mac 上核实 `app.Init`
   是不是用 flag 包读 `os.Args`（若是，启动前设
   `os.Args = []string{"go2rtc", "-c", configPath}`，绝不带 `-d`；
   若不是，改用它实际的入口，以 `app.go` 源码为准，不要猜）。
   **多次启停是未验证的最大风险**：`flag.Parse()` 在同一进程只能有效
   解析一次，各模块 `Init()` 大概率不是幂等的；首版先做到“单次启动 +
   幂等停止”，第二次启动必须返回错误并写日志，不要谎报成功。
   详见模板 §C。
2. **导出三个 C 函数**（`//export`，签名以生成的 `libgo2rtc.h` 为准，不要手写改动）：
   ```go
   //export IMIStartEngine
   func IMIStartEngine(configPath *C.char, logPath *C.char) C.int
   //export IMIStopEngine
   func IMIStopEngine() C.int
   //export IMIEngineStatus
   func IMIEngineStatus() *C.char
   ```
   - `IMIStartEngine`：入参是沙箱里的 `go2rtc.yaml` 与 `engine.log` 绝对路径；
     启动成功返回 `0`，失败返回非零并把原因写日志（不要 `os.Exit`）。
   - `IMIStopEngine`：停止监听、释放端口，可多次调用；再次 `IMIStartEngine` 应能重新启动
     （可多次启停是 V-01 的一部分，单次启动成功不算通过）。
   - `IMIEngineStatus`：返回 JSON 或字符串状态（如 `{"running":true,"port":19840}`），
     调用方负责释放返回的 C 字符串（见脚本注释里的 `C.free` 约定）。
3. **去掉 `os.Exit` 与信号依赖**：库里不能 `os.Exit`（会把整个 App 杀掉），
   信号处理要改成“收到停止调用时优雅停”，或直接不注册信号。
4. **路径改成沙箱路径**：配置/日志/临时文件一律走调用方传入的 `configPath` / `logPath`，
   不要写死 `/tmp`、当前目录或 `~`。
5. **全局单例可重入**：go2rtc 内部若有全局单例（HTTP server、流注册表），
   停止后要能清理干净，否则第二次启动会报“端口已被占用”或“重复注册”。
6. **关掉 iOS 上没有的依赖**：ffmpeg 转码兜底（iOS 上无 ffmpeg 二进制）、
   任何 `exec` 子进程的调用都要去掉或改成库内实现。

`engine/libimi/main.go.template`（本仓库）是上述胶水代码的**模板草稿**，
不是可直接编译的文件：它把第 2 步的三个导出函数骨架写出来了，
但 go2rtc 内部入口的真实函数名、导入路径要以 P-3 的源码为准，在 Mac 上填好后再改名成 `main.go`。
**不要把模板当成已完成的代码。**

## 4. 交叉编译步骤（脚本草稿，见 scripts/build-go-engine.sh）

脚本按以下顺序跑，每步失败都直接退出并打印原因，不继续往下编：

```
Step 0  预检：go / xcodebuild / xcrun / patch / lipo 都存在；打印版本
Step 1  取源码：git clone AlexxIT/go2rtc（tag v1.9.15）到 build/go2rtc-src/
        （若目录已存在且 tag 一致则跳过，避免重复下载）
Step 2  打补丁：按顺序 xiaomi-login.patch → xiaomi-control.patch
        每打一个先 --dry-run，失败就停；打完用 git diff --stat 确认改了哪些文件
Step 3  放入口：把 engine/libimi/ 复制到 build/go2rtc-src/cmd/libimi/
        （模板里的 TODO 必须先在 Mac 上填好，否则 Step 4 一定失败——这是预期的）
Step 4  编真机库：CGO_ENABLED=1 GOOS=ios GOARCH=arm64
        CC=<scripts/clangwrap-ios.sh>  (见 §5)
        go build -buildmode=c-archive -o build/libgo2rtc-arm64.a ./cmd/libimi
        产物：build/libgo2rtc-arm64.a + build/libgo2rtc-arm64.h
Step 5  （可选）编模拟器库：GOOS=ios GOARCH=arm64 SDK=iphonesimulator
        再用 lipo -create 合并真机 + 模拟器（模拟器库仅用于在 Mac 上跑 UI，
        不能装真机；若只验真机可跳过 Step 5）
Step 6  校验：lipo -info build/libgo2rtc.a（应含 arm64）
        nm -g build/libgo2rtc.a | grep IMIStartEngine（应能找到导出符号）
        grep IMIStartEngine build/libgo2rtc.h（头文件里应有声明）
Step 7  交接：把 .a + .h 复制到 IMILAN/Engine/vendor/（不进 git，见 .gitignore 建议），
        并在终端打印下一步：在 Xcode 里把 .a 拖进 target、Bridging Header 指向新头文件
```

关键环境变量（脚本里已写，含义如下）：

| 变量 | 值 | 说明 |
|---|---|---|
| `CGO_ENABLED` | `1` | c-archive 必须开 cgo，否则编不出 `.a` |
| `GOOS` | `ios` | Go 1.x 支持的 iOS 目标（不是 `darwin`） |
| `GOARCH` | `arm64` | 真机 arm64；模拟器 arm64-sim 另用 `SDK=iphonesimulator` |
| `CC` | `scripts/clangwrap-ios.sh` | 见 §5，不能直接用 `xcrun --find clang`（缺 `-arch` / `-isysroot`） |
| `SDK` | `iphoneos` | clangwrap 内部用；真机 `iphoneos`，模拟器 `iphonesimulator` |
| `IPHONEOS_DEPLOYMENT_TARGET` | `17.0` | 与工程 `IPHONEOS_DEPLOYMENT_TARGET = 17.0` 一致 |

## 5. clangwrap-ios.sh（本仓库新文件）

Go 自带 ` $GOROOT/misc/ios/clangwrap.sh`（Go 1.20+ 在 `misc/ios/` 下），
但直接引用 GOROOT 下的文件在 CI 上不稳定，所以本仓库在 `scripts/clangwrap-ios.sh`
里放了一份**从零手写的等价包装脚本**（逻辑与 Go 官方 clangwrap 同款，见来源）：

```sh
#!/bin/sh
# 用法：CC="$PWD/scripts/clangwrap-ios.sh" go build ...
SDK=iphoneos   # 模拟器版把这一行改成 iphonesimulator（脚本支持 SDK 环境变量覆盖）
SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
CLANG=$(xcrun --sdk "$SDK" --find clang)
exec "$CLANG" -arch "$GOARCH" -isysroot "$SDK_PATH" \
  -miphoneos-version-min=17.0 "$@"
```

要点：

- 必须用 `xcrun --sdk iphoneos --find clang` 找 clang，不能用系统默认 clang。
- 必须传 `-arch arm64` 与 `-isysroot <SDK_PATH>`，否则 cgo 会编出 macOS 的库，
  链接时报架构不匹配。
- `-miphoneos-version-min=17.0` 与工程部署目标一致；改部署目标时两处一起改。
- 模拟器版：`SDK=iphonesimulator` + `-mios-simulator-version-min=17.0`
  （脚本里用 `SDK` 环境变量区分，真机/模拟器不要共用同一个包装脚本调用）。

## 6. 失败模式速查（V-01 排错时先看这张表）

| 现象 | 可能原因 | 先查什么 |
|---|---|---|
| `GOOS=ios` 报错 `unknown GOOS` | Go 版本太老 | `go version`，升级到 P-2 的版本 |
| `cgo: C compiler "clang" not found` | `CC` 没设或 clangwrap 不可执行 | `chmod +x scripts/clangwrap-ios.sh`；`xcrun --sdk iphoneos --find clang` 能否输出路径 |
| `ld: library not found for -lSystem` / 架构不匹配 | `-isysroot` / `-arch` 缺了 | 看 clangwrap 是否被真正调用（`CC` 变量是否传进 `go build`） |
| `package main: buildmode=c-archive requires ...` | 入口包不是 `package main` 或缺 `//export` | `cmd/libimi/main.go` 的包名与导出函数 |
| `undefined: <go2rtc 内部函数>` | 模板里的 go2rtc 入口函数名与 1.9.15 源码不一致 | 在 `build/go2rtc-src/` 里 `grep` 真实入口函数名，再改模板 |
| `os.Exit` 把 App 杀掉 | 库里残留 `os.Exit` / 信号处理 | 全仓搜 `os.Exit`，改成返回错误码 |
| 第二次启动报端口占用 | 全局单例未清理 | `IMIStopEngine` 是否释放了 HTTP/RTSP 监听 |
| `lipo -info` 只有 x86_64 | 编成了模拟器库却当真机库用 | 确认 Step 4 的 `SDK=iphoneos` 与 `GOARCH=arm64` |
| `undefined: Run` / `undefined: Start` | 模板里编了一个不存在的 go2rtc 入口函数名 | go2rtc 没有单一 `Run()`/`Start()`；按 §3 把根 `main.go` 的模块列表原样抄过来，不要编函数名 |
| `flag.Parse` 第二次调用无效 / 重复注册 panic | `app.Init` 与各模块 `Init()` 不是幂等的 | 见模板 §C：首版只保证单次启动 + 幂等停止，第二次启动返回错误，不要谎报成功 |
| `api/restart` 重执行二进制失败 | 库版里残留 `api/restart` 的重执行逻辑 | grep 确认后禁掉它；重启走 App 侧重新拉起引擎（待验证） |
| `exec: "ffmpeg": executable file not found` | `exec` / `ffmpeg` 模块被抄进来了 | 首版模块列表里先排除 `exec` / `ffmpeg`（4 Pro 默认码流不需要转码）；见模板 §A |

## 7. V-02 补丁验证（库版）

V-01 通过后，在 MacBook 上先不要急着装 iPhone，按以下顺序验 V-02：

1. 用库版引擎（或先用同源码编的 macOS 版 go2rtc 作对照）在 Mac 上跑起来，
   配置里放 4 Pro 的 `xiaomi://` 流地址（model 待用户抄回，见 `docs/CAMERA-4PRO.md` §3）。
2. 扫码登录：走 Go 版扫码（`qr.go` 流程），看日志是否报 `401`。
   - 报 `401` → `xiaomi-login.patch` 未生效或 token 回写逻辑在库版里丢了，先查补丁是否打上（`git diff --stat`）。
   - 不报 `401` 且能拿到密钥 → 登录补丁生效。
3. 调 `http://127.0.0.1:19840/api/streams`（或网关的 `/api`），看 4 Pro 的流是否在列表里。
4. 调 `/ptz/spec` 与 `/ptz`（POST 一个方向指令，看是否返回成功而非 404）：
   - 404 → `xiaomi-control.patch` 未生效。
   - 返回成功但画面不动 → 可能是 4 Pro 的 `operation` 取值不同，记到 V-19 里，不要当成补丁失败。
5. 以上四步都通过，才算 V-02 通过；任一步失败都先回 Step 2 查补丁，不要跳到 V-05 验画面。

## 8. 本机 Linux 上的限制（诚实标注）

- 本机（Hatch VM，Linux）上：`go`、`swift`、`xcodebuild`、`clang` 均不存在
  （2026-11-22 实测 `go: command not found`），**未做任何 Go 交叉编译**，
  `scripts/build-go-engine.sh` 在本机上只会跑预检就退出（预期行为）。
- 脚本里的每条命令都标注了“须在 MacBook / macOS runner 上跑”，
  不要在本机上强行装 Go 再假装“我编过了”。
- 若日后在 MacBook 上跑通，应把实际输出（`go version`、`lipo -info`、`nm` 结果、
  补丁 `git diff --stat`）贴回本文件 §0 的“通过”栏，并更新 VALIDATION.md V-01/V-02 为通过。

## 9. 来源

- Go c-archive 机制：`go build -buildmode=c-archive` 生成 `.a` + `.h`；
  `CC=$GOROOT/misc/ios/clangwrap.sh GOOS=ios GOARCH=arm64 CGO_ENABLED=1`
  （v2ray-core Discussion #3171；Tailscale libtailscale Makefile：
  `c-archive-ios` 用 `GOOS=ios GOARCH=arm64 CC=clangwrap-ios.sh`，模拟器用 `lipo -create`）
- clangwrap 写法：Go 官方 `misc/ios/clangwrap.sh`（`xcrun --sdk $SDK --show-sdk-path` +
  `xcrun --sdk $SDK --find clang` + `-arch $CLANGARCH -isysroot $SDK_PATH`）；
  gaitatzis《Compile GoLang as a Mobile Library》（`SDK=iphoneos` / `iphonesimulator`、
  `IPHONEOS_DEPLOYMENT_TARGET`、c-archive 生成 `.a` + `.h`）
- go2rtc 补丁顺序：IMI-LAN README“从源码运行”：
  `xiaomi-login.patch` → `xiaomi-control.patch`，打到 go2rtc 1.9.15，
  前者修登录 Cookie/token 回写，后者提供 `/ptz` 与 `/ptz/spec`
- Ikemen GO iOS 移植：`go build -buildmode=c-archive -o libengine.a` 的 iOS 静态库做法
