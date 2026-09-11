# ZCode 功能地图（做 UI 的依据）

> 来源：桌面端 `app.asar` 的产物 + 远控页面实测。
> 用途：**在写原生 UI 之前，先把"官方有哪些功能、每个功能的数据从哪来"搞清楚**，
> 避免做出空壳界面。
>
> 本文是**结构性分析**（有哪些功能、数据怎么流），不搬运官方界面文案。
> 文案键名仅作为"该面板有这些字段"的证据列出。

## 一、服务清单（38 个）

官方 RPC 服务注册表（`out/host/chunk-RWMCBKS2.js` 内的服务名常量表）：

```
file            media-preview   system          terminal        git
git-checkpoint  setting         credential      cua-permission  cua-pip-session
broadcast       zcode-task      window-controller  zcode-agent  zcode-session
file-watcher    oauth           model-provider  usage-stats     coding-plan-subscription
client-scenes   skills          skill-sync      mcp-sync        plugin-sync
plugins         plugin-management  subagents    commands        hooks
memory          output-style    settings-sync   bots            feedback
repo-wiki       prompt-attachment-transfer       off-peak-task
```

**传输**：全部走第 8 节那套二进制 agent RPC（`<service>.<method>(args)`）。

### 1.1 方法清单（**已完整拿到并实测验证**）

**提取方法**：服务工厂是 `create<X>Service()` 返回的对象字面量，
压缩后函数真名在 `s(<标识符>,"create<X>Service")` 里。两步定位（先取标识符、再做花括号配对）
后扫描方法名，一次拿到 **29 个服务工厂**的完整方法表。

> 验证方式：用 relay 直接调用，看返回。
> `Method not found` 会立刻返回，所以穷举代价很低。

#### 用户关心的六个

| 服务 | 方法 | 实测 |
|---|---|---|
| **skills** | `list`、`deleteSkill`、`setEnabled`、`copyToCommon`、`removeFromCommon`、`buildPromptContext` | `list({workspacePath})` → `{skills:[{id,name,description,…}]}`，实测拿到 `brainstorming` 技能 ✓ |
| **hooks** | `loadHooks`、`saveHooks`、`addHook`、`updateHook`、`deleteHook`、`toggleHook`、`importHook`、`trustHook` | `loadHooks({workspacePath})` → `{hooks:[], hooksEnabled:false}` ✓ |
| **memory** | `loadMemory`、`saveMemory`、`clearMemory`、`getUserMemoryDirectory`、`listProjectMemories`、`readProjectMemoryFile` | `getUserMemoryDirectory()` → `{path:"<用户目录>/.claude/memory"}` ✓ |
| **subagents** | `list`、`createAgent`、`updateAgent`、`deleteAgent`、`setEnabled`、`getPrimaryUserAgentsDirectory`、`setBuiltInModelOverride` | `getPrimaryUserAgentsDirectory()` → `{path:"<用户目录>/.zcode/agents"}` ✓ |
| **mcp-sync** | `listLocalUserMcpCandidates`、`listRemoteUserMcpStatuses`、`canSyncMcp`、`exportMcpServers`、`importMcpServers` | `listLocalUserMcpCandidates()` → 实测拿到 `anysearch-0` 及完整 config ✓ |
| **repo-wiki** | `readWiki`、`readWikiPage`、`readWikiSummary`、`readPages`、`readPage`、`readSummary`、`readTask`、`writeWiki`、`writeTask`、`writeDraft`、`writeDraftPage`、`deleteDraft`、`deleteWorkspace`、`onRunningTaskCountChanged` | 方法存在；`getWorkspaceOverview` 不存在（需带参） |

#### 相关配套服务

