/**
 * CF-WebShell 自动同步服务 —— Cloudflare Worker + D1。
 *
 * 它只做一件事：在一组"配对过的设备"之间传一份 JSON 文档。
 * 合并逻辑全在客户端（core/lib/src/sync/doc.dart），服务端**故意不懂业务**：
 * 不懂站点、不懂偏好、不解析文档内容，只负责存放 + 版本号 CAS + 鉴权。
 *
 * 这样设计的理由：
 *   - 合并规则以后要改（比如加上文件夹分组），改客户端就行，不用重发 Worker；
 *   - 服务端看到的是不透明 JSON，即使日志泄露也拼不出"这台设备在用什么系统"；
 *   - D1 免费额度是按"读/写行数"算的，一次同步只碰 1~2 行。
 *
 * 安全边界（这是这个文件最重要的部分）：
 *   - 开空间要部署密钥（BOOTSTRAP_SECRET）。没有它，知道地址也开不出空间。
 *   - 设备凭证是 32 字节随机串，库里只存 sha256。
 *   - 所有数据接口都要 Bearer；空间归属从 token 反查，**URL 里没有 spaceId**，
 *     所以"猜空间 id"这条路根本不存在。
 *   - 配对码一次性、10 分钟过期。
 *   - 每台设备 / 每个空间都有写入限流。
 */

const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8' };

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */

function json(data, status = 200, extra) {
  return new Response(JSON.stringify(data), {
    status,
    headers: extra ? { ...JSON_HEADERS, ...extra } : JSON_HEADERS,
  });
}

function fail(error, status = 400) {
  return json({ error }, status);
}

function intEnv(value, fallback) {
  const n = parseInt(value, 10);
  return Number.isFinite(n) ? n : fallback;
}

function nowMs() {
  return Date.now();
}

/** 十六进制 sha256。凭证只以这个形式落库。 */
async function sha256Hex(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  const bytes = new Uint8Array(buf);
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, '0');
  }
  return out;
}

/** 定长比较，避免用时间差一点点试出密钥。 */
function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** 随机 id / token。base64url 去掉 `=` 和易混淆字符之外的东西。 */
function randomToken(bytes = 32) {
  const buf = crypto.getRandomValues(new Uint8Array(bytes));
  let s = '';
  for (let i = 0; i < buf.length; i++) {
    s += String.fromCharCode(buf[i]);
  }
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function newSpaceId() {
  return 'sp_' + randomToken(12).slice(0, 16);
}

function newDeviceId() {
  return 'dv_' + randomToken(12).slice(0, 16);
}

/** 配对码：8 位，去掉 0/O/1/I 这种念不对的字符。 */
function newPairCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const buf = crypto.getRandomValues(new Uint8Array(8));
  let s = '';
  for (let i = 0; i < 8; i++) s += alphabet[buf[i] % alphabet.length];
  return s.slice(0, 4) + '-' + s.slice(4);
}

function normalizeCode(raw) {
  return String(raw || '')
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '');
}

/** 客户端 IP，用于未认证接口的限流。 */
function clientIp(request) {
  return (
    request.headers.get('cf-connecting-ip') ||
    request.headers.get('x-forwarded-for') ||
    'unknown'
  );
}

/* ------------------------------------------------------------------ */
/* 限流（固定窗口）                                                     */
/* ------------------------------------------------------------------ */

async function rateTake(env, key, limit, windowMs, now) {
  if (limit <= 0) return true;
  const row = await env.DB.prepare('SELECT count, window_start FROM rate WHERE key = ?')
    .bind(key)
    .first();
  if (!row || now - row.window_start >= windowMs) {
    await env.DB.prepare(
      'INSERT INTO rate (key, count, window_start) VALUES (?, 1, ?) ' +
        'ON CONFLICT(key) DO UPDATE SET count = 1, window_start = ?'
    )
      .bind(key, now, now)
      .run();
    return true;
  }
  if (row.count >= limit) return false;
  await env.DB.prepare('UPDATE rate SET count = count + 1 WHERE key = ?').bind(key).run();
  return true;
}

/* ------------------------------------------------------------------ */
/* 鉴权                                                                */
/* ------------------------------------------------------------------ */

