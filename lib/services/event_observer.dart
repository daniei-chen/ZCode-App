import 'dart:convert';

import 'structured_log.dart';

const int kMaxListenBytes = 4194304;

/// zrSeen（预热请求录制）单批次的 **UTF-8 字节**上限（iter16）。
///
/// 钩子按这个预算在页面侧分批：批次 JSON 在 `recordSeen` 内按 UTF-8 字节
/// 累计，超预算先把当前批 `post` 出去再入队新条目——任何一次 `zrSeen`
/// 消息都远低于桥侧 `BridgeSchema.maxSeenBytes` 与 warmup 的接收上限，
/// 不会再出现"整批在桥侧被丢"（旧实现单批可到 ~1 MiB）。
/// 桥侧上限与 `WarmupMemoryNotifier.ingestSeen` 都以它为同口径基准。
const int kMaxSeenBatchBytes = 192 * 1024;

abstract final class EventObserver {
  static const String hookScript =
      '''
(function() {
  if (window.__zrHooked) return;
  window.__zrHooked = true;
  // 诊断用：区分"钩子没执行"与"钩子执行了但令牌没给"（PR bridge-token）。
  window.__zrHookReady = true;
  var q = [];
  var qBytes = 0;
  var qMaxEntries = 2048;
  // 主 frame 令牌（F03）：优先用 document-start UserScript 预置的
  // `window.__zrToken`（它在钩子之前注入，彻底避开"load stop 时才注入"的竞态）；
  // 运行时的 `__zrSetToken` 仍可作为补充路径。
  var zrToken = null;
  var tokenOf = function() {
    if (typeof zrToken === 'string' && zrToken) return zrToken;
    var preset = window.__zrToken;
    return (typeof preset === 'string' && preset) ? preset : null;
  };
  var presetToken = tokenOf();
  if (presetToken) zrToken = presetToken;
  // 分片预算（F04/B11）：单片 base64 上限 + 每个逻辑帧在途总字节上限
  // （收齐后的最终帧上限仍由 $kMaxListenBytes 判定）。
  var kMaxFragmentBytes = 16 * 1024 * 1024;
  var kMaxFragmentB64Chars = Math.ceil(kMaxFragmentBytes * 4 / 3) + 64;
  // R-13：队列预算按 **UTF-8 字节**；assembler 另加全局在途总额与槽位上限，
  // 防止多个未完成帧各自"合法"却把内存叠加到预想之外。
  var kMaxQueueBytes = $kMaxListenBytes;
  var kMaxAssemblerBytes = 16 * 1024 * 1024;
  var asmLimit = 32;
  // R-13：真实 UTF-8 字节数。ASCII 快路径（逐字符扫描，不分配）；含多字节
  // 时用 TextEncoder；TextEncoder 缺失按 3 字节/字符保守上界（宁可少观察）。
  var utf8Len = function(s) {
    var ascii = true;
    for (var ui = 0; ui < s.length; ui++) {
      if (s.charCodeAt(ui) > 127) { ascii = false; break; }
    }
    if (ascii) return s.length;
    try { return new TextEncoder().encode(s).length; }
    catch (e) { return s.length * 3; }
  };
  var post = function(name, body) {
    try {
      if (typeof body !== 'string') return;
      // 单条消息预算（F04/R-13）：按 **UTF-8 字节**判定，字符数不是字节数。
      // 超限一律丢弃，绝不把超预算正文送进桥（也不留在队列里）。
      var bodyBytes = utf8Len(body);
      if (bodyBytes > $kMaxListenBytes) {
        if (window.__zrStats) window.__zrStats.wsSkippedSize++;
        return;
      }
      var h = window.flutter_inappwebview;
      // 主 frame 令牌（F03）：拿到令牌之前一律入队等待，绝不裸发。
      // 令牌由 Dart 用 evaluateJavascript 注入（只在主 frame 执行），
      // 跨域子 frame 读不到主 frame 的变量，因此无法伪造桥消息。
      var token = tokenOf();
      if (token && h && h.callHandler) {
        h.callHandler(name, body, token);
        return;
      }
      if (q.length >= qMaxEntries) {
        qBytes -= q.shift().w; // 条目自记字节数（w），避免重算
        if (window.__zrStats) window.__zrStats.queueDropped++;
      }
      q.push({ n: name, b: body, w: bodyBytes });
      qBytes += bodyBytes;
      // 队列按**真实字节**收敛；q.length > 0 保证单条超限项不会被永久保留
      // （F04/B10；R-13：旧的 UTF-16 计数在中文/emoji 下会低估约 3 倍）。
      while (qBytes > kMaxQueueBytes && q.length > 0) {
        qBytes -= q.shift().w;
        if (window.__zrStats) window.__zrStats.queueDropped++;
      }
    } catch (e) {}
  };
  var flush = function() {
    var h = window.flutter_inappwebview;
    if (!h || !h.callHandler) return false;
    // 令牌未就绪时不放行队列（fail-closed）：宁可稍后补发，也不裸发。
    var token = tokenOf();
    if (!token) return false;
    while (q.length > 0) {
      var m = q.shift();
      qBytes -= m.w;
      try { h.callHandler(m.n, m.b, token); } catch (e) {}
    }
    return true;
  };
  // Dart 在主 frame 注入令牌后才放行（在途消息按序补发）。
  window.__zrSetToken = function(t) {
    if (typeof t !== 'string' || !t) return;
    zrToken = t;
    window.__zrToken = t;
    flush();
  };
  window.addEventListener('flutterInAppWebViewPlatformReady', function() { flush(); }, false);
  var flushTries = 0;
  var flushTimer = setInterval(function() {
    // 通道长期缺席（页面环境异常）时最多空转约 30s 后放弃；通道晚就绪
    // 另有 flutterInAppWebViewPlatformReady 事件兜底。
    if (flush() || ++flushTries > 250) clearInterval(flushTimer);
  }, 120);
  var send = function(body) { post('zrEvents', body); };
  // 观测遥测（W2）：只累计数字，绝不记录 query/cookie/正文。供诊断页
  // 核对白名单命中率；通道就绪时每 15 秒上报一次非空增量。
  var stats = window.__zrStats = window.__zrStats || {
    fetch200: 0, fetchCloned: 0, fetchSkipped: 0,
    sseMessages: 0, sseIgnored: 0, wsMessages: 0, wsIgnored: 0,
    wsSkippedSize: 0, fetchSkippedSize: 0,
    framesDecoded: 0, invalidFragments: 0, expiredFragments: 0,
    queueDropped: 0, seenDropped: 0
  };
  var statsDirty = false;
  var bump = function(k) {
    if (stats[k] == null) stats[k] = 0;
    stats[k]++;
    statsDirty = true;
  };
  var statsFlush = setInterval(function() {
    if (!statsDirty || !window.flutter_inappwebview) return;
    statsDirty = false;
    try { post('zrStats', JSON.stringify(stats)); } catch (e) {}
  }, 15000);
  var seenQ = [];
  var seenBytes = 0;
  // zrSeen 批次预算（iter16）：与 Dart 侧 kMaxSeenBatchBytes 同口径——
  // 批次 JSON 的 UTF-8 字节必须小于预算，否则整批会在桥侧（256 KiB）
  // 被丢弃且只计一次 droppedMessages。旧实现只限 64 条 × 16 KiB，
  // 单批可达 ~1 MiB，是"整批静默丢失"的来源。
  var kSeenBatchBytes = $kMaxSeenBatchBytes;
  var seenFlush = setInterval(function() {
    if (seenQ.length === 0 || !window.flutter_inappwebview) return;
    var batch = seenQ.splice(0, seenQ.length);
    seenBytes = 0;
    post('zrSeen', JSON.stringify(batch));
  }, 900);
  var seenDropOldest = function() {
    while (seenQ.length > 0) {
      var entry = seenQ.shift();
      seenBytes -= utf8Len(JSON.stringify(entry));
      if (window.__zrStats) window.__zrStats.seenDropped++;
    }
  };
  var recordSeen = function(url, method, body) {
    try {
      if (seenQ.length >= 64) {
        if (window.__zrStats) window.__zrStats.seenDropped++;
        return;
      }
      if (typeof url !== 'string' || url.length > 2048) return;
      var b = null;
      if (typeof body === 'string') b = body;
      else if (body && typeof body === 'object') {
        try { b = JSON.stringify(body); } catch (e2) { b = null; }
      }
      if (b && b.length > 16384) return;
      var entry = { u: url, m: String(method || 'GET').toUpperCase(), b: b };
      var entryBytes = utf8Len(JSON.stringify(entry)) + 2;
      // 单条就放不进任何批次（病态转义）：只丢这一条并计数。
      if (entryBytes > kSeenBatchBytes) {
        if (window.__zrStats) window.__zrStats.seenDropped++;
        return;
      }
      if (seenBytes + entryBytes > kSeenBatchBytes) {
        if (window.flutter_inappwebview) {
          // 先把当前批送出去（post 自身也会按预算收敛），再开新批。
          var batch = seenQ.splice(0, seenQ.length);
          seenBytes = 0;
          post('zrSeen', JSON.stringify(batch));
        } else {
          // 通道未就绪：腾空间只能丢最旧，绝不越过桥侧上限。
          seenDropOldest();
        }
      }
      seenQ.push(entry);
      seenBytes += entryBytes;
    } catch (e) {}
  };
  // 无原型对象（安全审计 S-3）：普通 `{}` 上 `asm["__proto__"]` 命中原型链，
  // 敌对 logicalFrameId 可污染 Object.prototype 破坏官方页脚本。
  var asm = Object.create(null);
  var asmOrder = [];
  // R-13：所有未完成 assembler 的在途字节总和（全局预算，见 tryDecodePayload）。
  var asmBytes = 0;
  // 过期 assembler 清理（W2）：60 秒内没有新分片的逻辑帧视为坏帧，周期
  // 清扫，防止异常页面让 assembler 无限滞留。
  var asmSweep = setInterval(function() {
    var now = Date.now();
    for (var k2 = asmOrder.length - 1; k2 >= 0; k2--) {
      var key = asmOrder[k2];
      if (asm[key] && now - asm[key].t > 60000) {
        asmBytes -= asm[key].bytes;
        delete asm[key];
        asmOrder.splice(k2, 1);
        bump('expiredFragments');
      }
    }
  }, 5000);
  var b64Bytes = function(b64) {
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var k = 0; k < bin.length; k++) bytes[k] = bin.charCodeAt(k);
    return bytes;
  };
  var tryDecodePayload = function(p) {
    try {
      if (!p || typeof p.dataBase64 !== 'string' || p.dataBase64.length === 0) return;
      // R-13：base64 判长用**编码后字符数**（解码前），且不信任 messageBytes
      // （可伪造为 1 绕过）。分片单片允许到单帧预算（收齐后还要过 4 MiB 门），
      // 非分片消息最终上限就是 4 MiB——编码长度超了必然超限，直接丢弃。
      var isFragment = p.kind === 'fragment' && p.fragmentCount > 1;
      var b64Len = p.dataBase64.length;
      var estBytes = Math.ceil(b64Len * 0.75);
      if (estBytes > (isFragment ? kMaxFragmentBytes : $kMaxListenBytes)) return;
      var bytes;
      if (isFragment) {
        var id = p.logicalFrameId;
        // id 必须是受限字符串（安全审计 S-3）：__proto__/constructor 等键落在
        // Object.prototype 链上会污染原型或读到继承属性；正则把键空间钉死。
        // 注意本脚本整体处于 Dart 插值字符串内，JS 正则的美元符须转义书写。
        if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{1,128}\$/.test(id)) {
          bump('invalidFragments');
          return;
        }
        var fc = p.fragmentCount;
        var fi = p.fragmentIndex;
        // 分片边界检查（W2/R-13）：count/index 必须是**有限整数**且范围内
        // （旧实现只查 typeof number，0.5 会被当作对象键保留）。
        if (typeof fc !== 'number' || fc !== Math.floor(fc) || fc < 1 || fc > 64 ||
            typeof fi !== 'number' || fi !== Math.floor(fi) || fi < 0 || fi >= fc) {
          bump('invalidFragments');
          return;
        }
        // 单片 base64 长度上限：解码之前就挡住"单片即超限"的输入（F04/B11）。
        if (b64Len > kMaxFragmentB64Chars) {
          bump('invalidFragments');
          return;
        }
        var slot = asm[id];
        if (!slot) {
          // 槽位上限；淘汰最老（R-13：另有全局在途总额兜底）。
          while (asmOrder.length >= asmLimit) {
            var evict = asmOrder.shift();
            asmBytes -= asm[evict] ? asm[evict].bytes : 0;
            delete asm[evict];
            bump('invalidFragments');
          }
          slot = asm[id] = { parts: {}, got: 0, bytes: 0, total: fc, t: Date.now() };
          asmOrder.push(id);
        }
        slot.t = Date.now();
        var part = b64Bytes(p.dataBase64);
        // 解码后真实字节复查（base64 声明长度≠解码长度）：单片不得超过
        // 单帧预算；单帧与全局的累计由下面的两道门负责。
        if (part.length > kMaxFragmentBytes) {
          asmBytes -= slot.bytes;
          delete asm[id];
          var oi = asmOrder.indexOf(id);
          if (oi >= 0) asmOrder.splice(oi, 1);
          bump('invalidFragments');
          return;
        }
        if (fi in slot.parts) {
          // 重复片：按差量更新——slot.bytes 与全局 asmBytes 都要先扣旧值
          // （b5 评审 H-1：旧实现只减了 slot.bytes，asmBytes 多记的旧值
          //  没有任何回收点，反复重发同一片可把全局预算永久耗尽）。
          var oldLen = slot.parts[fi].length;
          slot.bytes -= oldLen;
          asmBytes -= oldLen;
        } else {
          slot.got++;
        }
        slot.bytes += part.length;
        asmBytes += part.length;
        // 单帧在途总额 + 全 assembler 全局总额（R-13/B12）：任一超限立即
        // 释放该帧并重新核对全局。
        if (slot.bytes > kMaxFragmentBytes || asmBytes > kMaxAssemblerBytes) {
          asmBytes -= slot.bytes;
          delete asm[id];
          var dropIdx = asmOrder.indexOf(id);
          if (dropIdx >= 0) asmOrder.splice(dropIdx, 1);
          bump('invalidFragments');
          return;
        }
        slot.parts[fi] = part;
        if (slot.got < slot.total) return;
        asmBytes -= slot.bytes;
        delete asm[id];
        var idx = asmOrder.indexOf(id);
        if (idx >= 0) asmOrder.splice(idx, 1);
        var size = slot.bytes;
        if (size > $kMaxListenBytes) return;
        bytes = new Uint8Array(size);
        var off = 0;
        for (var q2 = 0; q2 < slot.total; q2++) {
          var part = slot.parts[q2];
          if (!part) return;
          bytes.set(part, off);
          off += part.length;
        }
      } else {
        bytes = b64Bytes(p.dataBase64);
      }
      var text = new TextDecoder('utf-8', {fatal: false}).decode(bytes);
      if (text && text.length > 0) {
        var first = text.indexOf('{');
        var last = text.lastIndexOf('}');
        if (first > 0 && last > first) {
          text = text.slice(first, last + 1);
        }
        if (text && text.length > 0) {
          bump('framesDecoded');
          send(text);
        }
      }
    } catch (e) {}
  };
  // A relay message has appeared in three equivalent shapes across desktop
  // versions: the rpc frame can be the root object, `payload`, or `frame`.
  // Walk those envelopes so session-index responses are observed even when
  // the official page is currently displaying a different conversation.
  var decodeEnvelope = function(node, depth) {
    if (!node || typeof node !== 'object' || depth > 6) return;
    if (typeof node.dataBase64 === 'string') tryDecodePayload(node);
    var keys = ['payload', 'frame', 'data', 'body', 'message'];
    for (var i = 0; i < keys.length; i++) {
      var child = node[keys[i]];
      if (child && typeof child === 'object') decodeEnvelope(child, depth + 1);
    }
  };
  var sendWithDecode = function(body) {
    // R-13（复审 B08）：预算判定必须在 **JSON.parse 之前**。旧实现先 parse
    // 再判定（post 里才挡），超限正文仍会进入解析路径，制造大对象/GC 抖动。
    // 这里先按真实 UTF-8 字节判定：超限直接丢弃（post 计数一次），不解析。
    if (typeof body !== 'string') return;
    if (utf8Len(body) > $kMaxListenBytes) {
      if (window.__zrStats) window.__zrStats.wsSkippedSize++;
      return;
    }
    send(body);
    try {
      var env = JSON.parse(body);
      decodeEnvelope(env, 0);
    } catch (e) {}
  };
  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function() {
      try {
        var u = arguments[0], init = arguments[1];
        var url = typeof u === 'string' ? u : ((u && u.url) || '');
        var method = (init && init.method) || '';
        if (url && method && String(method).toUpperCase() !== 'OPTIONS') {
          recordSeen(url, method, init && init.body);
        }
        if (url.indexOf('/mobile-view-state') >= 0 &&
            String(method).toUpperCase() === 'POST') {
          var b = init && init.body;
          if (typeof b === 'string' && b.length > 0) {
            post('zrViewState', b);
          }
        }
      } catch (e) {}
      var p = origFetch.apply(this, arguments);
      return p.then(function(res) {
        try {
          if (res.status !== 200) return res;
          bump('fetch200');
          var ct = (res.headers && res.headers.get)
              ? (res.headers.get('content-type') || '')
              : '';
          if (/^(image|audio|video|font)\\//.test(ct)) return res;
          var cl = (res.headers && res.headers.get)
              ? res.headers.get('content-length')
              : null;
          if (cl && +cl > $kMaxListenBytes) return res;
          // W2 fetch 白名单：只 clone 可能携带 relay 事件/会话索引的响应；
          // 其余（静态资源、无关 REST）完全不 clone，降低内存/CPU/隐私面。
          // 未命中的路径由 zrStats.fetchSkipped 计数，诊断页可核对是否有
          // 误伤；WS/SSE 是事件主通道，不受此表影响。
          var cloneAllow = [
            '/mobile-view-state', '/session', '/task', '/workspace',
            '/conversation', '/broadcast', '/event'
          ];
          // F15/B17：先解析 URL 并确认官方 origin/端口，再在 pathname 上匹配
          // 路径段——query 里的 "/session" 不再授予观察权限。
          var officialPath = null;
          try {
            var fu = new URL(url, location.href);
            if (fu.protocol === 'https:' &&
                fu.hostname.toLowerCase() === 'zcode.z.ai' &&
                (fu.port === '' || fu.port === '443')) {
              officialPath = fu.pathname;
            }
          } catch (e2) {}
          var urlOk = false;
          if (officialPath) {
            for (var ai = 0; ai < cloneAllow.length; ai++) {
              if (officialPath.indexOf(cloneAllow[ai]) >= 0) { urlOk = true; break; }
            }
          }
          if (!urlOk) {
            bump('fetchSkipped');
            return res;
          }
          bump('fetchCloned');
          // 有界读取（F04/B15）：优先流式读取，超限立即取消副本读取；
          // 环境不支持流时退回 text()（读毕立刻判长）。
          var clone = res.clone();
          var reader = (clone.body && clone.body.getReader) ? clone.body.getReader() : null;
          if (!reader) {
            clone.text().then(function(t) {
              if (t && t.length > 0 && t.length < $kMaxListenBytes) sendWithDecode(t);
            }).catch(function() {});
          } else {
            var chunks = [];
            var total = 0;
            var stopped = false;
            var pump = function() {
              reader.read().then(function(r) {
                if (stopped) return;
                if (r.done) {
                  if (total > 0) {
                    try {
                      var buf = new Uint8Array(total);
                      var off = 0;
                      for (var ci = 0; ci < chunks.length; ci++) {
                        buf.set(chunks[ci], off);
                        off += chunks[ci].length;
                      }
                      var ftext = new TextDecoder('utf-8', {fatal: false}).decode(buf);
                      if (ftext.length > 0) sendWithDecode(ftext);
                    } catch (e3) {}
                  }
                  return;
                }
                total += r.value.length;
                if (total > $kMaxListenBytes) {
                  stopped = true;
                  bump('fetchSkippedSize');
                  try { reader.cancel(); } catch (e4) {}
                  return;
                }
                chunks.push(r.value);
                pump();
              }).catch(function() {});
            };
            pump();
          }
        } catch (e) {}
        return res;
      });
    };
  }
  // W2 WS 白名单（依据实测协议记录：relay 端点为 wss://zcode.z.ai/ws?mid=…）：
  // 只有官方 relay 的 WS 会被观察；其他 WebSocket（第三方/诊断）完全透明
  // ——不挂监听、不读正文、不上报，只计入 wsIgnored。
  // 重要：过滤只影响"观测"，绝不改变页面自身的连接与功能。
  var wsAllowed = function(urlStr) {
    try {
      var u = new URL(urlStr, location.href);
      if (u.protocol !== 'wss:' || u.hostname.toLowerCase() !== 'zcode.z.ai') {
        return false;
      }
      // 端口必须与 Dart 侧信任规则一致（F15/B17）：默认端口或 443。
      if (u.port !== '' && u.port !== '443') return false;
      return u.pathname === '/ws' || u.pathname.indexOf('/ws/') === 0;
    } catch (e) { return false; }
  };
  //
  // SSE（P2-02 / b4 复审；b5 评审 M-1 修正论据）：协议实测记录
  // （`docs/RELAY-PROTOCOL-VERIFIED.md`）捕获到的全部事件通道是 WS/REST；
  // EventSource/SSE 从未在任何实测中出现，也不属于本应用的事件通道
  // （该文档"被推翻的推断"一节讲的是早期静态推断，不是本条的论据）。
  // 旧实现按"官方 host 即观察"给任何官方路径的 SSE 挂 message 监听，
  // 属无收益的观察面（CPU/内存/隐私）。现在**完全不观察 SSE**：不挂监听、
  // 不读正文、只计 sseIgnored（计数保留，一旦官方出现 SSE 通道可在诊断页
  // 第一时间发现）；页面自身的 SSE 行为不受影响（过滤只影响观测）。
  var OrigES = window.EventSource;
  if (OrigES) {
    var Wrapped = function(url, cfg) {
      var es = new OrigES(url, cfg);
      try {
        bump('sseIgnored');
      } catch (e) {}
      return es;
    };
    Wrapped.prototype = OrigES.prototype;
    var statics = ['CONNECTING', 'OPEN', 'CLOSED'];
    for (var i = 0; i < statics.length; i++) {
      Wrapped[statics[i]] = OrigES[statics[i]];
    }
    window.EventSource = Wrapped;
  }
  var OrigWS = window.WebSocket;
  if (OrigWS) {
    var wsSend = function(event) {
      post('zrWs', event);
    };
    var WSWrapped = function(url, protocols) {
      var ws = (protocols === undefined)
          ? new OrigWS(url)
          : new OrigWS(url, protocols);
      try {
        var urlStr = (url && url.href) ? url.href : String(url);
        // W2：非官方 relay 的 WS 一律透明（不挂监听、不读正文）。
        if (!wsAllowed(urlStr)) {
          bump('wsIgnored');
          return ws;
        }
        ws.addEventListener('open', function() {
          wsSend(JSON.stringify({s: 'open', u: urlStr}));
        });
        ws.addEventListener('close', function(ev) {
          wsSend(JSON.stringify({s: 'closed', u: urlStr, c: ev && ev.code, r: (ev && ev.reason) || ''}));
        });
        ws.addEventListener('message', function(ev) {
          try {
            bump('wsMessages');
            var d = ev.data;
            if (typeof d === 'string') {
              sendWithDecode(d);
            } else if (d && typeof d.size === 'number') {
              if (d.size > 0 && d.size < $kMaxListenBytes) {
                d.text().then(function(t) { sendWithDecode(t); }).catch(function() {});
              } else {
                bump('wsSkippedSize');
              }
            } else if (d && d.byteLength > 0 && d.byteLength < $kMaxListenBytes) {
              try { sendWithDecode(new TextDecoder('utf-8', {fatal: false}).decode(d)); } catch (e2) {}
            } else if (d && d.byteLength >= $kMaxListenBytes) {
              bump('wsSkippedSize');
            }
          } catch (e) {}
        });
      } catch (e) {}
      return ws;
    };
    WSWrapped.prototype = OrigWS.prototype;
    var wsStatics = ['CONNECTING', 'OPEN', 'CLOSED'];
    for (var j = 0; j < wsStatics.length; j++) {
      WSWrapped[wsStatics[j]] = OrigWS[wsStatics[j]];
    }
    window.WebSocket = WSWrapped;
  }
})();
''';
}

