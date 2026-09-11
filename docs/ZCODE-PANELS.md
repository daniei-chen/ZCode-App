# ZCode 桌面端设置面板清单（工作台复刻依据）

> 从 app.asar 的 i18n 资源（`settings.*` 键族）枚举出的桌面端侧边栏功能面板。
> 工作台 Tab 按此清单逐个做移动原生版，数据经桥接流量防御式抽取（见 ARCHITECTURE.md）。

| # | 面板 | 内容 | zremote 状态 |
|---|---|---|---|
| 1 | 模型设置 | 供应商列表（启用/禁用、模型清单）、编程套餐、额度条 | ✅ 原生页 + 详情页模型卡 |
| 2 | 用量统计 | 5 小时 Prompt 池 / 编程套餐额度 / 重置时间 | ✅ 原生页（额度条三级配色） |
| 3 | 子代理 | 子代理列表（描述 / 模型 / 启用） | ✅ 原生页（渐变头像 + 模型胶囊） |
| 4 | 技能 | 技能列表 | ✅ 通用列表模板 |
| 5 | MCP | MCP 服务器列表 | ✅ 原生只读列表（真实候选数据） |
| 6 | 插件 | 插件列表 | ✅ 原生只读列表（真实状态数据） |
| 7 | 命令 | 斜杠命令 | ✅ 通用列表模板 |
| 8 | 钩子 | 钩子列表 | ✅ 通用列表模板 |
| 9 | 记忆 | 记忆条目 | ✅ 通用列表模板 |
| 10 | 浏览器 | 浏览器工具配置 | ⏳ 未同步到数据（空态引导） |
| 11 | 电脑使用 | computer-use 配置 | ⏳ 同上 |
| 12 | 迁移 | 配置迁移 | ⏳ 桌面特有，低优先级 |
| 13 | 同步 | 多端同步 | ⏳ 桌面特有，低优先级 |
| 14 | （主设置区） | 通用/编辑器/终端等 | 移动端归入设置 Tab |

## 抽取字段约定（PanelDataExtractor）

- 供应商：`providers[] → {name|displayName|title, id, enabled, models[], current|isCurrent}`
- 套餐：`plan → {planName|plan|name|productName, audience, expiresAt, renewLabel}`
- 额度：`quota/entitlement[] → {label, percent|remaining|ratio, resetAt}`（≤1 视为比例 ×100）
- 子代理：`subagent[] → {name, description|prompt|whenToUse, model, enabled}`
- 通用列表：skills/mcp/plugin/command/hook/memories 键名匹配 → `{name, description, tag, enabled}`
- 未同步的面板显示"在远控页打开一次即同步"的引导空态；预热机制可自动补齐（见 ARCHITECTURE.md）
