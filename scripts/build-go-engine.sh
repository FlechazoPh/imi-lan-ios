#!/bin/bash
# IMI-LAN iOS — Go c-archive 交叉编译脚本（Phase 2，未验证）
#
# 目标：把已打补丁的 go2rtc 1.9.15 编成 iOS arm64 静态库 libgo2rtc.a + libgo2rtc.h，
# 再由 Swift 经 Bridging Header 调用（见 docs/GO-ENGINE-C-ARCHIVE.md）。
#
# 运行环境：只在 MacBook / macOS runner 上跑。本机 Linux 上 go/xcodebuild 均不存在，
# 预检就会退出——这是预期的，不要在本机上强行装 Go 再假装编过。
#
# 用法（在 MacBook 上，仓库根目录）：
#   ./scripts/build-go-engine.sh                # 只编真机 arm64
#   ./scripts/build-go-engine.sh --simulator     # 再编模拟器库并用 lipo 合并
#   ./scripts/build-go-engine.sh --skip-patches  # 源码已打好补丁时跳过 Step 2（不推荐首跑）
#   FETCH_PATCHES=1 ./scripts/build-go-engine.sh # 补丁缺失时自动从 IMI-LAN 上游取
#                                                 # （默认不自动取：首跑应在 Mac 上手工取补丁、
#                                                 #  手工打补丁，确认无误后再用自动取）
#
# 产物：
#   build/libgo2rtc-arm64.a / build/libgo2rtc-arm64.h   真机库
#   build/libgo2rtc.a / build/libgo2rtc.h               最终交接物（真机；加 --simulator 时为 fat 库）
#   交接位置：IMILAN/Engine/vendor/（不进 git，见 .gitignore）
#
# 前置见 docs/GO-ENGINE-C-ARCHIVE.md §2（Go 版本以 go2rtc go.mod 为准、Xcode 16+、
#   go2rtc 1.9.15、两个补丁、cmd/libimi 入口）。Step 3 的模板
#   （engine/libimi/main.go.template）必须先在 Mac 上按源码填好，否则 Step 4
#   一定失败——这是预期的，失败信息会指到模板。
# 每一步失败都直接退出（set -euo pipefail + 显式 exit 1）并打印原因，不继续往下编。
set -euo pipefail
cd "$(dirname "$0")/.."

GO2RTC_VERSION="${GO2RTC_VERSION:-v1.9.15}"
# IMI-LAN 上游仓库：只用来取 fpk/patches/ 下的两个补丁，不取它的任何二进制。
# IMI_LAN_REF 为空时取默认分支，并把 commit SHA 打印出来；想锁版本时再传 ref，
# 但不要凭空编一个 tag——先确认上游确实有这个 tag 再传。
IMI_LAN_REF="${IMI_LAN_REF:-}"
SRC_DIR="build/go2rtc-src"
PATCH_DIR="build/patches"
OUT_DIR="build"
SIMULATOR=0
SKIP_PATCHES=0
for arg in "$@"; do
  case "$arg" in
    --simulator) SIMULATOR=1 ;;
    --skip-patches) SKIP_PATCHES=1 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- Step 0: 预检 ---------------------------------------------------------
echo "== Step 0: 预检 =="
command -v go >/dev/null || fail "未找到 go（须在 MacBook 上装 Go，见 docs/GO-ENGINE-C-ARCHIVE.md §2 P-2）"
command -v xcodebuild >/dev/null || fail "未找到 xcodebuild（须在 MacBook 上装 Xcode 16+）"
command -v xcrun >/dev/null || fail "未找到 xcrun"
command -v lipo >/dev/null || fail "未找到 lipo"
command -v patch >/dev/null || fail "未找到 patch"
command -v git >/dev/null || fail "未找到 git"
test -x scripts/clangwrap-ios.sh || fail "scripts/clangwrap-ios.sh 不可执行，先 chmod +x"
go version
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
echo "IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-17.0}（默认 17.0，与工程一致）"
mkdir -p "$OUT_DIR"

# ---- Step 1: 取 go2rtc 源码 ----------------------------------------------
echo "== Step 1: 取 go2rtc $GO2RTC_VERSION 源码 =="
if [ -d "$SRC_DIR/.git" ]; then
  echo "源码目录已存在，跳过 clone（若 tag 不对请删掉 $SRC_DIR 重跑）"
  git -C "$SRC_DIR" describe --tags 2>/dev/null || true
  git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || true
else
  # 注意：不要用官方 release 二进制，那里面没有小米补丁。
  git clone --depth 1 --branch "$GO2RTC_VERSION" https://github.com/AlexxIT/go2rtc.git "$SRC_DIR" \
    || fail "clone go2rtc $GO2RTC_VERSION 失败（检查网络与 tag 是否存在）"
fi
# Go 版本以 go2rtc 源码的 go.mod 为准，不要只信脚本注释里的版本号。
if [ -f "$SRC_DIR/go.mod" ]; then
  echo "go2rtc go.mod 要求：$(grep '^go ' "$SRC_DIR/go.mod" || echo '未找到 go 指令')"
  echo "本机 Go：$(go version)"
  echo "若本机 Go 低于 go.mod 要求，先升级 Go 再重跑（不要改 go.mod 绕过）。"
