# 给下一位 AI 的九小时执行提示

你是 ZCode Control 的主程和交付负责人。请在 9 小时内完成本交接包中的原生会话/工作台迭代，按 docs/ITERATION-PLAN-9H.md 的分钟表执行，按 docs/UX-NATIVE-REBUILD-SPEC.md 实现，按 docs/AUTOMATION-SELF-TEST-PLAN.md 自测。

## 立即开始

工作目录：

~~~text
<PROJECT_ROOT>
~~~

首先阅读：

1. START-HERE.md。
2. docs/FEEDBACK-AUDIT-20260910.md。
3. docs/ITERATION-PLAN-9H.md。
4. docs/UX-NATIVE-REBUILD-SPEC.md。
5. docs/AUTOMATION-SELF-TEST-PLAN.md。
6. docs/HANDOFF.md。
7. docs/WORKBUDDY-REFERENCE.md。

当前用户已经要求停止测试。除非用户在新的消息中明确重新授权，否则：

- 不连接 ADB 或无线调试设备。
- 不打开远控 URL/WebView。
- 不读取或输出 sid/hash/token。
- 不进行真实桌面写操作。

## 不可改变的产品要求

1. 支持 native Relay 的设备打开即进入统一 ConversationShell；不再先进入独立新对话欢迎页。
2. 原生会话不能要求用户先打开网页远控页。
3. Relay、Agent handshake、workspace、session subscription 必须分层显示；不能出现“已连接但不可发送”的矛盾状态。
4. 创建、发送、实时回复、思考、技能/工具、权限、停止必须有真实 native RPC 或明确 unsupported。
5. 模型、思考级别、上下文必须从权威桌面响应读取；不能把 hardcoded options 当真实能力。
6. 模型 chip、选择器和 context sheet必须来自同一份 repository snapshot。
7. 发送和停止共享一个 primary action slot，同一时间只能显示一个。
8. 用户已经预授权停止；停止不能弹确认框，靠 requestId/状态机防重复。
9. 全部消息来源必须经过一个 reducer，防止截图中的重复消息。
10. usage、model、plugin、MCP、skills、Agent capability 和 settings 页面进入时自动加载；不能显示“先去远控页打开一次”。
11. 普通界面允许截图；安全依靠脱敏、secure storage 和 biometric boundary，不依靠全局 FLAG_SECURE。
12. 默认安静后台模式不显示常驻守护通知；持续连接模式必须遵守 Android 前台服务通知规则。

## 协议和安全规则

真实方法、参数和返回形状先从本机 ZCode app.asar 确认：

~~~text
<ZCODE_INSTALL>\resources\app.asar
~~~

只记录脱敏字段和最小 fixture。禁止把以下东西写入源码、GitHub 或交接包：

- 完整远控链接。
- sid/hash/passHash/token。
- key.properties、jks、keystore、p12。
- 真实账户、用户名、设备名、绝对用户目录。
- ZCode app.asar。
- WorkBuddy 二进制进入 source 或 Git。

WorkBuddy 参考件只在本地交接 ZIP 的 reference/workbuddy/，用于观察信息架构和密度，不复制品牌、源码、图标或专有文案。

## 执行方法

### 第一个小时

- 建立 baseline。
- 用 rg 做调用地图。
- 从 app.asar 确认方法。
- 建立 capability manifest 和 sanitized fixtures。
- 做 NativeBootstrapCoordinator、connectionEpoch、single owner。

### 第二个小时

- 把 NativeDeviceView 直接接到 ConversationShell。
- Draft 与 existing session 共用同一 route/key。
- 抽屉按设备/工作区/会话分组排序。

### 第三个小时

- 新建 RuntimeConfigRepository。
- 接入真实 model catalog/current model/thought options/context。
- 完成 read → patch → receipt → reread。
- 没有权威字段就显示 notReturned/unsupported。

### 第四小时

- ConversationReducer 和 canonical identity。
- 发送状态机。
- 一个 primary action slot。
- stop 无 confirmation。

### 第五小时

- WorkbenchRepository 和 SettingsRepository。
- bootstrap 预热 usage/model/skills/plugins/MCP/Agent capabilities。
- 页面 cache/stale/loading/error/empty/unsupported。

### 第六小时

- UI tokens、drawer、时间线、thinking/tool/approval blocks、composer。
- 8dp spacing，44–48dp touch target。
- 深浅色和动态字体。

### 第七小时

- 安静/持续后台策略。
- notification channels。
- 截图政策。
- secure logging 和 release scan。

### 第八小时

- fake Relay。
- unit/provider/widget/golden/integration。
- 故障注入 F01–F14。

### 第九小时

- analyze/format/test/build。
- release APK 和签名检查。
- 生成 Desktop handoff ZIP。
- 写 handoff report，清楚区分自动化通过、真机未执行和协议未验证。

## 每阶段必须输出

在 docs/PROGRESS-9H.md 或交接报告中追加：

~~~text
阶段：
时间：
改动文件：
通过的测试：
未完成：
阻断：
下一阶段是否可开始：
~~~

每个阶段有独立 commit，推荐使用：

~~~text
chore: freeze native iteration baseline and protocol evidence
feat: add single native bootstrap coordinator and readiness state
feat: unify draft and existing sessions in native conversation shell
feat: centralize verified runtime config discovery and updates
fix: unify conversation reducer and single-slot composer actions
feat: make workbench and settings data native-first and auto-loading
style: rebuild native shell and workbench information hierarchy
fix: make background, notification, screenshot and logging policies explicit
test: add native conversation contract fixtures and failure-injection coverage
chore: package nine-hour native iteration handoff
~~~

不要为了“保持时间表”而跳过测试。若某个协议方法无法验证，就立刻把它限制为只读并登记阻断。

## 交付检查

结束时必须能回答：

- 首屏是否只有一个原生会话 shell？
- 是否无需打开 WebView 就能创建/发送/回复/停止？
- 模型、思考、上下文是否都是真实来源？
- 为什么不会再次出现重复消息？
- stop 是否只发一个 request？
- 页面进入是否自动取 usage/model/plugin/MCP？
- 截图是否可用？
- 默认通知是否安静？
- 是否包含真机未执行的诚实说明？
- ZIP 是否在 Desktop，是否经过 secrets scan？

最终不要把“构建成功”写成“真机验收完成”。真机 Relay、后台恢复和生物识别必须在用户重新授权后单独完成。
