# ADR-004 每设备 WebView 站点数据隔离

- 状态：**提议，待产品决策**（2026-09-16）· 级别 P2
- 关联：R-17 细化、F16（资源池）、`docs/PRIVACY.md` WebView 存储清单

## 背景

所有设备的 WebView 加载同一官方 origin（`zcode.z.ai`），不同设备 = 不同控制链接（凭证在 URL 参数），但 **localStorage / IndexedDB / Cookie 按 origin 共享**。现状缓解：换链接即重建 generation 并 `clearForCredentialChange`；删除/擦除走 `clearAllSiteData`（R-15/R-17）。未做：同一时刻多台设备共存时的存储互见。

威胁模型定位：手机上的多台设备都是**同一用户自有**，跨设备存储互见的实际影响是"页面 A 的本地状态可能被页面 B 读到"，不构成跨用户越权；官方页是否把会话凭据写入本地存储未证实（协议文档未见）。

## 候选

| 方案 | 做法 | 收益 | 代价 / 风险 |
| --- | --- | --- | --- |
| A 共享 profile + 凭证变更清理（现状） | 维持 | 零改动 | 多设备并存时存储互见（同用户） |
| B 每设备独立 profile | Android WebView 多 Profile API（androidx.webkit `ProfileStore`，需较新 WebView 与插件支持；flutter_inappwebview 6.1.5 未暴露） | 真隔离 | 依赖插件能力；每 profile 独立 cookie/cache 增加内存（与 F16 资源池目标冲突） |
| C 每 generation 无持久化 | 隐身式：不落盘站点数据 | 隔离且省空间 | 若官方页依赖本地存储保持登录/偏好，会每次重新配对（体验回退） |
| D 逻辑隔离 | 注入脚本给 storage key 加设备前缀 | 不依赖插件 | 侵入官方页实现，脆弱且违背"不复刻/不篡改官方 UI"原则 |

## 推荐

维持 **A**，并在 `PRIVACY.md` 明确"同 origin 多设备共享站点数据（同用户）"；当 flutter_inappwebview 暴露 Profile API 时评估 B，与 F16 资源池一并做内存预算。否决 D。

## 需用户决定的点

- 是否接受"同用户多设备共享站点数据"为长期设计（是 → 关闭本项；否 → 排期 B，接受插件依赖）。

## 验证

- A：`webview_storage_test`（清理路径）保持；`PRIVACY.md` 清单与实现一致（R-17）。
- B（若做）：两设备并存时 `localStorage` 互不可见的 E2E；内存基线不超预算。

## 复审时间

flutter_inappwebview 暴露多 Profile 能力时；或用户报告跨设备状态串扰时。