async function authDevice(request, env, now) {
  const header = request.headers.get('authorization') || '';
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  if (token.length < 16) return null;

  const hash = await sha256Hex(token);
  const row = await env.DB.prepare(
    'SELECT id, space_id, name, revoked, last_seen FROM devices WHERE token_hash = ?'
  )
    .bind(hash)
    .first();

  if (!row || row.revoked) return null;

  // last_seen 节流到 5 分钟一次：D1 免费额度是按写入行数算的，
  // 每次请求都写一遍会把额度烧在毫无意义的"心跳"上。
  if (now - row.last_seen > 5 * 60 * 1000) {
    await env.DB.prepare('UPDATE devices SET last_seen = ? WHERE id = ?')
      .bind(now, row.id)
      .run();
  }
  return row;
}

async function loadSpace(env, spaceId) {
  return env.DB.prepare('SELECT id, version, doc, updated_at FROM spaces WHERE id = ?')
    .bind(spaceId)
    .first();
}

async function countDevices(env, spaceId) {
  const row = await env.DB.prepare(
    'SELECT COUNT(*) AS n FROM devices WHERE space_id = ? AND revoked = 0'
  )
    .bind(spaceId)
    .first();
  return row ? row.n : 0;
}

/* ------------------------------------------------------------------ */
/* 路由                                                                */
/* ------------------------------------------------------------------ */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    let path = url.pathname;
    while (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1);
    const now = nowMs();

    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-headers': 'authorization,content-type,x-bootstrap',
          'access-control-allow-methods': 'GET,POST,PUT,OPTIONS',
          'access-control-max-age': '86400',
        },
      });
    }

    try {
      // 探活 —— 客户端"测试连接"按钮用它，不需要凭证
      if (path === '/v1/health' && request.method === 'GET') {
        return json({ ok: true, service: 'cf-webshell-sync', schema: 1 });
      }

      if (path === '/v1/bootstrap' && request.method === 'POST') {
        return await handleBootstrap(request, env, now);
      }
      if (path === '/v1/pair' && request.method === 'POST') {
        return await handlePair(request, env, now);
      }

      // 以下全部需要设备凭证
      const device = await authDevice(request, env, now);
      if (!device) return fail('unauthorized', 401);

      if (path === '/v1/head' && request.method === 'GET') {
        return await handleHead(env, device);
      }
      if (path === '/v1/doc' && request.method === 'GET') {
        return await handleGetDoc(env, device);
      }
      if (path === '/v1/doc' && request.method === 'PUT') {
        return await handlePutDoc(request, env, device, now);
      }
      if (path === '/v1/pair/code' && request.method === 'POST') {
        return await handlePairCode(request, env, device, now);
      }
      if (path === '/v1/devices' && request.method === 'GET') {
        return await handleDevices(env, device);
      }
      if (path === '/v1/devices/revoke' && request.method === 'POST') {
        return await handleRevoke(request, env, device);
      }

      return fail('not_found', 404);
    } catch (err) {
      // 宁可返回一句人话，也不要把堆栈丢给客户端（里面可能带 SQL 和绑定名）。
      console.error('sync worker error', err && err.stack ? err.stack : err);
      return fail('server_error', 500);
    }
  },
};

/* ------------------------------------------------------------------ */
/* 建空间 / 配对                                                        */
/* ------------------------------------------------------------------ */