const Set<String> kKnownEventTypes = {
  'created',
  'prompt_sent',
  'resumed',
  'streaming',
  'permission_request',
  'permission_resolved',
  'elicitation_request',
  'elicitation_resolved',
  'updated',
  'completed',
  'error',
};

const Set<String> kNotifiableTypes = {
  'permission_request',
  'elicitation_request',
  'completed',
  'error',
};

/// 单任务待处理计数上限（R-19 复审）。观察面数值来自页面内容，超出这个
/// 量级只可能是异常或操纵；封顶后 permission + userInput 求和不会回绕为负。
const int kMaxPendingCount = 1024;

/// 页面可控数值 → 有限整数。非 num 或非有限值一律按缺席处理：
/// `jsonDecode('1e999')` 得到 `double.infinity`，直接 `toInt()` 会抛异常并
/// 中断整帧观察处理（安全复审 P2）。
int? _finiteInt(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return value.toInt();
}

/// 待处理计数：只认非负 int（小数 / 指数 / 超范围字面量经 jsonDecode 都是
/// double，不采信），并封顶 [kMaxPendingCount]。缺席或非法一律 0。
int _pendingCount(Object? value) {
  if (value is! int || value < 0) return 0;
  return value > kMaxPendingCount ? kMaxPendingCount : value;
}

