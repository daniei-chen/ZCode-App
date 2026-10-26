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
#     --url https://zhihui.kaogong.art \
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

[[ -n "$URL" ]] || die "缺少 --url（例：https://zhihui.kaogong.art）"
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
  say "          command: curl -sS -m 8 -X POST $BASE/zpush/publish …"
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
# 任何失败都必须静默退出 0——hook 的退出码会影响 ZCode 的任务流程，
# 绝不能因为"通知没发出去"就阻塞用户的工作。
set -uo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zcode-push"
TOKEN_FILE="$CONFIG_DIR/token"
ENDPOINT_FILE="$CONFIG_DIR/endpoint"

[[ -r "$TOKEN_FILE" && -r "$ENDPOINT_FILE" ]] || exit 0
TOKEN="$(cat "$TOKEN_FILE")"
BASE="$(cat "$ENDPOINT_FILE")"
[[ -n "$TOKEN" && -n "$BASE" ]] || exit 0

EVENT="${1:-unknown}"
PAYLOAD="$(cat 2>/dev/null || true)"

KIND="info"
case "$EVENT" in
  PermissionRequest) KIND="permission" ;;
  Stop)              KIND="completed" ;;
  PostToolUseFailure) KIND="info" ;;
esac

# 从事件 JSON 里取标题/正文/会话 id（字段名做了防御性回退；取不到就用
# 事件名兜底——宁可通知内容朴素，也不能因为格式变化整条链路失效）。
TITLE="$(printf '%s' "$PAYLOAD" | python3 -c '
import json,sys
kind=sys.argv[1]
try:
    e=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
if not isinstance(e,dict): print(""); raise SystemExit
def pick(*keys):
    for k in keys:
        v=e.get(k)
        if isinstance(v,str) and v.strip(): return v.strip()
    return ""
tool=pick("toolName","tool_name","tool")
summary=pick("summary","description","prompt","command")
if kind=="permission":
    print(("需要审批: "+tool) if tool else "需要审批")
elif kind=="completed":
    print("任务已完成")
else:
    print(tool or "ZCode 通知")
' "$KIND" 2>/dev/null || echo "")"

BODY="$(printf '%s' "$PAYLOAD" | python3 -c '
import json,sys
try:
    e=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
if not isinstance(e,dict): print(""); raise SystemExit
def pick(*keys):
    for k in keys:
        v=e.get(k)
        if isinstance(v,str) and v.strip(): return v.strip()
    return ""
print(pick("summary","description","command","prompt","toolName","tool_name")[:600])
' 2>/dev/null || echo "")"

SESSION="$(printf '%s' "$PAYLOAD" | python3 -c '
import json,sys
try:
    e=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
if not isinstance(e,dict): print(""); raise SystemExit
for k in ("sessionId","session_id","taskId","task_id"):
    v=e.get(k)
    if isinstance(v,str) and v.strip(): print(v.strip()); break
else: print("")
' 2>/dev/null || echo "")"

[[ -n "$TITLE" || -n "$BODY" ]] || exit 0

python3 - "$KIND" "$TITLE" "$BODY" "$SESSION" "$BASE" "$TOKEN" <<'PY' >/dev/null 2>&1 || exit 0
import json,sys,urllib.request
kind,title,body,session,base,token = sys.argv[1:7]
data = json.dumps({
    "kind": kind,
    "title": title,
    "body": body,
    "sessionId": session,
    "device": "desktop",
}, ensure_ascii=False).encode("utf-8")
req = urllib.request.Request(
    base.rstrip("/") + "/zpush/publish",
    data=data,
    headers={"Content-Type": "application/json", "X-ZP-Token": token},
    method="POST",
)
try:
    urllib.request.urlopen(req, timeout=8).read()
except Exception:
    pass
PY

exit 0
SCRIPT
chmod 700 "$NOTIFY_SH"
printf '%s' "$BASE" > "$CONFIG_DIR/endpoint"
chmod 600 "$CONFIG_DIR/endpoint"
say "✓ 上报脚本已写入 $NOTIFY_SH"

# 3) ZCode hook 配置
HOOK_FILE="$HOOKS_DIR/$HOOK_MARK.json"
cat > "$HOOK_FILE" <<JSON
{
  "hooks": [
    {
      "event": "PermissionRequest",
      "command": "$NOTIFY_SH PermissionRequest"
    },
    {
      "event": "Stop",
      "command": "$NOTIFY_SH Stop"
    }
  ],
  "_note": "$HOOK_MARK：由 install_zcode_hook.sh 写入；事件发生时把消息推到 $BASE"
}
JSON
chmod 644 "$HOOK_FILE"
say "✓ hook 配置已写入 $HOOK_FILE"

# 4) 自检：直接发一条测试消息
say ""
say "== 自检（发一条测试消息到服务器）=="
TEST_OK=0
if curl -sS -m 10 -o /dev/null -w '%{http_code}' \
     -X POST "$BASE/zpush/publish" \
     -H "X-ZP-Token: $TOKEN" \
     -H 'Content-Type: application/json' \
     -d '{"kind":"info","title":"外置通道已连通","body":"这条来自安装脚本的自检消息"}' \
     | grep -q '^200$'; then
  TEST_OK=1
  say "✓ 服务器接受消息（200）"
else
  say "✗ 服务器拒绝了消息——检查地址与令牌是否匹配"
fi

say ""
say "== 完成 =="
say "  1. 手机 App → 设置 → 外置通知通道，填同一地址与令牌，点「保存并测试」"
[[ "$TEST_OK" == "1" ]] && say "  2. 手机那次测试应该能收到上面这条自检消息"
say "  3. 之后桌面端每次审批/任务结束都会自动推送"
say ""
say "卸载：bash $0 --uninstall"
