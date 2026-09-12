# ZCode-Control 工程交接说明

> 这是一份给下一位 AI 的工程交接文档。当前任务是 **ZCode-Control 移动端原生化重构**，不是 ZCode Talent 活动的体验报告，也不是政务数据分析项目。
>
> 文档不包含真实设备的 sid、hash、token、远程完整 URL 或个人目录。后续 AI 必须继续遵守本文件的安全边界。

## 1. 任务身份与目标

项目：`ZCode-Control`，一个用 Flutter 编写的 ZCode 桌面端移动控制 App。

原始目标：

1. 把桌面端远控 Web 页面中可验证的功能尽可能接入移动端原生 Flutter UI；
2. 会话、任务、工具调用、思考、权限请求、停止、模型配置等功能不依赖先打开 WebView；
3. 工作台和设置页原生化，覆盖模型、用量、技能、MCP、插件、命令、子代理、钩子、记忆、索引等入口；
4. 全面重塑移动端 UI，统一状态、层级、空态、错误态、加载态和设备隔离；
5. 测试异常场景、断线重连、重复消息、丢回执、重复停止、多设备数据串线等问题；
6. 对没有协议证据的写操作显示 unsupported/只读，不凭猜测伪造成功。

特别说明：

- 本项目工程工作与“ZCode Talent 招募/体验报告”无关；
- 不要把本项目成果写成 Talent 体验报告，也不要把政务投诉数据项目的文件带入本项目；
- 用户曾明确要求停止消耗远程模型额度，因此本轮后续只允许本地仓库操作，不得调用远程 ZCode 或昂贵模型。

## 2. 仓库与本地工具链

当前仓库：

```text
D:\AI\codex\codex4\zremote-handoff-20260910\zremote
```

本地 Flutter/Dart：

```text
D:\AI\codex\codex4\.toolcache\flutter\bin\flutter.bat
D:\AI\codex\codex4\.toolcache\flutter\bin\dart.bat
D:\AI\codex\codex4\.toolcache\jdk-17
D:\phone\Android\android-sdk
```

PowerShell 常用环境：

```powershell
$env:JAVA_HOME='D:\AI\codex\codex4\.toolcache\jdk-17'
$env:Path="$env:JAVA_HOME\bin;$env:Path"
```

不要使用 `git reset --hard`、`git checkout --` 或其他破坏性命令覆盖工作区现有改动。

## 3. 已完成的主要工程阶段

### 3.1 协议与基础状态

- 建立 native Relay 传输层、Agent 握手和 Workspace/Session readiness 状态；
- 将 Transport、Agent、Workspace、Conversation subscription 分为四层，只有真实 ready 才允许发送；
- 订阅 ack、command receipt、epoch、重连重绑逻辑已接入；
- 删除按序号猜测响应的旧配对逻辑，改为内容谓词和 single-flight 等待；
- 用脱敏 fixture 固化协议证据，避免靠猜测字段名。

### 3.2 统一原生会话 Shell

- 原生设备首屏统一为 ConversationShell；
- 草稿会话和已有会话使用同一页面，不再跳转到独立的“大欢迎页/新对话页”；
- create 使用 `clientOperationId` 幂等；
- 创建回执丢失时从 task index 恢复，不重复创建；
- 失败时保留草稿和附件，并展示安全的 reason code。

### 3.3 消息 reducer 与发送/停止状态机

- initial、older、live、refresh、receipt、optimistic 全部进入统一 reducer；
- 重复推送、无 ID 行、乐观用户行与官方行替换均有 canonical identity；
- 删除 send/resolve/stop 后的固定延迟刷新；
- 发送状态包含 preparing、pendingReceipt、streaming、completed、failed；
- stop 不再弹二次确认；同一连接 epoch 内双击只发送一次，失败可重试；
- Relay 断线后旧 stream 作废，新的 bridge 恢复后自动重绑。

### 3.4 模型、思考和上下文配置

- 模型目录、当前模型、思考选项、上下文用量来自已验证的 session 快照；
- 删除硬编码的模型和思考能力；
- 明确区分“未返回目录”“返回空目录”“不可用模型”“传输错误”；
- 模型切换和思考切换使用独立方法及回执；
- 配置被拒绝时保留旧值，并展示安全错误原因；
- 明确的空模型目录可以覆盖旧缓存，避免旧数据假装仍有效。

