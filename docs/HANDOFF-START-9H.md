# ZCode Control 9 小时迭代交接包入口

## 给执行 AI

这是一个针对当前 ZCode Control 1.4.0 基线的下一轮彻底迭代包。工作重点不是继续叠加页面，而是把原生连接、会话、配置、工作台和设置收敛为一条可验证的数据链。

从以下顺序开始：

1. AI-EXECUTION-PROMPT.md。
2. docs/FEEDBACK-AUDIT-20260910.md。
3. docs/ITERATION-PLAN-9H.md。
4. docs/UX-NATIVE-REBUILD-SPEC.md。
5. docs/AUTOMATION-SELF-TEST-PLAN.md。

## 交付包内容

- source/：源码快照，已排除 build、.dart_tool、local.properties、签名文件和凭据。
- baseline/：当前可安装 APK，仅用于回归对照。
- feedback/current-run/：用户提供的当前版本截图，作为问题证据。
- reference/workbuddy/：本地 WorkBuddy 参考材料，只用于私下观察 UI/IA，不得复制到 GitHub。
- docs/：计划、行为合同、测试和安全边界。

## 当前真相

- 源码基线提交：8c79d3d。
- 当前版本的 P0 问题：native readiness 分裂、create/send 回执不可靠、消息重复、runtime config 不权威、工作台依赖被动 payload。
- 当前阶段不连接真机；真机验收需要用户重新授权。
- 本机协议勘探位置：<ZCODE_INSTALL>\resources\app.asar。
- 签名密钥位置如果存在：<SECRETS_DIR>；永远不进入交接包。

## 开工前的边界

不要打开同一 sid/hash 的 WebView 远控页来“帮助同步”。这会改变接管状态并污染 native 验收。不要用假模型、假思考级别、假上下文或默认 quota 让 UI 看起来有数据。

## 9 小时后必须有

- 自动化测试结果。
- release APK 或明确的签名阻断。
- APK/source SHA-256。
- 未完成项和协议未验证项。
- 真机测试待办。
- Desktop 交接 ZIP。
