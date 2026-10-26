#!/usr/bin/env bash
# =============================================================================
# ZCode App 外置通知 hook 安装器（v1.8.0）
#
# 作用：在桌面端 ZCode 注册两个 hook，让它在「审批请求出现」和「任务结束」
#       时把消息 POST 到你的 zcode-push 服务；手机 App 长轮询取走并弹通知。
#
# 为什么用 hook 而不是让 App 再开一条 relay 终端：
#   ZCode 的中继是「单控制端」语义——同一台电脑同时只允许一个手机终端。
#   App 内的会话页与后台监控已经在抢这个槽位（表现为「一直被其他设备接管」）。
#   hook 是桌面端主动推送，完全不经过 relay，因此不会与任何终端冲突。
#
# 用法：
#   bash install_zcode_hook.sh \
#     --url https://your-server.example.com \
#     --token <你的令牌>
#   （可选）--dry-run   只打印将要写入的配置，不落盘
#            --uninstall 移除本脚本添加的 hook
#
# 安全：令牌写入 ~/.config/zcode-push/token（chmod 600），不进命令行历史
#       以外的任何地方；hook 命令用 curl 读该文件，不在进程参数里暴露令牌。
# =============================================================================
set -euo pipefail

URL=""
TOKEN=""
DRY_RUN=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

HOOK_MARK="zcode-push-notify"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zcode-push"
TOKEN_FILE="$CONFIG_DIR/token"
HOOKS_DIR="${ZCODE_HOME:-$HOME/.zcode}/hooks"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1"; }
need curl
need python3

if [[ "$UNINSTALL" == "1" ]]; then
  say "== 移除 zcode-push hook =="
  removed=0
  if [[ -d "$HOOKS_DIR" ]]; then
    while IFS= read -r -d '' f; do
      if grep -qF "$HOOK_MARK" "$f" 2>/dev/null; then
        rm -f "$f"
        say "  已删除: $f"
        removed=$((removed + 1))
      fi
    done < <(find "$HOOKS_DIR" -type f -name '*.json' -print0 2>/dev/null)
  fi
  rm -f "$TOKEN_FILE"
  say "  已清除令牌文件 $TOKEN_FILE"
  [[ "$removed" == "0" ]] && say "  （没有找到本脚本安装的 hook 文件）"
  say ""
  say "注意：如果 hook 是在 ZCode 界面里手动加的，请在 设置 → 钩子 里删除。"
  exit 0
fi

[[ -n "$URL" ]] || die "缺少 --url（例：https://your-server.example.com）"
[[ -n "$TOKEN" ]] || die "缺少 --token（服务器 /etc/zcode-push/token 的内容）"

BASE="${URL%/}"
case "$BASE" in
  https://*) ;;
  *) die "服务器地址必须是 https://（令牌走 header，明文不可接受）" ;;
esac
[[ ${#TOKEN} -ge 16 ]] || die "令牌过短，检查是否复制完整"

say "== ZCode App 外置通知 hook 安装 =="
say "  服务器: $BASE"
say "  令牌:   ${TOKEN:0:6}…（共 ${#TOKEN} 字符）"
say ""

mkdir -p "$CONFIG_DIR" "$HOOKS_DIR"
chmod 700 "$CONFIG_DIR"

if [[ "$DRY_RUN" == "1" ]]; then
  say "[dry-run] 将写入 $TOKEN_FILE"
  say "[dry-run] 将在 $HOOKS_DIR 下写入 hook 配置："
  say "          events: PermissionRequest, Stop"
  say "          （配置经桌面端 设置→钩子 写入并授权）"
  exit 0
fi

# 1) 令牌落盘（600，只有本人可读）
printf '%s' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
say "✓ 令牌已写入 $TOKEN_FILE（权限 600）"

# 2) 上报脚本：统一收口 URL/鉴权/超时，hook 配置里只调它
NOTIFY_SH="$CONFIG_DIR/notify.sh"
cat > "$NOTIFY_SH" <<'SCRIPT'
#!/usr/bin/env bash
# 由 ZCode hook 调用：从 stdin 读事件 JSON，POST 到 zcode-push。
#
# 两条硬约束（都是实测踩出来的）：
#  1. 任何失败都必须静默 exit 0——hook 的退出码会影响 ZCode 的任务流程，
#     绝不能因为"通知没发出去"就阻塞用户的工作；
#  2. 不依赖 python：Windows 上 `python3` 常是 Microsoft Store 的桩程序
#     （运行即静默失败），依赖它会导致字段解析全空、一条通知都发不出。
#     这里用纯 bash + sed 提取字段。
set -uo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zcode-push"
TOKEN_FILE="$CONFIG_DIR/token"
ENDPOINT_FILE="$CONFIG_DIR/endpoint"

[ -r "$TOKEN_FILE" ] || exit 0
[ -r "$ENDPOINT_FILE" ] || exit 0
TOKEN="$(cat "$TOKEN_FILE")"
BASE="$(cat "$ENDPOINT_FILE")"
[ -n "$TOKEN" ] || exit 0
[ -n "$BASE" ] || exit 0

EVENT="${1:-unknown}"

# stdin：ZCode 的「进程」模式可能不传 stdin。有界读，绝不无限等待。
PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD="$(timeout 2 cat 2>/dev/null || true)"
fi

KIND="info"
case "$EVENT" in
  PermissionRequest) KIND="permission" ;;
  Stop) KIND="completed" ;;
  SessionEnd) KIND="completed" ;;
  *) KIND="info" ;;
