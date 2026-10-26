# zcode-push（外置通知通道，v1.8.0）

桌面端 ZCode 的 hook 在 `PermissionRequest` / `Stop` 事件发生时把消息 POST
到这里；手机 App 长轮询取走并弹系统通知。

**这条通道完全不经过 ZCode 的 relay 终端槽位**，因此不会和 WebView 会话、
头无监控引擎互踢——这是它相对"再开一条 relay 终端"的根本优势。

## 前置

`/etc/zcode-push/token` 存放共享令牌（只读挂进容器）：

```bash
sudo mkdir -p /opt/zcode-push/data /etc/zcode-push
sudo openssl rand -base64 32 | sudo tee /etc/zcode-push/token >/dev/null
sudo chmod 600 /etc/zcode-push/token
sudo chown 10001:10001 /opt/zcode-push/data
```

## 部署（Docker Compose，与现有服务隔离）

```bash
sudo mkdir -p /opt/zcode-push/src
# 把本目录（Dockerfile / docker-compose.yml / push_server.py）拷进 /opt/zcode-push/src
cd /opt/zcode-push/src
sudo docker compose up -d --build
sudo docker compose ps
curl -s http://127.0.0.1:8788/zpush/healthz     # {"ok":true,...}
```

## nginx（只新增一个 location，不动现有规则）

在**你的站点**的 `server { }` 内加入：

```nginx
location ^~ /zpush/ {
    proxy_pass http://127.0.0.1:8788;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    # 长轮询 25s，给足余量
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
    # 不缓存、不记录令牌
    proxy_buffering off;
}
```

```bash
sudo cp /etc/nginx/sites-available/<你的站点>{,.bak-$(date +%Y%m%d-%H%M%S)}
sudo nginx -t && sudo systemctl reload nginx
curl -s https://<你的域名>/zpush/healthz
```

## 回滚

```bash
cd /opt/zcode-push/src && sudo docker compose down
# 删掉 nginx 里的 location ^~ /zpush/ 块
sudo nginx -t && sudo systemctl reload nginx
```

## 接口

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| POST | `/zpush/publish` | `X-ZP-Token` | hook 上报：`{kind,title,body,sessionId,device}` |
| GET | `/zpush/poll?after=<id>` | `X-ZP-Token` | App 长轮询（最长 25s），返回未投递消息 |
| POST | `/zpush/ack` | `X-ZP-Token` | App 确认：`{ids:[…]}`，投递后即删 |
| GET | `/zpush/healthz` | 无 | 存活探测，只返回待投递条数 |

`kind` 取值：`permission`（审批请求）/ `completed`（任务结束）/ `info`。

存储上限：已投递即删；未投递保留 7 天 / 最多 2000 条。

## 自测

```bash
python3 server/zcode-push/test_server.py
```

20 项断言：鉴权（缺/错/短令牌）、publish 校验与字段截断、poll 游标与去重、
ack 后即删、健康检查、未知路由。全部 stdlib，无需起容器。

## 桌面端安装（一次性，在你自己电脑上跑）

```bash
bash install_zcode_hook.sh \
  --url https://<你的域名> \
  --token <把 /etc/zcode-push/token 的内容贴这里>
```

脚本会：

1. 把令牌写到 `~/.config/zcode-push/token`（权限 600；hook 命令从这里读，
   不会把令牌放进进程参数或 shell 历史）；
2. 生成上报脚本 `~/.config/zcode-push/notify.sh`（读 stdin 事件 JSON，
   **任何失败都静默 exit 0**——通知发不出去绝不能阻塞 ZCode 的任务）；
3. 在 `~/.zcode/hooks/zcode-push-notify.json` 注册两个 hook：
   `PermissionRequest`（审批请求）与 `Stop`（任务结束）；
4. 自检：直接发一条测试消息，确认服务器接受。

卸载：`bash install_zcode_hook.sh --uninstall`。

### 关于 hook 写入位置（v1.8.2 实测修正）

**不要把 JSON 丢进 `~/.zcode/hooks/`——ZCode 不扫描那个目录。**

真实机制（从官方 3.16.3 bundle 逆向确认）：

- hooks 由桌面端**按 workspace 持久化**，通过 `saveHooks({workspacePath, scope})`
  写入，UI 在 **设置 → 钩子**（插件详情里的标识是 `settings.plugins.detail.hook`）；
- 写入后需要**信任授权**（`grantWorkspaceHookTrust`），未信任的 hook 不执行；
- 真实 schema 是**按事件名分组**的对象：

```json
{
  "hooks": {
    "PermissionRequest": [
      { "hooks": [ { "type": "command", "command": "… PermissionRequest", "timeout": 10 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "… Stop", "timeout": 10 } ] }
    ]
  }
}
```

支持的事件名：`SessionStart`、`UserPromptSubmit`、`PreToolUse`、
`PermissionRequest`、`PostToolUse`、`PostToolUseFailure`、`Stop`。

`install_zcode_hook.sh` 会把这份（格式正确的）JSON 生成到
`~/.config/zcode-push/hooks.json`，并打印在界面里逐条填写所需的命令与事件。

### 如果界面里已经配过 hook

Zone 的 hook 也可以在桌面端 设置 → 钩子 里手工加。手工配置时填：

| 事件 | 命令 |
|---|---|
| `PermissionRequest` | `~/.config/zcode-push/notify.sh PermissionRequest` |
| `Stop` | `~/.config/zcode-push/notify.sh Stop` |