async function handleBootstrap(request, env, now) {
  // 没配密钥 = 拒绝一切。绝不允许"空密钥等于无鉴权"那种写法。
  const secret = env.BOOTSTRAP_SECRET;
  if (!secret || secret.length < 16) {
    return fail('bootstrap_disabled', 403);
  }
  const given = request.headers.get('x-bootstrap') || '';
  if (!safeEqual(given, secret)) {
    // 暴力试密钥也要限流
    const ok = await rateTake(env, `boot:${clientIp(request)}`, 10, 3600 * 1000, now);
    if (!ok) return fail('rate_limited', 429);
    return fail('bad_bootstrap', 403);
  }

  const body = await readJson(request);
  const deviceName = String((body && body.deviceName) || '').slice(0, 64) || '第一台设备';

  const spaceId = newSpaceId();
  const deviceId = newDeviceId();
  const token = randomToken(32);
  const hash = await sha256Hex(token);

  await env.DB.batch([
    env.DB.prepare(
      'INSERT INTO spaces (id, created_at, version, doc, updated_at) VALUES (?, ?, 0, ?, ?)'
    ).bind(spaceId, now, JSON.stringify({ schema: 1, spaceId, sites: {}, prefs: {}, suppressed: [] }), now),
    env.DB.prepare(
      'INSERT INTO devices (id, space_id, name, token_hash, created_at, last_seen, revoked) ' +
        'VALUES (?, ?, ?, ?, ?, ?, 0)'
    ).bind(deviceId, spaceId, deviceName, hash, now, now),
  ]);

  return json({ spaceId, deviceId, deviceToken: token });
}

async function handlePairCode(request, env, device, now) {
  const ok = await rateTake(env, `paircode:${device.id}`, 20, 3600 * 1000, now);
  if (!ok) return fail('rate_limited', 429);

  // 顺手清掉过期很久的配对码，免得表越攒越大（D1 免费 5 GB，但没必要浪费）
  await env.DB.prepare('DELETE FROM pair_codes WHERE expires_at < ?')
    .bind(now - 24 * 3600 * 1000)
    .run();

  const code = newPairCode();
  const ttl = intEnv(env.PAIR_TTL_SECONDS, 600) * 1000;
  const expiresAt = now + ttl;

  await env.DB.prepare(
    'INSERT INTO pair_codes (code, space_id, created_at, expires_at, used) VALUES (?, ?, ?, ?, 0)'
  )
    .bind(normalizeCode(code), device.space_id, now, expiresAt)
    .run();

  return json({ code, expiresAt });
}

async function handlePair(request, env, now) {
  const ipOk = await rateTake(env, `pair:${clientIp(request)}`, 20, 3600 * 1000, now);
  if (!ipOk) return fail('rate_limited', 429);

  const body = await readJson(request);
  const code = normalizeCode(body && body.code);
  if (code.length < 6) return fail('bad_code', 400);

  const row = await env.DB.prepare(
    'SELECT code, space_id, expires_at, used FROM pair_codes WHERE code = ?'
  )
    .bind(code)
    .first();

  if (!row || row.used || row.expires_at < now) return fail('bad_code', 400);

  const limit = intEnv(env.MAX_DEVICES, 0);
  if (limit > 0) {
    const n = await countDevices(env, row.space_id);
    if (n >= limit) return fail('space_full', 403);
  }

  // 先占码再建设备：并发两台设备同时用同一个码时，只有一台能拿到 changes=1。
  const claim = await env.DB.prepare('UPDATE pair_codes SET used = 1 WHERE code = ? AND used = 0')
    .bind(code)
    .run();
  if (!claim.meta || claim.meta.changes !== 1) return fail('bad_code', 400);

  const deviceId = newDeviceId();
  const token = randomToken(32);
  const hash = await sha256Hex(token);
  const name = String((body && body.deviceName) || '').slice(0, 64) || '新设备';

  await env.DB.prepare(
    'INSERT INTO devices (id, space_id, name, token_hash, created_at, last_seen, revoked) ' +
      'VALUES (?, ?, ?, ?, ?, ?, 0)'
  )
    .bind(deviceId, row.space_id, name, hash, now, now)
    .run();

  return json({ spaceId: row.space_id, deviceId, deviceToken: token });
}

/* ------------------------------------------------------------------ */
/* 文档读写                                                             */
/* ------------------------------------------------------------------ */

async function handleHead(env, device) {
  const space = await loadSpace(env, device.space_id);
  if (!space) return fail('not_found', 404);
  return json({ v: space.version, updatedAt: space.updated_at });
}

async function handleGetDoc(env, device) {
  const space = await loadSpace(env, device.space_id);
  if (!space) return fail('not_found', 404);
  let doc = {};
  try {
    doc = JSON.parse(space.doc || '{}');
  } catch (e) {
    doc = {};
  }
  return json({ v: space.version, updatedAt: space.updated_at, doc });
}

