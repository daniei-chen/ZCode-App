# 原生链路自动化与自测试方案

目标是让下一位执行 AI 不依赖“我点过一次网页所以现在看起来有数据”。所有 P0 都要能在没有 Android 真机、没有 WebView、没有真实凭据的情况下通过 fake Relay 和脱敏 fixture 验证；真机只负责最后的设备、后台、权限和厂商行为验收。

## 1. 测试分层

| 层级 | 目标 | 运行位置 | 必须阻断发布 |
| --- | --- | --- | --- |
| Pure Dart | parser、identity、reducer、排序、状态机 | test | 是 |
| Provider/state | Riverpod notifier、single-flight、epoch、cache | test | 是 |
| Widget | shell、composer、sheet、错误/空态、导航 | test | 是 |
| Golden | 深浅色、draft/running/error、动态字体 | test/goldens | 是 |
| Contract | fake Relay + verified response shape | test/fake_relay | 是 |
| Integration | bootstrap → create → send → stream → stop | integration_test + fake Relay | 是 |
| Android instrumentation | FLAG_SECURE、通知 channel、恢复、biometric boundary | android/test 或 integration | release 前 |
| 真机手工 | Xiaomi/厂商后台、电池、无线 Relay、真实桌面版本 | 用户授权后 | release candidate |

禁止把一个绿色的 widget test 当成 native 链路完成。每个层级的结果都要写入交接报告。

## 2. 测试目录约定

建议新增：

~~~text
test/
  fixtures/
    native/
      verified/
      legacy/
      failures/
  fake_relay/
    fake_relay_server.dart
    fake_relay_script.dart
    fake_relay_transport.dart
  native_bootstrap_state_test.dart
  runtime_config_repository_test.dart
  conversation_identity_test.dart
  conversation_reducer_test.dart
  workspace_grouping_test.dart
  notification_policy_test.dart
  screenshot_policy_test.dart
  composer_action_test.dart
  native_shell_test.dart
  workbench_autoload_test.dart
  capability_manifest_test.dart
  security_redaction_test.dart
integration_test/
  native_conversation_flow_test.dart
  native_workbench_flow_test.dart
  native_lifecycle_flow_test.dart
test/goldens/
  native_shell/
  composer/
  workbench/
~~~

文件名可以按现有项目习惯调整，但职责不能省略。

## 3. Fixture 规则

### 3.1 来源

协议 fixture 的字段来源只能是：

1. 本机 ZCode app.asar 的当前实现。
2. 已有真机抓包/日志中经脱敏的 payload。
3. 当前仓库已经验证并有测试覆盖的 payload。

下列内容禁止进入 fixture：

- sid/hash/token/passHash。
- 完整 remote/v4 URL。
- 真实用户名、设备名、账号 ID。
- 绝对用户目录。
- 真实对话正文，除非已改成“你好/fixture message”。
- key.properties、keystore、签名密码。

### 3.2 每个 fixture 的旁注

每个 JSON 旁边放同名 .md，记录：

- source version。
- method/service。
- request shape 摘要。
- response shape 摘要。
- 已验证字段。
- 未验证字段。
- 脱敏操作。
- 预期 parser 结果。

### 3.3 最小 fixture 集

~~~text
verified/relay_handshake_ready.json
verified/service_capabilities.json
verified/workspace_tasks_snapshot.json
verified/session_snapshot_with_runtime.json
verified/model_catalog_grouped.json
verified/thought_options_by_model.json
verified/context_usage_full.json
verified/usage_stats_summary.json
verified/skills_list.json
verified/plugins_overview.json
verified/mcp_candidates.json
verified/conversation_rows_with_tools.json
verified/create_receipt.json
verified/send_receipt_and_stream.json
verified/stop_receipt.json
failures/handshake_delayed.json
failures/method_not_found.json
failures/response_out_of_order.json
failures/create_receipt_dropped.json
failures/duplicate_rows.json
failures/stale_epoch_response.json
failures/config_rejected.json
failures/reconnect_during_stream.json
~~~

## 4. Fake Relay

### 4.1 功能

fake Relay 不需要真实网络或设备凭据，但必须模拟真实异步行为：

- 建立/关闭连接。
- handshake phase。
- service capability response。
- request/response receipt。
- event stream。
- 延迟、乱序、丢包、重复、断线。
- session conflict。

对外暴露测试控制：

