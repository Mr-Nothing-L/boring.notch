# 通知横幅整合到刘海 — 开发文档

> 本文档记录「系统通知横幅 → 刘海内嵌显示」功能的已验证技术事实、架构决策与开发指引。
> 最后更新：2026-08-18（功能已实现并通过端到端链路验证，部分 UI 验收待真机确认）

## 1. 功能形态（最终实现）

- **闭合态**：新通知到达 → 刘海黑块**向下延展**一行（图标 + 标题 + 正文 + 同 app 合并「×N」徽标），
  与刘海同一 NotchShape 裁切，无分隔、圆角连续，spring 弹性动效；`notificationPeekDuration` 秒（默认 5，设置 3–10 可调）后自动收起
- **预览行点击** → 展开刘海并直达「通知」tab
- **展开态**：header 左侧 tab 栏新增铃铛 tab（有活跃通知时带红点），点入为**通知卡片页**；
  通知在页面中**持久保留**，直到用户点击跳转（AXPress 原横幅深链接）或点右下角**垃圾桶清空**
- **系统横幅处理**：默认移出屏外（`.hideSystemNotificationBanners`），失败回退镜像显示
- **通知中心面板防护**：点开系统通知中心不会误触发（见 2.4 过滤器）

## 2. PoC 已验证事实（macOS 26.4 实测）

### 2.1 横幅宿主与事件

- 横幅由 **`com.apple.notificationcenterui`** 进程托管
- 需要辅助功能（AX）权限
- **关键坑 1**：必须先对该进程的 AX app 元素设置 `"AXEnhancedUserInterface" = true`，否则 `kAXWindowCreatedNotification` 不触发
- 设置后事件序列：`AXCreated` → `AXWindowCreated` → `AXLayoutChanged`；横幅销毁触发 `AXUIElementDestroyed`

### 2.2 横幅 AX 结构

```
AXWindow (subrole=AXSystemDialog, title="Notification Center")
└─ AXGroup (AXHostingView)
   └─ AXGroup
      └─ AXScrollArea
         └─ AXGroup (subrole=AXNotificationCenterBanner,
                     AXDescription="{App名} {标题}, {副标题}, {正文}")
            ├─ AXStaticText (标题) / (副标题) / (正文)
```

- app 显示名：`AXDescription` 前缀（无 bundleID，用 `NSWorkspace.runningApplications` 最长前缀匹配）

### 2.3 横幅操作

- **移出屏外**：`kAXPositionAttribute` 设 (-5000,-5000)，实测生效（读回确认）
- **动作**：横幅组暴露 `AXPress` / 显示详细信息 / 显示 / 关闭；AXPress 等效用户点击（深链接保留）

### 2.4 通知中心面板 vs 瞬时横幅（防误触发）

- 点菜单栏时钟打开通知中心面板时，面板里**已送达通知带同样的 banner 结构**，若不加区分会被批量误捕获（用户实测出现 ×7 虚增合并计数）
- 实测（macOS 26.4）：瞬时横幅窗口与面板窗口**都是全屏 AXSystemDialog 覆盖层**，subrole 和窗口尺寸都无法区分（瞬时横幅窗口也是 1470×956 全屏，窗口内容才是右上角小卡片）
- **有效判别**：瞬时横幅窗口内只含 **1 个** `AXNotificationCenterBanner`；面板窗口内含**多个**（已送达列表）。helper 只处理横幅数==1 的窗口，>1 拒绝并记日志（实测日志 `window rejected: 3 banners (通知中心面板)`）
- 已知边缘情况：面板里恰好只有 1 条已送达通知时会被误收一条（可接受）

### 2.5 留存语义（用户确认的最终版）

- 通知分组**持久保留**在通知页，直到：点击跳转、垃圾桶清空、功能关闭或 app 重启
- 闭合态预览行按 `notificationPeekDuration` 自动收起（仅影响预览行，不影响页面留存）
- 系统横幅销毁（didDismiss）只清理 AXPress 引用，不移除分组

### 2.6 helper 进程保活

- XPC service 默认会因空闲被系统回收，回收后 AX 监听静默停止、已存横幅 id 失效
- main.swift 里 `ProcessInfo.processInfo.disableAutomaticTermination + disableSuddenTermination` 常驻
- 主 app 侧连接中断时（interruptionHandler）自动 `startNotificationRelay` 重挂
- **listener 接受的连接必须强引用**（弱引用会被提前释放导致反向推送静默丢失）

## 3. 架构（沙盒倒逼的最终形态）

```
NotificationCenter 横幅
   │  AXObserver（非沙盒 XPC helper，专用 runloop 线程）
   ▼
BoringNotchXPCHelper / NotificationRelayService
   │  解析 + 移出屏外 + 持有横幅引用（供 AXPress）
   │  NSXPCConnection 双向通道推送（remoteObjectProxy）
   ▼
NotificationRelayManager（主 app，沙盒）— XPC 客户端
   │  按 app 合并（×N）、groups 持久化、预览行计时
   ▼
ContentView 闭合态分支 → NotificationPeekView（刘海向下延展）
TabSelectionView 铃铛 tab → NotificationsView（卡片页 + 垃圾桶）
```

