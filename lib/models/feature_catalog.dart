/// The service domains exposed by the ZCode desktop client.
///
/// This is intentionally a small, honest capability registry for the native
/// app.  It is not a list of buttons that pretend every desktop method is
/// available on mobile: each entry records the current access boundary and a
/// safe method summary that can be shown to the user.
enum NativeFeatureAccess { native, readOnly, pending, restricted }

class NativeFeatureSpec {
  const NativeFeatureSpec({
    required this.service,
    required this.titleZh,
    required this.titleEn,
    required this.groupZh,
    required this.groupEn,
    required this.methods,
    required this.access,
    required this.summaryZh,
    required this.summaryEn,
    this.panel,
  });

  final String service;
  final String titleZh;
  final String titleEn;
  final String groupZh;
  final String groupEn;
  final List<String> methods;
  final NativeFeatureAccess access;
  final String summaryZh;
  final String summaryEn;

  /// Name of the native settings panel when this feature already has a
  /// navigable page.  Kept as a string to avoid coupling the model to Flutter.
  final String? panel;

  bool get isWired => access == NativeFeatureAccess.native;

  bool get isReadOnly => access == NativeFeatureAccess.readOnly;

  bool get isRestricted => access == NativeFeatureAccess.restricted;
}

abstract final class NativeFeatureCatalog {
  static const all = <NativeFeatureSpec>[
    NativeFeatureSpec(
      service: 'file',
      titleZh: '文件',
      titleEn: 'Files',
      groupZh: '工作区与开发',
      groupEn: 'Workspace and development',
      methods: ['workspace files'],
      access: NativeFeatureAccess.pending,
      summaryZh: '需要路径授权、变更确认和写入回执',
      summaryEn: 'Needs path permission, change confirmation, and receipts',
    ),
    NativeFeatureSpec(
      service: 'media-preview',
      titleZh: '媒体预览',
      titleEn: 'Media preview',
      groupZh: '工作区与开发',
      groupEn: 'Workspace and development',
      methods: ['preview'],
      access: NativeFeatureAccess.pending,
      summaryZh: '协议已列出，移动端预览管线尚未接通',
      summaryEn: 'Listed by the protocol; the mobile preview path is not wired',
    ),
    NativeFeatureSpec(
      service: 'system',
      titleZh: '系统信息',
      titleEn: 'System info',
      groupZh: '设备与连接',
      groupEn: 'Device and connection',
      methods: ['info', 'listIntegratedTerminalShells'],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '已接入安全白名单诊断信息和集成终端列表',
      summaryEn: 'Allow-listed diagnostics and integrated shells are wired',
      panel: 'system',
    ),
    NativeFeatureSpec(
      service: 'terminal',
      titleZh: '终端',
      titleEn: 'Terminal',
      groupZh: '工作区与开发',
      groupEn: 'Workspace and development',
      methods: ['terminal sessions'],
      access: NativeFeatureAccess.pending,
      summaryZh: '需要独立会话生命周期和命令确认',
      summaryEn: 'Needs a session lifecycle and command confirmation',
    ),
    NativeFeatureSpec(
      service: 'git',
      titleZh: 'Git',
      titleEn: 'Git',
      groupZh: '工作区与开发',
      groupEn: 'Workspace and development',
      methods: ['getStatus', 'getChanges', 'getDiff', 'commit'],
      access: NativeFeatureAccess.pending,
      summaryZh: '读取与写入都需要路径范围和确认回执',
      summaryEn: 'Reads and writes need path scoping and confirmation receipts',
    ),
    NativeFeatureSpec(
      service: 'git-checkpoint',
      titleZh: 'Git 检查点',
      titleEn: 'Git checkpoints',
      groupZh: '工作区与开发',
      groupEn: 'Workspace and development',
      methods: ['checkpoint'],
      access: NativeFeatureAccess.pending,
      summaryZh: '待与工作区变更页合并',
      summaryEn: 'Waiting to be integrated with workspace changes',
    ),
    NativeFeatureSpec(
      service: 'setting',
      titleZh: '应用设置',
      titleEn: 'App settings',
      groupZh: '设置与同步',
      groupEn: 'Settings and sync',
      methods: ['get', 'update', 'updateDataBaseDir'],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '已接入安全白名单读取；未核验写入保持关闭',
      summaryEn:
          'Safe allow-listed reads are wired; unverified writes stay off',
      panel: 'indexing',
    ),
    NativeFeatureSpec(
      service: 'credential',
      titleZh: '凭证',
      titleEn: 'Credentials',
      groupZh: '账户与安全',
      groupEn: 'Account and security',
      methods: ['credential store'],
      access: NativeFeatureAccess.restricted,
      summaryZh: '移动端不读取或代操作桌面凭证',
      summaryEn: 'Mobile does not read or operate desktop credentials',
    ),
    NativeFeatureSpec(
      service: 'cua-permission',
      titleZh: '电脑控制权限',
      titleEn: 'Computer-use permission',
      groupZh: '浏览器与电脑控制',
      groupEn: 'Browser and computer control',
      methods: ['permission'],
      access: NativeFeatureAccess.pending,
      summaryZh: '需要权限申请、审批和撤销生命周期',
      summaryEn: 'Needs request, approval, and revocation lifecycle',
    ),
    NativeFeatureSpec(
      service: 'cua-pip-session',
      titleZh: '电脑控制会话',
      titleEn: 'Computer-use session',
      groupZh: '浏览器与电脑控制',
      groupEn: 'Browser and computer control',
      methods: ['pip session'],
      access: NativeFeatureAccess.pending,
      summaryZh: '待接入原生会话和画面流',
      summaryEn: 'Waiting for native session and screen streaming',
    ),
    NativeFeatureSpec(
      service: 'broadcast',
      titleZh: '实时广播',
      titleEn: 'Live broadcast',
      groupZh: '设备与连接',
      groupEn: 'Device and connection',
      methods: ['onMessage'],
      access: NativeFeatureAccess.native,
      summaryZh: '会话事件与通知由原生通道接收',
      summaryEn:
          'Session events and notifications arrive over the native channel',
    ),
    NativeFeatureSpec(
      service: 'zcode-task',
      titleZh: '任务',
      titleEn: 'Tasks',
      groupZh: '会话与任务',
      groupEn: 'Sessions and tasks',
      methods: ['task index', 'workspace list'],
      access: NativeFeatureAccess.native,
      summaryZh: '任务列表和跨设备切换已原生接入',
      summaryEn: 'Task list and cross-device switching are native',
    ),
    NativeFeatureSpec(
      service: 'window-controller',
      titleZh: '窗口控制',
      titleEn: 'Window controller',
      groupZh: '设备与连接',
      groupEn: 'Device and connection',
      methods: ['desktop window'],
      access: NativeFeatureAccess.pending,
      summaryZh: '移动端不直接操作桌面窗口',
      summaryEn: 'Mobile does not directly operate desktop windows',
    ),
    NativeFeatureSpec(
      service: 'zcode-agent',
      titleZh: 'Agent',
      titleEn: 'Agent',
      groupZh: '会话与任务',
      groupEn: 'Sessions and tasks',
      methods: ['helloConversationV4', 'sendConversationCommandV4', 'stop'],
      access: NativeFeatureAccess.native,
      summaryZh: '会话正文、发送、停止、审批和附件走原生 RPC',
      summaryEn:
          'Messages, send, stop, approvals, and attachments use native RPC',
    ),
    NativeFeatureSpec(
      service: 'zcode-session',
      titleZh: '会话',
      titleEn: 'Sessions',
      groupZh: '会话与任务',
      groupEn: 'Sessions and tasks',
      methods: ['readSession', 'setModel', 'setThoughtLevel'],
      access: NativeFeatureAccess.native,
      summaryZh: '模型目录、思考级别、上下文和配置变更已接入',
      summaryEn:
          'Model catalog, thought level, context, and config changes are native',
    ),
    NativeFeatureSpec(
      service: 'file-watcher',
      titleZh: '文件监听',
      titleEn: 'File watcher',
      groupZh: '工作区与开发',
      groupEn: 'Workspace and development',
      methods: ['onDynamicChange'],
      access: NativeFeatureAccess.pending,
      summaryZh: '待与文件和索引页形成可见闭环',
      summaryEn: 'Waiting for a visible file and indexing flow',
    ),
    NativeFeatureSpec(
      service: 'oauth',
      titleZh: '登录授权',
      titleEn: 'OAuth',
      groupZh: '账户与安全',
      groupEn: 'Account and security',
      methods: ['OAuth flow'],
      access: NativeFeatureAccess.restricted,
      summaryZh: '移动端不代替桌面端登录或保存授权',
      summaryEn: 'Mobile does not replace desktop login or store authorization',
    ),
    NativeFeatureSpec(
      service: 'model-provider',
      titleZh: '模型供应商',
      titleEn: 'Model providers',
      groupZh: '模型与输出',
      groupEn: 'Models and output',
      methods: ['provider catalog'],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '当前模型目录来自 zcode-session.readSession',
      summaryEn:
          'The current model catalog comes from zcode-session.readSession',
      panel: 'models',
    ),
    NativeFeatureSpec(
      service: 'usage-stats',
      titleZh: '使用统计',
      titleEn: 'Usage stats',
      groupZh: '数据与统计',
      groupEn: 'Data and statistics',
      methods: ['getAppUsageStats', 'getAppUsageSnapshot'],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '已接入多版本只读回退链，字段按白名单脱敏',
      summaryEn:
          'Read-only fallbacks are wired with an allow-listed field policy',
      panel: 'usage',
    ),
    NativeFeatureSpec(
      service: 'coding-plan-subscription',
      titleZh: '套餐与计费',
      titleEn: 'Plans and billing',
      groupZh: '账户与安全',
      groupEn: 'Account and security',
      methods: ['billing'],
      access: NativeFeatureAccess.restricted,
      summaryZh: '按项目合规边界，移动端不调用计费接口',
      summaryEn:
          'Billing APIs are not called under the project compliance boundary',
    ),
    NativeFeatureSpec(
      service: 'client-scenes',
      titleZh: '客户端场景',
      titleEn: 'Client scenes',
      groupZh: '设置与同步',
      groupEn: 'Settings and sync',
      methods: ['onboarding'],
      access: NativeFeatureAccess.pending,
      summaryZh: '待接入原生引导与迁移入口',
      summaryEn: 'Waiting for native onboarding and migration entry points',
    ),
    NativeFeatureSpec(
      service: 'skills',
      titleZh: '技能',
      titleEn: 'Skills',
      groupZh: 'Agent 能力',
      groupEn: 'Agent capabilities',
      methods: ['list', 'buildPromptContext', 'setEnabled'],
      access: NativeFeatureAccess.native,
      summaryZh: '列表与用户/工作区启用已接入；插件/内置只读，删除和复制仍受限',
      summaryEn:
          'Real list reads and local-scope enable; plugin/built-in stay read-only',
      panel: 'skills',
    ),
    NativeFeatureSpec(
      service: 'skill-sync',
      titleZh: '技能同步',
      titleEn: 'Skill sync',
      groupZh: '设置与同步',
      groupEn: 'Settings and sync',
      methods: ['listLocalUserSkillCandidates', 'exportSkillsArchive'],
      access: NativeFeatureAccess.pending,
      summaryZh: '需要归档、冲突和覆盖确认',
      summaryEn: 'Needs archive, conflict, and overwrite confirmation',
    ),
    NativeFeatureSpec(
      service: 'mcp-sync',
      titleZh: 'MCP 同步',
      titleEn: 'MCP sync',
      groupZh: 'Agent 能力',
      groupEn: 'Agent capabilities',
      methods: ['listLocalUserMcpCandidates', 'listRemoteUserMcpStatuses'],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '本地候选与远端状态已接入；同步写入仍需确认',
      summaryEn:
          'Local candidates and remote status are wired; sync writes await confirmation',
      panel: 'mcpServers',
    ),
    NativeFeatureSpec(
      service: 'plugin-sync',
      titleZh: '插件同步',
      titleEn: 'Plugin sync',
      groupZh: '设置与同步',
      groupEn: 'Settings and sync',
      methods: ['listLocalUserPluginCandidates', 'exportPluginsArchive'],
      access: NativeFeatureAccess.pending,
      summaryZh: '需要归档和远端写权限回执',
      summaryEn: 'Needs archive handling and remote write-access receipts',
    ),
    NativeFeatureSpec(
      service: 'plugins',
      titleZh: '插件',
      titleEn: 'Plugins',
      groupZh: 'Agent 能力',
      groupEn: 'Agent capabilities',
      methods: ['getOverview', 'getPluginsOverview'],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '插件目录、市场摘要和插件 MCP 状态已接入',
      summaryEn:
          'Plugin catalog, marketplace summary, and plugin MCP status are wired',
      panel: 'plugins',
    ),
    NativeFeatureSpec(
      service: 'plugin-management',
      titleZh: '插件管理',
      titleEn: 'Plugin management',
      groupZh: 'Agent 能力',
      groupEn: 'Agent capabilities',
      methods: ['describePlugin', 'validatePlugin', 'setPluginEnabled'],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '管理服务可读；安装、卸载和启用待写回执核验',
      summaryEn:
          'Management reads are wired; install, uninstall, and enable await receipts',
      panel: 'plugins',
    ),
    NativeFeatureSpec(
      service: 'subagents',
      titleZh: '子智能体',
      titleEn: 'Subagents',
      groupZh: 'Agent 能力',
      groupEn: 'Agent capabilities',
      methods: ['list', 'createAgent', 'setEnabled'],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '列表真实读取；增删改和启用待回执核验',
      summaryEn:
          'Real list reads; create, edit, delete, and enable await receipts',
      panel: 'subagents',
    ),
    NativeFeatureSpec(
      service: 'commands',
      titleZh: '命令',
      titleEn: 'Commands',
      groupZh: 'Agent 能力',
      groupEn: 'Agent capabilities',
      methods: ['list', 'parseCommandFile', 'generateCommandFileContent'],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '列表探测和安全展示已接入；文件写入待核验',
      summaryEn:
          'List probing and safe display are wired; file writes await verification',
      panel: 'commands',
    ),
    NativeFeatureSpec(
      service: 'hooks',
      titleZh: '钩子',
      titleEn: 'Hooks',
      groupZh: 'Agent 能力',
      groupEn: 'Agent capabilities',
      methods: ['loadHooks', 'toggleHook', 'trustHook'],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '规则列表真实读取；保存、信任和切换待回执核验',
      summaryEn: 'Rule reads are wired; save, trust, and toggle await receipts',
      panel: 'hooks',
    ),
    NativeFeatureSpec(
      service: 'memory',
      titleZh: '记忆',
      titleEn: 'Memory',
      groupZh: 'Agent 能力',
      groupEn: 'Agent capabilities',
      methods: [
        'listProjectMemories',
        'getUserMemoryDirectory',
        'readProjectMemoryFile',
      ],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '目录与项目列表可读；正文和清空动作保持受限',
      summaryEn:
          'Directory and project lists are readable; content and clear stay restricted',
      panel: 'memory',
    ),
    NativeFeatureSpec(
      service: 'output-style',
      titleZh: '输出样式',
      titleEn: 'Output styles',
      groupZh: '模型与输出',
      groupEn: 'Models and output',
      methods: ['listStyles', 'getActiveStyle', 'setActiveStyle'],
      access: NativeFeatureAccess.readOnly,
      summaryZh: '样式列表真实读取；增删改和激活待回执核验',
      summaryEn: 'Style reads are wired; edit and activation await receipts',
      panel: 'outputStyles',
    ),
    NativeFeatureSpec(
      service: 'settings-sync',
      titleZh: '设置同步与迁移',
      titleEn: 'Settings sync and migration',
      groupZh: '设置与同步',
      groupEn: 'Settings and sync',
      methods: ['detect', 'importSelected', 'update'],
      access: NativeFeatureAccess.pending,
      summaryZh: '需要导入选择、冲突处理和覆盖确认',
      summaryEn:
          'Needs import selection, conflict handling, and overwrite confirmation',
    ),
    NativeFeatureSpec(
      service: 'bots',
      titleZh: '机器人',
      titleEn: 'Bots',
      groupZh: '项目工具',
      groupEn: 'Project tools',
      methods: ['bot catalog'],
      access: NativeFeatureAccess.pending,
      summaryZh: '当前项目没有稳定的移动端入口',
      summaryEn: 'There is no stable mobile entry in the current project',
    ),
    NativeFeatureSpec(
      service: 'feedback',
      titleZh: '反馈',
      titleEn: 'Feedback',
      groupZh: '项目工具',
      groupEn: 'Project tools',
      methods: ['feedback'],
      access: NativeFeatureAccess.pending,
      summaryZh: '待接入脱敏反馈表单',
      summaryEn: 'Waiting for a redacted feedback form',
    ),
    NativeFeatureSpec(
      service: 'repo-wiki',
      titleZh: '仓库 Wiki',
      titleEn: 'Repository wiki',
      groupZh: '项目工具',
      groupEn: 'Project tools',
      methods: ['readWiki', 'readPage', 'writeDraft'],
      access: NativeFeatureAccess.pending,
      summaryZh: '需要项目范围和草稿写入确认',
      summaryEn: 'Needs project scoping and draft-write confirmation',
    ),
    NativeFeatureSpec(
      service: 'prompt-attachment-transfer',
      titleZh: '提示词附件',
      titleEn: 'Prompt attachments',
      groupZh: '会话与任务',
      groupEn: 'Sessions and tasks',
      methods: ['attachmentBeginV4', 'attachmentChunkV4', 'attachmentCommitV4'],
      access: NativeFeatureAccess.native,
      summaryZh: '会话附件上传已由原生会话编辑器承载',
      summaryEn: 'Session attachment upload is handled by the native composer',
    ),
    NativeFeatureSpec(
      service: 'off-peak-task',
      titleZh: '错峰任务',
      titleEn: 'Off-peak tasks',
      groupZh: '项目工具',
      groupEn: 'Project tools',
      methods: ['off-peak task'],
      access: NativeFeatureAccess.pending,
      summaryZh: '待确认调度、取消和通知回执',
      summaryEn: 'Waiting for schedule, cancel, and notification receipts',
    ),
  ];

  static NativeFeatureSpec? byService(String service) {
    for (final item in all) {
      if (item.service == service) return item;
    }
    return null;
  }

  static int count(NativeFeatureAccess access) =>
      all.where((item) => item.access == access).length;
}