| 服务 | 方法 |
|---|---|
| **skill-sync** | `listLocalUserSkillCandidates`、`listRemoteUserSkillStatuses`、`exportSkillsArchive`、`importSkillsArchive`、`checkRemoteUserSkillWriteAccess` |
| **plugins** | `getOverview`、`addMarketplace`、`removeMarketplace`、`updateMarketplace`、`installPlugin`、`uninstallPlugin`、`setPluginEnabled` |
| **plugin-management** | `installPlugin`、`uninstallPlugin`、`setPluginEnabled`、`cancelPluginOperation`、`configurePlugin`、`describePlugin`、`validatePlugin`、`getPluginsOverview`、`getPluginReferenceCatalog`、`resolveSuggestedPluginReference`、`resetPluginConfig`、`restoreBuiltinPlugin`、`updatePlugin`、`addPluginMarketplace`、`removePluginMarketplace`、`updatePluginMarketplace`、`onDynamicPluginOperationProgress` |
| **plugin-sync** | `listLocalUserPluginCandidates`、`listRemoteUserPluginStatuses`、`exportPluginsArchive`、`importPluginsArchive`、`exportMarketplaceSourceArchive`、`importMarketplaceSourceArchive`、`checkRemoteUserPluginWriteAccess` |
| **commands** | `generateCommandFileContent`、`parseCommandFile`（+ 渲染层的 `updateCommandFile` / `writeCommandFile`） |
| **output-style** | `listStyles`、`addStyle`、`updateStyle`、`deleteStyle`、`getUserStylesDirectory`、`setActiveStyle`、`getActiveStyle` |
| **settings-sync** | `detect`、`importSelected`、`update`、`getClaudeAgentsFileMigrationStatus`、`getFirstRunPromptState`、`markFirstRunPromptHandled`、`copyClaudeAgentsFileToZcodeAgentsFile` |
| **usage-stats** | `getAppUsageSnapshot`、`getAppUsageStats`、`getSnapshot`、`getUsageStatsSnapshot`、`getEntitlementSnapshot`、`getCodingPlanUsageSnapshot`、`getCodingPlanResetStatus`、`getSnapshotForRequest`、`markCodingPlanResetHistoryRead`、`requestCodingPlanResetOpportunity`、`useCodingPlanReset` |
| **setting** | `get`、`update`、`updateDataBaseDir`（+ 内部 `ensureDefaultProject`） |
| **system** | `info`、`listIntegratedTerminalShells` |
| **git** | `getChanges`、`getStatus`、`getDiff`、`getIdentity`、`getCommitGraph`、`getLocalBranches`、`listLocalBranches`、`switchBranch`、`createBranchAndSwitch`、`stage`、`stagePaths`、`unstage`、`unstagePaths`、`discard`、`discardPaths`、`commit`、`generateCommitMessage`、`getBranchComparison`、`getIgnoredPaths`、`getWorkspaceRepositoryInfo`、`getRepositorySummary`、`refresh` |
| **zcode-task** | 16 个（见下表） |
| **zcode-session** | `createSession`、`closeSession`、`readSession`、`readWorkspaceState`、`setModel`、`setThoughtLevel`、`setWorkspaceDefaultModel`、`setWorkspaceDefaultThoughtLevel`、`resolveRuntimeModelForV4`、`respondProviderRuntimeHeaders`、`closeDeferredDraftSession` |
| **zcode-agent** | 会话四件套 + 自动化（`createAutomation`/`listAutomations`/`runAutomationNow`…）+ 附件（`attachmentBeginV4`/`attachmentChunkV4`/`attachmentCommitV4`…）+ MCP/插件管理 + `listSessionSubagents`、`getTaskTokenUsage`、`compactSession`、`sendConversationCommandV4` 等 |

> ⚠️ **`coding-plan-subscription` 的 30+ 个方法（含 `payStripe`、`bindStripeCard`、
> `createEnterpriseOrder` 等）属于账户与计费域，按 [COMPLIANCE.md](COMPLIANCE.md) 一律不调用。**

#### 实测拿到的真实数据（可作 UI 的 mock 依据）

```
skills.list              → brainstorming（glm:user:brainstorming:…）
mcp-sync.listLocalUserMcpCandidates → anysearch-0（含 url / headers 完整 config）
output-style.listStyles  → default（内置）、explanatory 等
plugins.getOverview      → {marketplaces:[], availablePlugins:[], installedPlugins:[], capability:{supported:false}}
memory.getUserMemoryDirectory   → <用户目录>/.claude/memory
subagents.getPrimaryUserAgentsDirectory → <用户目录>/.zcode/agents
output-style.getUserStylesDirectory     → <用户目录>/.claude/output-styles
setting.get              → 全量设置（约 40 键）
```

#### 探测工具（已固化，可复用）

```bash
# 批量调用并打印结果；binary 走二进制 agent RPC，platform 走 platform-request
dart run tools/relay_probe.dart tools/relay_link.local.txt --batch tools/method_probe.txt
```

> 探针踩坑：连续调用会出现 **off-by-one**（上一条的响应被下一条吃掉），
> 因为响应没有可用的关联字段。已在每次调用后加 600ms 间隔缓解；
> 判断归属时以「返回内容的形状」为准，不要只看顺序。

## 二、设置面板地图（14 个，分三组）

侧边栏分组与设置项（分组名来自 `settings.sidebar.group.*`）：

### 基础设置

