#!/usr/bin/env node
// 注入脚本（JS）校验器：从 Dart 源码提取内联 JS，做语法检查 + 受控运行冒烟 + 边界行为断言。
//
// 为什么需要它：这些 JS 在 Dart 里是字符串常量，`flutter analyze`/`flutter test`
// 都不会校验它们的语法；一个笔误就会让观测静默失效（页面照常，通知没了）或让
// 跳转静默失效（点了通知没反应）。这个脚本让这类错误在 CI 的 fast gate 里立刻失败，
// 并把 D 报告复现过的输入边界固化成回归断言（对应 B08–B12、B15、B17、F12）。
//
// 覆盖：
//   1. lib/services/event_observer.dart 的 hookScript（页面观测钩子）
//   2. lib/services/session_jump.dart 的 jumpScript（页面内跳转 + 回执）
//
// 用法：node scripts/check_injected_js.mjs

import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const MAX_LISTEN_BYTES = 4194304;
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dartFile = resolve(root, 'lib/services/event_observer.dart');
const jumpFile = resolve(root, 'lib/services/session_jump.dart');

/** 从 Dart 源码提取 hookScript 的运行期字符串值。 */
export function extractHook(dartSource) {
  const marker = 'hookScript =';
  const markerAt = dartSource.indexOf(marker);
  if (markerAt < 0) throw new Error('hookScript 未找到');
  const open = dartSource.indexOf("'''", markerAt);
  const close = dartSource.indexOf("\n''';", open);
  if (open < 0 || close < 0) throw new Error('hookScript 的三引号边界未找到');

  const raw = dartSource.slice(open + 3, close);
  let out = '';
  for (let i = 0; i < raw.length; i += 1) {
    const c = raw[i];
    if (c === '\\' && i + 1 < raw.length) {
      out += raw[i + 1];
      i += 1;
      continue;
    }
    if (c === '$' && raw.startsWith('kMaxListenBytes', i + 1)) {
      out += String(MAX_LISTEN_BYTES);
      i += 'kMaxListenBytes'.length;
      continue;
    }
    if (c === '$' && raw[i + 1] === '{') {
      const end = raw.indexOf('}', i);
      if (end > 0) {
        out += String(MAX_LISTEN_BYTES);
        i = end;
        continue;
      }
    }
    out += c;
  }
  return out;
}

/** 提取 jumpScript 的运行期字符串值（插值点只有 tid/ws/attemptId/reportRetryMax）。 */
export function extractJumpScript(
  dartSource,
  { taskId = 'canary-task', workspace = null, attemptId = 7 } = {},
) {
  const at = dartSource.indexOf('static String jumpScript(');
  if (at < 0) throw new Error('jumpScript 未找到');
  const open = dartSource.indexOf("'''", at);
  // 结尾的 ''' 与 })() 同行，不能要求前面有换行。
  const close = dartSource.indexOf("'''", open + 3);
  if (open < 0 || close < 0) throw new Error('jumpScript 的三引号边界未找到');
  const raw = dartSource.slice(open + 3, close);
  return raw
    .replaceAll('$tidLiteral', JSON.stringify(taskId))
    .replaceAll(
      '$wsLiteral',
      workspace === null ? 'null' : JSON.stringify(workspace),
    )
    .replaceAll('$attemptId', String(attemptId))
    .replaceAll('$reportRetryMax', '20');
}

function makeSandbox() {
  const posted = [];
  const handlers = {};
  const window = {
    __zrStats: null,
    __zrHooked: false,
    flutter_inappwebview: {
      // 记录全部实参：F03 要求每条桥消息都携带主 frame 令牌（第 3 个参数）。
      callHandler: (...args) => posted.push(args),
    },
    addEventListener: (type, fn) => {
      handlers[type] = fn;
    },
  };
  const fetches = [];
  const sockets = [];
  window.WebSocket = function FakeWebSocket(url) {
    this.url = url;
    this.listeners = {};
    this.addEventListener = (type, fn) => {
      this.listeners[type] = fn;
    };
    sockets.push(this);
  };
  window.EventSource = function FakeEventSource(url) {
    this.url = url;
    this.listeners = {};
    this.addEventListener = (type, fn) => {
      this.listeners[type] = fn;
    };
  };
  window.fetch = async (input, init) => {
    fetches.push({ input: String(input), init: init || {} });
    const body = {
      status: 200,
      headers: { get: () => null },
      clone() {
        return this;
      },
      text: async () => '{"type":"data"}',
      body: null,
    };
    return body;
  };

  const sandbox = {
    window,
    location: { href: 'https://zcode.z.ai/remote/v4?sid=canary' },
    URL,
    TextDecoder,
    Uint8Array,
    atob,
    JSON,
    Date,
    Math,
    Promise,
    Object,
    Array,
    String,
    Number,
    console,
    setInterval: () => 0,
    clearInterval: () => {},
    setTimeout: () => 0,
    fetch: window.fetch,
  };
  const context = vm.createContext(sandbox);
  return { context, window, posted, handlers, fetches, sockets };
}

