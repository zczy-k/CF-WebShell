-- CF-WebShell 同步服务 —— D1 表结构
--
-- 设计取舍：文档整份存成一列 JSON，不做行级拆表。
--   站点清单是几十条量级、一次全量读写几十 KB，拆成行只会换来一堆 JOIN 和
--   更麻烦的事务，没有收益。版本号 CAS 本身就是原子的，够用。
--
-- 注意：这段 SQL 是幂等的（都用 IF NOT EXISTS），
-- 重复执行 `wrangler d1 execute` 不会报错。

-- 一个"空间"= 一组互相同步的设备（通常是同一个人所有设备）。
CREATE TABLE IF NOT EXISTS spaces (
  id          TEXT PRIMARY KEY,          -- sp_xxx
  created_at  INTEGER NOT NULL,
  version     INTEGER NOT NULL DEFAULT 0,-- 单调递增，推送时做 CAS 基准
  doc         TEXT    NOT NULL DEFAULT '{}',
  updated_at  INTEGER NOT NULL DEFAULT 0
);

-- 设备。token 只存 sha256，库被拖走也换不回可用凭证。
CREATE TABLE IF NOT EXISTS devices (
  id          TEXT PRIMARY KEY,          -- dv_xxx
  space_id    TEXT    NOT NULL,
  name        TEXT    NOT NULL DEFAULT '',
  token_hash  TEXT    NOT NULL UNIQUE,
  created_at  INTEGER NOT NULL,
  last_seen   INTEGER NOT NULL DEFAULT 0,
  revoked     INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_devices_space ON devices (space_id);

-- 一次性配对码：新设备凭它换自己的 token。
-- 有效期 10 分钟、用一次即废 —— 不需要额外的"撤销配对码"功能。
CREATE TABLE IF NOT EXISTS pair_codes (
  code        TEXT PRIMARY KEY,
  space_id    TEXT    NOT NULL,
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL,
  used        INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_pair_expires ON pair_codes (expires_at);

-- 历史版本。每次推送成功顺手插一条，只留最近的若干版。
--
-- 它不参与合并，也不参与版本号 CAS —— 纯粹是"回去的路"。合并算法再严密也防不住
-- 输入本身就是假的（库被重建、文档损坏、某台设备把空文档推上来），那时候唯一
-- 能救用户的就是"十分钟前那一版还在"。
--
-- 代价：一次推送多写一行。免费额度 10 万行/天，一天几十次推送根本碰不到边。
CREATE TABLE IF NOT EXISTS space_history (
  space_id    TEXT    NOT NULL,
  version     INTEGER NOT NULL,
  doc         TEXT    NOT NULL,
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (space_id, version)
);

CREATE INDEX IF NOT EXISTS idx_history_created ON space_history (space_id, created_at);

-- 固定窗口限流。用一张表而不是 KV：少一个绑定，少一份额度，
-- 而且限流本来就是"写一次计数器"，正好是 D1 擅长的。
CREATE TABLE IF NOT EXISTS rate (
  key           TEXT PRIMARY KEY,
  count         INTEGER NOT NULL DEFAULT 0,
  window_start  INTEGER NOT NULL DEFAULT 0
);