else
  fail "源码里没有 go.mod（$SRC_DIR/go.mod 缺失），clone 可能不完整"
fi

# ---- Step 1b: 取补丁（仅当补丁缺失且 FETCH_PATCHES=1） -------------------
# 默认不自动取：首跑应在 Mac 上手工取补丁、手工打补丁。
# CI（.github/workflows/build-ipa.yml）会在调本脚本之前先取好补丁。
echo "== Step 1b: 补丁来源检查 =="
mkdir -p "$PATCH_DIR"
if [ ! -f "$PATCH_DIR/xiaomi-login.patch" ] || [ ! -f "$PATCH_DIR/xiaomi-control.patch" ]; then
  if [ "${FETCH_PATCHES:-0}" = "1" ]; then
    echo "补丁缺失且 FETCH_PATCHES=1，从 IMI-LAN 上游取（只取 fpk/patches/）"
    rm -rf build/imi-lan-upstream
    if [ -n "$IMI_LAN_REF" ]; then
      git clone --depth 1 --branch "$IMI_LAN_REF" https://github.com/pigstrong9/IMI-LAN.git build/imi-lan-upstream \
        || fail "clone IMI-LAN ref $IMI_LAN_REF 失败（先确认上游确实有这个 ref）"
    else
      git clone --depth 1 https://github.com/pigstrong9/IMI-LAN.git build/imi-lan-upstream \
        || fail "clone IMI-LAN 默认分支失败"
    fi
    echo "IMI-LAN 上游 commit：$(git -C build/imi-lan-upstream rev-parse HEAD)"
    cp build/imi-lan-upstream/fpk/patches/xiaomi-login.patch "$PATCH_DIR/" \
      || fail "上游缺少 fpk/patches/xiaomi-login.patch"
    cp build/imi-lan-upstream/fpk/patches/xiaomi-control.patch "$PATCH_DIR/" \
      || fail "上游缺少 fpk/patches/xiaomi-control.patch"
  else
    echo "补丁缺失：$PATCH_DIR/xiaomi-login.patch 或 xiaomi-control.patch 不存在。"
    echo "  做法 A（首跑推荐）：手工从 IMI-LAN 仓库 fpk/patches/ 取两个补丁放到 $PATCH_DIR/，再重跑。"
    echo "  做法 B：FETCH_PATCHES=1 $0 $*（自动从上游默认分支取，commit SHA 会打印出来）。"
    exit 1
  fi
fi
echo "补丁文件："
ls -l "$PATCH_DIR/xiaomi-login.patch" "$PATCH_DIR/xiaomi-control.patch"
sha256sum "$PATCH_DIR/"*.patch 2>/dev/null || shasum -a 256 "$PATCH_DIR/"*.patch

# ---- Step 2: 打补丁（顺序不能换） ----------------------------------------
echo "== Step 2: 打补丁 xiaomi-login → xiaomi-control =="
if [ "$SKIP_PATCHES" -eq 1 ]; then
  echo "跳过打补丁（--skip-patches）。若补丁其实没打，Step 6 会失败。"
else
  # 补丁来源：IMI-LAN 仓库 fpk/patches/（与 fpk/build.py 同款顺序）。
  for p in xiaomi-login xiaomi-control; do
    f="$PATCH_DIR/$p.patch"
    test -f "$f" || fail "缺补丁文件 $f"
    echo "-- dry-run $p.patch"
    (cd "$SRC_DIR" && patch -p1 --dry-run < "../patches/$p.patch") || {
      echo "dry-run 失败。先看下面两行，再决定是已打过（用 --skip-patches）还是版本不对："
      git -C "$SRC_DIR" status --short | head -20
      git -C "$SRC_DIR" diff --stat | head -20
      echo "FAIL: $p.patch 干跑失败（可能已打过或源码版本不对）。勿强行 -f 打。" >&2
      exit 1
    }
    (cd "$SRC_DIR" && patch -p1 < "../patches/$p.patch") \
      || fail "$p.patch 正式打补丁失败"
  done
  echo "-- 补丁改动统计："
  git -C "$SRC_DIR" diff --stat
fi

# ---- Step 3: 放入口 -------------------------------------------------------
echo "== Step 3: 放入口 cmd/libimi =="
test -f engine/libimi/main.go || {
  echo "FAIL: engine/libimi/main.go 不存在。"
  echo "  先按 engine/libimi/main.go.template + docs/GO-ENGINE-C-ARCHIVE.md §3"
  echo "  在 Mac 上填好 go2rtc 内部入口（§A grep 清单），再复制为 engine/libimi/main.go。"
  echo "  不要直接把模板改名——模板里的 TODO 会让下一步检查失败，这是预期的。"
  exit 1
}
grep -q "TODO" engine/libimi/main.go && {
  echo "FAIL: engine/libimi/main.go 里还有 TODO（内部入口未填），先填好再编。"
  grep -n "TODO" engine/libimi/main.go >&2
  exit 1
}
# 模板里的关键禁令：库版入口里绝不能出现阻塞式信号等待。
grep -q "RunUntilSignal" engine/libimi/main.go && {
  echo "FAIL: engine/libimi/main.go 里有 RunUntilSignal（见模板 §B：停止只由 IMIStopEngine 触发）。"
  echo "  改成等 done chan，见 engine/libimi/main.go.template §A/§C。"
  exit 1
}
mkdir -p "$SRC_DIR/cmd/libimi"
cp engine/libimi/main.go "$SRC_DIR/cmd/libimi/main.go"
echo "已复制 engine/libimi/main.go -> $SRC_DIR/cmd/libimi/main.go"

