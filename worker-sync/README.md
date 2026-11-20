# CF-WebShell 自动同步服务

一台电脑上加了个网站，手机上自动就有了；手机上删掉，电脑上也跟着删。
中间那一站就是这个小 Worker —— 架在你自己的 Cloudflare 账号上，**不经过任何第三方服务器**。

---

## 一、它到底做了什么

只有一件事：在一组「配对过的设备」之间传一份 JSON 文档。

| 事情 | 谁负责 |
| --- | --- |
| 存文档、版本号、配对、踢设备 | **这个 Worker** |
| 判断"谁改了什么"、"删除要不要传播" | 客户端（`core/lib/src/sync/doc.dart`） |

服务端**故意不解析文档内容**。好处是：合并规则以后要改（比如加网站分组），
只发客户端就行，不用重新部署 Worker；而且日志里看到的就是一堆不透明 JSON。

一次正常同步只碰 1~2 行 D1 记录，免费额度（10 万写/天）够用很久。

---

## 二、部署（10 分钟）

需要 Node.js 18+，和 [Cloudflare 账号](https://dash.cloudflare.com)。

```bash
cd worker-sync

# 1) 建数据库，把输出里的 database_id 填进 wrangler.toml
npx wrangler d1 create cf-webshell-sync

# 2) 建表（--remote 才是真的建在线上库，别漏了）
npx wrangler d1 execute cf-webshell-sync --remote --file=schema.sql

# 3) 设"部署密钥" —— 自己编一串 32 位以上的随机字符，别用生日/手机号
#    这串东西决定了"谁能开同步空间"，它就是你的门锁。
npx wrangler secret put BOOTSTRAP_SECRET

# 4) 部署，记下输出的 https://cf-webshell-sync.<你的>.workers.dev
npx wrangler deploy
```

验证：

```bash
curl https://cf-webshell-sync.xxx.workers.dev/v1/health
# {"ok":true,"service":"cf-webshell-sync","schema":1}
```

打开 App → 设置 → **自动同步** → 填服务地址 + 部署密钥 → 「开启并配对这台设备」。
之后在任意一台已配对的设备上点「显示配对码」，另一台输进去，就完事了。
设备数量不限制，配对过的都能连。

---

## 三、为什么别人接不进你的项目

这是设计时最先定下来的一条，四道门：

1. **开空间要部署密钥。** `POST /v1/bootstrap` 必须带 `X-Bootstrap`，且
   服务端用定长比较（`safeEqual`）核对，不给时间差攻击留口子。
   没配 `BOOTSTRAP_SECRET` 时接口直接 403 —— 不存在"空密钥等于无鉴权"。
2. **数据接口只认设备 token。** 32 字节随机串，库里只存 sha256，看库也换不回凭证。
3. **URL 里没有 spaceId。** 空间归属从 token 反查。所以"猜空间 id 读别人数据"
   这条路根本不存在，也不存在越权传 `spaceId` 的可能。
4. **配对码一次性 + 10 分钟过期。** 用掉即作废，过期即作废，不需要"撤销"。

另外：每台设备每小时最多 60 次写、每个空间 2000 次；开了空间也没法拿它当免费
大容量存储刷额度。

**你自己要守住的两件事**：部署密钥别外传；别把 `wrangler.toml` 里的
`database_id` 和密钥一起提交到公开仓库（这个仓库里的 `database_id` 是占位符）。

---

## 四、接口

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| GET | `/v1/health` | 无 | 探活 |
| POST | `/v1/bootstrap` | `X-Bootstrap` | 开空间 + 注册第一台设备 |
| POST | `/v1/pair/code` | Bearer | 生成 8 位配对码 |
| POST | `/v1/pair` | 无（凭配对码） | 新设备换 token |
| GET | `/v1/head` | Bearer | `{v, updatedAt}`，轮询用 |
| GET | `/v1/doc` | Bearer | `{v, updatedAt, doc}` |
| PUT | `/v1/doc` | Bearer | `{baseV, doc}` → `{ok,v}`；版本不符返回 `409 {ok:false,v,doc}` |
| GET | `/v1/devices` | Bearer | 本空间设备列表 |
| POST | `/v1/devices/revoke` | Bearer | `{deviceId}`，踢人（不能踢自己） |

`409` 是**正常路径**不是错误：客户端拿到最新文档，三方合并后再推一次，
用户完全看不到"冲突"两个字。

---

## 五、免费额度够不够

| 项 | 免费额度 | 这套东西的花费 |
| --- | --- | --- |
| Workers 请求 | 10 万/天 | 每台设备每 60~180 秒一次 `/v1/head`，一天约 480~1400 次 |
| D1 读 | 500 万行/天 | 每次同步 1~2 行 |
| D1 写 | 10 万行/天 | 只在真有改动时才写，一天几十行 |

十台设备一年也跑不满免费额度。

## 六、为什么不用 KV

KV 免费额度是 **1000 写/天**，而且写进去之后最多 60 秒才全球可见。
"删了必须真删、不能复活"这条要求容不下这种延迟 —— 一台设备刚推完删除，
另一台 60 秒内读到的还是旧的，会把删掉的网站又推回来。D1 是强一致的，没这问题。

---

## 七、改这里之前先看一眼

- `schema.sql` 全是 `IF NOT EXISTS`，可以重复执行。
- 加字段请**只增不改**：老版本 App 读到不认识的字段会直接忽略。
- 文档体积上限默认 512 KB（`wrangler.toml` 里的 `MAX_DOC_BYTES`）。
  几百个站点 × 每个都带自定义 header 才可能碰到它。
- `MAX_DEVICES` 默认 `0` = 不限。想限制就把数字填上，超了会返回 `space_full`。