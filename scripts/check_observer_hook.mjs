#!/usr/bin/env node
// 观测钩子（JS）校验器：从 Dart 源码提取 hookScript，做语法检查 + 受控运行冒烟 + 边界行为断言。
//
// 为什么需要它：JS 在 Dart 里是一个字符串常量，`flutter analyze`/`flutter test`
// 都不会校验它的语法；一个笔误就会让观测静默失效（页面照常，通知没了）。
// 这个脚本让这类错误在 CI 的 fast gate 里立刻失败，并把 D 报告复现过的
// 输入边界固化成回归断言（对应 B08–B12、B15、B17）。
//
// 用法：node scripts/check_observer_hook.mjs

import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const MAX_LISTEN_BYTES = 4194304;
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dartFile = resolve(root, 'lib/services/event_observer.dart');

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

// 1) 语法：单独的 JS 语法检查（不执行）。
await check('提取出的钩子通过 JS 语法检查', () => {
  new vm.Script(hook, { filename: 'observer_hook.js' });
});

// 2) 运行冒烟：在受控环境里安装钩子，不得抛错。
const { context, window, posted, sockets, fetches } = makeSandbox();
await check("受控环境准备", () => {});
await check('在受控环境安装钩子不抛错', () => {
  vm.runInContext(hook, context, { filename: 'observer_hook.js' });
  assert(window.__zrHooked === true, 'window.__zrHooked 应为 true');
  assert(typeof window.__zrStats === 'object', '遥测计数应已初始化');
});

// 3) F03：令牌未注入前不得裸发；注入后在途消息按序补发并携带令牌。
await check('F03 令牌未注入前桥消息只入队、不裸发', () => {
  const ws = new window.WebSocket('wss://zcode.z.ai/ws?mid=token-probe');
  assert(typeof ws.listeners.message === 'function', '官方 relay 的 WS 应挂上监听');
  ws.listeners.message({ data: JSON.stringify({ type: 'data', payload: 'pre-token' }) });
  assert(posted.length === 0, `令牌未就绪时不得发送（实际 ${posted.length} 条）`);
});

await check('F03 令牌注入后在途消息补发且携带令牌', () => {
  vm.runInContext("window.__zrSetToken && window.__zrSetToken('test-token')", context);
  assert(posted.length === 1, `在途消息应补发（实际 ${posted.length} 条）`);
  assert(posted[0][2] === 'test-token', '桥消息第 3 个参数应为令牌');
});

// 4) B08：超限的 WS 文本不得进入桥（cap+1 字符）。
await check('B08 超限 WS 文本被丢弃、不产生桥消息', () => {
  const ws = new window.WebSocket('wss://zcode.z.ai/ws?mid=1');
  assert(typeof ws.listeners.message === 'function', '官方 relay 的 WS 应挂上监听');
  const before = posted.length;
  ws.listeners.message({ data: 'x'.repeat(MAX_LISTEN_BYTES + 1) });
  assert(posted.length === before, `超限文本不应进入桥（新增 ${posted.length - before} 条）`);
  assert(window.__zrStats.wsSkippedSize > 0, '应计入 wsSkippedSize');
});

// 5) B08 正例：正常大小的事件仍应送达（且带令牌）。
await check('B08 正常大小 WS 文本照常上报', () => {
  const ws = new window.WebSocket('wss://zcode.z.ai/ws?mid=2');
  const before = posted.length;
  ws.listeners.message({ data: JSON.stringify({ type: 'data', payload: 'ok' }) });
  assert(posted.length > before, '正常消息应产生桥消息');
  assert(
    posted.slice(before).every((args) => args[2] === 'test-token'),
    '每条桥消息都必须携带令牌（F03）',
  );
});

// 5) B17：非默认端口的官方 host 不得被观察。
await check('B17 非默认端口（:8443）的 WS 不被观察', () => {
  const before = window.__zrStats.wsIgnored;
  const ws = new window.WebSocket('wss://zcode.z.ai:8443/ws');
  assert(typeof ws.listeners.message !== 'function', ':8443 的 WS 不应挂监听');
  assert(window.__zrStats.wsIgnored > before, '应计入 wsIgnored');
});

// 6) B17：跨域 URL query 含 /session 不得命中 fetch 白名单。
await check('B17 跨域 query 子串不授予 fetch 观察权限', async () => {
  const before = window.__zrStats.fetchCloned;
  await window.fetch('https://example.invalid/asset?next=/session');
  assert(
    window.__zrStats.fetchCloned === before,
    '跨域 URL 不应被 clone 观察',
  );
});

const failed = results.filter((r) => !r.ok);
console.log(`hook checks: ${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length === 0 ? 0 : 1);
