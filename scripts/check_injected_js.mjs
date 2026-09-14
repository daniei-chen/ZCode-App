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

/** 提取 InPageBack.script 的运行期字符串值（插值点：attemptId/maxCandidates/reportRetryMax）。 */
export function extractBackScript(
  dartSource,
  { attemptId = 5, maxCandidates = 6, reportRetryMax = 12 } = {},
) {
  const at = dartSource.indexOf('static String script(int attemptId)');
  if (at < 0) throw new Error('InPageBack.script 未找到');
  const open = dartSource.indexOf("'''", at);
  const close = dartSource.indexOf("'''", open + 3);
  if (open < 0 || close < 0) throw new Error('InPageBack.script 的三引号边界未找到');
  const raw = dartSource.slice(open + 3, close);
  let out = '';
  for (let i = 0; i < raw.length; i += 1) {
    const c = raw[i];
    if (c === '\\' && i + 1 < raw.length) {
      out += raw[i + 1];
      i += 1;
      continue;
    }
    out += c;
  }
  return out
    .replaceAll('$attemptId', String(attemptId))
    .replaceAll('$maxCandidates', String(maxCandidates))
    .replaceAll('$reportRetryMax', String(reportRetryMax));
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

// ---------------------------------------------------------------- 假 DOM（返回脚本）

/** 极简元素：只需要脚本真正用到的属性/方法。 */
function backEl({
  tag = 'button',
  ariaLabel = null,
  title = null,
  testid = null,
  text = '',
  rect = { top: 40, left: 16, width: 40, height: 40 },
  role = null,
  tabindex = null,
  disabled = false,
  icon = null,
  computedStyle = null,
  onActivate = null,
  attrs = null,
} = {}) {
  const element = {
    tagName: tag.toUpperCase(),
    attrs: attrs ? { ...attrs } : {},
    textContent: text,
    className: '',
    disabled,
    clicks: 0,
    icon: icon === null ? { tagName: 'SVG' } : icon,
    computedStyle,
    getAttribute: (name) => (name in element.attrs ? element.attrs[name] : null),
    // 几何兜底会问"是不是图标键"：有 svg 子节点即视为图标（脚本里的判据之一）。
    querySelector: (selector) => (selector === 'svg' ? element.icon : null),
    getBoundingClientRect: () => ({
      ...rect,
      right: rect.left + rect.width,
      bottom: rect.top + rect.height,
    }),
    scrollIntoView: () => {},
    click() {
      element.clicks += 1;
      if (onActivate) onActivate(element);
    },
  };
  if (ariaLabel) element.attrs['aria-label'] = ariaLabel;
  element.attrs = { ...element.attrs };
  if (title) element.attrs['title'] = title;
  if (testid) element.attrs['data-testid'] = testid;
  if (role) element.attrs['role'] = role;
  if (tabindex !== null) element.attrs['tabindex'] = String(tabindex);
  return element;
}

/** 支持本脚本用到的选择器：tag、[attr]、[attr="v"]、[attr*="v"]、[attr^="v"]、[attr$="v"]、逗号分组。 */
function matchesSelector(element, selector) {
  const part = selector.trim();
  const match = /^([a-zA-Z]*)(?:\[([a-zA-Z-]+)(?:([*^$]?=)"([^"]*)")?\])?$/.exec(part);
  if (!match) return false;
  const [, tag, attr, op, value] = match;
  if (tag && element.tagName !== tag.toUpperCase()) return false;
  if (!attr) return Boolean(tag);
  const actual = element.getAttribute(attr);
  if (actual === null) return false;
  if (!op) return true;
  if (op === '=') return actual === value;
  if (op === '*=') return actual.includes(value);
  if (op === '^=') return actual.startsWith(value);
  if (op === '$=') return actual.endsWith(value);
  return false;
}

function matchAll(elements, selector) {
  const parts = selector
    .split(',')
    .map((part) => part.trim())
    .filter(Boolean);
  return elements.filter((element) =>
    parts.some((part) => matchesSelector(element, part)),
  );
}

/** 返回脚本的受控环境：假 DOM + 可控时钟 + 可手动 flush 的定时器。 */
function makeBackSandbox({ elements = [], token = 'tok', now = 1000, perfNow = null } = {}) {
  const posted = [];
  const timers = [];
  const clock = { now };
  const performance = perfNow === null ? null : { now: () => perfNow };
  const document = {
    title: 'conversation',
    body: { firstElementChild: { className: 'app-root', tagName: 'DIV' } },
    querySelectorAll: (selector) => matchAll(elements, selector),
    querySelector: (selector) => matchAll(elements, selector)[0] || null,
  };
  const location = { href: 'https://zcode.z.ai/remote/v4?sid=canary' };
  const window = {
    __zrToken: token,
    innerHeight: 800,
    performance,
    getComputedStyle: (element) =>
      element.computedStyle || {
        display: 'block',
        visibility: 'visible',
        pointerEvents: 'auto',
      },
    flutter_inappwebview: {
      callHandler: (...args) => posted.push(args),
    },
  };
  const sandbox = {
    window,
    document,
    location,
    performance,
    Date: { now: () => clock.now },
    JSON,
    Math,
    Object,
    Array,
    String,
    Number,
    RegExp,
    Boolean,
    console,
    setTimeout: (fn, ms) => {
      timers.push({ fn, ms });
      return timers.length;
    },
    clearTimeout: () => {},
  };
  const context = vm.createContext(sandbox);
  return { context, window, document, location, posted, timers, clock, elements };
}

/** 逐个执行排队的定时器（推进时钟），直到脚本回执或没有定时器为止。 */
function flushTimers(box, { maxSteps = 400 } = {}) {
  let steps = 0;
  while (box.timers.length > 0 && steps < maxSteps) {
    const timer = box.timers.shift();
    box.clock.now += timer.ms || 0;
    timer.fn();
    steps += 1;
  }
}

function backPayload(posted, index = 0) {
  const args = posted[index];
  if (!args) throw new Error(`没有第 ${index} 条桥消息`);
  if (args[0] !== 'zrBack') {
    throw new Error(`handler 名应为 zrBack，实际 ${args[0]}`);
  }
  return { args, body: JSON.parse(args[1]) };
}

function boxDocumentTitle(box, value) {
  box.document.title = value;
}

function runBack(box) {
  vm.runInContext(back, box.context, { filename: 'in_page_back.js' });
  flushTimers(box);
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
const backFile = resolve(root, 'lib/services/in_page_back.dart');
const back = extractBackScript(readFileSync(backFile, 'utf8'));

/** 抽取 Dart 源里的 `static const [...] = [r]'''...'''` 注入脚本（原样文本）。 */
function extractDartScripts(source) {
  const out = [];
  const re = /static const(?: String)?\s+(\w+)\s*=\s*(r?)'''([\s\S]*?)'''/g;
  let match;
  while ((match = re.exec(source)) !== null) {
    let body = match[3];
    if (match[2] !== 'r') {
      // 非 raw 字符串：Dart 会处理转义，对齐到运行期文本。
      body = body.split('\\\\').join('\\').split('\\$').join('$');
    }
    out.push({ name: match[1], body });
  }
  return out;
}

// 0) 页面注入脚本（探针 / 过渡卡隐藏器）：语法错误会让探针静默失败
//    （盖板状态永不更新、过渡卡永不隐藏），比逻辑 bug 更难在真机上发现，
//    所以这里对所有 `static const` 脚本统一做语法闸门。
const remoteScripts = extractDartScripts(
  readFileSync(resolve(root, 'lib/ui/official_remote_page.dart'), 'utf8'),
);
await check('official_remote_page 注入脚本全部通过 JS 语法检查', () => {
  assert(
    remoteScripts.length >= 3,
    `至少应提取到 3 段注入脚本（实际 ${remoteScripts.length}）`,
  );
  for (const script of remoteScripts) {
    new vm.Script(script.body, { filename: `${script.name}.js` });
  }
});

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

// 3) F03 引导路径：document-start 预置的 window.__zrToken 必须直接生效
//    （真机回归：运行时注入有时打空，钩子改为一安装就读预置值）。
await check('F03 钩子在安装时读取 document-start 预置令牌', () => {
  const box = makeSandbox();
  vm.runInContext("window.__zrToken = 'preset-token'", box.context);
  vm.runInContext(hook, box.context, { filename: 'observer_hook.js' });
  const ws = new box.window.WebSocket('wss://zcode.z.ai/ws?mid=preset');
  ws.listeners.message({
    data: JSON.stringify({ type: 'data', payload: 'preset' }),
  });
  // preset+flush 由 __zrSetToken 触发；这里直接调一次（Dart 侧仍会调用它）。
  vm.runInContext("window.__zrSetToken && window.__zrSetToken('preset-token')", box.context);
  assert(box.posted.length === 1, `预置令牌应在补发时随消息带上（实际 ${box.posted.length}）`);
  assert(box.posted[0][2] === 'preset-token', '第 3 个参数应为预置令牌');
  assert(box.posted[0][1].includes('preset'), '补发的应是在途消息');
});

await check('F03 钩子安装时标记 __zrHookReady（诊断用）', () => {
  const box = makeSandbox();
  vm.runInContext(hook, box.context, { filename: 'observer_hook.js' });
  assert(box.window.__zrHookReady === true, '__zrHookReady 应为 true');
});

// 3b) F03：令牌未注入前不得裸发；注入后在途消息按序补发并携带令牌。
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

// ---------------------------------------------------------------------------
// 页内返回脚本（用户上报回归）：能自证"页面真的换了"，找不到就如实报告。
// ---------------------------------------------------------------------------

await check('返回脚本通过 JS 语法检查', () => {
  new vm.Script(back, { filename: 'in_page_back.js' });
});

await check('带 aria-label 的返回控件：点一次、页面变化后回执 clicked', () => {
  const box = makeBackSandbox({
    elements: [
      backEl({
        ariaLabel: '返回任务首页',
        onActivate: () => {
          box.document.title = 'task-list';
        },
      }),
    ],
  });
  runBack(box);
  assert(box.elements[0].clicks === 1, `应点击一次（实际 ${box.elements[0].clicks}）`);
  const { args, body } = backPayload(box.posted);
  assert(body.id === 5, `回执应带 attemptId（实际 ${body.id}）`);
  assert(body.ok === true, 'ok 应为 true');
  assert(body.reason === 'clicked', `reason 应为 clicked（实际 ${body.reason}）`);
  assert(args[2] === 'tok', '回执第 3 个参数必须是主 frame 令牌');
});

await check('纯图标返回键（无 aria-label）也能靠左上角几何启发式命中', () => {
  const content = backEl({
    tag: 'div',
    role: 'button',
    rect: { top: 120, left: 320, width: 240, height: 400 },
  });
  const box = makeBackSandbox({
    elements: [
      content,
      backEl({
        // 真实官方页面：返回键 (8,10,24,24)，纯图标无 aria-label。
        rect: { top: 10, left: 8, width: 24, height: 24 },
        onActivate: () => {
          box.document.title = 'task-list';
        },
      }),
    ],
  });
  runBack(box);
  assert(box.elements[1].clicks === 1, '左上角图标按钮应被点击');
  assert(content.clicks === 0, '内容区域不得被点击');
  assert(backPayload(box.posted).body.reason === 'clicked');
});

await check('「返回顶部」绝不被当成返回：不点击并报告 not_found', () => {
  const box = makeBackSandbox({
    elements: [
      backEl({
        ariaLabel: '返回顶部',
        rect: { top: 720, left: 360, width: 40, height: 40 },
        onActivate: () => {
          box.document.title = 'scrolled-top';
        },
      }),
    ],
  });
  runBack(box);
  assert(box.elements[0].clicks === 0, '返回顶部不得被点击');
  const { body } = backPayload(box.posted);
  assert(body.ok === false, 'ok 应为 false');
  assert(body.reason === 'not_found', `reason 应为 not_found（实际 ${body.reason}）`);
});

await check('折叠/菜单/侧边类控件绝不当返回键：不点击并报告 not_found', () => {
  // 真机 no_change 实锤：平板上误点到侧栏折叠/菜单图标，页面没变化，
  // 返回键看起来"闪一下又回设备页"。负向过滤后这些控件必须被跳过。
  const box = makeBackSandbox({
    elements: [
      backEl({
        ariaLabel: '收起侧边面板',
        rect: { top: 10, left: 8, width: 24, height: 24 },
        onActivate: () => {
          box.document.title = 'sidebar-collapsed';
        },
      }),
      backEl({
        ariaLabel: '打开菜单',
        rect: { top: 12, left: 40, width: 24, height: 24 },
        onActivate: () => {
          box.document.title = 'menu-opened';
        },
      }),
    ],
  });
  runBack(box);
  assert(box.elements[0].clicks === 0, '收起侧边面板不得被点击');
  assert(box.elements[1].clicks === 0, '打开菜单不得被点击');
  assert(backPayload(box.posted).body.reason === 'not_found');
});

await check('带 aria-expanded/aria-pressed 的开关类图标不算返回键', () => {
  const box = makeBackSandbox({
    elements: [
      backEl({
        ariaLabel: null,
        attrs: { 'aria-expanded': 'false' },
        rect: { top: 10, left: 8, width: 24, height: 24 },
        onActivate: () => {
          box.document.title = 'toggled';
        },
      }),
    ],
  });
  runBack(box);
  assert(box.elements[0].clicks === 0, 'aria-expanded 开关不得被点击');
  assert(backPayload(box.posted).body.reason === 'not_found');
});

await check('aria-label 含「设置」的图标键仍被负向词挡掉（负向过滤不许被放宽）', () => {
  // 修 settings-back-button 误杀时**不能**把负向词整体去掉：几何路径上的
  // 设置类图标键仍必须跳过，否则平板上又会误点侧栏图标。
  const box = makeBackSandbox({
    elements: [
      backEl({
        ariaLabel: '设置',
        rect: { top: 10, left: 8, width: 24, height: 24 },
        onActivate: () => {
          box.document.title = 'settings-opened';
        },
      }),
    ],
  });
  runBack(box);
  assert(box.elements[0].clicks === 0, '「设置」图标键不得被点击');
  assert(backPayload(box.posted).body.reason === 'not_found');
});

await check('「改数据」控件绝不被返回键点到：v4-feedback-like-4（含 back 子串）必须跳过', () => {
  // 真机复现（v1.0.0+22 验收）：官方页的消息行里有
  // `v4-feedback-like-4` / `v4-feedback-dislike-4`，testid 里含 feed**back**
  // 子串，被 `[data-testid*="back"]` 选中 → 平板上按返回键静默给用户消息点了赞
  // （aria-label 变"已赞"、对话还被 scrollIntoView 滚到那条消息）。
  const like = backEl({
    testid: 'v4-feedback-like-4',
    ariaLabel: '赞',
    rect: { top: 10, left: 8, width: 24, height: 24 },
    onActivate: () => {
      // 点赞不会改变 testid 签名：正是旧实现把它当成"点了但没变化"继续乱点的原因
    },
  });
  const dislike = backEl({
    testid: 'v4-feedback-dislike-4',
    ariaLabel: '踩',
    rect: { top: 40, left: 8, width: 24, height: 24 },
  });
  const box = makeBackSandbox({ elements: [like, dislike] });
  runBack(box);
  assert(like.clicks === 0, `点赞键不得被点击（实际 ${like.clicks}）`);
  assert(dislike.clicks === 0, `点踩键不得被点击（实际 ${dislike.clicks}）`);
  assert(backPayload(box.posted).body.reason === 'not_found');
});

await check('禁用的返回键（desktop-top-nav-back disabled）不点，且不误报 not_found 之外的结果', () => {
  const disabledNav = backEl({
    testid: 'desktop-top-nav-back',
    ariaLabel: '后退',
    disabled: true,
    rect: { top: 14, left: 0, width: 28, height: 28 },
  });
  const box = makeBackSandbox({ elements: [disabledNav] });
  runBack(box);
  assert(disabledNav.clicks === 0, '禁用控件不得被点击');
  assert(backPayload(box.posted).body.reason === 'not_found');
});

await check('testid 精确规则仍能命中 settings-back-button 与 desktop-top-nav-back 形态', () => {
  // settings-back-button → 显式选择器 + `[data-testid$="-back"]`
  // desktop-top-nav-back → `[data-testid$="-back"]`
  // 收紧子串通配后，这两种真实形态都必须仍进入候选并自证成功。
  for (const id of ['settings-back-button', 'desktop-top-nav-back']) {
    const store = { elements: [] };
    const btn = backEl({
      testid: id,
      ariaLabel: id === 'settings-back-button' ? '返回工作区' : '后退',
      rect: { top: 64, left: 12, width: 40, height: 40 },
      onActivate: () => {
        // 关闭当前层：testid 总数变化 → 签名变化 → 自证成功
        store.elements.length = 0;
      },
    });
    store.elements.push(btn);
    const box = makeBackSandbox({ elements: store.elements });
    runBack(box);
    const { body } = backPayload(box.posted);
    assert(btn.clicks === 1, `${id} 应被点击（实际 ${btn.clicks}）`);
    assert(body.ok === true, `${id} 点击后应自证成功（实际 ${body.ok}/${body.reason}）`);
  }
});

await check('web 设置页返回：官方返回键（testid 含 settings）必须被点掉并自证', () => {
  // 真机命中测试实锤的两个坑，缺一不可：
  //   1. 官方返回键 = button[aria-label="返回工作区"][data-testid="settings-back-button"]。
  //      旧 labelOf 把 data-testid 也拼进"标签"，testid 里的 "settings"
  //      命中 isNotBack → 唯一候选被滤掉 → not_found → Dart 兜底露出设备页
  //      （用户看到的"设置返回闪回设备列表页"）。
  //   2. 设置层是追加在文档末尾的覆盖层，真机 testid 总数 104；旧签名只取
  //      前 40 个 testid，设置层整个在窗口外 → 点击后签名不变 → 误报
  //      no_change。现在签名带计数 + 首尾，关闭设置层必然改变签名。
  const store = { elements: [] };
  for (let i = 0; i < 45; i++) {
    store.elements.push(
      backEl({ tag: 'div', testid: `task-item-sess_${i}`, text: `任务 ${i}`, icon: null }),
    );
  }
  const settingsPage = backEl({
    tag: 'div',
    testid: 'settings-page',
    text: '常规 界面语言 选择应用 UI 的显示语言。',
    rect: { top: 0, left: 0, width: 800, height: 1256 },
    icon: null,
  });
  const backBtn = backEl({
    ariaLabel: '返回工作区',
    testid: 'settings-back-button',
    text: '返回工作区',
    rect: { top: 64, left: 12, width: 40, height: 40 },
    onActivate: () => {
      const keep = store.elements.filter((el) => el !== settingsPage && el !== backBtn);
      store.elements.length = 0;
      store.elements.push(...keep);
    },
  });
  store.elements.push(settingsPage, backBtn);
  const box = makeBackSandbox({ elements: store.elements });
  runBack(box);
  flushTimers(box);
  assert(backBtn.clicks === 1, `官方返回键应被点一次（实际 ${backBtn.clicks}）`);
  assert(
    store.elements.indexOf(settingsPage) < 0,
    '设置层应已关闭（签名随之变化）',
  );
  const { body } = backPayload(box.posted);
  assert(body.ok === true, `ok 应为 true（实际 ${body.ok}/${body.reason}）`);
  assert(body.reason === 'clicked', `reason 应为 clicked（实际 ${body.reason}）`);
});

await check('点到控件但页面没变：报告 no_change（不谎报成功）', () => {
  const box = makeBackSandbox({
    elements: [backEl({ ariaLabel: '返回' })],
  });
  runBack(box);
  assert(box.elements[0].clicks === 1, '候选会被点一次');
  const { body } = backPayload(box.posted);
  assert(body.ok === false, 'ok 应为 false');
  assert(body.reason === 'no_change', `reason 应为 no_change（实际 ${body.reason}）`);
});

await check('第一个候选无效时继续试下一个候选', () => {
  const box = makeBackSandbox({
    elements: [
      backEl({ ariaLabel: '返回任务首页' }), // 点了没反应
      backEl({
        ariaLabel: '返回',
        onActivate: () => {
          box.document.title = 'task-list';
        },
      }),
    ],
  });
  runBack(box);
  assert(box.elements[0].clicks === 1, '先试第一个候选');
  assert(box.elements[1].clicks === 1, '第一个无效后必须继续试下一个');
  assert(backPayload(box.posted).body.reason === 'clicked');
});

await check('几何兜底只认左上角图标键：列表页的宽控件不得被点（真机实测回归）', () => {
  // 复现真机现象：列表页左上角没有返回键，但页面里存在"工作区选择/新建"这类
  // 靠上偏左的控件。旧规则（左上 96px 内、宽 96px）会把它们点掉，表现为
  // "越返回越往里走"。收紧到左上 56×40 的图标方块后必须一个都不点。
  const workspacePicker = backEl({
    ariaLabel: '切换工作区',
    rect: { top: 40, left: 16, width: 120, height: 32 },
    text: '杂事',
    onActivate: () => {
      boxDocumentTitle(box, 'switched');
    },
  });
  const newTask = backEl({
    rect: { top: 54, left: 68, width: 28, height: 28 },
    onActivate: () => {},
  });
  const box = makeBackSandbox({ elements: [workspacePicker, newTask] });
  runBack(box);
  assert(workspacePicker.clicks === 0, '宽控件不得被当成返回键');
  assert(newTask.clicks === 0, '偏右/偏下的图标键不得被当成返回键');
  const { body } = backPayload(box.posted);
  assert(body.ok === false, 'ok 应为 false');
  assert(body.reason === 'not_found', `reason 应为 not_found（实际 ${body.reason}）`);
});

await check('几何兜底仍然命中左上角纯图标返回键（8,10,24,24）', () => {
  const box = makeBackSandbox({
    elements: [
      backEl({
        rect: { top: 10, left: 8, width: 24, height: 24 },
        onActivate: () => {
          box.document.title = 'task-list';
        },
      }),
    ],
  });
  runBack(box);
  assert(box.elements[0].clicks === 1, '左上角图标键必须命中');
  assert(backPayload(box.posted).body.reason === 'clicked');
});

await check('候选迟到（刚切到对话页）时先重试再判 not_found', () => {
  // 长跑实测偶发：点开对话后立刻按返回，返回键还没挂上 → 直接 not_found 会让
  // 返回键闪回设备页。脚本必须有一个短重试窗口（1.2s）。
  const box = makeBackSandbox({ elements: [] });
  box.window.__late = () => {
    box.elements.push(
      backEl({
        ariaLabel: '返回任务首页',
        rect: { top: 10, left: 8, width: 24, height: 24 },
        onActivate: () => {
          box.document.title = 'task-list';
        },
      }),
    );
  };
  vm.runInContext(back, box.context, { filename: 'in_page_back.js' });
  // 第一次收集为空 → 只应排队重试，不应回执
  flushTimers(box, { maxSteps: 2 });
  assert(box.posted.length === 0, '候选为空时不得立刻回执 not_found');
  vm.runInContext('window.__late()', box.context);
  flushTimers(box);
  const { body } = backPayload(box.posted);
  assert(body.reason === 'clicked', `迟到候选应被点到（实际 ${body.reason}）`);
});

await check('候选始终不存在时，重试窗口用尽后如实报 not_found', () => {
  const box = makeBackSandbox({ elements: [] });
  runBack(box);
  const { body } = backPayload(box.posted);
  assert(body.ok === false, 'ok 应为 false');
  assert(body.reason === 'not_found', `reason 应为 not_found（实际 ${body.reason}）`);
});

await check('页面刚加载（<6s）无候选 → 仍走 1.2s 重试窗口（护住秒开秒返竞态）', () => {
  const box = makeBackSandbox({ elements: [], perfNow: 3000 });
  vm.runInContext(back, box.context, { filename: 'in_page_back.js' });
  assert(box.posted.length === 0, '窗口期内不得立刻回执');
  assert(box.timers.length > 0, '窗口期内应安排重试定时器');
  flushTimers(box);
  assert(backPayload(box.posted).body.reason === 'not_found');
});

await check('页面已稳定（加载超 6s）无候选 → 立即 not_found，不再白等 1.2s', () => {
  // 真机诊断包（v1.1.3 连续 WV109/not_found）：列表页永远没有返回控件，
  // 稳定态下每次返回都白等重试窗口，用户感知"返回键卡一秒"。
  // 窗口只允许发生在页面刚加载的几秒内。
  const box = makeBackSandbox({ elements: [], perfNow: 7000 });
  runBack(box);
  const { body } = backPayload(box.posted);
  assert(body.ok === false, 'ok 应为 false');
  assert(body.reason === 'not_found', `reason 应为 not_found（实际 ${body.reason}）`);
  assert(box.timers.length === 0, '稳定态不得安排任何重试定时器');
});

await check('disabled 与 pointer-events:none 的控件不点', () => {
  const disabled = backEl({ ariaLabel: '返回', disabled: true });
  const noPointer = backEl({
    ariaLabel: '返回',
    computedStyle: { display: 'block', visibility: 'visible', pointerEvents: 'none' },
  });
  const box = makeBackSandbox({ elements: [disabled, noPointer] });
  runBack(box);
  assert(disabled.clicks === 0, 'disabled 不得点击');
  assert(noPointer.clicks === 0, 'pointer-events:none 不得点击');
  assert(backPayload(box.posted).body.reason === 'not_found');
});

await check('令牌未就绪不裸发，令牌到位后补发同一条结果', () => {
  const box = makeBackSandbox({
    token: null,
    elements: [
      backEl({
        ariaLabel: '返回任务首页',
        onActivate: () => {
          box.document.title = 'task-list';
        },
      }),
    ],
  });
  runBack(box);
  // 上面 runBack 会跑光重试定时器；这条用例要验证"令牌迟到"，所以重跑一次并
  // 只推进到回执尝试之前。
  box.posted.length = 0;
  box.timers.length = 0;
  box.elements[0].clicks = 0;
  box.window.__zrToken = null;
  box.document.title = 'conversation'; // 复位签名，让点击再次产生可观测变化
  vm.runInContext(back, box.context, { filename: 'in_page_back.js' });
  flushTimers(box, { maxSteps: 6 });
  assert(box.posted.length === 0, `没有令牌时不得发回执（实际 ${box.posted.length}）`);
  box.window.__zrToken = 'tok-late';
  flushTimers(box);
  assert(box.posted.length === 1, '令牌到位后应补发回执');
  const { args, body } = backPayload(box.posted);
  assert(body.reason === 'clicked', '补发的应是同一条结果');
  assert(args[2] === 'tok-late', '补发也必须带令牌');
});

const failed = results.filter((r) => !r.ok);
console.log(
  `injected-js checks: ${results.length - failed.length}/${results.length} passed`,
);
process.exit(failed.length === 0 ? 0 : 1);
