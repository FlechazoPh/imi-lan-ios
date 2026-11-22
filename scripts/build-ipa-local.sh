#!/bin/bash
# IMI-LAN iOS — MacBook 本地打 IPA（Phase 2，未验证，需 Xcode 16+）
#
# 用法（在 MacBook 上，仓库根目录）：
#   ./scripts/build-ipa-local.sh               # 未签名 IPA（默认）
#   ./scripts/build-ipa-local.sh --signed      # 已签名 IPA（开发者账号模式）
#   ./scripts/build-ipa-local.sh --signed --multicast
#                                              # 已签名 + 传 multicast entitlement
#                                              # （仅当 Apple 已批准 multicast 且描述文件
#                                              #  已再生时才加 --multicast，否则签名会失败）
#
# --signed 时须先设置 Team ID（只在本地终端里传，不要写进仓库、不要提交）：
#   IMILAN_TEAM_ID="<你的 Team ID>" ./scripts/build-ipa-local.sh --signed
# 未设置 IMILAN_TEAM_ID 时 --signed 会直接报错退出。
# 未签名模式永远不传 CODE_SIGN_ENTITLEMENTS。
#
# 产物：
#   未签名：build/IMI-LAN-iOS-unsigned.ipa
#   已签名：build/IMI-LAN-iOS-signed.ipa（ExportOptions.plist 在 build/ 下临时生成，不进仓库）
#
# 前置：先在 Xcode 里跑通一次自动签名（docs/SIGNING.md §1），再用 --signed 导出。
# 若已获批 multicast，Xcode 里须已加 Multicast Networking Capability，
# 否则签名会因描述文件缺 entitlement 而失败（见 docs/MULTICAST-ENTITLEMENT.md §4）。
set -euo pipefail
cd "$(dirname "$0")/.."

SIGNED=0
MULTICAST=0
for arg in "$@"; do
  case "$arg" in
    --signed) SIGNED=1 ;;
    --multicast) MULTICAST=1 ;;
    *) echo "未知参数: $arg（可用 --signed / --multicast）" >&2; exit 2 ;;
  esac
done
if [ "$MULTICAST" -eq 1 ] && [ "$SIGNED" -eq 0 ]; then
  echo "FAIL: --multicast 只能和 --signed 一起用（未签名模式不传 entitlement）" >&2
  exit 2
fi

xcodebuild -version
xcodebuild -list -project IMILAN.xcodeproj

if [ "$SIGNED" -eq 0 ]; then
  echo "== 未签名模式 =="
  xcodebuild -project IMILAN.xcodeproj \
    -scheme IMILAN \
    -configuration Release \
    -sdk iphoneos \
    -archivePath build/IMILAN.xcarchive \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    archive

  mkdir -p build/Payload
  rm -rf build/Payload/IMILAN.app
  cp -R build/IMILAN.xcarchive/Products/Applications/IMILAN.app build/Payload/
  cd build && zip -r IMI-LAN-iOS-unsigned.ipa Payload
  ls -lh IMI-LAN-iOS-unsigned.ipa
  echo "OK: build/IMI-LAN-iOS-unsigned.ipa"
  echo "再用侧载工具装到 iPhone（用户自选工具）。"
  exit 0
fi

# ---- 已签名模式 ----
echo "== 开发者账号签名模式 =="
test -n "${IMILAN_TEAM_ID:-}" || {
  echo "FAIL: --signed 需要 IMILAN_TEAM_ID（Team ID 只在本地终端里传，不要写进仓库）" >&2
  echo "  用法：IMILAN_TEAM_ID=\"<你的 Team ID>\" ./scripts/build-ipa-local.sh --signed" >&2
  exit 1
}

# multicast entitlement 只在 --multicast 时传；未获批时绝不传。
ENTITLEMENT_ARGS=()
if [ "$MULTICAST" -eq 1 ]; then
  test -f IMILAN/IMILAN.entitlements || { echo "FAIL: 缺 IMILAN/IMILAN.entitlements" >&2; exit 1; }
  ENTITLEMENT_ARGS=(CODE_SIGN_ENTITLEMENTS="IMILAN/IMILAN.entitlements")
fi

xcodebuild -project IMILAN.xcodeproj \
  -scheme IMILAN \
  -configuration Release \
  -sdk iphoneos \
  -archivePath build/IMILAN.xcarchive \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$IMILAN_TEAM_ID" \
  "${ENTITLEMENT_ARGS[@]}" \
  archive

# ExportOptions.plist 临时生成（method=development），不进仓库。
cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>development</string>
  <key>teamID</key><string>$IMILAN_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath build/IMILAN.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist
ls -lh build/export/*.ipa
cp build/export/*.ipa build/IMI-LAN-iOS-signed.ipa
echo "OK: build/IMI-LAN-iOS-signed.ipa"