/// 该值是否是一个合法的待处理计数（用于判定任务行是否表达了 pending 状态）。
bool _hasPendingCount(Object? value) => value is int && value >= 0;

class ObservedEvent {
  const ObservedEvent({
    required this.type,
    this.taskId,
    this.sessionTitle,
    this.summary,
    this.pendingTotal,
  });

  final String type;

  final String? taskId;

  final String? sessionTitle;

  final String? summary;

  /// 转移完成后该任务的剩余待处理交互总数（permission + userInput）。
  ///
  /// R-19：观察面（`pendingInteractionSummary`）只有按任务聚合的计数，
  /// 没有请求级 id，所以 pending 记账按计数降级——resolved 携带剩余量，
  /// 同任务还有剩余交互时红点与系统通知都保留。null = 观察面给不出计数
  /// （例如任务整行消失），消费方按"未知"处理而非当成 0。
  final int? pendingTotal;

  ObservedEvent copyWith({
    String? sessionTitle,
    String? summary,
    int? pendingTotal,
  }) => ObservedEvent(
    type: type,
    taskId: taskId,
    sessionTitle: sessionTitle ?? this.sessionTitle,
    summary: summary ?? this.summary,
    pendingTotal: pendingTotal ?? this.pendingTotal,
  );
}

abstract final class EventParser {
  static const int _maxDepth = 3;