~~~dart
await relay.start(script: RelayScript([
  RelayStep.delay(const Duration(milliseconds: 80)),
  RelayStep.reply('handshake', verifiedHandshake),
  RelayStep.reply('capabilities', verifiedCapabilities),
  RelayStep.push('conversation.row', userRow),
]));
~~~

真实实现可以采用 dart:io 的 HttpServer/WebSocket，也可以通过现有 RelayBridge 注入 transport。不要为测试引入一个不能在 CI 使用的外部服务。

### 4.2 故障脚本

必须有可重复编号：

| 编号 | 注入 | 预期 |
| --- | --- | --- |
| F01 | Relay handshake 延迟 2 秒 | shell 显示 connecting，输入 draft 保留 |
| F02 | Relay 已 ready，Agent handshake 延迟 | 不显示“可发送” |
| F03 | session subscribe 失败 | 显示 session retry，不显示 transport failure |
| F04 | create receipt 丢失但 task index 有新会话 | 恢复 session，不重复创建 |
| F05 | create receipt 丢失且没有新会话 | 保留草稿，允许人工重试 |
| F06 | send accepted 之后重复 stream row | reducer 只显示一条 |
| F07 | response 属于旧 epoch | 丢弃，不覆盖新设备状态 |
| F08 | model catalog empty | chip 可显示 current，但 sheet 明确 catalog empty |
| F09 | thought options 未返回 | 只能显示 current/read-only |
| F10 | context max 缺失 | 显示 used / —，不猜 max |
| F11 | config update rejected | 保留旧值并显示拒绝原因 |
| F12 | stop clicked twice | 只发送一次 stop request |
| F13 | reconnect during assistant stream | 行保留，恢复后 reconcile |
| F14 | usage/plugin/MCP method not found | 页面显示 unsupported/retry，不打开 WebView |

## 5. Unit/state 测试明细

### 5.1 Bootstrap

断言：

- phase 转换顺序稳定。
- 当前请求失败不会把其它已成功的层重置。
- epoch 增加后旧回调无效。
- connect 并发调用只建立一个 bridge。
- disconnect 清理所有 pending request/stream。
- readiness 只有所有必要层就绪才为 true。

### 5.2 Runtime config

断言：

- current model 和 catalog 可独立存在。
- provider grouped/list/direct 三种 catalog 都能解析。
- disabled model 不可选。
- thought options 来自 fixture，不出现未返回的 hardcode。
- used/max/threshold 各自缺失时显示正确状态。
- usage quota 不会被当作 context max。
- update 成功后重新读取；update reject 不污染旧值。
- revision 过旧的 response 不覆盖新 snapshot。

### 5.3 Conversation identity/reducer

断言：

- rowId 相同的 row 替换。
- entityId/toolCallId 相同的 row 替换。
- clientOperationId 能把 optimistic row 和官方 row 合并。
- 无 ID 的相同 role/content/timestamp row 在容差内去重。
- assistant streaming 内容更新不会新建气泡。
- receipt 不生成可见 row。
- refresh 空结果不删除已有 live row。
- older page 和当前 page 在边界处不重复。

### 5.4 Workspace/session grouping

断言：

- path 规范化后大小写/尾斜线不产生重复工作区。
- pinned 优先。
- running/waiting approval 优先于普通最近会话。
- updatedAt 降序。
- updatedAt 缺失时 tie-break 稳定。
- 没有 workspace 的 session 进入“未归类”。
- 同名标题显示短 ID 区分。

## 6. Widget 测试明细

### 6.1 路由

- pump NativeDeviceView 后，树中出现 ConversationShell。
- 不出现 NewConversationPage 的独立欢迎布局。
- draft → create receipt 后 route 数量不变。
- 点击抽屉会话只更新当前 shell identity。
- 原生设备默认树中没有 InAppWebView。

### 6.2 连接态

- relay connecting：显示连接 skeleton。
- Agent handshaking：显示初始化 Agent。
- session unavailable：显示会话重试。
- live：显示会话 ready。
- error：显示具体层级 + retry。
- old error 不覆盖 fresh success。

### 6.3 Composer

- 空输入只有 plus/attachment 主动作。
- 有文字或附件只有 send 主动作。
- sending 只有 spinner。
- running 只有 stop。
- stopping 禁止第二次点击。
- stop 点击不出现 AlertDialog/Modal confirmation。
- 发送失败后文本、附件仍在。
- 键盘 Enter 和按钮走同一 send handler。
- 44dp 最小点击区域存在。

### 6.4 Runtime sheets

