# ZCode

<p align="center">
  <img src="assets/brand/mark.png" width="96" alt="ZCode 图标" />
</p>

<p align="center">
  <strong>ZCode App</strong><br />
  ZCode 桌面端的 Android 移动远程控制客户端
</p>

<p align="center">
  <a href="https://github.com/2421873411a-rgb/ZCode-App/releases">下载 Release</a>
  ·
  <a href="https://github.com/2421873411a-rgb/ZCode-App/issues">反馈问题</a>
</p>

> ZCode App 是个人开发的非官方软件，与 Z.ai 无隶属关系。ZCode 及相关名称、图标和商标归其各自所有者所有。

## 项目简介

ZCode App（当前版本 1.0.8）面向需要在手机或平板上管理 ZCode 桌面任务的用户。它通过 ZCode 桌面端的移动远程控制功能接入电脑：扫码或粘贴控制链接，命名并保存设备，之后即可从设备页快速进入最近使用的设备和会话。

应用采用原生 Flutter 外壳承载设备管理、设置和通知；进入设备后的任务与会话页面使用内置 WebView 加载 ZCode 桌面端移动远程控制页面，保持电脑端的页面、布局和交互体验。Android 安装标识为 `com.zcode.app`，应用显示名为 `ZCode`。

<p align="center">
  <img src="docs/doraemon-zcode.png" width="820" alt="ZCode App 介绍图" />
</p>

> 介绍图仅用于项目展示，其中的角色形象及相关素材权利归其各自权利人所有。

## 界面预览

### 设备管理与设置

<table>
  <tr>
    <td align="center"><strong>设备管理</strong></td>
    <td width="24"></td>
    <td align="center"><strong>设置</strong></td>
  </tr>
  <tr>
    <td align="center">
      <img src="docs/screenshots/device-light.png" width="260" alt="ZCode 设备管理浅色模式" />
    </td>
    <td width="24"></td>
    <td align="center">
      <img src="docs/screenshots/settings-light.png" width="260" alt="ZCode 设置浅色模式" />
    </td>
  </tr>
</table>

### 会话页（内置 WebView）

进入设备后，任务与会话页面由内置 WebView 加载 ZCode 桌面端的移动远程控制页面，页面与功能以 WebView 中的电脑端体验为准。介绍页不再使用原生会话面板截图冒充实际会话页面。

截图中的设备名、任务内容和链接均为演示数据。请勿把真实二维码、控制链接或包含 `sid`、`hash`、token 的截图上传到公开仓库。

## 主要功能

- **扫码 / 链接接入**：设备页提供并排的“扫码”和“链接”入口，支持导入桌面端控制链接。
- **多设备管理**：设备可命名、排序、替换链接和删除；保存后无需重复导入。
- **快速启动**：启动进入可选——自动恢复最近使用的设备，或停留在设备中心；没有设备时显示“等待接入设备”的设备页。
- **桌面体验兼容**：设备页、设置页和通知由 App 原生外壳负责；进入设备后的实际任务与会话页面统一使用内置 WebView，加载 ZCode 桌面端远程控制页面。
- **统一主题链路**：日间、夜间和跟随系统设置同时影响设备页、设置页、启动冷屏及进入后的 WebView 主题。
- **任务通知**：审批请求、任务完成和任务失败都支持通知；前台使用应用内通知栏，离开应用后才使用 Android 弹窗式通知。
- **通知提醒方式**：声音 / 仅振动 / 静音三选，应用内和应用外通知统一跟随该设置。
- **通知跳转**：通知标题使用实际会话标题，内容显示任务摘要；点击后直接回到对应设备和对话。
- **后台消息提醒**：不显示“ZCode 运行中”常驻通知；应用退到后台后，在 WebView 和应用进程仍存活时继续监听，只有审批、完成或失败事件才发送提醒。若 Android 回收应用进程，系统不会保证无常驻服务的持续监听。
- **简体中文**：界面固定使用简体中文，不提供中英文切换。
- **更新入口**：设备页提供检查更新和 GitHub 仓库入口；发现新版后在应用内下载 APK（支持断点续传与 SHA256 完整性校验），弹窗展示本次更新内容，交给系统安装，也可一键跳转 GitHub 下载。
- **反馈与联系**：设置页提供 GitHub Issues 反馈入口与联系作者入口。

## 使用方式

1. 在电脑端 ZCode 打开“移动远程控制”。
2. 在 ZCode App 设备页点击“扫码”，或点击“链接”粘贴控制链接。
3. 导入后为设备命名，例如“家里电脑”或“办公室”。
4. 点击设备卡片进入内置 WebView 任务和会话页；再次打开应用会优先恢复最近使用的设备。

控制链接相当于远程访问凭据。请只在自己的设备之间传递，不要提交到 Git、Issue、日志或公开截图中。

## 构建

环境要求：

- Flutter `>= 3.47`
- Dart `>= 3.10`
- Android SDK 36
- JDK 17

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

正式 Release 构建需要在 `android/key.properties` 中配置发布签名。GitHub Actions 同样要求配置仓库 Secrets：`KEYSTORE_BASE64` 和 `KEYSTORE_PASSWORD`；没有发布签名时工作流会主动失败，不会退回使用 debug key。

## 项目结构

```text
lib/
  models/       设备、通知、会话等数据模型
  services/     设备存储、WebView、通知、更新和后台服务
  state/        设备池、会话、事件流和页面状态
  ui/           设备、WebView 会话入口、通知和设置页面
android/        Android 原生启动、通知音效和后台服务实现
docs/           架构说明、协议记录、测试截图和设计资料
test/           Dart 单元测试与 Widget 测试
```

## 测试状态

质量门禁以 CI 为准（不手工维护测试数字）：

[![ci](https://github.com/2421873411a-rgb/ZCode-App/actions/workflows/ci.yml/badge.svg)](https://github.com/2421873411a-rgb/ZCode-App/actions/workflows/ci.yml)

- `flutter analyze` + `flutter test`：每次 push / PR 在 CI 执行
- 包名：`com.zcode.app`（Android 专用，不支持 iOS）

## 声明与许可证

本软件为个人开发的非官方软件，如有侵权，请联系作者处理。软件仅通过 ZCode 桌面端公开的移动远程控制链路接入，不伪造请求、不绕过鉴权。

本项目基于上游开源项目 [pjpv/zremote](https://github.com/pjpv/zremote) 改造，遵循 MIT License 发布。
