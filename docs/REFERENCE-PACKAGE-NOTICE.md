# WorkBuddy 参考包使用声明

交接 ZIP 中的 reference/workbuddy/ 来自用户本机已有的本地材料，仅用于比较信息架构、状态表达、列表密度和交互节奏。

它不是 ZCode Control 的源码或构建依赖，不得：

- 复制 WorkBuddy 品牌、应用图标、专有文案、页面源码或二进制实现。
- 将 workbuddy.apk、wb_libapp.so 或 wb_icons.txt 放入 Git/GitHub、Flutter assets、APK 或 release artifact。
- 根据参考包猜测 ZCode 协议字段或写操作。
- 把参考包当成当前版本验收证据。

实现时只提取通用设计原则：任务/工作区分组、状态 pill、清晰的空态、紧凑输入区和可读的导航层级。协议和功能必须来自 ZCode 本机 app.asar、脱敏 fixture 或真实桌面回执。

该参考包只随本地交接 ZIP 传递给用户指定的下一位 AI；如需对外发布，应先删除 reference/workbuddy/ 并重新生成清单和 checksum。