  static List<ObservedEvent> parseMessage(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseRoot(root);
  }

  static List<ObservedEvent> parseRoot(dynamic root) {
    final events = <ObservedEvent>[];
    _walk(root, 0, events);
    return events;
  }

  /// Returns only events that represent an immediate user action request.
  ///
  /// Completion and failure are deliberately not returned here. The remote
  /// page carries many nested `type`/`event` values while a reply is still
  /// streaming (for example a tool step finishing or a reasoning item being
  /// updated). Those values are not proof that the whole assistant turn has
  /// ended. The callers use [StateDiffer] for the terminal transition instead.
  static List<ObservedEvent> parseUserActionRoot(dynamic root) =>
      parseRoot(root)
          .where((event) {
            final hasTarget = event.taskId != null && event.taskId!.isNotEmpty;
            return hasTarget &&
                (event.type == 'permission_request' ||
                    event.type == 'elicitation_request');
          })
          .toList(growable: false);

  /// Removes duplicate representations of one event in a relay delivery.
  /// The same request can arrive once as an explicit event and once alongside
  /// the state delta that produced it.
  static List<ObservedEvent> dedupe(Iterable<ObservedEvent> input) {
    final indexByKey = <String, int>{};
    final result = <ObservedEvent>[];
    for (final event in input) {
      final key = '${event.type}\u0000${event.taskId ?? ''}';
      final kept = indexByKey[key];
      if (kept == null) {
        indexByKey[key] = result.length;
        result.add(event);
        continue;
      }
      // 显式页面事件排在 differ 事件之前、且不带计数；同一逻辑事件的后到
      // 副本若带权威剩余计数，要合并进保留副本，否则 feed 只能按"在场"
      // 记 1（R-19 复审）。保留副本的文案不动，只补计数与缺失的标题。
      final current = result[kept];
      if (current.pendingTotal == null && event.pendingTotal != null) {
        result[kept] = current.copyWith(
          pendingTotal: event.pendingTotal,
          sessionTitle: current.sessionTitle ?? event.sessionTitle,
        );
      }
    }
    return result;
  }

  static void _walk(dynamic node, int depth, List<ObservedEvent> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      final type = _eventTypeOf(node);
      if (type != null) out.add(_eventFrom(node, type));
      for (final value in node.values) {
        _walk(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walk(value, depth + 1, out);
      }
    }
  }

  static String? _eventTypeOf(Map<dynamic, dynamic> node) {
    for (final key in const ['event', 'type']) {
      final value = node[key];
      if (value is String && kKnownEventTypes.contains(value)) return value;
    }
    return null;
  }

