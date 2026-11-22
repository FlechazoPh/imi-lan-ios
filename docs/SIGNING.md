# 签名与侧载 — 开发者账号模式（Phase 2）

> 状态：**步骤已写清，未配置、未验证。**
> 用户已有 Apple 开发者账号（Phase 1 时无）。本文件只写步骤与占位 secret 名，
> **不要索要、不要写入真实证书私钥、Team ID、密码、描述文件内容。**
> 所有真实值只由用户在自己的 Mac / GitHub Secrets 里填，绝不进仓库。

## 0. 两种模式（默认未签名）

| 模式 | 触发 | 产物 | 适用 |
|---|---|---|---|
| `unsigned`（默认） | 不传 signing 参数 | 未签名 IPA，需用侧载工具装 | 无证书时调试壳 / 占位验证（V-15） |
| `developer` | 传入开发者账号签名配置 | 已签名 IPA，可直接装真机 / 7 天+有效期按账号类型 | **用户当前模式**：有开发者账号，用 Xcode 直装或 Actions 出已签名包 |

**默认永远是 `unsigned`**。只有用户明确说“用开发者账号签”时才走 `developer` 分支，
workflow 与本地脚本都以开关控制，不写死 Team ID。

## 1. 模式 A — Xcode 用开发者账号直接装真机（推荐先走这条路）

这是最快验证真机的路，不需要先配 Actions secrets：

1. MacBook 上用 Xcode 打开 `IMILAN.xcodeproj`。
2. 选 target `IMILAN` → Signing & Capabilities：
   - 勾选 **Automatically manage signing**
   - Team：选用户的开发团队（**不要把 Team ID 写进仓库**，只在 Xcode 里选）
   - Bundle Identifier：`imi.lan.ios`（与 `Info.plist` / App ID 一致）
3. 若已获批 multicast（见 `docs/MULTICAST-ENTITLEMENT.md`）：
   - 同一页 `+ Capability` → **Multicast Networking**，确认 `IMILAN.entitlements` 被引用。
   - 若未获批，**不要加**这个 Capability，否则签名会失败。
4. iPhone 用数据线连 MacBook，Xcode 顶部设备选这台 iPhone（iOS 27.0.1），点 Run。
5. 首次运行若 iPhone 提示“不受信任的开发者”：iPhone → 设置 → 通用 → VPN 与设备管理 →
   点开发者的 Apple ID → 信任。
6. 验证点：App 能启动到首页（V-14），再按 VALIDATION.md 逐项验证。

排错：

- `No signing certificate "iOS Development" found`：Xcode → Settings → Accounts →
  选 Apple ID → Download Manual Profiles，或让 Xcode 自动创建开发证书。
- `Provisioning profile doesn't include the multicast entitlement`：
  描述文件是获批前生成的，按 `docs/MULTICAST-ENTITLEMENT.md` §4 再生。
- `Failed to code sign` 且用了手动签名：先切回 Automatically manage signing 再试。

## 2. 模式 B — MacBook 本地导出已签名 IPA

```bash
# 1. 先在 Xcode 里跑通一次模式 A（自动签名已生成证书与描述文件）
# 2. 用脚本导出已签名包（Team ID 只在命令行/环境变量里传，不写进仓库）：
IMILAN_TEAM_ID="<你的 Team ID，只在本地终端里填，不要提交>" \
  ./scripts/build-ipa-local.sh --signed

# 产物：build/IMI-LAN-iOS-signed.ipa
# 3. 把 IPA 传到 iPhone 安装（AirDrop / 侧载工具均可，用户自选）
```

脚本行为（见 `scripts/build-ipa-local.sh`）：

- `--signed` 时：`xcodebuild archive` 用 `CODE_SIGN_STYLE=Automatic`
  + `DEVELOPMENT_TEAM=$IMILAN_TEAM_ID`，再用 `xcodebuild -exportArchive`
  + `ExportOptions.plist`（method=`development`，由脚本在 `build/` 下临时生成，**不进仓库**）导出 IPA。
- 不传 `--signed` 时：保持 Phase 1 的未签名分支不变。
- `IMILAN_TEAM_ID` 未设置时 `--signed` 会直接报错退出，不会用空值继续编。

## 3. 模式 C — GitHub Actions 出已签名 IPA（可选）

### 3.1 需要用户在自己 Mac 上准备的东西（一次性）

只在用户自己的 Mac 上做，**不要把生成的文件发给助手**：

1. **导出开发/发布证书（.p12）**：
   - Mac → 钥匙串访问 → 登录钥匙串 → 我的证书 → 找到 `Apple Development` /
     `Apple Distribution` 证书（没有就先在开发者网站创建一个）→ 右键 → 导出 →
     存为 `.p12`，设一个强密码（这个密码就是 `P12_PASSWORD`）。
   - 转 base64：`base64 -i Certificates.p12 | pbcopy`（macOS）→ 贴进 GitHub secret
     `BUILD_CERTIFICATE_BASE64`。
2. **下载描述文件（.mobileprovision）**：
   - 开发者网站 → Certificates, Identifiers & Profiles → Profiles →
     找到 `imi.lan.ios` 的开发描述文件（Development，含这台 iPhone 的 UDID）→ Download。
   - 转 base64：`base64 -i xxx.mobileprovision | pbcopy` → 贴进 secret
     `PROVISION_PROFILE_BASE64`。
   - 若已获批 multicast，**必须用获批后重新生成的描述文件**，旧的会缺 entitlement。