function makeEl(testid, { connected = true, visible = true } = {}) {
  return {
    clicks: 0,
    isConnected: connected,
    textContent: '',
    getAttribute: (name) => (name === 'data-testid' ? testid : null),
    getClientRects: () => (visible ? [{}] : []),
    scrollIntoView: () => {},
    click() {
      this.clicks += 1;
    },
  };
}

/** 跳转脚本的受控环境：假 DOM + 可控时钟 + 可手动触发的定时器。 */
function makeJumpSandbox({ token = 'tok', now = 1000 } = {}) {
  const posted = [];
  const els = [];
  const timeouts = [];
  const intervals = [];
  const observers = [];
  const clock = { now };
  const window = {
    __zrToken: token,
    flutter_inappwebview: { callHandler: (...args) => posted.push(args) },
  };
  const document = {
    body: {},
    querySelectorAll: (selector) =>
      selector === '[data-testid]' ? els.slice() : [],
    querySelector: () => null,
  };
  function FakeMutationObserver(callback) {
    this.callback = callback;
    this.disconnected = false;
    this.observe = () => {};
    this.disconnect = () => {
      this.disconnected = true;
    };
    observers.push(this);
  }
  const sandbox = {
    window,
    document,
    Date: { now: () => clock.now },
    JSON,
    Math,
    Object,
    Array,
    String,
    Number,
    RegExp,
    WeakSet,
    console,
    setInterval: (fn, ms) => {
      intervals.push({ fn, ms });
      return intervals.length;
    },
    clearInterval: () => {},
    setTimeout: (fn, ms) => {
      timeouts.push({ fn, ms });
      return timeouts.length;
    },
    clearTimeout: () => {},
    MutationObserver: FakeMutationObserver,
  };
  const context = vm.createContext(sandbox);
  return {
    context,
    window,
    posted,
    els,
    timeouts,
    intervals,
    observers,
    clock,
    document,
  };
}

function jumpPayload(posted, index = 0) {
  const args = posted[index];
  if (!args) throw new Error(`没有第 ${index} 条桥消息`);
  if (args[0] !== 'zrJump') {
    throw new Error(`handler 名应为 zrJump，实际 ${args[0]}`);
  }
  return { args, body: JSON.parse(args[1]) };
}

const results = [];
async function check(name, fn) {
  try {
    await fn();
    results.push({ name, ok: true });
    console.log(`  [ok] ${name}`);
  } catch (error) {
    results.push({ name, ok: false, error: String(error && error.message) });
    console.log(`  [FAIL] ${name} — ${error && error.message}`);
  }
}
function assert(cond, message) {
  if (!cond) throw new Error(message);
}

const hook = extractHook(readFileSync(dartFile, 'utf8'));
const jump = extractJumpScript(readFileSync(jumpFile, 'utf8'));

// 1) 语法：单独的 JS 语法检查（不执行）。
await check('提取出的钩子通过 JS 语法检查', () => {
  new vm.Script(hook, { filename: 'observer_hook.js' });
});

// 2) 运行冒烟：在受控环境里安装钩子，不得抛错。
const { context, window, posted, sockets, fetches } = makeSandbox();
await check('受控环境准备', () => {});
await check('在受控环境安装钩子不抛错', () => {
  vm.runInContext(hook, context, { filename: 'observer_hook.js' });
  assert(window.__zrHooked === true, 'window.__zrHooked 应为 true');
  assert(typeof window.__zrStats === 'object', '遥测计数应已初始化');
});