### 3.5 工作台和设置原生化

Relay 设备的工作台入口已经原生路由到以下页面：

- 模型；
- 使用统计；
- 技能；
- MCP 服务器；
- 插件；
- 命令；
- 子代理；
- 钩子；
- 记忆；
- 索引设置；
- 输出样式（本轮新增，读取 `output-style.listStyles`）。

数据按 `deviceId + workspacePath` 隔离。之前会把多台设备的模型、用量、插件字段 fold 到一起的路径已经删除；工作台会优先跟随当前设备。

资源列表统一支持：

- 搜索、状态筛选、分组；
- loading、empty、unsupported、transport error；
- stale/cache 保留；
- retry。

没有得到可靠写协议的能力保持只读，例如技能开关、插件配置、MCP 编辑、命令文件修改等，不允许伪造“已保存”。

### 3.6 通知和底部导航

- 按用户要求移除了通知底部导航入口；
- 通知历史改由设置页中的通知中心卡片进入；
- 保留审批、完成、失败通知和未读数量；
- 通知点击支持 `deviceId|sessionId`，可直达对应会话；
- 通知中心不再占用一个根 Tab；
- 默认通知保持安静，不默认启动常驻前台服务。

### 3.7 隐私、日志和状态展示

- 用量页面只允许显式白名单指标，拒绝 sessionId、路径、token、URL、邮箱等标识字段；
- 日志不打印完整 payload、凭据或远程链接；
- 资源刷新失败时保留上次成功数据，并显示“上次同步数据/重试”提示；
- 原生设备默认不创建 WebView；只有不支持 Relay 的旧设备保留明确兼容回退；
- 没有设置全局 `FLAG_SECURE`，截图策略仍需真机复现。

## 4. 本轮新增或修正的文件范围

本轮本地工作重点包括：

- `lib/ui/app_shell.dart`：移除通知根 Tab；
- `lib/state/root_tabs.dart`：根导航由 5 项调整为 4 项；
- `lib/ui/settings_page.dart`：新增通知中心入口；
- `lib/ui/notifications_page.dart`：通知历史直达指定会话；
- `lib/ui/panels_page.dart`：当前设备选择、跨设备隔离、输出样式入口；
- `lib/ui/settings_panel_page.dart`：输出样式原生页面路由；
- `lib/state/agent_capabilities.dart`：接入 `output-style.listStyles` 只读读取；
- `lib/state/panel_state.dart` 与 `lib/ui/panels/generic_panel_page.dart`：新增输出样式兼容 key；
- `lib/ui/resource_list_view.dart`：缓存数据 stale/retry 展示；
- `lib/services/notifier.dart`：修正事件 taskId payload 使用；
- `lib/relay/relay_bridge.dart`、`lib/state/relay_source.dart`、`lib/state/conversation.dart`：按 session 隔离回执和拒绝信息；
- `lib/state/conversation_config.dart`：显式空模型目录覆盖旧缓存；
- `lib/l10n/app_zh.arb`、`lib/l10n/app_en.arb` 及生成文件：补充输出样式文案；
- 对应 widget/unit/fake-relay 测试；
- `docs/PROGRESS-9H.md`：追加本地收口记录。

当前工作区有未提交改动。下一位 AI 必须先查看：

```powershell
git status --short
git diff --stat
```

不要擅自丢弃这些改动。

## 5. 自动化验证结果

最近一次结果：

```text
flutter analyze                         通过，0 issues
dart format --set-exit-if-changed       通过
flutter test --reporter compact         641 passed / 0 failed
```

Fake Relay 覆盖的场景包括：

- 四层 readiness；
- Agent 握手未完成时不可发送；
- 订阅失败；
- create 回执丢失恢复；
- create 完全丢失保留草稿；
- 重复消息去重；
- 断线重连与 stream 重绑；
- 空目录与未返回目录区分；
- 配置拒绝；
- 双击 stop 只发一次；
- 多设备工作台隔离；
- method not found 显示 unsupported。

