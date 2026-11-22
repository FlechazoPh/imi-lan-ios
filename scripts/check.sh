#!/bin/bash
# 骨架自检（Linux 可跑，不构建、不联网、不读 /tmp/imi-lan）
set -u
cd "$(dirname "$0")/.."
fail=0
check() {
  if [ -e "$1" ]; then echo "OK  $1"; else echo "MISS $1"; fail=1; fi
}
for f in README.md ARCHITECTURE.md VALIDATION.md .gitignore \
  docs/CAMERA-4PRO.md docs/MULTICAST-ENTITLEMENT.md docs/SIGNING.md docs/GO-ENGINE-C-ARCHIVE.md \
  IMILAN.xcodeproj/project.pbxproj \
  IMILAN/IMILANApp.swift IMILAN/ContentView.swift IMILAN/Info.plist IMILAN/IMILAN.entitlements \
  IMILAN/Models/Camera.swift \
  IMILAN/Engine/EngineManager.swift IMILAN/Engine/GoEngineBridge.swift IMILAN/Engine/GoEngineBridge.h \
  IMILAN/Engine/XiaomiConfig.swift \
  IMILAN/Web/WebViewContainer.swift IMILAN/Web/LocalGateway.swift IMILAN/Web/Fmp4Player.swift \
  IMILAN/Auth/KeychainStore.swift IMILAN/Auth/QRLoginView.swift IMILAN/Auth/XiaomiQRLogin.swift \
  IMILAN/Views/CameraGridView.swift IMILAN/Views/CameraCardView.swift \
  IMILAN/Views/SingleCameraView.swift IMILAN/Views/SettingsView.swift IMILAN/Views/EngineLogView.swift \
  engine/libimi/main.go.template engine/patches/imi-ios-xiaomi-token.patch \
  .github/workflows/build-ipa.yml \
  scripts/build-ipa-local.sh scripts/build-go-engine.sh scripts/clangwrap-ios.sh; do
  check "$f"
done
# 可执行位检查（脚本须 +x，否则 MacBook/Actions 上跑不起来）
for s in scripts/build-ipa-local.sh scripts/build-go-engine.sh scripts/clangwrap-ios.sh scripts/check.sh; do
  if [ -x "$s" ]; then echo "OK  $s (+x)"; else echo "MISS +x $s"; fail=1; fi
done
echo "---"
echo "Swift 文件数: $(find IMILAN -name '*.swift' | wc -l)"
echo "TODO 数量: $(grep -rn 'TODO' IMILAN scripts .github 2>/dev/null | wc -l) (应 >0，骨架阶段 TODO 是预期的)"
echo "行数: $(find IMILAN -name '*.swift' | xargs wc -l | tail -1)"
[ "$fail" -eq 0 ] && echo "CHECK PASS (仅文件齐全，不代表可编译/可运行)" || echo "CHECK FAIL"
exit $fail
