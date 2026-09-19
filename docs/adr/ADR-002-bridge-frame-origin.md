# ADR-002 桥调用方 frame/origin 强校验路线（R-14 / F03 残余）

- 状态：**提议，待运行时证据**（2026-09-16）
- 关联：F03（PR04 已落地主 frame 令牌）、R-14

## 背景

现状：桥回调 = 文档信任（`getUrl()` 在官方页）+ 主 frame 随机令牌（`_bridgeAllowed`）。令牌能挡**跨域**子 frame（读不到父窗口全局）。残余：同源 / `srcdoc` / `about:blank` 子 frame 可读父窗口 `__zrToken`；未设 `regexToCancelSubFramesLoading`；flutter_inappwebview 6.1.5 的 JS handler 不给调用方 frame/origin（6.2.0-beta 才有）。

风险评估：同源子 frame 能读令牌的前提是攻击者已能在官方页同源下执行脚本——此时攻击者本就能从主 frame 直接调桥，令牌与 frame 校验都不构成额外防线。残余风险的真实价值是**纵深**（防止官方页自身嵌入的第三方 iframe 被利用），而非新攻击面。

## 候选

| 方案 | 做法 | 收益 | 代价 / 风险 |
| --- | --- | --- | --- |
| A 阻断全部子 frame | `regexToCancelSubFramesLoading: '.*'` | 一行，彻底 | 若官方页合法使用 iframe（登录、预览、嵌入终端）会直接破坏功能；**无运行时证据** |
| B 升级插件 6.2.0-beta | 用 handler 的 source frame/origin 参数校验 `isMainFrame && origin == 官方` | 精确 | beta 进发布链是供应链决策；需回归 11 插件存活门、E2E |
| C 本地最小补丁 | fork 插件 Android 层，在 `addJavascriptInterface` 回调注入 frame/origin | 精确、不依赖 beta | 维护 fork；SBOM/许可证记录；升级成本 |
| D 接受残余并记录 | 令牌 + 文档信任为现状 | 零改动 | 纵深缺一层 |

## 决定（分两步）

1. **先取证，不盲断**：在 `shouldOverrideUrlLoading` 中对 `!navigationAction.isForMainFrame` 计数（诊断页 `subFrameNavigations` + 目标 host 类别），随真机/soak 收集。**零合法子 frame** → 采纳 A；否则按白名单 regex 只放行观测到的合法 host。
2. 插件 6.2 转 stable 后评估 B（供应链复审：OSV、插件存活门、E2E 全跑）；C 仅在 B 长期不可用且 A 不可行时启用。

当前状态维持 D（已在 `docs/THREAT-MODEL.md`/台账记录）。

## 验证

- 负测：跨域子 frame、`srcdoc`、`about:blank`、导航竞争、旧 generation 消息（PLAN B01–B07）；
- A 落地后：官方页关键路径 E2E（配对、会话、设置面板、审批）在 API 30/34 全绿。

## 回退

- A/B/C 任一均可单独 revert；A 为一行配置。

## 复审时间

下一次真机矩阵/soak 归档时（取证数据到位）；或 flutter_inappwebview 6.2 stable 发布时。