### 关键决策与两个血泪坑

1. **沙盒主 app 无法注册跨进程 AXObserver**：`AXObserverAddNotification` 在沙盒内稳定返回
   `-25204 (kAXErrorCannotComplete)`；同代码在非沙盒 CLI 正常。→ AX 监听整体下沉到
   **非沙盒 XPC helper**（其 entitlements 本就 `app-sandbox = false`，与亮度/权限检查同一模式）。
   注意：CGEvent tap（HUD 媒体键拦截用的机制）沙盒是允许的，**AXObserver 不是**——两者别混淆。
2. **XPC service 的主 runloop 不被驱动**：`NSXPCListener.service().resume()` 只泵主 dispatch queue，
   挂在 `CFRunLoopGetMain()` 上的 AXObserver 回调永远不触发。→ helper 内为 AXObserver 建了
   **专用 runloop 线程**（`AXRunLoopThread`，空 mach port 保活 + `CFRunLoopRun()`）。
3. XPC 反向推送：主 app 连接上设 `exportedInterface/exportedObject`（须在 `resume()` 之前），
   helper 侧 `ServiceDelegate` 保存连接并设 `remoteObjectInterface`，经 `remoteObjectProxyWithErrorHandler` 推送。

## 4. 设置键（`models/Constants.swift`）

| Key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `.notchNotificationsEnabled` | Bool | false | 总开关；开启时引导辅助功能授权 |
| `.hideSystemNotificationBanners` | Bool | true | 系统横幅移出屏外；失败回退镜像显示 |
| `.notificationPeekDuration` | Double | 5.0 | 闭合态预览行自动隐藏时长（3–10 秒滑杆）；**不影响通知页留存** |
| `.appLanguage` | String | "system" | 语言覆盖：system / zh-Hans / en（写 AppleLanguages + 重启生效） |

## 5. 中英切换

- 设置 → 通用 → 语言：跟随系统 / 中文 / English
- 实现：`UserDefaults AppleLanguages` + `helpers/ApplicationRelauncher.swift` 确认后自动重启
- 简体中文存量翻译已 236/236 完整（Crowdin）；新增文案见 `Localizable.xcstrings`（en + zh-Hans 双语已填）

## 6. 文件地图

| 文件 | 状态 | 说明 |
|---|---|---|
| `BoringNotchXPCHelper/NotificationRelayService.swift` | 新建 | AX 监听/解析/隐藏原横幅/AXPress，专用 runloop 线程 |
| `BoringNotchXPCHelper/main.swift` | 修改 | 反向通道 remoteObjectInterface + 连接保存 |
| `BoringNotchXPCHelper/BoringNotchXPCHelper.swift` | 修改 | 三个新协议方法的入口转发 |
| `BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift` | 修改 | 协议 + NotificationRelayClientProtocol（与主 app 侧拷贝保持同步） |
| `boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift` | 修改 | 协议主 app 侧拷贝（与 helper 侧同步） |
| `boringNotch/XPCHelperClient/XPCHelperClient.swift` | 修改 | relay start/stop/press 客户端方法 + exportedObject 反向通道 |
| `boringNotch/managers/NotificationRelayManager.swift` | 新建 | 合并/留存/预览计时/清空/跳转（XPC 客户端，无直接 AX） |
| `boringNotch/components/Live activities/NotificationPeekView.swift` | 新建 | 闭合态延展行 + 通知卡片页 + 垃圾桶 |
| `boringNotch/ContentView.swift` | 修改 | 闭合态通知分支（peekVisible）+ 延展动效 + tab switch 新 case |
| `boringNotch/components/Tabs/TabSelectionView.swift` | 修改 | 铃铛 tab + 红点徽标 |
| `boringNotch/enums/generic.swift` | 修改 | `NotchViews.notifications` |
| `boringNotch/components/Notch/BoringHeader.swift` | 修改 | （曾插紧凑视图，后改 tab 方案已还原） |
| `boringNotch/models/Constants.swift` | 修改 | 4 个新 Defaults keys |
| `boringNotch/components/Settings/SettingsView.swift` | 修改 | 通知分区 + 通用区语言切换 |
| `boringNotch/Localizable.xcstrings` | 修改 | 新增 key 的 en + zh-Hans |

## 7. 构建与调试

- 构建：`xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug build`
- 本机命令行拉 GitHub 需代理：`export http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890`（VPN 规则模式不覆盖 CLI）
- 运行日志：主 app `NSLog [NRM]` 前缀；helper 的 NSLog 在统一日志里不可见，
  调试期会同时写 `/tmp/bn_helper.log`（`NotificationRelayService.swift` 顶部 relayLog）
