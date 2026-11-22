//
//  GoEngineBridge.h — c-archive 桥接头（占位，Phase 1）
//
//  真实头文件由 Go 编译生成：
//      CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC=<clangwrap.sh> \
//        go build -buildmode=c-archive -o libgo2rtc.a ./cmd/libimi
//  生成的 libgo2rtc.h 会声明 IMIStartEngine / IMIStopEngine 等导出函数。
//  本文件只是占位声明，链接时没有 libgo2rtc.a 会失败 —— 这是预期的，
//  见 ARCHITECTURE.md §4.1 与 VALIDATION.md V-01。
//
//  TODO (Phase 1B): 用真实生成的头文件替换本文件，不要手写改动导出签名。
//

#ifndef GoEngineBridge_h
#define GoEngineBridge_h

// TODO: 待 libgo2rtc.a 生成后，由 Go 侧 //export 生成以下声明：
//   int IMIStartEngine(const char *configPath, const char *logPath);
//   int IMIStopEngine(void);
//   const char *IMIEngineStatus(void);

#endif /* GoEngineBridge_h */