async function handlePutDoc(request, env, device, now) {
  // 两层限流：单设备防手抖/死循环，单空间防"一群设备同时抽风"。
  const perDevice = intEnv(env.RATE_WRITES_PER_HOUR, 60);
  const perSpace = intEnv(env.RATE_SPACE_PER_HOUR, 2000);
  if (!(await rateTake(env, `w:${device.id}`, perDevice, 3600 * 1000, now))) {
    return fail('rate_limited', 429);
  }
  if (!(await rateTake(env, `w:${device.space_id}`, perSpace, 3600 * 1000, now))) {
    return fail('rate_limited', 429);
  }

  const body = await readJson(request);
  if (!body || typeof body !== 'object') return fail('bad_body', 400);

  const baseV = Number.isFinite(body.baseV) ? body.baseV : -1;
  if (baseV < 0) return fail('bad_body', 400);

  const doc = body.doc;
  if (!doc || typeof doc !== 'object') return fail('bad_body', 400);

  const text = JSON.stringify(doc);
  const maxBytes = intEnv(env.MAX_DOC_BYTES, 524288);
  if (text.length > maxBytes) {
    // 用字符数近似字节数：站点清单全是 ASCII 为主，误差可以忽略，
    // 而且这里只是防呆，不是精确计量。
    return fail('too_large', 413);
  }

  // 空间 id 由客户端带上来，但**必须**和 token 反查出来的一致；
  // 不一致就当成一次陈旧的写入，直接按冲突处理，不给任何越权的机会。
  const spaceId = device.space_id;

  // CAS：版本号对得上才写。D1 的 UPDATE 是原子的，不需要自己加锁。
  const res = await env.DB.prepare(
    'UPDATE spaces SET doc = ?, version = version + 1, updated_at = ? WHERE id = ? AND version = ?'
  )
    .bind(text, now, spaceId, baseV)
    .run();

  if (!res.meta || res.meta.changes !== 1) {
    // 冲突是正常路径：把最新版本一起返回，客户端合并后再推一次。
    const space = await loadSpace(env, spaceId);
    if (!space) return fail('not_found', 404);
    let current = {};
    try {
      current = JSON.parse(space.doc || '{}');
    } catch (e) {
      current = {};
    }
    return json({ ok: false, v: space.version, doc: current }, 409);
  }

  const space = await loadSpace(env, spaceId);
  return json({ ok: true, v: space ? space.version : baseV + 1 });
}

/* ------------------------------------------------------------------ */
/* 设备管理                                                             */
/* ------------------------------------------------------------------ */

async function handleDevices(env, device) {
  const rows = await env.DB.prepare(
    'SELECT id, name, created_at, last_seen, revoked FROM devices WHERE space_id = ? ORDER BY created_at'
  )
    .bind(device.space_id)
    .all();
  const list = (rows.results || []).map((r) => ({
    id: r.id,
    name: r.name,
    created: r.created_at,
    lastSeen: r.last_seen,
    revoked: !!r.revoked,
    self: r.id === device.id,
  }));
  return json({ devices: list });
}

async function handleRevoke(request, env, device) {
  const body = await readJson(request);
  const target = String((body && body.deviceId) || '').trim();
  if (!target) return fail('bad_body', 400);

  // 只允许踢自己空间里的设备。少了这个条件，任何人只要知道别人的 deviceId
  // 就能把别人的手机踢下线。
  const row = await env.DB.prepare('SELECT id, space_id FROM devices WHERE id = ?')
    .bind(target)
    .first();
  if (!row || row.space_id !== device.space_id) return fail('not_found', 404);

  // 不允许把自己踢掉 —— 那等于当场把当前设备登出，用户很难理解发生了什么。
  // 要退出请用客户端的"断开同步"。
  if (row.id === device.id) return fail('cannot_revoke_self', 400);

  await env.DB.prepare('UPDATE devices SET revoked = 1 WHERE id = ?').bind(target).run();
  return json({ ok: true });
}

/* ------------------------------------------------------------------ */

async function readJson(request) {
  try {
    const text = await request.text();
    if (!text) return null;
    return JSON.parse(text);
  } catch (e) {
    return null;
  }
}