- 测试通知：`osascript -e 'display notification "正文" with title "标题"'`（以「脚本编辑器」身份出现）
- **重编译会使辅助功能授权失效**（ad-hoc 签名按二进制哈希记账），每次重装后需重新授权；
  正式签名发布后授权稳定。启动时若授权检查失败会重试 5 次（helper 冷启动较慢）再决定是否关闭功能开关
- 展开刘海快捷键：⌘⇧I（toggleNotchOpen，3 秒自动关闭）

## 8. 已知限制

- 专注模式/勿扰下系统不弹横幅 → 刘海同样无显示（系统行为）
- 锁屏/通知堆叠组的结构未单独适配；只处理 `AXSystemDialog` 瞬时横幅
- app 名匹配失败时（同名 app 歧义）bundleID 为 nil，点击跳转不可用（仍能显示）
- 通知仅内存留存，app 重启清空（无历史持久化，属设计取舍）
- 网页推送（Safari Web Push）走同一横幅管道；其子级 AXStaticText 带 `Identifier`（title/subtitle/body，
  subtitle=域名），解析优先按 Identifier 提取；appName/bundleID 无法前缀匹配时按「描述首段是域名」
  判定为网页推送：appName=域名，bundleID=系统默认浏览器（回退 com.apple.Safari），点击可跳转浏览器
- 通知预览行的悬停/点击语义：悬停预览行**不展开**刘海（`isHoveringNotificationPeek` 门控
  ContentView.handleHover），鼠标上移至刘海本体才展开；点击预览行直接 `activate` 跳来源 app
- 刘海内可点元素统一震动：`helpers/Haptics.swift` 的 `Haptics.play()`（NSHapticFeedbackManager .alignment，
  受 `enableHaptics` 开关控制）
- 第三方包 LaunchAtLogin-Modern 的内部 Text 解析在包自身 bundle，设置里的「登录时启动」标签需用
  `LaunchAtLogin.Toggle { Text("Launch at login") }`（闭包内 Text 在主 module 创建，走主 catalog）才能翻译
- helper 对不满足「窗口内横幅数==1」的横幅窗口会记录 `window rejected` 日志（/tmp/bn_helper.log），
  若某 app 通知不显示，先看该日志确认 subrole

## 10. AI 用量功能（2026-08-20 新增）

### 接口（本机凭证实测）

- **GLM**：`GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`，头 `Authorization: <key>`（裸 key）；
  `data.limits[]` 按 `unit` 区分（3=5h、6=周，取 `percentage` + `nextResetTime` 毫秒），`TIME_LIMIT`=月度工具额度；
  `type` 可能是 `CREDIT_LIMIT` 或 `TOKENS_LIMIT`，**禁止按 type 硬编码**
- **Kimi Code**：`GET https://api.kimi.com/coding/v1/usages`，头 `Authorization: Bearer <token>`；
  `usage`（limit/used/remaining/resetTime）是周额度；`limits[]` 的 `window.duration==300`（分钟）且
  **window 与 detail 平级**，`detail.used/limit/remaining` **是字符串**（用 `asDouble` 兼容）；
  `user.membership.level`、`boosterWallet.status`；401 用 refresh_token 向 `auth.kimi.com/api/oauth/token` 刷新
- 两接口均未官方文档化，显示层必须容错降级

### 凭证安全

- 优先级：手动输入（**macOS Keychain**，`helpers/KeychainHelper.swift`，service=`theboringteam.boringnotch.usage`）> 本机配置
- 沙盒主 app 读不了 `~/.kimi-code/` → 由非沙盒 XPC helper 代读（协议 `readKimiCodeCredentials`），
  任何 key 内容**禁止进日志**（含片段）

### 实现位置

- `managers/UsageManager.swift`：凭证解析/轮询（5 分钟）/历史快照（`~/Library/Application Support/boringNotch/usage_history.json`，7 天剪枝）
- `components/Usage/UsageRingsView.swift`：闭合态双模型圆环（左 Kimi 右 GLM，蓝=周、绿=5h，显示剩余量）
- `components/Usage/UsageDetailView.swift`：Token tab 详情 + Swift Charts 历史曲线
- logo：`Assets.xcassets/kimi-logo`（kimi.moonshot.cn favicon）/ `glm-logo`（github.com/zai-org 头像），拉取失败自绘兜底
- 开启 `usageDisplayEnabled` 时自动关闭 `showNotHumanFace`（趣味表情让位）；音乐播放时圆环让位 MusicLiveActivity

## 9. 后续可扩展点

- per-app 过滤名单（黑名单/白名单）
- 通知操作按钮转发（横幅的「显示详细信息」「关闭」动作已在 helper 可见，可透传）
- 通知历史面板（需持久化，另起设计）
- 多条通知在闭合态的轮播/堆叠展示（当前预览行只显示最新一条）