- model sheet loading/data/empty/notReturned 各有正确空态。
- chip 与 sheet 选择同一个 provider snapshot。
- thought 只显示权威 options。
- context sheet 对 used/max/threshold 缺失分别显示。
- update rejected 后 UI 回到旧 model/thought。

### 6.5 Workbench/settings

- 进入 usage/model/plugin/MCP 页面立即触发 repository load。
- coordinator 未 ready 时注册 intent。
- coordinator ready 后只执行一次 pending intent。
- 不调用“打开远控页”的 Navigator。
- stale cache 显示 last sync。
- empty 与 unsupported 不混淆。
- write toggle 等待 receipt，再更新 UI。

## 7. Golden 测试

固定 viewport、字体、locale、主题和时间。至少保存：

| Golden | 要观察的风险 |
| --- | --- |
| draft_connecting | 首页是否又变成巨大欢迎页 |
| draft_ready | composer 是否可直接输入 |
| existing_history | 时间线密度与工作区标题 |
| thinking_expanded | 思考持续时间和折叠层级 |
| tools_grouped | 技能数量、耗时、状态 |
| model_sheet | 目录加载和真实模型名称 |
| thought_sheet | 动态选项，禁止硬编码回归 |
| context_sheet | used/max/threshold |
| running_composer | 只有 stop action |
| workbench_error | 局部错误和 retry |
| workbench_stale | 缓存 + 最后同步时间 |
| settings_native | 当前值/来源/回执状态 |

golden 变更必须在 PR/交接报告中附一句原因；禁止用全量更新命令掩盖布局回归。

## 8. Integration 流程

不连真机，用 fake Relay 执行：

1. 构造支持 Relay 的 device。
2. 启动 AppShell。
3. 注入 F01/F02，确认首屏 draft 和连接状态。
4. handshake/capabilities/workspace ready。
5. 输入“你好”，确认只出现一个 send slot。
6. create receipt 到达，shell identity 原地更新。
7. 推送 thinking、tool、assistant rows。
8. 展开 thinking，检查 duration/skill count。
9. 打开 model/thought/context sheet。
10. update model success，再 update thought rejected。
11. 打开 usage/model/plugin/MCP，确认自动加载。
12. 点击 stop 两次，确认只发一个 request。
13. 断线、重连、推送旧 epoch，确认数据仍一致。
14. 退出/恢复 app，确认草稿和会话索引不丢。

最终断言：

- route 只有原生 shell。
- 没有网页打开动作。
- 一次发送对应一条用户行。
- 一次停止对应一个 stop request。
- 没有旧 epoch 污染。
- 所有页面状态可解释。

## 9. Android/真机验收清单

这部分必须等待用户重新授权，不能由本轮自动执行：

- ADB/wireless debugging 连接设备并只确认用户指定设备。
- Relay 真机 handshake。
- 创建/发送/实时回复/停止。
- app 切后台后恢复。
- Xiaomi 电池优化/自启动限制。
- 安静模式通知不常驻。
- 持续连接模式通知合规。
- 普通页面可以截图。
- biometric lock 只保护敏感入口。
- 系统字体放大、TalkBack、旋转/键盘。
- 锁屏通知脱敏。

手工结果需要附截图、时间、APK SHA-256、桌面端版本和是否打开过 WebView。只要测试过程中打开了同一 sid/hash 的网页，native session-conflict 结果就不能作为纯原生验收证据。

## 10. CI 命令和质量门槛

推荐 CI 顺序：

~~~powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
flutter test test/native_shell_test.dart test/composer_action_test.dart
flutter build apk --debug
~~~

release job 另外执行：

- Android release build。
- APK signing verification。
- source/package forbidden-file scan。
- SHA-256 manifest。
- 不把 WorkBuddy reference 目录上传到 GitHub artifact。

质量阈值：

- analyze 0 issues。
- 所有 unit/widget/contract tests pass。
- golden 无未解释变化。
- P0 integration pass。
- 安全扫描 0 real credential。
- package scan 0 key/keystore/local.properties/build/.dart_tool。

## 11. 自测试结果模板

执行 AI 每次交接都填写：

~~~text
Run time:
Commit:
Flutter version:
Desktop ZCode version:
Tests:
  analyze:
  unit:
  widget:
  golden:
  contract:
  integration:
Android build:
APK SHA-256:
P0 status:
Manual device status:
Known blockers:
WebView opened during evidence: yes/no
Secrets scan: pass/fail
~~~

“未执行”必须写原因，不能留空或写 pass。
