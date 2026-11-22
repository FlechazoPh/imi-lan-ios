#!/bin/sh
# clangwrap-ios.sh — Go c-archive iOS 交叉编译的 clang 包装脚本（Phase 2，从零手写）
#
# 逻辑与 Go 官方 $GOROOT/misc/ios/clangwrap.sh 同款：
#   用 xcrun 找 iphoneos SDK 的 clang，补上 -arch 与 -isysroot 再调用。
# 不要直接用 `xcrun --find clang` 当 CC——缺 -arch/-isysroot 时 cgo 会编出 macOS 库。
#
# 用法：
#   CC="$PWD/scripts/clangwrap-ios.sh" CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
#     go build -buildmode=c-archive -o libgo2rtc.a ./cmd/libimi
#
# 环境变量：
#   SDK     目标 SDK，默认 iphoneos；模拟器时设 SDK=iphonesimulator
#   GOARCH  目标架构，默认 arm64（由 go build 传入，脚本直接用 $GOARCH）
#   IPHONEOS_DEPLOYMENT_TARGET  默认 17.0，与工程部署目标一致
set -eu

SDK="${SDK:-iphoneos}"
GOARCH="${GOARCH:-arm64}"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
CLANG="$(xcrun --sdk "$SDK" --find clang)"

if [ "$SDK" = "iphonesimulator" ]; then
  exec "$CLANG" -arch "$GOARCH" -isysroot "$SDK_PATH" \
    -mios-simulator-version-min="$DEPLOYMENT_TARGET" "$@"
else
  exec "$CLANG" -arch "$GOARCH" -isysroot "$SDK_PATH" \
    -miphoneos-version-min="$DEPLOYMENT_TARGET" "$@"
fi
