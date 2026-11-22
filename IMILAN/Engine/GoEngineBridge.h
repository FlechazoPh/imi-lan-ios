
//
//  GoEngineBridge.h — c-archive 桥接头（Phase 1B）
//
//  导出声明由 Go 编译生成，不要手写改动签名：
//      CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC=<clangwrap.sh> \
//        go build -buildmode=c-archive -o libgo2rtc.a ./cmd/libimi
//  生成的 libgo2rtc.h 由 scripts/build-go-engine.sh 交接到
//  IMILAN/Engine/vendor/（不进 git），本文件直接包含它。
//  先跑构建脚本再编 Xcode，否则头文件缺失、Swift 编译失败——这是预期的。
//

#ifndef GoEngineBridge_h
#define GoEngineBridge_h

#include "vendor/libgo2rtc.h"

#endif /* GoEngineBridge_h */