3. **Team ID**：开发者网站 → Membership → Team ID（10 位字符）→ secret `IOS_TEAM_ID`。
4. **Keychain 密码**：任意随机密码，`openssl rand -base64 32` 生成 → secret `KEYCHAIN_PASSWORD`。
   仅供 Actions  runner 上的临时钥匙串使用，与 Apple ID 密码无关。

### 3.2 GitHub Secrets 占位名（只列名，不含值）

| Secret 名 | 内容 | 备注 |
|---|---|---|
| `BUILD_CERTIFICATE_BASE64` | .p12 的 base64 | 见 §3.1-1 |
| `P12_PASSWORD` | .p12 导出密码 | 用户自设 |
| `PROVISION_PROFILE_BASE64` | .mobileprovision 的 base64 | 见 §3.1-2，获批 multicast 后要用新版 |
| `KEYCHAIN_PASSWORD` | 临时钥匙串密码（随机） | `openssl rand -base64 32` |
| `IOS_TEAM_ID` | 10 位 Team ID | 开发者网站 Membership 页 |
| `IOS_PROVISIONING_PROFILE_NAME` | 描述文件显示名（可选） | 若 workflow 里用名字匹配时才需要 |

> 再次强调：以上 secret **只由用户在 GitHub 仓库 Settings → Secrets and variables → Actions
> 里自己填**。助手不索要、不接收、不写入这些值。

### 3.3 Workflow 里的签名步骤（见 `.github/workflows/build-ipa.yml`）

`signing_mode` 是 `workflow_dispatch` 的输入，默认 `unsigned`：

- `unsigned`：跳过全部签名步骤，走 Phase 1 的 `CODE_SIGN_IDENTITY=""` 分支。
- `developer`：按顺序执行——
  1. `if: inputs.signing_mode == 'developer'` 且 secrets 齐全才继续，缺任一 secret 直接报错退出，
     不会静默回退到未签名（避免用户以为“已签名”其实拿到的是未签名包）。
  2. 建临时钥匙串（`security create-keychain`，密码取 `KEYCHAIN_PASSWORD`），
     导入 `BUILD_CERTIFICATE_BASE64`（密码 `P12_PASSWORD`），设为默认钥匙串。
  3. 解码 `PROVISION_PROFILE_BASE64` 到 `~/Library/MobileDevice/Provisioning Profiles/`。
  4. `xcodebuild archive` 用 `CODE_SIGN_STYLE=Manual` +
     `DEVELOPMENT_TEAM=${{ secrets.IOS_TEAM_ID }}` +
     `CODE_SIGN_IDENTITY="Apple Development"`（开发模式）或
     `Apple Distribution`（发布模式，见 workflow 注释）。
  5. 生成临时 `ExportOptions.plist`（`method=development`，
     `provisioningProfiles: { "imi.lan.ios": "<profile name>" }`，
     `teamID=${{ secrets.IOS_TEAM_ID }}`），`xcodebuild -exportArchive` 导出 IPA。
  6. 上传 Artifact（`IMI-LAN-iOS-signed`）。

### 3.4 不用 TestFlight / App Store 的说明

- 本项目是个人非官方工具，与小米无关联，**不走 App Store 审核**，
  所以 workflow 只出 IPA，不做 `altool` 上传、TestFlight 分发。
- 若用户日后想走 TestFlight，需另加 App Store Connect API Key
 （`APPSTORE_API_KEY_ID` / `APPSTORE_ISSUER_ID` / `APP_APPLE_ID`），
  不在 Phase 2 范围内。

## 4. 安全提醒

- `.p12` 含私钥：**不要提交到 git、不要发聊天、不要放公开网盘**。只放 GitHub Secrets。
- 证书过期 / 描述文件过期后，Actions 会在签名步骤报错，按 §3.1 重新导出即可。
- 换电脑后证书不在新 Mac 的钥匙串里，需重新从开发者网站下载证书或重新导出 .p12。
- 仓库里已有的 `.gitignore` 建议（Phase 2 待补进仓库根 `.gitignore`，若本项目尚未建 git 仓库则先记在这里）：
  `*.p12`、`*.mobileprovision`、`ExportOptions.plist`、`build/`、`*.ipa` 一律不入库。

## 5. 来源

- GitHub Actions iOS 签名通用做法：`BUILD_CERTIFICATE_BASE64` / `P12_PASSWORD` /
  `PROVISION_PROFILE_BASE64` / `KEYCHAIN_PASSWORD` / `TEAM_ID` 五件套，
  临时钥匙串 + base64 解码 + `xcodebuild -exportArchive`（Project-Phoenix-MP
  `GITHUB_ACTIONS_SETUP.md`；sasikanth.dev《Managing iOS signing certificates…》；
  andrewhoog.com《How to build an iOS app with GitHub Actions》）
- `ExportOptions.plist` 模板：`method` / `provisioningProfiles` / `signingStyle=manual` /
  `teamID`（同上）
- Apple 开发者文档：自动签名（Xcode 在 Archive 时用开发证书、Export 时用发布证书重签）
  与手动签名的区别；Multicast 获批后描述文件失效需再生的说明见
  `docs/MULTICAST-ENTITLEMENT.md` §4