  static ObservedEvent _eventFrom(Map<dynamic, dynamic> node, String type) {
    String? taskId;
    for (final key in const ['taskId', 'task_id']) {
      final value = node[key];
      if (value is String && value.isNotEmpty) {
        taskId = value;
        break;
      }
    }

    final summary = _firstEventText(
      node,
      type == 'permission_request' || type == 'elicitation_request'
          ? const ['description', 'summary', 'title', 'kind', 'toolName']
          : const [
              'summary',
              'content',
              'text',
              'message',
              'result',
              'error',
              'output',
              'response',
              'description',
            ],
    );

    return ObservedEvent(type: type, taskId: taskId, summary: summary);
  }

  static String? _firstEventText(
    Map<dynamic, dynamic> node,
    List<String> keys,
  ) {
    for (final key in keys) {
      final text = _eventText(node[key]);
      if (text != null) return text;
    }
    return null;
  }

  static String? _eventText(Object? value) {
    if (value is String) {
      final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) return null;
      // 截断走共享的码元边界保护（iter16）：180 切点上不得产出孤立代理对。
      return text.length > 180
          ? '${LogRedactor.clipCodeUnits(text, 180)}…'
          : text;
    }
    if (value is Map) {
      for (final key in const [
        'text',
        'content',
        'message',
        'body',
        'response',
        'output',
      ]) {
        final text = _eventText(value[key]);
        if (text != null) return text;
      }
    }
    return null;
  }
}

class SessionState {
  const SessionState({
    required this.sessionId,
    this.title,
    this.phase,
    this.sessionEnded,
    this.permissionCount = 0,
    this.userInputCount = 0,
    this.hasPendingSummary = false,
    this.interactionKind,
    this.toolName,
    this.description,
    this.preview,
    this.lastActivityAt,
    this.createdAt,
    this.workspace,
    this.workspacePath,
    this.pinned = false,
  });

  final String sessionId;
  final String? title;
  final String? phase;
  final bool? sessionEnded;
  final int permissionCount;
  final int userInputCount;

  /// 源节点是否真的带 `pendingInteractionSummary`（R-19）。
  ///
  /// 计数缺省是 0，"没带 summary"与"确认无待处理"不可区分；重复副本
  /// 合并时靠它挡住缺 summary 的扁平行覆盖带 summary 的会话镜像。
  final bool hasPendingSummary;
  final String? interactionKind;
  final String? toolName;

  final String? description;

  /// 最近一段可恢复的会话正文，用于完成/失败通知的正文预览。
  final String? preview;

  final int? lastActivityAt;

  final int? createdAt;

  /// 工作区显示名（relay 侧是 `workspaceLabel`）。
  final String? workspace;

  /// 工作区**完整路径**。relay 的会话接口（订阅 / 拉正文）需要它。
  final String? workspacePath;

  final bool pinned;

  /// 缺 summary 的行不表达 pending 状态：沿用 [baseline] 的计数（R-19）。
  ///
  /// 返回的副本标记为权威（`hasPendingSummary=true`），这样下一条真正带
  /// summary 的同计数行不会被当成 0→N 的新转移而重复发请求事件。
  SessionState inheritPendingFrom(SessionState baseline) => SessionState(
    sessionId: sessionId,
    title: title,
    phase: phase,
    sessionEnded: sessionEnded,
    permissionCount: baseline.permissionCount,
    userInputCount: baseline.userInputCount,
    hasPendingSummary: true,
    interactionKind: interactionKind ?? baseline.interactionKind,
    toolName: toolName ?? baseline.toolName,
    description: description ?? baseline.description,
    preview: preview ?? baseline.preview,
    lastActivityAt: lastActivityAt,
    createdAt: createdAt,
    workspace: workspace,
    workspacePath: workspacePath,
    pinned: pinned,
  );

  @override
  bool operator ==(Object other) =>
      other is SessionState &&
      other.sessionId == sessionId &&
      other.title == title &&
      other.phase == phase &&
      other.sessionEnded == sessionEnded &&
      other.permissionCount == permissionCount &&
      other.userInputCount == userInputCount &&
      other.hasPendingSummary == hasPendingSummary &&
      other.interactionKind == interactionKind &&
      other.toolName == toolName &&
      other.description == description &&
      other.preview == preview &&
      other.lastActivityAt == lastActivityAt &&
      other.createdAt == createdAt &&
      other.workspace == workspace &&
      other.workspacePath == workspacePath &&
      other.pinned == pinned;

  @override
  int get hashCode => Object.hashAll([
    sessionId,
    title,
    phase,
    sessionEnded,
    permissionCount,
    userInputCount,
    hasPendingSummary,
    interactionKind,
    toolName,
    description,
    preview,
    lastActivityAt,
    createdAt,
    workspace,
    workspacePath,
    pinned,
  ]);
}

abstract final class SessionStateExtractor {
  static const int _maxDepth = 8;

  static List<SessionState> parse(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseRoot(root);
  }

  static List<SessionState> parseRoot(dynamic root) {
    final states = <SessionState>[];
    _walk(root, 0, states);
    return states;
  }

  static List<String> parseRemoved(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseRemovedRoot(root);
  }

  static List<String> parseRemovedRoot(dynamic root) {
    final removed = <String>[];
    _walkRemoved(root, 0, removed);
    return removed;
  }

  static void _walkRemoved(dynamic node, int depth, List<String> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      if (node['op'] == 'session.removed') {
        final id = node['sessionId'];
        if (id is String && id.isNotEmpty) out.add(id);
      }
      for (final value in node.values) {
        _walkRemoved(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walkRemoved(value, depth + 1, out);
      }
    }
  }

  static String? workspaceBasenameOf(String? id) {
    if (id == null) return null;
    final trimmed = id.trim();
    if (trimmed.isEmpty) return null;
    final slash = trimmed.lastIndexOf('/');
    final backslash = trimmed.lastIndexOf(r'\');
    final cut = slash > backslash ? slash : backslash;
    final base = (cut < 0 ? trimmed : trimmed.substring(cut + 1)).trim();
    return base.isEmpty ? null : base;
  }

  static void _walk(dynamic node, int depth, List<SessionState> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      final state = _stateOf(node);
      if (state != null) out.add(state);
      for (final value in node.values) {
        _walk(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walk(value, depth + 1, out);
      }
    }
  }

  static SessionState? _stateOf(Map<dynamic, dynamic> node) {
    final id = node['sessionId'];
    if (id is! String || id.isEmpty) return null;
    final hasSummary = node['pendingInteractionSummary'] is Map;
    final hasEnded = node['sessionEnded'] is bool;
    final hasPhase = node['phase'] is String;
    if (!hasSummary && !hasEnded && !hasPhase) return null;

    var permCount = 0;
    var userInputCount = 0;
    final summary = node['pendingInteractionSummary'];
    if (summary is Map) {
      permCount = _pendingCount(summary['permissionCount']);
      userInputCount = _pendingCount(summary['userInputCount']);
    }
    String? interactionKind;
    String? toolName;
    String? description;
    final interaction = node['pendingInteraction'];
    if (interaction is Map) {
      final k = interaction['kind'];
      final t = interaction['toolName'];
      if (k is String) interactionKind = k;
      if (t is String) toolName = t;
      for (final key in const ['description', 'summary']) {
        final d = interaction[key];
        if (d is String && d.isNotEmpty) {
          description = d;
          break;
        }
      }
    }

    final title = node['title'];
    final laa = node['lastActivityAt'];
    final ca = node['createdAt'];
    final workspacePath = _firstString(node, const [
      'workspacePath',
      'workspaceId',
    ]);
    final workspaceLabel = _firstString(node, const [
      'workspaceLabel',
      'workspace',
    ]);
    return SessionState(
      sessionId: id,
      title: title is String ? title : null,
      phase: node['phase'] is String ? node['phase'] as String? : null,
      sessionEnded: node['sessionEnded'] is bool
          ? node['sessionEnded'] as bool?
          : null,
      permissionCount: permCount,
      userInputCount: userInputCount,
      hasPendingSummary: summary is Map,
      interactionKind: interactionKind,
      toolName: toolName,
      description: description,
      preview: previewOf(node),
      lastActivityAt: _finiteInt(laa),
      createdAt: _finiteInt(ca),
      workspace: workspaceLabel ?? workspaceBasenameOf(workspacePath),
      workspacePath: workspacePath,
    );
  }

  /// 从不同桌面端版本的任务快照中提取最近正文。字段不存在时返回 null，
  /// 不把工作区标题或内部状态误当成消息内容。
  static String? previewOf(Map<dynamic, dynamic> node) {
    final sources = <Map<dynamic, dynamic>>[node];
    for (final key in const ['activity', 'meta', 'latest', 'lastMessage']) {
      final value = node[key];
      if (value is Map) sources.add(value);
    }
    for (final source in sources) {
      for (final key in const [
        'lastAssistantText',
        'lastAssistantMessage',
        'lastResponse',
        'lastMessage',
        'preview',
        'summary',
        'content',
        'output',
      ]) {
        final text = _previewText(source[key]);
        if (text != null) return text;
      }
    }
    return null;
  }

  static String? _previewText(Object? value) {
    if (value is String) {
      final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) return null;
      // 同 `_eventText`：码元边界保护（iter16）。
      return text.length > 180
          ? '${LogRedactor.clipCodeUnits(text, 180)}…'
          : text;
    }
    if (value is Map) {
      for (final key in const [
        'text',
        'content',
        'message',
        'body',
        'output',
      ]) {
        final text = _previewText(value[key]);
        if (text != null) return text;
      }
    }
    return null;
  }

