// main.go — go2rtc c-archive 库入口（libimi），由 main.go.template 填好
//
// 来源：go2rtc v1.9.15 仓库根 main.go（package main），2026-11-22 在
// /tmp/go2rtc-src 里逐行核对后原样搬运。不要凭记忆改模块名或顺序。
//
// 核实过的关键事实（以 1.9.15 源码为准，先前模板里两处写错了，已纠正）：
//   - 模块一共 45 个，不是约 53 个；顺序见下面的 modules 列表。
//   - 1.9.15 的 main() 结尾只有阻塞式信号等待，没有 streams.SetReady()
//     调用（全仓 grep 无此调用）；库版里用等 done chan 代替它。
//   - app.Init（internal/app/app.go）用 flag 包读 os.Args：-c/--config、
//     -d/--daemon、-v/--version。-v 会直接退出进程；-d 会重执行自身
//     并退出父进程。库版启动前把 os.Args 设成只有 -c，绝不带 -d/-v。
//     flag.Parse() 在同一进程里只能有效解析一次，这是多次启停做不到的原因。
//   - 全仓 os.Exit 只有四处：app.go 的 -v（0）、-d 失败（1）、-d 成功（0）；
//     internal/api/api.go 的 api/exit 处理器（POST /api/exit?code=，只在
//     有人调该接口时触发）；internal/onvif/onvif.go 的 DeviceSystemReboot
//     处理（只在收到 ONVIF 重启请求时触发）。onvif 模块已从本列表排除，
//     其余三处在库版里不会被走到：启动参数里没有 -v/-d，App 侧不要调
//     /api/exit，/api/restart 同样不要调（它用 syscall.Exec 重执行进程）。
//
// 模块取舍（相对上游 main.go 的 45 个，首版排除了 3 个）：
//   - exec：调外部二进制，iOS 沙箱里没有可 exec 的程序。
//   - ffmpeg：调 ffmpeg 二进制，iOS 上没有；4 Pro 默认码流不需要转码就能出流。
//   - onvif：含 DeviceSystemReboot 的退出调用，且 iOS 侧不需要 ONVIF 服务。
//   其余 42 个原样保留（含 alsa/v4l2：它们在非 Linux 上是空实现，见
//   internal/alsa/alsa.go 与 internal/v4l2/v4l2.go 的 build tag）。
//   若后续某模块在 iOS 编译失败，按日志逐个排除，不要一次性全删。
//
// 约束（与模板一致）：
//   - 单次启动 + 幂等停止。第二次调用 IMIStartEngine 返回非零并写明
//     原因，不谎报成功；重启要 App 重新拉起进程。
//   - 停止只关 done chan：HTTP/RTSP/WebRTC 监听是否真停、端口是否释放，
//     go2rtc 没有公开的 Stop API，实测前不声称已释放。
//   - logPath 是本库自己的日志文件（启动/停止/失败行）；go2rtc 内部日志
//     走 MemoryLog（可用 /api/log 读），Swift 侧生成 go2rtc.yaml 时若想
//     让 go2rtc 也写文件日志，在 yaml 里加 log: {output: "file:<logPath>"}。
//
// 对外契约（以生成的 libgo2rtc.h 为准）：
//   int IMIStartEngine(const char *configPath, const char *logPath);
//   int IMIStopEngine(void);
//   const char *IMIEngineStatus(void);

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"sync"
	"time"

	"github.com/AlexxIT/go2rtc/internal/alsa"
	"github.com/AlexxIT/go2rtc/internal/api"
	"github.com/AlexxIT/go2rtc/internal/api/ws"
	"github.com/AlexxIT/go2rtc/internal/app"
	"github.com/AlexxIT/go2rtc/internal/bubble"
	"github.com/AlexxIT/go2rtc/internal/debug"
	"github.com/AlexxIT/go2rtc/internal/doorbird"
	"github.com/AlexxIT/go2rtc/internal/dvrip"
	"github.com/AlexxIT/go2rtc/internal/echo"
	"github.com/AlexxIT/go2rtc/internal/eseecloud"
	"github.com/AlexxIT/go2rtc/internal/expr"
	"github.com/AlexxIT/go2rtc/internal/flussonic"
	"github.com/AlexxIT/go2rtc/internal/gopro"
	"github.com/AlexxIT/go2rtc/internal/hass"
	"github.com/AlexxIT/go2rtc/internal/hls"
	"github.com/AlexxIT/go2rtc/internal/homekit"
	"github.com/AlexxIT/go2rtc/internal/http"
	"github.com/AlexxIT/go2rtc/internal/isapi"
	"github.com/AlexxIT/go2rtc/internal/ivideon"
	"github.com/AlexxIT/go2rtc/internal/kasa"
	"github.com/AlexxIT/go2rtc/internal/mjpeg"
	"github.com/AlexxIT/go2rtc/internal/mp4"
	"github.com/AlexxIT/go2rtc/internal/mpeg"
	"github.com/AlexxIT/go2rtc/internal/multitrans"
	"github.com/AlexxIT/go2rtc/internal/nest"
	"github.com/AlexxIT/go2rtc/internal/ngrok"
	"github.com/AlexxIT/go2rtc/internal/pinggy"
	"github.com/AlexxIT/go2rtc/internal/ring"
	"github.com/AlexxIT/go2rtc/internal/roborock"
	"github.com/AlexxIT/go2rtc/internal/rtmp"
	"github.com/AlexxIT/go2rtc/internal/rtsp"
	"github.com/AlexxIT/go2rtc/internal/srtp"
	"github.com/AlexxIT/go2rtc/internal/streams"
	"github.com/AlexxIT/go2rtc/internal/tapo"
	"github.com/AlexxIT/go2rtc/internal/tuya"
	"github.com/AlexxIT/go2rtc/internal/v4l2"
	"github.com/AlexxIT/go2rtc/internal/webrtc"
	"github.com/AlexxIT/go2rtc/internal/webtorrent"
	"github.com/AlexxIT/go2rtc/internal/wyoming"
	"github.com/AlexxIT/go2rtc/internal/wyze"
	"github.com/AlexxIT/go2rtc/internal/xiaomi"
	"github.com/AlexxIT/go2rtc/internal/yandex"
)

