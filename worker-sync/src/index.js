/**
 * Starport 自动同步服务 —— Cloudflare Worker + D1。
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
const CORS_HEADERS = { 'access-control-allow-origin': '*' };
const BODY_TOO_LARGE = Symbol('body-too-large');

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */

function json(data, status = 200, extra) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS_HEADERS, ...JSON_HEADERS, ...(extra || {}) },
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
          ...CORS_HEADERS,
          'access-control-allow-headers': 'authorization,content-type,x-bootstrap',
          'access-control-allow-methods': 'GET,POST,PUT,OPTIONS',
          'access-control-max-age': '86400',
        },
      });
    }

    try {
      // 探活 —— 客户端"测试连接"按钮用它，不需要凭证
      if (path === '/v1/health' && request.method === 'GET') {
        return json({ ok: true, service: 'starport-sync', schema: 1 });
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
      if (path === '/v1/history' && request.method === 'GET') {
        return await handleHistory(env, device);
      }
      if (path === '/v1/history/restore' && request.method === 'POST') {
        return await handleRestore(request, env, device, now);
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

  // 成功路径也要限流。密钥万一外泄，别人能无限开新空间 —— 数据他读不到
  // （空间归属从 token 反查），但每次开空间都是 2 行写入，能把 D1 额度刷干。
  // 正常用户一辈子只走一次这个接口，5 次/小时已经很宽松了。
  const openOk = await rateTake(env, `bootok:${clientIp(request)}`, 5, 3600 * 1000, now);
  if (!openOk) return fail('rate_limited', 429);

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

  // 限流窗口的行是只增不减的：退役的设备、换过的 IP 会永久占一行。
  // 跑两年能攒到几千行，虽然不影响正确性，但没必要留着。顺手清一天前的。
  await env.DB.prepare('DELETE FROM rate WHERE window_start < ?')
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
  const doc = parseDoc(space.doc);
  if (doc === null) {
    // 文档坏了必须让客户端停手，绝不能返回一份"什么站点都没有"。
    // 空文档在客户端眼里等于"所有站点都被删了"，接着就是全量墓碑推上来 ——
    // 一份坏数据能连带清空所有设备。500 会被客户端翻成"连不上"，原地等下一轮。
    return fail('corrupt_doc', 500);
  }
  return json({ v: space.version, updatedAt: space.updated_at, doc });
}

/** 解析服务端存的 JSON。坏了返回 null（调用方必须当成错误处理，不能当成空文档）。 */
function parseDoc(text) {
  try {
    const v = JSON.parse(text || '{}');
    return v && typeof v === 'object' && !Array.isArray(v) ? v : null;
  } catch (e) {
    return null;
  }
}

/**
 * 每台设备每小时最多推几次 —— 写历史版本和限流窗口都要跟着它走，
 * 保证"一次成功推送的副作用"是可控的一小撮行。
 */
function keepHistory(env, spaceId, version, docText, now) {
  // ★ 结尾的 .run() 是命门：prepare().bind() 只拼语句、不执行，await 一个语句
  // 对象等于什么也没干，而且**不报错**。漏掉它的症状是"推送一切正常、版本号
  // 一直涨、历史版本永远是空的"，查起来能查一整天。
  return env.DB.prepare(
    'INSERT OR REPLACE INTO space_history (space_id, version, doc, created_at) VALUES (?, ?, ?, ?)'
  )
    .bind(spaceId, version, docText, now)
    .run();
}

async function trimHistory(env, spaceId, now, keep, ttlMs) {
  // 只留最近 keep 版，再顺手清掉过期的。两条 DELETE 比在列表页里做过滤便宜。
  await env.DB.prepare(
    'DELETE FROM space_history WHERE space_id = ? AND version NOT IN ' +
      '(SELECT version FROM space_history WHERE space_id = ? ORDER BY version DESC LIMIT ?)'
  )
    .bind(spaceId, spaceId, keep)
    .run();
  await env.DB.prepare('DELETE FROM space_history WHERE space_id = ? AND created_at < ?')
    .bind(spaceId, now - ttlMs)
    .run();
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

  const maxBytes = Math.max(0, intEnv(env.MAX_DOC_BYTES, 524288));
  // Bound the raw request too, while leaving room for the JSON envelope and formatting.
  const maxRequestBytes = Math.min(Number.MAX_SAFE_INTEGER, maxBytes * 6 + 64 * 1024);
  const body = await readJson(request, maxRequestBytes);
  if (body === BODY_TOO_LARGE) return fail('too_large', 413);
  if (!body || typeof body !== 'object' || Array.isArray(body)) return fail('bad_body', 400);

  const baseV = Number.isFinite(body.baseV) ? body.baseV : -1;
  if (baseV < 0) return fail('bad_body', 400);

  const doc = body.doc;
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return fail('bad_body', 400);

  const text = JSON.stringify(doc);
  if (new TextEncoder().encode(text).byteLength > maxBytes) {
    return fail('too_large', 413);
  }

  // 空间 id 一律从 token 反查，客户端传什么都不看 —— 这样"越权写别人的空间"
  // 这条路连入口都不存在（连猜都不用防）。
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
    const current = parseDoc(space.doc);
    if (current === null) return fail('corrupt_doc', 500);
    return json({ ok: false, v: space.version, doc: current }, 409);
  }

  const newVersion = baseV + 1;

  // 写历史放在 CAS 成功之后：只有真正成为"某一版"的文档才值得留档。
  // 曾经先写历史再 CAS，结果被 409 顶回来的那些都没进库，历史里留了一堆
  // 从没生效过的中间态 —— 恢复的时候会捞到一份不存在过的状态。
  try {
    await keepHistory(env, spaceId, newVersion, text, now);
    const keep = intEnv(env.HISTORY_KEEP, 20);
    const ttl = intEnv(env.HISTORY_TTL_DAYS, 7) * 24 * 3600 * 1000;
    await trimHistory(env, spaceId, now, keep, ttl);
  } catch (e) {
    // 历史写失败不能让一次成功的推送变成失败：文档已经落库了，
    // 客户端那边版本号也已经生效。最坏情况是这一版没进历史。
    console.error('history write failed', e && e.stack ? e.stack : e);
  }

  return json({ ok: true, v: newVersion });
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
/* 历史版本                                                             */
/* ------------------------------------------------------------------ */

async function handleHistory(env, device) {
  // 文档本体不返回 —— 列表页只要"第几版、什么时候、几个站点"。
  const rows = await env.DB.prepare(
    'SELECT version, doc, created_at FROM space_history WHERE space_id = ? ORDER BY version DESC LIMIT 50'
  )
    .bind(device.space_id)
    .all();

  const versions = (rows.results || []).map((r) => {
    let sites = 0;
    const doc = parseDoc(r.doc);
    if (doc && doc.sites && typeof doc.sites === 'object') {
      for (const k of Object.keys(doc.sites)) {
        const s = doc.sites[k];
        if (!s || s.deleted !== true) sites++;
      }
    }
    return { v: r.version, createdAt: r.created_at, sites };
  });

  return json({ versions });
}

async function handleRestore(request, env, device, now) {
  // 恢复本身也是一次写，单独一套额度：用完了推不上去还能恢复，这个优先级更高。
  const ok = await rateTake(env, `rs:${device.id}`, 20, 3600 * 1000, now);
  if (!ok) return fail('rate_limited', 429);

  const body = await readJson(request);
  const want = Number.isFinite(body && body.v) ? body.v : -1;
  if (want < 0) return fail('bad_body', 400);

  const spaceId = device.space_id;
  const row = await env.DB.prepare(
    'SELECT version, doc FROM space_history WHERE space_id = ? AND version = ?'
  )
    .bind(spaceId, want)
    .first();
  if (!row) return fail('no_history', 404);

  // 校验一下这一版本身没坏。坏的那版捞回去等于把坏数据重新推一遍。
  if (parseDoc(row.doc) === null) return fail('corrupt_doc', 500);

  const space = await loadSpace(env, spaceId);
  if (!space) return fail('not_found', 404);

  // 走 CAS，不直接覆盖：万一这中间又有设备推了新东西，宁可让调用方拿到 409
  // 重新决定，也不能把它刚推的改动无声地抹掉。
  const nextV = space.version + 1;
  const res = await env.DB.prepare(
    'UPDATE spaces SET doc = ?, version = ?, updated_at = ? WHERE id = ? AND version = ?'
  )
    .bind(row.doc, nextV, now, spaceId, space.version)
    .run();

  if (!res.meta || res.meta.changes !== 1) {
    const latest = parseDoc(space.doc);
    if (latest === null) return fail('corrupt_doc', 500);
    return json({ ok: false, v: space.version, doc: latest }, 409);
  }

  try {
    await keepHistory(env, spaceId, nextV, row.doc, now);
    // 恢复也要跟着裁剪：不然反复"恢复 → 恢复 → 恢复"会让历史表一直长，
    // 每次恢复都往里面塞一行，而正常推送那条路的裁剪又未必轮得到。
    const keep = intEnv(env.HISTORY_KEEP, 20);
    const ttl = intEnv(env.HISTORY_TTL_DAYS, 7) * 24 * 3600 * 1000;
    await trimHistory(env, spaceId, now, keep, ttl);
  } catch (e) {
    console.error('history write failed', e && e.stack ? e.stack : e);
  }

  return json({ ok: true, v: nextV });
}

/* ------------------------------------------------------------------ */

async function readJson(request, maxBytes = Infinity) {
  try {
    if (Number.isFinite(maxBytes)) {
      const contentLength = request.headers.get('content-length');
      if (/^\d+$/.test(contentLength || '') && Number(contentLength) > maxBytes) {
        return BODY_TOO_LARGE;
      }

      if (request.body && typeof request.body.getReader === 'function') {
        const reader = request.body.getReader();
        const chunks = [];
        let total = 0;
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          total += value.byteLength;
          if (total > maxBytes) {
            try {
              await reader.cancel();
            } catch (e) {
              // The request is already rejected; cancellation failure is non-fatal.
            }
            return BODY_TOO_LARGE;
          }
          chunks.push(value);
        }

        const bytes = new Uint8Array(total);
        let offset = 0;
        for (const chunk of chunks) {
          bytes.set(chunk, offset);
          offset += chunk.byteLength;
        }
        const text = new TextDecoder().decode(bytes);
        if (!text) return null;
        return JSON.parse(text);
      }
    }

    const text = await request.text();
    if (!text) return null;
    if (Number.isFinite(maxBytes) && new TextEncoder().encode(text).byteLength > maxBytes) {
      return BODY_TOO_LARGE;
    }
    return JSON.parse(text);
  } catch (e) {
    return null;
  }
}
