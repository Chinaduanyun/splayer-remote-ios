# SPlayer 遥控器（iOS）

面向 **SPlayer for Android Next** 的原生 SwiftUI iPhone 遥控器。它是一个**独立应用**，
与 SPlayer 官方项目没有隶属关系，也不使用其品牌素材。

- 单一「正在播放」面板 + 悬浮玻璃交通控制簇
- iOS 26 使用真正的 Liquid Glass（`.glassEffect` / `.buttonStyle(.glass)`），
  iOS 17–25 自动退回 `Material` 玻璃质感
- 轮询播放状态（约 2 秒），支持播放 / 暂停 / 停止 / 上一曲 / 下一曲 / 跳转 / 音量
- Token 存放于 **系统钥匙串**；主机与端口存于 `UserDefaults`
- 温暖深色背景 + 克制的橙色强调，中文界面，支持动态字体与「减弱动态效果」

> ⚠️ 本项目只在 Linux 上做了**结构校验**：本环境没有 `swift` / `xcodebuild`，
> **尚未编译、未做语义类型检查、未运行 XCTest**。请在 macOS + Xcode 上完成编译与测试。

---

## 1. 上游 API 契约

来自 `reference/`（已检索的上游 Kotlin 与文档）与
<https://github.com/SPlayer-CE/SFA-Next-docs/blob/main/docs/api.md>：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/external/info` | `{name, version, wsClients}` |
| GET | `/api/external/status` | `{state, position(ms), duration(ms), volume(0..1), isFinished}` |
| GET | `/api/external/now-playing` | `{src, songId, paused, playing, buffering, position(ms), duration(ms), volume}` |
| POST | `/api/external/play` `/pause` `/stop` `/next` `/prev` | `{ok:true}` |
| POST | `/api/external/seek` | `{positionMs: Int >= 0}` |
| POST | `/api/external/volume` | `{volume: Double 0..1}` |

要点：

- 鉴权：`Authorization: Bearer TOKEN`（或 `X-SPlayer-Token`）。**本 App 只放在请求头**，
  绝不写入 URL / 查询参数，也不写入日志。
- `next` / `prev` 是异步派发，命令返回 `{ok:true}` **不代表**播放已切换；App 通过轮询确认最终状态。
- 上游**不提供**标题、艺人、封面。`now-playing` 里的 `src` 是媒体地址，App **刻意不解析**，
  既不显示也不记录。

---

## 2. 目录结构

```
SPlayerRemote.xcodeproj/        由脚本生成的真实 Xcode 工程（含共享 scheme）
SPlayerRemote/
  App/            SPlayerRemoteApp.swift
  Models/         RemoteModels.swift（解码模型，忽略 src）
  Networking/     HostValidator / APIRequestFactory / RemoteAPIClient / RemoteAPIError
  Security/       KeychainStore.swift（钥匙串 Token 存储）
  Persistence/    SettingsStore.swift（只持久化 host/port）
  ViewModels/     RemoteViewModel.swift（轮询 / 命令互斥 / 世代隔离）
  Views/          GlassSupport / Components / RootView / SettingsView
  Resources/      Assets.xcassets（AppIcon / AccentColor）
  Info.plist
SPlayerRemoteTests/             聚焦的协议 / 请求契约 / 状态机测试
scripts/
  generate_xcodeproj.py         用 Python 标准库生成 .xcodeproj
  generate_icon.py              生成 1024x1024 App 图标
  validate_project.py           Linux 可运行的结构一致性检查
  build_unsigned.sh             生成未签名设备 IPA（不能直接安装）
mockserver/
  mock_server.py                本地 Mock HTTP 服务器
  fixtures/*.json               与契约一致的夹具
project.yml                     XcodeGen 可选配置（若你更偏好 XcodeGen）
```

工程文件 `SPlayerRemote.xcodeproj/project.pbxproj` 由脚本**确定性地**生成，可重复执行：

```bash
python3 scripts/generate_xcodeproj.py
```

