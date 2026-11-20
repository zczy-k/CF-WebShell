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

> **不想碰命令行？** 看 [**DEPLOY.md**](DEPLOY.md) —— 全程在浏览器里点点点，9 步，
> 每一步都写了"做完你应该看到什么"，还带一张「出问题怎么办」对照表。
> 本机不用装 Node，也不用装 wrangler，只要一个 Cloudflare 账号。

下面这一版是命令行版，给习惯终端的人。两条路通向同一个结果，选一条走就行。

需要 Node.js 18+，和 [Cloudflare 账号](https://dash.cloudflare.com)。

```bash
cd worker-sync

# 1) 建数据库，把输出里的 database_id 填进 wrangler.toml
npx wrangler d1 create cf-webshell-sync

# 2) 建表（--remote 才是真的建在线上库，别漏了）
npx wrangler d1 execute cf-webshell-sync --remote --file=schema.sql
#    已经部署过旧版的话，这一步要重跑一次：历史版本表是后加的，
#    全是 IF NOT EXISTS，跑第二遍不会动已有数据。

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

> ⚠️ **国内用户**：`*.workers.dev` 在国内基本不可用（转圈、超时、连接被重置）。
> 给 Worker 挂一个自己的域名（域名加进 Cloudflare → 改 NS → Worker 的
> Settings → Domains & Routes → Add custom domain）就能通，服务器在境外不用备案。
> 挂完在 App 里改一下服务地址即可，**不用重新配对**（凭证里的 endpoint 会一起改写）。
> 详细九步见 [DEPLOY.md](DEPLOY.md) 第 7 步下面那节。

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
| GET | `/v1/history` | Bearer | `{versions:[{v,createdAt,sites}]}`，新的在前 |
| POST | `/v1/history/restore` | Bearer | `{v}` → `{ok,v}`；期间别人又推了就 `409` |

`409` 是**正常路径**不是错误：客户端拿到最新文档，三方合并后再推一次，
用户完全看不到"冲突"两个字。

---

## 五、历史版本（误删的退路）

每次推送**真正写进库之后**，服务端顺手把这一版存进 `space_history`。
留最近 `HISTORY_KEEP` 版（默认 20），最多留 `HISTORY_TTL_DAYS` 天（默认 7）。
两个值都在 `wrangler.toml` 的 `[vars]` 里改，改完重新 `deploy` 就生效。

恢复走的是"**把老内容当成一次新推送**"，不是直接覆盖：

- 版本号照样 +1，其它设备下一次 `/v1/head` 一比对就知道该拉了，
  不需要额外的通知通道；
- 恢复本身也走 CAS，中途有别人推了就返回 `409`，让你重新选，
  而不是把它刚推的改动无声抹掉；
- 恢复也有独立限流（每台设备 20 次/小时），和普通推送互不占用。

App 里在**设置 → 同步 → 云端历史版本**。大面积删除被护栏拦下来时，
那条黄条上也有一个「恢复上一版」的入口 —— 那正是最需要它的时刻。

历史写失败**不会**影响推送成功：文档已经落库了，最坏情况只是这一版没留档。

---

## 六、免费额度够不够

| 项 | 免费额度 | 这套东西的花费 |
| --- | --- | --- |
| Workers 请求 | 10 万/天 | 每台设备每 60~180 秒一次 `/v1/head`，一天约 480~1400 次 |
| D1 读 | 500 万行/天 | 每次同步 1~2 行 |
| D1 写 | 10 万行/天 | 只在真有改动时才写，一天几十行 |

十台设备一年也跑不满免费额度。

## 七、为什么不用 KV

KV 免费额度是 **1000 写/天**，而且写进去之后最多 60 秒才全球可见。
"删了必须真删、不能复活"这条要求容不下这种延迟 —— 一台设备刚推完删除，
另一台 60 秒内读到的还是旧的，会把删掉的网站又推回来。D1 是强一致的，没这问题。

---

## 八、改这里之前先看一眼

- `schema.sql` 全是 `IF NOT EXISTS`，可以重复执行。
- 加字段请**只增不改**：老版本 App 读到不认识的字段会直接忽略。
- 文档体积上限默认 512 KB（`wrangler.toml` 里的 `MAX_DOC_BYTES`）。
  几百个站点 × 每个都带自定义 header 才可能碰到它。
- `MAX_DEVICES` 默认 `0` = 不限。想限制就把数字填上，超了会返回 `space_full`。
- **库里存的文档解析不出来时，一律返回 `corrupt_doc` 500，当成空文档处理是错的。**
  空文档在合并里等于"远端把站点全删了"，一次解析失败就会让所有设备跟着清空。
  宁可这一轮同步失败（用户看到重试），也不能把坏数据当真。
- 历史版本想立刻清空：`npx wrangler d1 execute cf-webshell-sync --remote
  --command="DELETE FROM space_history"`。平时靠 `HISTORY_KEEP` /
  `HISTORY_TTL_DAYS` 自动裁剪，不用管。