// ---- 状态机（单次启动 + 幂等停止） ----
var (
	mu          sync.Mutex
	running     bool
	everStarted bool // 进程内是否曾经启动过；为 true 时拒绝再次启动。
	done        chan struct{}
	startErr    string
	logFilePath string
	logMu       sync.Mutex
)

// goString 把 C 字符串安全转 Go string；nil 返回 ""。
func goString(s *C.char) string {
	if s == nil {
		return ""
	}
	return C.GoString(s)
}

// appendLog 往本库自己的日志文件追加一行（失败就静默丢弃，不阻塞引擎）。
func appendLog(msg string) {
	logMu.Lock()
	defer logMu.Unlock()
	if logFilePath == "" {
		return
	}
	f, err := os.OpenFile(logFilePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), msg)
}

// statusJSON 生成 IMIEngineStatus 返回的 JSON；调用方负责 C.free。
// 注意：不回显 configPath/logPath 的完整路径（路径里可能含用户名）。
func statusJSON() *C.char {
	mu.Lock()
	defer mu.Unlock()
	b, _ := json.Marshal(map[string]interface{}{
		"running":     running,
		"everStarted": everStarted,
		"error":       startErr,
	})
	return C.CString(string(b))
}

// runEngine 是真正的启动逻辑，在独立 goroutine 里跑。
// 顺序与 go2rtc 1.9.15 根 main.go 完全一致，只做两处替换：
//   - 启动前把 os.Args 设成只有 -c（app.Init 用 flag 读它），绝不带 -d/-v；
//   - 结尾不等信号，改为等 done chan（IMIStopEngine 关闭它）。
func runEngine(configPath string) {
	defer func() {
		if r := recover(); r != nil {
			mu.Lock()
			startErr = fmt.Sprintf("engine panic during init: %v", r)
			running = false
			mu.Unlock()
			appendLog("FAIL: " + startErr)
		}
	}()

	// app.Init 用 flag 包解析 os.Args；只给 -c，不给 -d（重执行）与 -v（退出）。
	os.Args = []string{"go2rtc", "-c", configPath}

	app.Version = "1.9.15"

	type module struct {
		name string
		init func()
	}

	// 42 个模块，顺序与上游 main.go 一致，仅排除了 exec、ffmpeg、onvif
	// （原因见文件头注释）。name == "" 的模块永远跑；其余模块受
	// 配置里 app.modules 的 allow-list 过滤，与上游 main() 的逻辑相同。
	modules := []module{
		{"", app.Init},    // init config and logs
		{"api", api.Init}, // init API before all others
		{"ws", ws.Init},   // init WS API endpoint
		{"", streams.Init},
		// Main sources and servers
		{"http", http.Init},     // rtsp source, HTTP server
		{"rtsp", rtsp.Init},     // rtsp source, RTSP server
		{"webrtc", webrtc.Init}, // webrtc source, WebRTC server
		// Main API
		{"mp4", mp4.Init},     // MP4 API
		{"hls", hls.Init},     // HLS API
		{"mjpeg", mjpeg.Init}, // MJPEG API
		// Other sources and servers
		{"hass", hass.Init},             // hass source, Hass API server
		{"homekit", homekit.Init},       // homekit source, HomeKit server
		{"rtmp", rtmp.Init},             // rtmp source, RTMP server
		{"webtorrent", webtorrent.Init}, // webtorrent source, WebTorrent module
		{"wyoming", wyoming.Init},
		// Exec and script sources (exec/ffmpeg 已排除，见文件头)
		{"echo", echo.Init},
		{"expr", expr.Init},
		// Hardware sources (非 Linux 上为空实现)
		{"alsa", alsa.Init},
		{"v4l2", v4l2.Init},
		// Other sources
		{"bubble", bubble.Init},
		{"doorbird", doorbird.Init},
		{"dvrip", dvrip.Init},
		{"eseecloud", eseecloud.Init},
		{"flussonic", flussonic.Init},
		{"gopro", gopro.Init},
		{"isapi", isapi.Init},
		{"ivideon", ivideon.Init},
		{"kasa", kasa.Init},
		{"mpegts", mpeg.Init},
		{"multitrans", multitrans.Init},
		{"nest", nest.Init},
		{"ring", ring.Init},
		{"roborock", roborock.Init},
		{"tapo", tapo.Init},
		{"tuya", tuya.Init},
		{"wyze", wyze.Init},
		{"xiaomi", xiaomi.Init},
		{"yandex", yandex.Init},
		// Helper modules
		{"debug", debug.Init},
		{"ngrok", ngrok.Init},
		{"pinggy", pinggy.Init},
		{"srtp", srtp.Init},
	}

	for _, m := range modules {
		if app.Modules == nil || m.name == "" || slices.Contains(app.Modules, m.name) {
			m.init()
		}
	}

	appendLog("engine started")

	// 阻塞等停止；不要调信号等待（iOS 进程里信号不是引擎的生命周期信号）。
	<-done

	appendLog("engine stopped")
}