若你更偏好 [XcodeGen](https://github.com/yonaskolb/XcodeGen)，也可以：

```bash
xcodegen generate   # 读取 project.yml
```

---

## 3. 在 macOS 上构建与运行

前置：macOS + Xcode 26 或更新版本。即使运行于 iOS 17，源码中使用的 Liquid Glass API 也需要 Xcode 26 SDK 才能编译；运行时会自动回退到磨砂材质。

```bash
# 1) 生成工程（仓库已包含，重复生成保持一致）
python3 scripts/generate_xcodeproj.py

# 2) 打开
open SPlayerRemote.xcodeproj
```

在 Xcode 中：

1. 选择 target `SPlayerRemote` → **Signing & Capabilities**；
2. 勾选 *Automatically manage signing*，选择你的 Team；
3. 把 Bundle ID（默认 `com.example.splayerremote`）改成全局唯一的（例如 `com.yourname.splayerremote`）；
4. 选择已连接的 iPhone 或模拟器运行。

### 运行测试

```bash
xcodebuild test \
  -project SPlayerRemote.xcodeproj \
  -scheme SPlayerRemote \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

（模拟器名称按本机 `xcrun simctl list devices available` 调整。）

### 生成未签名归档（仅用于检查包结构）

```bash
./scripts/build_unsigned.sh
```

输出 `build/SPlayerRemote-unsigned.ipa`，内含为 iPhone 编译的 `.app` 和标准 `Payload/` 目录。**它尚未签名，不能直接安装到真机**；需要使用自己的有效签名与 provisioning profile，或在 Xcode 中配置 Team 后安装。

也可在公开仓库的 Actions 页面手动运行 `iOS build and tests`：标准 macOS runner 执行模拟器测试与设备归档，产物只保留 3 天。工作流不需要 Apple ID 或签名凭证，不自动在 push 时触发。

---

## 4. Android 端准备

1. 打开 SPlayer for Android Next。
2. 进入 **设置 → 外部 API**，开启服务。
3. 如需从 iPhone 访问，开启 **允许局域网访问**。
4. 记下 **端口**（默认 `6688`）与 **Token**（32 字节十六进制）。
5. 确保 iPhone 与手机处于同一 WiFi，且手机 IP 可从 iPhone 访问。

在 App 的「设置」中填写：主机（例如 `192.168.31.100` 或 `myphone.local`）、端口、Token，
点「保存并连接」。

---

## 5. 安全说明

- **Token 只存钥匙串**（`kSecClassGenericPassword`，`AfterFirstUnlockThisDeviceOnly`），
  不写入 `UserDefaults` / 明文文件 / 日志；写入失败会显式报错，绝不静默降级。
- **明文 HTTP**：局域网直连使用 `http://`，Token 会以明文经过受信任的 WiFi。
  请勿在公网或不可信网络暴露该端口，也不要做公网端口转发。如需加密，请自行在可信网络上
  使用 VPN。
- **拒绝 HTTP 重定向**：`URLSession` 委托在收到 3xx 时返回 `nil`，防止 Token 被转发到其它主机。
- **主机校验**：使用 `URLComponents` 构造 URL；拒绝 scheme / 路径 / 查询 / userinfo；
  端口限定 `1...65535`；支持 IPv4、`.local`、IPv6。
- **ATS**：`Info.plist` 设置了 `NSAllowsArbitraryLoads = true` 与 `NSAllowsLocalNetworking = true`，
  这是为了让任意局域网 IP 的明文 HTTP 可用；该放行**范围较宽**，仅适用于本工具类 App 的可信网络场景。
  另含中文 `NSLocalNetworkUsageDescription`。
- 仓库中**不含任何真实 Token**。

---

## 6. 本地 Mock 服务器（可选）

用于在没有 Android 设备时验证网络层：

```bash
python3 mockserver/mock_server.py --host 0.0.0.0 --port 6688 --token devtoken
```

在 App 设置中填入电脑 IP、端口 `6688`、Token `devtoken`。

> Mock 服务器**不能**替代真机联调，只是请求 / 响应契约的复现。

---

## 7. 本仓库已执行的校验 / 未执行的校验

已执行（Linux，无需 Xcode）：

```bash
python3 scripts/validate_project.py   # 结构一致性（51 项通过）
python3 -m py_compile scripts/*.py mockserver/mock_server.py
bash -n scripts/build_unsigned.sh
python3 mockserver/mock_server.py ... # 用 curl 验证端点 / 鉴权 / 400
```

其中 `validate_project.py` 检查：`project.pbxproj` 可解析且引用完整、所有 Swift 文件均被
对应 target 引用、`Info.plist` 关键键与 ATS、资源 `Contents.json` 与图标 PNG、mock 夹具 JSON、
以及仓库内无疑似真实 Token。

**未执行（请在 macOS 上完成）：**

```bash
xcodebuild build -project SPlayerRemote.xcodeproj -scheme SPlayerRemote -destination 'generic/platform=iOS Simulator'
xcodebuild test  -project SPlayerRemote.xcodeproj -scheme SPlayerRemote -destination 'platform=iOS Simulator,name=iPhone 16'
```

因此：**编译、Swift 语义类型检查与 XCTest 均未验证**。已知的潜在风险：
iOS 26 Liquid Glass 的具体 API 名称 / 签名（`.glassEffect(_:in:)`、`.buttonStyle(.glass)`）
需以本机 SDK 为准，若名称不同，只需修改 `Views/GlassSupport.swift` 一处。

---

## 8. 测试覆盖（XCTest）

- `HostValidatorTests`：IPv4 / IPv6 / `.local` / 主机名规范化，scheme、路径、userinfo、非法端口拒绝，
  IPv6 URL 方括号。
- `RequestEncodingTests`：方法、路径、鉴权头、Token 不进 URL、seek / volume 请求体、稳定 JSON。
- `RemoteAPIClientTests`：`URLProtocol` 桩验证 401 / 403 / 5xx / 解码失败 / 网络错误 / 取消映射，
  `now-playing` 忽略 `src`，音量越界钳制。
- `SettingsStoreTests`：host/port 持久化、Token 不入 `UserDefaults`、钥匙串失败上报、清除 Token。
- `RemoteViewModelTests`：连接成功 / 失败、未连接时命令被忽略、命令互斥、音量与跳转钳制。
