# zcode-push（外置通知通道，v1.8.0）

桌面端 ZCode 的 hook 在 `PermissionRequest` / `Stop` 事件发生时把消息 POST
到这里；手机 App 长轮询取走并弹系统通知。

**这条通道完全不经过 ZCode 的 relay 终端槽位**，因此不会和 WebView 会话、
头无监控引擎互踢——这是它相对"再开一条 relay 终端"的根本优势。

## 部署（一次性）

```bash
# 1. 目录与权限
sudo mkdir -p /opt/zcode-push /var/lib/zcode-push /etc/zcode-push
sudo chown www-data:www-data /var/lib/zcode-push
sudo install -m 644 /opt/zcode-push/download/push_server.py /opt/zcode-push/push_server.py

# 2. 生成访问令牌（只打印一次，记下来填进 App 与桌面 hook）
sudo python3 /opt/zcode-push/push_server.py --mint-token

# 3. 服务
sudo install -m 644 /opt/zcode-push/download/zcode-push.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now zcode-push
sudo systemctl status zcode-push --no-pager

# 4. nginx（只新增一个 location，不动现有规则）
sudo cp /etc/nginx/sites-available/zhihui.kaogong.art{,.bak-$(date +%Y%m%d-%H%M%S)}
# 在 server{} 内加：
#   location ^~ /zpush/ { proxy_pass http://127.0.0.1:8788; ... }
sudo nginx -t && sudo systemctl reload nginx
```

## 回滚

```bash
sudo systemctl disable --now zcode-push
# 从 nginx 站点配置里删掉 location ^~ /zpush/ 块
sudo nginx -t && sudo systemctl reload nginx
```

## 接口

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| POST | `/zpush/publish` | `X-ZP-Token` | hook 上报：`{kind,title,body,sessionId,device}` |
| GET | `/zpush/poll?after=<id>` | `X-ZP-Token` | App 长轮询（最长 25s），返回未投递消息 |
| POST | `/zpush/ack` | `X-ZP-Token` | App 确认：`{ids:[…]}`，投递后即删 |
| GET | `/zpush/healthz` | 无 | 存活探测，只返回待投递条数 |

存储上限：已投递即删；未投递保留 7 天 / 最多 2000 条。