//export IMIStartEngine
func IMIStartEngine(configPath *C.char, logPath *C.char) C.int {
	cfg := goString(configPath)
	log := goString(logPath)
	if cfg == "" || log == "" {
		mu.Lock()
		startErr = "IMIStartEngine: configPath/logPath must not be empty"
		mu.Unlock()
		return 1
	}
	mu.Lock()
	if running {
		mu.Unlock()
		return 1 // 已在运行；不要重复启动。
	}
	if everStarted {
		// flag.Parse() 与各模块 Init() 不是幂等的；进程内只允许启动一次。
		// 再次启动要 App 重新拉起进程，不要谎报成功。
		startErr = "IMIStartEngine: restart requires App relaunch"
		mu.Unlock()
		return 2
	}
	running = true
	everStarted = true
	startErr = ""
	done = make(chan struct{})
	logFilePath = log
	mu.Unlock()

	appendLog("IMIStartEngine: starting engine")
	go runEngine(cfg)

	// 异步启动：返回 0 只表示“已接受启动请求”，真正的运行状态
	// 由 IMIEngineStatus 查询；启动失败的原因写进日志文件与 startErr。
	return 0
}

//export IMIStopEngine
func IMIStopEngine() C.int {
	mu.Lock()
	if !running {
		mu.Unlock()
		return 0 // 幂等：未在运行也返回 0。
	}
	close(done)
	running = false
	mu.Unlock()
	appendLog("IMIStopEngine: stop requested")
	// 注意：上面只关了 done chan。HTTP/RTSP/WebRTC 监听是否真停、
	// 端口是否释放、流注册表是否清理，go2rtc 没有公开的 Stop API，
	// 实测前不要声称已释放。
	return 0
}

//export IMIEngineStatus
func IMIEngineStatus() *C.char {
	// 返回的 C 字符串由调用方（Swift 侧）负责 C.free，
	// 不要返回指向 Go 内存的指针。
	return statusJSON()
}

func main() {
	// c-archive 模式下 main() 不会被调用，但 package main 必须有 main 函数。
	// 不要在这里启动引擎——启动只由 IMIStartEngine 触发。
}