  static String? _firstString(Map<dynamic, dynamic> node, List<String> keys) {
    for (final key in keys) {
      final value = node[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }
}

abstract final class TaskIndexExtractor {
  static const int _maxDepth = 8;

  static List<SessionState> parse(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseRoot(root);
  }

  static List<SessionState> parseRoot(dynamic root) {
    final states = <SessionState>[];
    _walk(root, 0, states);
    return states;
  }

  static void _walk(dynamic node, int depth, List<SessionState> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      if (node['op'] == 'task.upserted' && node['task'] is Map) {
        final state = _stateOf(node['task'] as Map<dynamic, dynamic>);
        if (state != null) out.add(state);
      }
      for (final value in node.values) {
        _walk(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walk(value, depth + 1, out);
      }
    }
  }

  static List<String> parseArchived(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseArchivedRoot(root);
  }

  static List<String> parseArchivedRoot(dynamic root) {
    final archived = <String>[];
    _walkArchived(root, 0, archived);
    return archived;
  }

  static List<String> parseRemoved(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseRemovedRoot(root);
  }

  static List<String> parseRemovedRoot(dynamic root) {
    final removed = <String>[];
    _walkRemoved(root, 0, removed);
    return removed;
  }

  static void _walkRemoved(dynamic node, int depth, List<String> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      if (node['op'] == 'task.removed' && node['address'] is Map) {
        final id = (node['address'] as Map<dynamic, dynamic>)['taskId'];
        if (id is String && id.isNotEmpty) out.add(id);
      }
      for (final value in node.values) {
        _walkRemoved(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walkRemoved(value, depth + 1, out);
      }
    }
  }

  static void _walkArchived(dynamic node, int depth, List<String> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      if (node['op'] == 'task.upserted' && node['task'] is Map) {
        final task = node['task'] as Map<dynamic, dynamic>;
        final membership = task['membership'];
        if (membership is Map && membership['archived'] == true) {
          final id = _taskIdOf(task);
          if (id != null) out.add(id);
        }
      }
      for (final value in node.values) {
        _walkArchived(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walkArchived(value, depth + 1, out);
      }
    }
  }

  static String? _taskIdOf(Map<dynamic, dynamic> task) {
    final address = task['address'];
    if (address is Map) {
      final id = address['taskId'];
      if (id is String && id.isNotEmpty) return id;
    }
    final meta = task['meta'];
    if (meta is Map) {
      final id = meta['taskId'];
      if (id is String && id.isNotEmpty) return id;
    }
    return null;
  }

  static List<SessionState>? parseSnapshot(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return null;
    }
    return parseSnapshotRoot(root);
  }

  static List<SessionState>? parseSnapshotRoot(dynamic root) {
    final snapshot = _findTasksSnapshot(root, 0);
    if (snapshot == null) return null;
    final out = <SessionState>[];
    for (final t in snapshot) {
      if (t is Map<dynamic, dynamic>) {
        final state = _stateOf(t);
        if (state != null) out.add(state);
      }
    }
    return out;
  }

  static List<dynamic>? _findTasksSnapshot(dynamic node, int depth) {
    if (depth > _maxDepth || node is! Map) return null;
    final payload = node['payload'];
    if (payload is Map && payload['kind'] == 'snapshot') {
      final snapshot = payload['snapshot'];
      if (snapshot is Map && snapshot['tasks'] is List) {
        return snapshot['tasks'] as List<dynamic>;
      }
    }
    for (final value in node.values) {
      final found = _findTasksSnapshot(value, depth + 1);
      if (found != null) return found;
    }
    return null;
  }

  static List<SessionState>? parseResultTasks(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return null;
    }
    return parseResultTasksRoot(root);
  }

  static List<SessionState>? parseResultTasksRoot(dynamic root) {
    final tasks = _findResultTasks(root, 0);
    if (tasks == null) return null;
    final out = <SessionState>[];
    for (final t in tasks) {
      if (t is! Map<dynamic, dynamic>) continue;
      final state = _stateOfFlat(t);
      if (state != null) out.add(state);
    }
    return out;
  }

  static List<dynamic>? _findResultTasks(dynamic node, int depth) {
    if (depth > _maxDepth || node is! Map) return null;
    final result = node['result'];
    if (result is Map && result['tasks'] is List) {
      return result['tasks'] as List<dynamic>;
    }
    for (final value in node.values) {
      final found = _findResultTasks(value, depth + 1);
      if (found != null) return found;
    }
    return null;
  }

  static bool isBootstrapResult(dynamic root) {
    if (root is! Map) return false;
    final payload = root['payload'];
    if (payload is! Map) return false;
    final requestId = payload['requestId'];
    return requestId is String && requestId.startsWith('bootstrap');
  }

  static SessionState? _stateOfFlat(Map<dynamic, dynamic> t) {
    final id = t['taskId'];
    if (id is! String || id.isEmpty) return null;
    final status = t['displayStatus'];
    final phase = status is String ? _phaseFromStatus(status) : null;
    final laa = t['updatedAt'];
    final ca = t['createdAt'];
    final wsPath = t['workspacePath'];
    final wsLabel = t['workspaceLabel'];
    return SessionState(
      sessionId: id,
      title: t['title'] is String ? t['title'] as String? : null,
      preview: SessionStateExtractor.previewOf(t),
      phase: phase,
      lastActivityAt: _finiteInt(laa),
      createdAt: _finiteInt(ca),
      workspace: wsLabel is String && wsLabel.isNotEmpty
          ? wsLabel
          : SessionStateExtractor.workspaceBasenameOf(
              wsPath is String ? wsPath : null,
            ),
      workspacePath: wsPath is String && wsPath.isNotEmpty ? wsPath : null,
    );
  }