// 3) F03：令牌未注入前不得裸发；注入后在途消息按序补发并携带令牌。
await check('F03 令牌未注入前桥消息只入队、不裸发', () => {
  const ws = new window.WebSocket('wss://zcode.z.ai/ws?mid=token-probe');
  assert(
    typeof ws.listeners.message === 'function',
    '官方 relay 的 WS 应挂上监听',
  );
  ws.listeners.message({
    data: JSON.stringify({ type: 'data', payload: 'pre-token' }),
  });
  assert(posted.length === 0, `令牌未就绪时不得发送（实际 ${posted.length} 条）`);
});

await check('F03 令牌注入后在途消息补发且携带令牌', () => {
  vm.runInContext(
    "window.__zrSetToken && window.__zrSetToken('test-token')",
    context,
  );
  assert(posted.length === 1, `在途消息应补发（实际 ${posted.length} 条）`);
  assert(posted[0][2] === 'test-token', '桥消息第 3 个参数应为令牌');
});

// 4) B08：超限的 WS 文本不得进入桥（cap+1 字符）。
await check('B08 超限 WS 文本被丢弃、不产生桥消息', () => {
  const ws = new window.WebSocket('wss://zcode.z.ai/ws?mid=1');
  assert(
    typeof ws.listeners.message === 'function',
    '官方 relay 的 WS 应挂上监听',
  );
  const before = posted.length;
  ws.listeners.message({ data: 'x'.repeat(MAX_LISTEN_BYTES + 1) });
  assert(
    posted.length === before,
    `超限文本不应进入桥（新增 ${posted.length - before} 条）`,
  );
  assert(window.__zrStats.wsSkippedSize > 0, '应计入 wsSkippedSize');
});

// 5) B08 正例：正常大小的事件仍应送达（且带令牌）。
await check('B08 正常大小 WS 文本照常上报', () => {
  const ws = new window.WebSocket('wss://zcode.z.ai/ws?mid=2');
  const before = posted.length;
  ws.listeners.message({
    data: JSON.stringify({ type: 'data', payload: 'ok' }),
  });
  assert(posted.length > before, '正常消息应产生桥消息');
  assert(
    posted.slice(before).every((args) => args[2] === 'test-token'),
    '每条桥消息都必须携带令牌（F03）',
  );
});

// 6) B17：非默认端口的官方 host 不得被观察。
await check('B17 非默认端口（:8443）的 WS 不被观察', () => {
  const before = window.__zrStats.wsIgnored;
  const ws = new window.WebSocket('wss://zcode.z.ai:8443/ws');
  assert(typeof ws.listeners.message !== 'function', ':8443 的 WS 不应挂监听');
  assert(window.__zrStats.wsIgnored > before, '应计入 wsIgnored');
});

// 7) B17：跨域 URL query 含 /session 不得命中 fetch 白名单。
await check('B17 跨域 query 子串不授予 fetch 观察权限', async () => {
  const before = window.__zrStats.fetchCloned;
  await window.fetch('https://example.invalid/asset?next=/session');
  assert(window.__zrStats.fetchCloned === before, '跨域 URL 不应被 clone 观察');
});

// ---------------------------------------------------------------------------
// 跳转脚本（F12 / N07–N08）：命中要回执，失败要带原因，且回执带主 frame 令牌。
// ---------------------------------------------------------------------------

await check('跳转脚本通过 JS 语法检查', () => {
  new vm.Script(jump, { filename: 'session_jump.js' });
});

await check('F12 命中目标：点击一次并回执 found（含 attemptId/句柄/令牌）', () => {
  const box = makeJumpSandbox();
  const el = makeEl('task-item-canary-task');
  box.els.push(el);
  const returned = vm.runInContext(jump, box.context, {
    filename: 'session_jump.js',
  });
  assert(el.clicks === 1, `应点击一次（实际 ${el.clicks}）`);
  assert(returned === true, `同步命中应返回 true（实际 ${returned}）`);
  assert(box.posted.length === 1, `应恰好一条回执（实际 ${box.posted.length}）`);
  const { args, body } = jumpPayload(box.posted);
  assert(body.id === 7, `回执必须带 attemptId（实际 ${body.id}）`);
  assert(body.ok === true, 'ok 应为 true');
  assert(body.reason === 'found', `reason 应为 found（实际 ${body.reason}）`);
  assert(body.taskId === 'canary-task', '回执必须带请求的 taskId');
  assert(
    body.resolvedTaskId === 'task-item-canary-task',
    `回执应带命中的句柄（实际 ${body.resolvedTaskId}）`,
  );
  assert(args[2] === 'tok', '回执第 3 个参数必须是主 frame 令牌');
});