| 面板 | 文案键前缀 | 规模 | 作用 |
|---|---|---|---|
| **常规** | `settings.system*` | ~20 | 语言、窗口体验、通知、代理、数据目录、归档策略 |
| **外观** | `settings.appearance*`、`themeMode`、`uiFontSize`、`preview*` | ~30 | 主题（浅/深/跟随系统）、界面字号、代码主题与字号、行号、换行、代码预览 |
| **模型设置** | `settings.modelProvider*` | **1048** | 最大的一个：供应商增删改、模型配置、目录选择、认证方式 |
| **浏览器控制** | `settings.browser*` | 88 | 内置浏览器开关、安全、数据导入（Chrome 登录态）、视口 |
| **电脑控制** | `settings.computerUse*` | 24 | Computer Use 开关、输入框入口、环境可用性提示 |

### Agent 能力

| 面板 | 文案键前缀 | 规模 | 作用 |
|---|---|---|---|
| **记忆** | `settings.memory*` | 75 | 工作区记忆开开关 + 记忆文件的按项目浏览/搜索（详情只支持本地桌面端） |
| **子智能体** | `settings.subagents*` | 170 | 用户级子智能体 md 文件的增删改查、搜索、来源分组 |
| **插件** | `settings.plugins*`、`settings.plugin*` | 494+78 | 插件/MCP/技能/命令四个 Tab、作用域（用户/工作区）、市场、远端同步 |
| **MCP 服务器** | `settings.mcp*`、`settings.mcpServers*` | 204+58 | MCP 服务器增删改、从外部 Agent 导入、插件来源分组、远端同步 |
| **技能** | `settings.skills*` | 250 | 项目级/用户级技能、启用状态、来源筛选、刷新、Plugin 技能分组 |
| **命令** | `settings.commands*` | 132 | `.md` 命令文件增删改查、来源筛选、搜索 |
| **钩子** | `settings.hooks*` | 120 | 钩子规则增删改、高级 JSON、命令与参数、异步开关 |

### 数据与统计

| 面板 | 文案键前缀 | 规模 | 作用 |
|---|---|---|---|
| **索引库** | `settings.indexing*` | 12 | 新文件夹自动索引、Grep 即时索引（Beta） |
| **使用统计** | `settings.usage*` | 286 | 应用用量 / 个人套餐两个 Tab、工具调用分布、Token 用量 |
| **迁移** | `settings.migration*` | 92 | 从 Claude Code 历史迁移会话到 ZCode 任务列表 |
| **引导** | `settings.onboarding*` | 3 | 一个按钮：重新打开引导弹窗（走迁移与导入设置） |

> 共 3282 条设置文案键 —— 每个面板的标签、说明、选项、空态、错误态都齐了。

## 三、设置数据模型

**设置是「一整块」聚合对象**，`setting.get` 一次返回全部（实测 2.7KB）：

```json
{
  "locale": "zh-CN", "localePreference": "system",
  "recentProjects": [...],
  "themeMode": …, "uiFontSize": …, "darkTheme": …, "lightTheme": …,
  "messageStreamShowReasoning": true, "messageStreamShowTodos": true,
  "toolGroupingExploreEnabled": true, "toolGroupingTerminalEnabled": true,
  "toolGroupingChangesEnabled": false,
  "zcodeInteractionBehavior": "queue",
  "askUserQuestionAutoResolutionEnabled": true,
  "modelIoFullRetentionEnabled": true, "optimizeAgentExperienceEnabled": false,
  "memoryEnabled": true, "nativeSearchEnhancementsEnabled": true,
  "repoSnapshotIndexingEnabled": false, "instantGrepIndexingEnabled": false,
  "taskAutoArchiveEnabled": false, "taskAutoArchiveOlderThanDays": 7,
  "closeToTrayOnWindows": true, "keepAwakeWhileRunning": true,
  "desktopWindowSize": {...}, "desktopChromiumHardwareAccelerationEnabled": true,
  "terminalInheritSystemProfile": true,
  "embeddedBrowserAllowInsecureCertificates": true,
  "embeddedBrowserViewportPreference": {...},
  "computerUseComposerEntryHidden": true,
  "enabledBuiltinAgentCliProviders": ["glm"],
  "modelProviderFamilyModes": {"zai":"apiKey","bigmodel":"oauth"},
  "modelProviderFamilySelectedKeys": {...},
  "providerFamilyDomain": "bigmodel",
  "lastWorkspaceSession": [...]
}
```

**含义**：设置面板**不需要每页一个接口**。一次 `setting.get` 拿到全量，
改动走 `setting.update`（增量）。所以原生 UI 只需一个设置状态层。

> 实测印证：在页面上切换设置分区**不产生任何新请求**。

## 四、面板的交互形态（从文案键推得）

这些面板是同一套「资源列表」模式，可以统一实现：