  static SessionState? _stateOf(Map<dynamic, dynamic> task) {
    final taskId = _taskIdOf(task);
    if (taskId == null) return null;

    final membership = task['membership'];
    if (membership is Map && membership['archived'] == true) return null;

    final address = task['address'];
    final meta = task['meta'];
    final activity = task['activity'];

    final containers = <Map<dynamic, dynamic>>[
      task,
      if (address is Map) address,
      if (meta is Map) meta,
      if (activity is Map) activity,
      for (final key in const ['latest', 'lastMessage'])
        if (task[key] is Map) task[key] as Map<dynamic, dynamic>,
    ];

    Map<dynamic, dynamic>? firstMap(String key) {
      for (final source in containers) {
        final value = source[key];
        if (value is Map) return value;
      }
      return null;
    }

    int countFromMaps(String key) {
      for (final source in containers) {
        final value = source[key];
        if (_hasPendingCount(value)) return _pendingCount(value);
      }
      return 0;
    }

    final pendingSummary = firstMap('pendingInteractionSummary');
    final permissionCount = pendingSummary == null
        ? countFromMaps('permissionCount')
        : _pendingCount(pendingSummary['permissionCount']);
    final userInputCount = pendingSummary == null
        ? countFromMaps('userInputCount')
        : _pendingCount(pendingSummary['userInputCount']);

    final pending = firstMap('pendingInteraction');
    final interactionKind = pending != null && pending['kind'] is String
        ? pending['kind'] as String
        : null;
    final toolName = pending != null && pending['toolName'] is String
        ? pending['toolName'] as String
        : null;
    String? description;
    for (final key in const ['description', 'summary']) {
      final value = pending == null ? null : pending[key];
      if (value is String && value.trim().isNotEmpty) {
        description = value.trim();
        break;
      }
    }

    String? workspacePath;
    if (address is Map) {
      final p = address['workspacePath'];
      if (p is String && p.isNotEmpty) workspacePath = p;
    }
    if (workspacePath == null && meta is Map) {
      final p = meta['workspacePath'];
      if (p is String && p.isNotEmpty) workspacePath = p;
    }

    String? title;
    if (meta is Map) {
      final t = meta['title'];
      if (t is String && t.isNotEmpty) title = t;
    }

    int? lastActivityAt;
    if (activity is Map) {
      lastActivityAt = _finiteInt(activity['lastActivityAt']);
    }
    if (lastActivityAt == null && meta is Map) {
      lastActivityAt = _finiteInt(meta['updatedAt']);
    }

    int? createdAt;
    if (meta is Map) {
      createdAt = _finiteInt(meta['createdAt']);
    }

    String? phase;
    if (activity is Map) {
      final p = activity['phase'];
      if (p is String && p.isNotEmpty) phase = p;
    }
    if (phase == null) {
      final live = task['liveStatus'];
      if (live is String && live.isNotEmpty) phase = live;
    }
    if (phase == null && meta is Map) {
      final status = meta['status'];
      if (status is String) phase = _phaseFromStatus(status);
    }
    if (phase == null && task['displayStatus'] is String) {
      phase = _phaseFromStatus(task['displayStatus'] as String);
    }

    bool? sessionEnded;
    for (final source in containers) {
      final value = source['sessionEnded'];
      if (value is bool) {
        sessionEnded = value;
        break;
      }
    }

    // 任务行是否真的表达了 pending 状态（R-19）：summary 对象存在，或容器里
    // 任一扁平计数字段是合法非负 int，即算权威（负数/小数视为缺席）；两者都
    // 缺时计数 0 只是缺省值，StateDiffer 会沿用基线而不是当成"已解决"。
    bool hasFlatCount(String key) =>
        containers.any((source) => _hasPendingCount(source[key]));
    final hasPendingSummary =
        pendingSummary != null ||
        hasFlatCount('permissionCount') ||
        hasFlatCount('userInputCount');

    return SessionState(
      sessionId: taskId,
      title: title,
      preview: SessionStateExtractor.previewOf(task),
      phase: phase,
      sessionEnded: sessionEnded,
      permissionCount: permissionCount,
      userInputCount: userInputCount,
      hasPendingSummary: hasPendingSummary,
      interactionKind: interactionKind,
      toolName: toolName,
      description: description,
      lastActivityAt: lastActivityAt,
      createdAt: createdAt,
      workspace: SessionStateExtractor.workspaceBasenameOf(workspacePath),
      workspacePath: workspacePath,
      pinned: membership is Map && membership['pinned'] == true,
    );
  }

  static String? _phaseFromStatus(String status) => switch (status) {
    'completed' => 'completedSuccess',
    'error' => 'error',
    'running' => 'running',
    _ => null,
  };
}

class StateDiffer {
  StateDiffer();

  /// 基线条目上限（安全审计 S-1，与 `SessionIndexNotifier` 的单设备上限
  /// 同量级）：超限按插入序淘汰最旧的条目。
  static const int maxPrevEntries = 10000;

  final Map<String, SessionState> _prev = {};

  List<ObservedEvent> apply(
    List<SessionState> incoming, {
    List<String> removed = const [],
  }) {
    final events = <ObservedEvent>[];
    for (final id in removed) {
      final gone = _prev.remove(id);
      if (gone != null &&
          (gone.permissionCount > 0 || gone.userInputCount > 0)) {
        events.add(
          ObservedEvent(type: 'resolved', taskId: id, sessionTitle: gone.title),
        );
      }
    }
    // A single relay delivery may contain both a task delta and its nested
    // session mirror. Collapse those copies before diffing; otherwise the
    // same non-current session can produce an event and immediately overwrite
    // its baseline with a second representation.
    //
    // 同一投递内的重复副本描述同一时刻，分歧只能是形状差异而非新鲜度
    // （R-19）：缺 pendingInteractionSummary 的扁平行不能覆盖带 summary 的
    // 镜像——否则计数被 0 覆盖后立刻产生假 resolved，把仍在等待的红点清掉。
    final latestById = <String, SessionState>{};
    for (final next in incoming) {
      final kept = latestById[next.sessionId];
      if (kept != null && kept.hasPendingSummary && !next.hasPendingSummary) {
        continue;
      }
      latestById[next.sessionId] = next;
    }
    for (final candidate in latestById.values) {
      final prev = _prev[candidate.sessionId];
      // 跨投递同理（R-19）：任务索引刷新只发扁平行时，基线里的 1 不能被
      // 缺省 0 覆盖成"已解决"。沿用基线计数并标记权威，避免下一条真正
      // 带 summary 的同计数行被当成新转移重复发请求。
      final next =
          prev != null && prev.hasPendingSummary && !candidate.hasPendingSummary
          ? candidate.inheritPendingFrom(prev)
          : candidate;
      _prev[next.sessionId] = next;

      final prevPerm = prev?.permissionCount ?? 0;
      final prevInput = prev?.userInputCount ?? 0;
      // 权威剩余量：观察面按任务聚合的总计数（无请求级 id，R-19 降级口径）。
      final pendingTotal = next.permissionCount + next.userInputCount;

      if (next.permissionCount > 0 && prevPerm == 0) {
        events.add(
          ObservedEvent(
            type: 'permission_request',
            taskId: next.sessionId,
            sessionTitle: next.title,
            summary: next.description ?? next.preview,
            pendingTotal: pendingTotal,
          ),
        );
      }
      if (next.userInputCount > 0 && prevInput == 0) {
        events.add(
          ObservedEvent(
            type: 'elicitation_request',
            taskId: next.sessionId,
            sessionTitle: next.title,
            summary: next.description ?? next.preview,
            pendingTotal: pendingTotal,
          ),
        );
      }

      if ((prevPerm > 0 && next.permissionCount == 0) ||
          (prevInput > 0 && next.userInputCount == 0)) {
        events.add(
          ObservedEvent(
            type: 'resolved',
            taskId: next.sessionId,
            sessionTitle: next.title,
            pendingTotal: pendingTotal,
          ),
        );
      }

      final prevPhase = prev?.phase;
      final phase = next.phase;
      const donePhases = {'completedSuccess', 'completedInterrupted'};
      // `sessionEnded:false` is still an active turn even if a nested
      // activity object briefly reports a completed-looking phase. A flat
      // task-index row may omit sessionEnded, so null remains acceptable for
      // that authoritative displayStatus representation.
      final isDone =
          phase != null &&
          donePhases.contains(phase) &&
          next.sessionEnded != false;
      final wasDone =
          prev != null &&
          prev.sessionEnded != false &&
          prevPhase != null &&
          donePhases.contains(prevPhase);
      final wasError =
          prev != null && prev.sessionEnded != false && prevPhase == 'error';
      if (prev != null && isDone && !wasDone) {
        events.add(
          ObservedEvent(
            type: 'completed',
            taskId: next.sessionId,
            sessionTitle: next.title,
            summary: next.preview ?? next.description ?? prev.preview,
          ),
        );
      }
      if (prev != null &&
          phase == 'error' &&
          next.sessionEnded != false &&
          !wasError) {
        events.add(
          ObservedEvent(
            type: 'error',
            taskId: next.sessionId,
            sessionTitle: next.title,
            summary: next.preview ?? next.description ?? prev.preview,
          ),
        );
      }
    }
    // 安全审计 S-1：`_prev` 基线按插入序封顶（Map 保插入序）。被驱逐的
    // 会话下次出现会重新产生一次边沿事件——这是攻击下的可接受代价，
    // 换来敌对页面无法用唯一 sessionId 灌爆进程内存。
    if (_prev.length > maxPrevEntries) {
      for (final id in _prev.keys.take(_prev.length - maxPrevEntries).toList(growable: false)) {
        _prev.remove(id);
      }
    }
    return events;
  }