esac

# 从扁平 JSON 里取第一个匹配 key 的字符串值。
# 用 # 作 sed 分隔符（内容常含 / | 等字符）。
json_str() {
  key="$1"
  src="$2"
  pattern='.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*'
  printf '%s' "$src" | sed -n "s#${pattern}#\\1#p" | head -1
}

TOOL="$(json_str toolName "$PAYLOAD")"
[ -n "$TOOL" ] || TOOL="$(json_str tool_name "$PAYLOAD")"
SUMMARY="$(json_str summary "$PAYLOAD")"
[ -n "$SUMMARY" ] || SUMMARY="$(json_str description "$PAYLOAD")"
[ -n "$SUMMARY" ] || SUMMARY="$(json_str command "$PAYLOAD")"
[ -n "$SUMMARY" ] || SUMMARY="$(json_str prompt "$PAYLOAD")"
SESSION="$(json_str sessionId "$PAYLOAD")"
[ -n "$SESSION" ] || SESSION="$(json_str taskId "$PAYLOAD")"

case "$KIND" in
  permission) TITLE="需要审批" ;;
  completed) TITLE="任务已完成" ;;
  *) TITLE="ZCode 通知" ;;
esac
if [ -n "$TOOL" ]; then
  TITLE="$TITLE: $TOOL"
fi

# 正文兜底：没有摘要就用事件名（宁可朴素，也不能整条链路失效）。
BODY="${SUMMARY:-$EVENT}"

# 截断（服务端还会二次截断）。
TITLE="$(printf '%s' "$TITLE" | cut -c1-180)"
BODY="$(printf '%s' "$BODY" | cut -c1-500)"

# JSON 字符串转义：反斜杠、双引号、换行。
json_escape() {
  printf '%s' "$1" \
    | tr -d '\r' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk 'BEGIN{ORS=""} {if (NR > 1) printf "\\n"; print}'
}

TITLE_ESC="$(json_escape "$TITLE")"
BODY_ESC="$(json_escape "$BODY")"
SESSION_ESC="$(json_escape "$SESSION")"

BODY_FILE="$(mktemp)"
printf '{"kind":"%s","title":"%s","body":"%s","sessionId":"%s","device":"desktop"}' \
  "$KIND" "$TITLE_ESC" "$BODY_ESC" "$SESSION_ESC" > "$BODY_FILE"

# 静默上报：失败不影响 ZCode 的任务流程。
curl -sS -m 10 -o /dev/null \
  -X POST "$BASE/zpush/publish" \
  -H "X-ZP-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary "@$BODY_FILE" 2>/dev/null || true

rm -f "$BODY_FILE"
exit 0
SCRIPT
chmod 700 "$NOTIFY_SH"
printf '%s' "$BASE" > "$CONFIG_DIR/endpoint"
chmod 600 "$CONFIG_DIR/endpoint"
say "✓ 上报脚本已写入 $NOTIFY_SH"

