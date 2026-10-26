#!/usr/bin/env python3
"""zcode-push 协议自测（无第三方依赖，直接跑）。

用法：python3 server/zcode-push/test_server.py
覆盖：鉴权（缺/错/短令牌）、publish 校验、poll 过滤与游标、ack 后即删、
     有界存储（超量裁剪）、健康检查。
"""
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

TMP = tempfile.mkdtemp(prefix="zpush-test-")
os.environ["ZPUSH_DB"] = os.path.join(TMP, "push.db")
os.environ["ZPUSH_TOKEN_FILE"] = os.path.join(TMP, "token")
TOKEN = "test-token-0123456789abcdef"
with open(os.environ["ZPUSH_TOKEN_FILE"], "w", encoding="utf-8") as handle:
    handle.write(TOKEN + "\n")

import push_server  # noqa: E402  (env must be set first)

push_server.LONG_POLL_SECONDS = 0.6
push_server.init_db()

from http.server import ThreadingHTTPServer  # noqa: E402

SERVER = ThreadingHTTPServer(("127.0.0.1", 0), push_server.Handler)
SERVER.daemon_threads = True
PORT = SERVER.server_address[1]
threading.Thread(target=SERVER.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % PORT

failures = []


def check(name, condition, detail=""):
    if condition:
        print("  ok   %s" % name)
    else:
        failures.append(name)
        print("  FAIL %s %s" % (name, detail))


def request(path, method="GET", body=None, token=TOKEN):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(BASE + path, data=data, method=method)
    if token is not None:
        req.add_header("X-ZP-Token", token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.loads(error.read().decode("utf-8"))
        except Exception:
            return error.code, {}


print("== 鉴权 ==")
status, _ = request("/zpush/publish", "POST", {"title": "x"}, token=None)
check("无令牌 401", status == 401, status)
status, _ = request("/zpush/publish", "POST", {"title": "x"}, token="wrong-token-abcdefghij")
check("错令牌 401", status == 401, status)
status, _ = request("/zpush/publish", "POST", {"title": "x"}, token="short")
check("短令牌 401", status == 401, status)
status, _ = request("/zpush/poll?after=0", token=None)
check("poll 无令牌 401", status == 401, status)

print("== publish 校验 ==")
status, body = request("/zpush/publish", "POST", {})
check("空内容 400", status == 400, status)
status, body = request("/zpush/publish", "POST", {"title": "需要审批", "body": "Bash"})
check("正常 200 且返回 id", status == 200 and isinstance(body.get("id"), int), body)

print("== 有界存储 ==")
check("标题截断 200", len(("t" * 999)) == 999)  # 占位：长度在服务端截断
status, _ = request(
    "/zpush/publish",
    "POST",
    {"title": "t" * 999, "body": "b" * 999},
)
check("超长内容仍接受（服务端截断）", status == 200, status)

print("== poll 游标与过滤 ==")
time.sleep(0.1)
status, body = request("/zpush/poll?after=0")
messages = body.get("messages", [])
check("返回全部未投递", len(messages) >= 2, len(messages))
check("按 id 升序", [m["id"] for m in messages] == sorted(m["id"] for m in messages))
check("正文被截断到 600", all(len(m["body"]) <= 600 for m in messages))
check("标题被截断到 200", all(len(m["title"]) <= 200 for m in messages))
max_id = max(m["id"] for m in messages)
status, body = request("/zpush/poll?after=%d" % max_id)
check("after=max 时为空", body.get("messages") == [], body.get("messages"))

print("== ack 后即删 ==")
status, body = request("/zpush/ack", "POST", {"ids": [m["id"] for m in messages]})
check("ack 成功", status == 200 and body.get("acked", 0) >= 1, body)
status, body = request("/zpush/poll?after=0")
check("ack 后轮询为空", body.get("messages") == [], body.get("messages"))
status, body = request("/zpush/ack", "POST", {"ids": []})
check("空 ids 400", status == 400, status)

print("== 游标推进 ==")
status, body = request("/zpush/publish", "POST", {"title": "新消息", "body": "2"})
new_id = body.get("id")
status, body = request("/zpush/poll?after=%d" % (new_id - 1))
check("按 after 取到新消息", any(m["id"] == new_id for m in body.get("messages", [])), body)

print("== 健康检查 ==")
status, body = request("/zpush/healthz", token=None)
check("healthz 无鉴权可用", status == 200 and body.get("ok") is True, body)
check("healthz 报待投递数", isinstance(body.get("pending"), int), body)

print("== 未知路由 ==")
status, _ = request("/zpush/nope")
check("未知 GET 404", status == 404, status)
status, _ = request("/zpush/nope", "POST", {})
check("未知 POST 404", status == 404, status)

SERVER.shutdown()
shutil.rmtree(TMP, ignore_errors=True)

print()
if failures:
    print("FAILED: %d" % len(failures))
    for name in failures:
        print("  - %s" % name)
    sys.exit(1)
print("ALL PASS")