  /// 快照全量替换后的基线对账：只剪"已终态且不在最新快照中"的条目。
  ///
  /// completed/error 事件都要求 prev != null，因此 pending（审批/输入
  /// 计数大于 0）与运行中基线一律保留，否则会漏报；终态条目不会再产生
  /// 新转移（唯一出口是 removed 对账），剪掉零漏报，同时清掉长会话场景
  /// 下 `_prev` 的增长大头。
  void pruneOnSnapshot(Iterable<SessionState> snapshot) {
    if (_prev.isEmpty) return;
    final alive = snapshot.map((s) => s.sessionId).toSet();
    _prev.removeWhere((id, state) {
      if (alive.contains(id)) return false;
      final terminal =
          (state.phase == 'error' ||
              state.phase == 'completedSuccess' ||
              state.phase == 'completedInterrupted') &&
          state.sessionEnded != false;
      return terminal;
    });
  }
}

abstract final class MobileViewStateSync {
  static ({bool valid, String? taskId}) parse(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return (valid: false, taskId: null);
    }
    if (root is! Map) return (valid: false, taskId: null);
    if (root['activeWorkspaceKey'] is! String) {
      return (valid: false, taskId: null);
    }
    final id = root['activeTaskId'];
    return (valid: true, taskId: id is String && id.isNotEmpty ? id : null);
  }
}

abstract final class ActiveSessionExtractor {
  static const int _maxDepth = 6;

  static String? parse(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return null;
    }
    return parseRoot(root);
  }

  static String? parseRoot(dynamic root) => _walk(root, 0);

  static String? _walk(dynamic node, int depth) {
    if (depth > _maxDepth || node is! Map) return null;
    final topic = node['topic'];
    if (topic is String && topic.startsWith('conversation/')) {
      final sid = topic.substring('conversation/'.length);
      if (sid.isNotEmpty) return sid;
    }
    final view = node['mobileViewState'];
    if (view is Map) {
      final id = view['activeTaskId'];
      if (id is String && id.isNotEmpty) return id;
    }
    final bridge = node['bridge'];
    if (bridge is Map) {
      final id = bridge['initialTaskId'];
      if (id is String && id.isNotEmpty) return id;
    }
    String? found;
    for (final value in node.values) {
      found = _walk(value, depth + 1);
      if (found != null) return found;
    }
    return null;
  }
}

abstract final class NotificationGate {
  static bool shouldNotify({
    required bool appForeground,
    required String? visibleDeviceId,
    required String eventDeviceId,
    required String? activeSessionId,
    required String? eventSessionId,
  }) {
    // 前台由应用内浮窗和通知中心承接；系统通知只在应用离开前台后发出，
    // 避免同一个事件在屏幕上重复出现。保留其余参数是为了兼容调用方。
    return !appForeground;
  }
}

/// 跨消息幂等闸门（F12）。
///
/// 一次投递内的重复由 [EventParser.dedupe] 处理；重连重放、同帧多通道投递
/// 会让同一条逻辑事件跨消息再次到达，这里用一个**有界 + 带窗口**的表抑制它：
/// - 窗口内相同的 (type, taskId) 只放行一次；
/// - 键**不含** summary：敌对页面轮换摘要文本制造不出新键（D-20260916-10）；
///   同任务的第二笔请求在窗口内不再单独提醒，红点数量仍由观察面的
///   权威计数（pendingTotal / resolved 字道）保证准确——窗口内计数值
///   可能滞后到下一条 resolved 才校准，红点在场性不受影响；
/// - 窗口外允许再次提醒（不压制合法的"新一轮"）；
/// - 收到 resolved 时清掉该任务的历史键——用户处理完一轮后，
///   同一任务的新请求必须照常提醒（N06）。
class EventDedupeGate {
  EventDedupeGate({
    this.window = const Duration(minutes: 2),
    this.maxEntries = 256,
  }) {
    // 默认时钟取**单调**时长（进程起点 + Stopwatch），而不是墙钟（iter16）：
    // 系统时间被回拨时 `now.difference(last)` 变负，旧键永不过期且同
    // (type,taskId) 的新事件被一律压制（不写 feed、不进历史、不提醒），
    // 红点计数停在上一次的值直到墙钟追平。单调钟对回拨免疫。
    clock = () => _monotonicOrigin.add(_monotonic.elapsed);
  }

  final Duration window;
  final int maxEntries;

  final Map<String, DateTime> _recent = {};

  static final DateTime _monotonicOrigin = DateTime.now();

  final Stopwatch _monotonic = Stopwatch()..start();

  /// 便于测试注入时钟；默认是构造时装配的单调源（见构造函数）。
  late DateTime Function() clock;

  /// 键尾保留空 summary 段：resolved 清理用 `\0taskId\0` 标记做包含匹配，
  /// 键必须以 `\0taskId\0` 结尾才不会被前缀更长的 taskId 误清。
  static String keyOf(ObservedEvent event) =>
      '${event.type}\u0000${event.taskId ?? ''}\u0000';

  /// true = 应提醒；false = 窗口内重复，抑制。
  bool allow(ObservedEvent event) {
    final now = clock();
    _recent.removeWhere((_, at) => now.difference(at) >= window);
    final taskId = event.taskId;
    if (event.type == 'resolved') {
      if (taskId != null && taskId.isNotEmpty) {
        final marker = '\u0000$taskId\u0000';
        _recent.removeWhere((key, _) => key.contains(marker));
      }
      return true;
    }
    final key = keyOf(event);
    final last = _recent[key];
    if (last != null && now.difference(last) < window) return false;
    _recent[key] = now;
    if (_recent.length > maxEntries) {
      // 有界：按时间丢弃最旧的一半，绝不无限增长。
      final entries = _recent.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (final entry in entries.take(entries.length - maxEntries ~/ 2)) {
        _recent.remove(entry.key);
      }
    }
    return true;
  }
}