### Release APK

此前已成功构建并验证签名：

- APK：`build/app/outputs/flutter-apk/app-release.apk`；
- 大小约 71.9MB；
- `apksigner verify`：v2 签名通过，单签名；
- 构建时 SHA-256：`B5DDBCA28450E9891F069F738A3610E0D3D85BD7CAB855E87A19ECEAED3FD09C`。

注意：输出样式入口是在该 APK 构建之后加入的。若要交付最新代码，必须重新执行 release build 并重新计算 SHA-256，不能把旧 APK 当成最新版本。

### 集成测试限制

曾在本机 Android 模拟器上运行 `integration_test/app_smoke_test.dart`，但模拟器反复变为 offline，出现：

```text
VmServiceDisappearedException
adb: device offline
```

因此不得声称 integration smoke 已通过。单元测试、widget 测试、fake-relay 契约测试和 Dart/Flutter 静态检查是已通过的部分。

## 6. 当前明确未完成/未验证事项

这些事项不能在交接时被写成“已完成”：

1. 真实桌面端 Relay 的握手、create、send、reply、stop 回执；
2. 真机后台恢复、前台服务、电池优化、生物识别、锁屏通知脱敏；
3. 真机截图限制，尤其 local_auth 弹窗和厂商系统策略；
4. Golden 视觉基线；
5. 最新代码的 APK 重新构建与真机安装验收；
6. 桌面端写协议未充分验证的资源操作：插件安装/卸载、MCP 编辑、技能开关、钩子保存、记忆保存、子代理增删改、命令文件写入；
7. 浏览器控制、Computer Use、迁移、跨端同步等桌面专属设置尚未全部形成原生页面；
8. 一些桌面服务的方法参数形状仍只有静态证据或脱敏 fixture，不能凭猜测扩展写操作。

## 7. 下一位 AI 的推荐执行顺序

### 第一步：确认工作区

```powershell
Set-Location 'D:\AI\codex\codex4\zremote-handoff-20260910\zremote'
git status --short
flutter analyze
```

### 第二步：不要调用远程 ZCode

- 不打开原始远程 URL；
- 不使用真实 sid/hash/token；
- 不调用计费或订阅接口；
- 不使用远程 5.3 继续探索；
- 只使用仓库中的脱敏 fixture、fake Relay 和本地代码证据。

### 第三步：继续原生化空白面板

优先级建议：

1. `plugins.getOverview` 与 `plugin-sync.listLocalUserPluginCandidates` 的脱敏只读展示；
2. `mcp-sync.listRemoteUserMcpStatuses` 的只读状态合并；
3. `skill-sync.listRemoteUserSkillStatuses` 的只读同步状态；
4. `output-style` 的 active style 与 read-only provenance；
5. `setting.get` 的原生设置快照和安全白名单；
6. 对浏览器、Computer Use、迁移、同步等未验证能力提供明确 unsupported 页面，而不是空白或 WebView 假入口；
7. 只有拿到真实协议证据后，才实现写操作。

### 第四步：每次改动后的固定闸门

```powershell
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test --reporter compact
```

需要构建 APK 时：

```powershell
$env:JAVA_HOME='D:\AI\codex\codex4\.toolcache\jdk-17'
$env:Path="$env:JAVA_HOME\bin;$env:Path"
flutter build apk --release
& 'D:\phone\Android\android-sdk\build-tools\36.0.0\apksigner.bat' verify --verbose --print-certs build\app\outputs\flutter-apk\app-release.apk
Get-FileHash build\app\outputs\flutter-apk\app-release.apk -Algorithm SHA256
```

## 8. 交接结论

当前不是“全部 Web 功能已经完成”的状态，而是：

- 原生会话主链路、状态机、回执恢复、工作台主要面板、通知重构和自动化测试已经形成较完整基础；
- 代码静态检查和 641 项自动化测试通过；
- 仍有真实桌面回执、真机行为、Golden 视觉和若干桌面设置/资源写操作未验证；
- 下一位 AI 应在本地继续扩展，而不是重新打开远程页面或把这项工作误认为 ZCode Talent 体验报告。