| 能力 | 出现的面板 |
|---|---|
| 搜索框 + 空态 + 计数 | 技能、MCP、插件、命令、子智能体、记忆 |
| 新建 / 编辑 / 删除（含二次确认） | 命令、子智能体、钩子、MCP、模型供应商 |
| 启用 / 禁用开关 | 技能、插件、MCP、钩子 |
| 来源/状态筛选 | 技能、命令、MCP、插件 |
| 作用域切换（用户 / 工作区 / 默认） | 插件、技能、子智能体 |
| 分组（本地 / Plugin 来源） | 技能、MCP、插件 |
| 导入 / 导出 | MCP（从外部 Agent 导入）、插件、命令 |
| 远端同步（SSH 目标） | 插件、MCP、技能 |
| 只读提示（仅桌面端可用） | 记忆详情、子智能体用户级、浏览器数据、迁移、电脑控制 |

**对 UI 的直接结论**：做一个 **"资源列表"通用组件**（搜索 + 过滤 + 分组 + 卡片 + 开关 +
增删改 + 导入导出），12 个面板里有 8 个能复用同一套骨架，只是数据源不同。

## 五、会话能力（已完全打通）

见 [RELAY-PROTOCOL-VERIFIED.md](RELAY-PROTOCOL-VERIFIED.md) 第八节。简述：

```
zcode-agent.helloConversationV4()           → connectionId / clientMode / capabilities
zcode-agent.initializeConversationV4(clientHello)
zcode-agent.subscribeSessionsIndexV4({workspacePath, runtimePolicy})
zcode-agent.subscribeConversationV4({workspacePath, sessionId})
zcode-agent.conversationRowsRangeV4({workspacePath, sessionId, beforeRowId?, limit})
zcode-agent.conversationPlansV4({workspacePath, sessionId})
```

正文行的 `kind`：`assistantText` / `reasoning` / `toolCall` / `hookInvocation`，
工具调用带 `toolName` / `status` / `inputText`。

**已有**：任务列表（34 条实测）、会话索引、正文流（含工具调用）。

## 六、写操作（命令层）

会话命令的统一信封：

```js
{ commandId, clientId, sessionId, baseRevision?, baseLogEpoch?, type, payload, issuedAt }
```

类型全集：

```
applyFileRewind  forkAssistant  editUserQuery  retryTurn  setAssistantFeedback
sendQueuedNow  editQueueItem  reorderQueueItem  deleteQueueItem  setAutoDrain
switchModelConfig  switchCollaborationMode  setFollowupMode  pauseGoal  resumeGoal
snoozeInteractionAutoResolution  …
```

⚠️ CAS 命令（`applyFileRewind` / `forkAssistant` / `editUserQuery` / `retryTurn` /
`setAssistantFeedback`）**必须带 `baseRevision`**；row target 命令必须带 `baseLogEpoch`。

按 [COMPLIANCE.md](COMPLIANCE.md)：**写操作逐个确认，不做静默自动批准**。

## 七、对原生 UI 的落地映射

| 原生页面 | 数据来源 | 状态 |
|---|---|---|
| 任务 Tab | `workspace-list-request` | ✅ 已接 |
| 会话正文 + 工具调用 | `conversationRowsRangeV4` / `subscribeConversationV4` | ✅ 原生 UI 已接入 |
| 设置 · 常规/外观 | `setting.get` / `update` | 数据模型已明确 |
| 工作台面板（设备维度的） | 原生 service RPC + 本地状态 | ✅ 支持 Relay 的设备走原生路由 |
| 设置 · 12 个资源面板 | `platform-request` + 各服务方法 | 方法名待逐面板抓取 |

**建议的 UI 顺序**：

1. **会话正文页**（数据已齐，用户最想要）—— 工具调用卡片 + 正文流 + 思考折叠
2. **资源列表通用组件** —— 一次做好，8 个面板复用
3. **设置页骨架** —— 三组导航 + 分区路由（一个 `setting.get` 驱动）
4. 逐面板接数据（需要时再补抓 `platform-request` 方法名）

## 八、剩余的空白

原先列为空白的六个服务方法名 —— **已全部解决**，见 1.1 节。

仍待确认的只有细枝末节：

- `subagents.list` / `memory.listProjectMemories` 的**参数形状**（方法存在，
  需要 workspace 上下文，尚未取到稳定返回）
- `repo-wiki` 的实际用途：方法集偏「读写 wiki 文件」，与设置里的**索引库**
  （`repoSnapshotIndexingEnabled` / `instantGrepIndexingEnabled`）不是同一个东西 ——
  索引库的开关走 `setting.update`，没有独立服务
- `client-scenes`（引导）的作用范围

这些都不挡 UI：面板结构、字段、文案键都已齐备，接数据时按需补即可。