await check('F12 不可见/已卸载的候选不点击，也不误报 found', () => {
  const box = makeJumpSandbox();
  const hidden = makeEl('task-item-canary-task', { visible: false });
  const gone = makeEl('other-canary-task-2', { connected: false });
  box.els.push(hidden, gone);
  vm.runInContext(jump, box.context, { filename: 'session_jump.js' });
  assert(hidden.clicks === 0, '不可见元素不得点击');
  assert(gone.clicks === 0, '已卸载元素不得点击');
  assert(
    box.posted.filter((args) => JSON.parse(args[1]).ok).length === 0,
    '未命中不得回执 found',
  );
});

await check('F12 超时：20s 预算耗尽后回执 timeout', () => {
  const box = makeJumpSandbox();
  vm.runInContext(jump, box.context, { filename: 'session_jump.js' });
  assert(box.posted.length === 0, '搜索期间不得提前回执');
  box.clock.now += 21000;
  assert(box.intervals.length === 1, '应注册一个 interval 兜底');
  box.intervals[0].fn();
  const { body } = jumpPayload(box.posted);
  assert(body.reason === 'timeout', `reason 应为 timeout（实际 ${body.reason}）`);
  assert(body.ok === false, 'timeout 必须 ok=false');
});

await check('F12 令牌迟到：先不回执，令牌到位后补发同一条结果', () => {
  const box = makeJumpSandbox({ token: null });
  vm.runInContext(jump, box.context, { filename: 'session_jump.js' });
  box.clock.now += 21000;
  box.intervals[0].fn();
  assert(
    box.posted.length === 0,
    `没有令牌时不得裸发（实际 ${box.posted.length} 条）`,
  );
  assert(box.timeouts.length > 0, '应安排令牌重试');
  box.window.__zrToken = 'tok-late';
  box.timeouts[box.timeouts.length - 1].fn();
  assert(box.posted.length === 1, '令牌到位后应补发回执');
  const { args, body } = jumpPayload(box.posted);
  assert(body.reason === 'timeout', '补发的应是同一条 timeout 结果');
  assert(args[2] === 'tok-late', '补发也必须带令牌');
});

await check('F12 连点两跳：旧一代回执 superseded，且不误点', () => {
  const box = makeJumpSandbox();
  vm.runInContext(jump, box.context, { filename: 'session_jump.js' });
  const second = extractJumpScript(
    readFileSync(jumpFile, 'utf8'),
    { attemptId: 8 },
  );
  vm.runInContext(second, box.context, { filename: 'session_jump-2.js' });
  box.intervals[0].fn();
  const { body } = jumpPayload(box.posted);
  assert(body.id === 7, `旧一代回执应带自己的 id（实际 ${body.id}）`);
  assert(
    body.reason === 'superseded',
    `reason 应为 superseded（实际 ${body.reason}）`,
  );
  assert(
    box.posted.every((args) => JSON.parse(args[1]).id !== 8),
    '新的一代不应被旧代的结果顶替',
  );
});

await check('F12 空 taskId：回执 invalid 且不同步返回 true', () => {
  const box = makeJumpSandbox();
  const empty = extractJumpScript(readFileSync(jumpFile, 'utf8'), {
    taskId: '',
    attemptId: 3,
  });
  const returned = vm.runInContext(empty, box.context, {
    filename: 'session_jump-empty.js',
  });
  assert(returned === false, `空 taskId 应返回 false（实际 ${returned}）`);
  const { body } = jumpPayload(box.posted);
  assert(body.reason === 'invalid', `reason 应为 invalid（实际 ${body.reason}）`);
});

const failed = results.filter((r) => !r.ok);
console.log(
  `injected-js checks: ${results.length - failed.length}/${results.length} passed`,
);
process.exit(failed.length === 0 ? 0 : 1);
