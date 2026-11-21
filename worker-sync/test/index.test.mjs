import assert from 'node:assert/strict';
import test from 'node:test';
import worker from '../src/index.js';

class MockDB {
  constructor({ deviceRate = null, spaceDoc = '{}' } = {}) {
    this.deviceRate = deviceRate;
    this.spaceDoc = spaceDoc;
    this.spaceWrites = 0;
  }

  prepare(sql) {
    const db = this;
    return {
      values: [],
      bind(...values) {
        this.values = values;
        return this;
      },
      async first() {
        if (sql.includes('SELECT count, window_start FROM rate')) {
          if (this.values[0] === 'w:device' && db.deviceRate !== null) {
            return { count: db.deviceRate, window_start: Date.now() };
          }
          return null;
        }
        if (sql.includes('FROM devices WHERE token_hash = ?')) {
          return {
            id: 'device',
            space_id: 'space',
            name: 'test device',
            revoked: 0,
            last_seen: Date.now(),
          };
        }
        if (sql.includes('FROM spaces WHERE id = ?')) {
          return { id: 'space', version: 0, doc: db.spaceDoc, updated_at: 0 };
        }
        return null;
      },
      async run() {
        if (sql.startsWith('UPDATE spaces SET doc =')) db.spaceWrites++;
        return { meta: { changes: 1 } };
      },
      async all() {
        return { results: [] };
      },
    };
  }
}

function env(db, extras = {}) {
  return {
    DB: db,
    MAX_DOC_BYTES: '524288',
    ...extras,
  };
}

function docRequest(doc, options = {}) {
  const payload = options.payload ?? JSON.stringify({ baseV: 0, doc });
  return new Request('https://worker.test/v1/doc', {
    method: 'PUT',
    headers: { authorization: 'Bearer test-token-0123456789', 'content-type': 'application/json' },
    body: payload,
  });
}

test('PUT limits serialized document by UTF-8 byte length, including multibyte text', async () => {
  const doc = { text: '😀' };
  const docBytes = new TextEncoder().encode(JSON.stringify(doc)).byteLength;

  const tooLargeDb = new MockDB();
  const tooLarge = await worker.fetch(docRequest(doc), env(tooLargeDb, { MAX_DOC_BYTES: String(docBytes - 1) }));
  assert.equal(tooLarge.status, 413);
  assert.equal((await tooLarge.json()).error, 'too_large');
  assert.equal(tooLargeDb.spaceWrites, 0);

  const exactDb = new MockDB();
  const exact = await worker.fetch(docRequest(doc), env(exactDb, { MAX_DOC_BYTES: String(docBytes) }));
  assert.equal(exact.status, 200);
  assert.equal(exactDb.spaceWrites, 1);
});

test('PUT rejects array, null, and non-object document values', async () => {
  for (const doc of [[], null, 'text', 42]) {
    const response = await worker.fetch(docRequest(doc), env(new MockDB()));
    assert.equal(response.status, 400);
    assert.equal((await response.json()).error, 'bad_body');
  }
});

test('stored array and null documents are treated as corrupt', async () => {
  for (const stored of ['[]', 'null']) {
    const response = await worker.fetch(new Request('https://worker.test/v1/doc', {
      headers: { authorization: 'Bearer test-token-0123456789' },
    }), env(new MockDB({ spaceDoc: stored })));
    assert.equal(response.status, 500);
    assert.equal((await response.json()).error, 'corrupt_doc');
  }
});

test('PUT rejects an oversized streaming request before reading it fully', async () => {
  let cancelled = false;
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array(40 * 1024));
      controller.enqueue(new Uint8Array(30 * 1024));
    },
    cancel() {
      cancelled = true;
    },
  });
  const request = new Request('https://worker.test/v1/doc', {
    method: 'PUT',
    headers: { authorization: 'Bearer test-token-0123456789', 'content-type': 'application/json' },
    body: stream,
    duplex: 'half',
  });
  const response = await worker.fetch(request, env(new MockDB(), { MAX_DOC_BYTES: '0' }));
  assert.equal(response.status, 413);
  assert.equal(cancelled, true);
});

test('write rate limit remains enforced and normal JSON responses include CORS', async () => {
  const limitedDb = new MockDB({ deviceRate: 1 });
  const limited = await worker.fetch(docRequest({ ok: true }), env(limitedDb, {
    RATE_WRITES_PER_HOUR: '1',
  }));
  assert.equal(limited.status, 429);
  assert.equal(limitedDb.spaceWrites, 0);
  assert.equal(limited.headers.get('access-control-allow-origin'), '*');

  const health = await worker.fetch(new Request('https://worker.test/v1/health'), env(new MockDB()));
  assert.equal(health.status, 200);
  assert.equal(health.headers.get('access-control-allow-origin'), '*');

  const preflight = await worker.fetch(new Request('https://worker.test/v1/doc', { method: 'OPTIONS' }), env(new MockDB()));
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('access-control-allow-origin'), '*');
});