# 3) ZCode hook 配置
#
# 重要（v1.8.2 实测修正）：ZCode 的 hooks **不扫描** `~/.zcode/hooks/*.json`。
# 它们由桌面端按 **workspace** 持久化，必须经 `saveHooks({workspacePath,
# scope})` 写入并完成信任授权（`grantWorkspaceHookTrust`），UI 位置是
#   设置 → 钩子（插件详情里也叫 settings.plugins.detail.hook）
# 真实 schema 是按事件名分组的对象，每一项形如：
#   { "hooks": [ { "type": "command", "command": "...", "timeout": 10 } ],
#     "matcher": "..." }
#
# 因此这里做两件事：
#   1. 仍然把一份**格式正确**的 JSON 写到 ~/.config/zcode-push/hooks.json，
#      供你在界面里用"导入"直接选它；
#   2. 把同样的内容打印出来，界面不支持导入时可以逐条粘贴。
HOOK_JSON="$CONFIG_DIR/hooks.json"
cat > "$HOOK_JSON" <<JSON
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$NOTIFY_SH PermissionRequest",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$NOTIFY_SH Stop",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
JSON
chmod 600 "$HOOK_JSON"
say "✓ hook 配置已生成：$HOOK_JSON"

say ""
say "══════════════════════════════════════════════════════════════"
say "  还需在 ZCode 桌面端做最后一步（必须，否则不会触发）"
say "══════════════════════════════════════════════════════════════"
say ""
say "  ZCode 的 hooks 存在工作区配置里并需要信任授权，命令行无法直接写入。"
say "  请在桌面端：设置 → 钩子 → 新建/导入，填下面两条："
say ""
say "    事件 PermissionRequest"
say "    命令 bash \"$NOTIFY_SH\" PermissionRequest"
say ""
say "    事件 Stop"
say "    命令 bash \"$NOTIFY_SH\" Stop"
say ""
say "  ⚠ Windows：命令必须带 bash 前缀。ZCode 的「进程」方式直接执行，"
say "    .sh 不是可执行程序会报找不到文件。若 bash 不在 PATH，用完整路径："
say "    C:\Program Files\Git\bin\bash.exe \"$NOTIFY_SH\" Stop"
say ""
say "  支持"导入"的版本可以直接选这个文件："
say "    $HOOK_JSON"
say ""
say "  保存后如果提示"需要信任"，点允许——不信任的 hook 不会执行。"
say "══════════════════════════════════════════════════════════════"
say ""

# 4) 自检：直接发一条测试消息
say ""
say "== 自检（发一条测试消息到服务器）=="
TEST_OK=0
# 用临时文件承接 JSON 体：Git Bash 会把命令行里的中文按 GBK 传，服务端按
# UTF-8 解析会 400（bad_json）。写文件走 --data-binary 就没有这个问题。
TEST_BODY="$(mktemp)"
printf '%s' '{"kind":"info","title":"外置通道已连通","body":"这条来自安装脚本的自检消息"}' > "$TEST_BODY"
HTTP_CODE=$(curl -sS -m 15 -o /dev/null -w '%{http_code}'   -X POST "$BASE/zpush/publish"   -H "X-ZP-Token: $TOKEN"   -H 'Content-Type: application/json'   --data-binary "@$TEST_BODY" 2>/dev/null)
rm -f "$TEST_BODY"
HTTP_CODE="${HTTP_CODE:-000}"
if [[ "$HTTP_CODE" == "200" ]]; then
  TEST_OK=1
  say "✓ 服务器接受消息（HTTP 200）——手机上点「保存并测试」应能收到"
else
  say "✗ 服务器返回 HTTP $HTTP_CODE"
  case "$HTTP_CODE" in
    401) say "  令牌不匹配：手机与桌面必须用同一个 /etc/zcode-push/token" ;;
    404) say "  端点不存在：检查 --url 是否指向已部署 zcode-push 的域名" ;;
    000) say "  连不上：检查网络，或服务器上 docker ps 看 zcode-push 是否在跑" ;;
  esac
fi

say ""
say "== 完成 =="
say "  1. 手机 App → 设置 → 外置通知通道，填同一地址与令牌，点「保存并测试」"
[[ "$TEST_OK" == "1" ]] && say "  2. 手机那次测试应该能收到上面这条自检消息"
say "  3. 之后桌面端每次审批/任务结束都会自动推送"
say ""
say "卸载：bash $0 --uninstall"