# ---- Step 4: 编真机库 -----------------------------------------------------
# 注意：go build 没有 --chdir 参数，正确做法是 cd 进源码目录再编（Go 1.20+ 也可用 `go -C dir build`，
# 这里用 cd 子 shell，兼容性最好）。输出用绝对路径，避免 cd 后相对路径错位。
echo "== Step 4: 编真机 arm64 c-archive =="
ROOT="$PWD"
(cd "$SRC_DIR" && CGO_ENABLED=1 GOOS=ios GOARCH=arm64 SDK=iphoneos \
  CC="$ROOT/scripts/clangwrap-ios.sh" \
  go build -buildmode=c-archive \
    -o "$ROOT/$OUT_DIR/libgo2rtc-arm64.a" ./cmd/libimi) \
  || fail "编真机 c-archive 失败（看上面 go build 的报错；常见原因见 docs/GO-ENGINE-C-ARCHIVE.md §6）"
test -s "$OUT_DIR/libgo2rtc-arm64.a" || fail "libgo2rtc-arm64.a 为空或不存在"
test -s "$OUT_DIR/libgo2rtc-arm64.h" || fail "libgo2rtc-arm64.h 为空或不存在"
ls -lh "$OUT_DIR/libgo2rtc-arm64.a" "$OUT_DIR/libgo2rtc-arm64.h"

# ---- Step 5: （可选）编模拟器库并合并 ------------------------------------
if [ "$SIMULATOR" -eq 1 ]; then
  echo "== Step 5: 编模拟器库并 lipo 合并 =="
  (cd "$SRC_DIR" && CGO_ENABLED=1 GOOS=ios GOARCH=arm64 SDK=iphonesimulator \
    CC="$ROOT/scripts/clangwrap-ios.sh" \
    go build -buildmode=c-archive \
      -o "$ROOT/$OUT_DIR/libgo2rtc-sim-arm64.a" ./cmd/libimi) \
    || fail "编模拟器 c-archive 失败"
  lipo -create "$OUT_DIR/libgo2rtc-arm64.a" "$OUT_DIR/libgo2rtc-sim-arm64.a" \
    -output "$OUT_DIR/libgo2rtc.a" || fail "lipo 合并失败"
  cp "$OUT_DIR/libgo2rtc-arm64.h" "$OUT_DIR/libgo2rtc.h"
else
  cp "$OUT_DIR/libgo2rtc-arm64.a" "$OUT_DIR/libgo2rtc.a"
  cp "$OUT_DIR/libgo2rtc-arm64.h" "$OUT_DIR/libgo2rtc.h"
fi

# ---- Step 6: 校验 ---------------------------------------------------------
echo "== Step 6: 校验 =="
lipo -info "$OUT_DIR/libgo2rtc.a" || fail "lipo -info 失败"
lipo -info "$OUT_DIR/libgo2rtc.a" | grep -q "arm64" || fail "lipo -info 里没有 arm64（V-01 未通过）"
echo "-- 导出符号（应能找到 IMIStartEngine / IMIStopEngine / IMIEngineStatus）："
nm -g "$OUT_DIR/libgo2rtc.a" | grep -E "IMIStartEngine|IMIStopEngine|IMIEngineStatus" || {
  echo "FAIL: 导出符号缺失，V-01 未通过。先查 cmd/libimi 的 //export 是否写对。" >&2; exit 1; }
grep -E "IMIStartEngine|IMIStopEngine|IMIEngineStatus" "$OUT_DIR/libgo2rtc.h" || {
  echo "FAIL: 头文件里缺导出声明，V-01 未通过。" >&2; exit 1; }
echo "-- 产物大小："
ls -lh "$OUT_DIR/libgo2rtc.a" "$OUT_DIR/libgo2rtc.h"

# ---- Step 7: 交接 ---------------------------------------------------------
echo "== Step 7: 交接 =="
mkdir -p IMILAN/Engine/vendor
cp "$OUT_DIR/libgo2rtc.a" "$OUT_DIR/libgo2rtc.h" IMILAN/Engine/vendor/
ls -lh IMILAN/Engine/vendor/
echo "OK: libgo2rtc.a 已生成（V-01 构建通过，不等于真机验证通过）。"
echo "下一步：在 Xcode 里把 IMILAN/Engine/vendor/libgo2rtc.a 拖进 target，"
echo "Bridging Header 指向 vendor/libgo2rtc.h，再按 docs/GO-ENGINE-C-ARCHIVE.md §7 验 V-02。"
