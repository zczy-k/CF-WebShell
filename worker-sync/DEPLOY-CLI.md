# 同步服务部署（命令行版）

这份是给**装了 Node.js、愿意敲命令**的人看的。
只想用鼠标点网页的人请走 [DEPLOY.md](DEPLOY.md)，那份从头到尾不用装任何工具。

两条路互不混用：网页部署出来的 Worker 没有 `wrangler.toml` 里的 `[vars]`，
命令行部署会把它们自动上传。以后要长期改配置，固定走其中一条。

---

## 首次部署

本仓库的 `wrangler.toml` 已经把 `database_id`、`routes`、`[vars]` 全配好了，
**不用改任何占位符**：

```bash
cd worker-sync

npx wrangler login
npx wrangler d1 execute starport-sync --remote --file=schema.sql
npx wrangler secret put BOOTSTRAP_SECRET
npx wrangler deploy
```

- `--remote` 不能漏：漏了就建在本地库，线上还是空的。
- `BOOTSTRAP_SECRET` 至少 40 位随机字符。
- `npx wrangler deploy` 输出末行会列出 `routes` 里写的域名 `(custom domain)`，
  比如本仓库的 `starport.zczy6.dpdns.org (custom domain)`。
  没出现这一行 = 域名没绑上，往下看「坑」。

验证：

```bash
curl https://starport.zczy6.dpdns.org/v1/health
# {"ok":true,"service":"starport-sync","schema":1}
```

---

## fork 出去自己部署：要改两处

`wrangler.toml` 里的值对应本仓库线上那个库。你 fork 后要换成自己的：

```toml
routes = [
  { pattern = "sync.你的域名.com", custom_domain = true }
]

[[d1_databases]]
binding = "DB"
database_name = "starport-sync"
database_id = "你自己建的库 uuid"
```

建库拿 uuid：

```bash
npx wrangler d1 create starport-sync
```

---

## 那 7 个变量哪来的

部署后到 Cloudflare 后台 `Settings → Variables and Secrets`，会看到 1 个 Secret
（`BOOTSTRAP_SECRET`）和 7 个 Text 变量。后者来自 `wrangler.toml` 的 `[vars]` 段，
是 `wrangler deploy` 自动上传的，不用手填：

| 配置 | 默认 | 意思 |
| --- | --- | --- |
| `MAX_DOC_BYTES` | `524288` | 一份站点清单最大多大 |
| `RATE_WRITES_PER_HOUR` | `60` | 每台设备每小时最多推几次 |
| `RATE_SPACE_PER_HOUR` | `2000` | 所有设备加起来每小时最多几次 |
| `MAX_DEVICES` | `0` | 最多几台设备，`0` = 不限 |
| `PAIR_TTL_SECONDS` | `600` | 配对码几分钟有效 |
| `HISTORY_KEEP` | `20` | 云端历史版本留几版 |
| `HISTORY_TTL_DAYS` | `7` | 云端历史版本留几天 |

代码里 `intEnv(env.XXX, 默认值)` 有同样的兜底，所以网页部署不上传它们也能跑。
⚠️ 命令行 `deploy` 会用 toml 的 `[vars]` **覆盖**后台手动改过的同名变量。

---

## 想改名 = 搬家，不是重命名

Worker 脚本名、D1 库名都改不了，只能新建一个、把数据搬过去、再删旧的。
自定义域是唯一能直接改的，跟着 `wrangler.toml` 的 `routes` 走。

| 东西 | 直接改名 | 正确做法 |
| --- | --- | --- |
| Worker 脚本 | 不行 | 改 `wrangler.toml` 的 `name` → `wrangler deploy` 新建 |
| D1 数据库 | 不行（API 传 `name` 报 7400） | `d1 create` 新库 → 导出旧库 → 导入新库 → 换 `database_id` |
| 自定义域 | 可以 | 改顶层 `routes` 的 `pattern` |

顺序（别跳步）：

```bash
cd worker-sync

# 1) 导出旧库（这份就是你的全部数据，别删）
npx wrangler d1 export 旧库名 --remote --output /tmp/migrate.sql

# 2) 建新库，记下输出的 database_id
npx wrangler d1 create 新库名

# 3) 先把 wrangler.toml 的 database_id 换成新库 uuid，再导入。
#    漏了这步会报 Invalid uuid（文件里还是旧的 / 占位符）
npx wrangler d1 execute 新库名 --remote --file=/tmp/migrate.sql

# 4) 对一遍行数，两库必须一致
npx wrangler d1 execute 新库名 --remote --command="SELECT COUNT(*) FROM spaces;"

# 5) bootstrap 密钥读不出来，只能在新 Worker 上重设
npx wrangler secret put BOOTSTRAP_SECRET --name 新Worker名

# 6) 部署。routes 写在 toml 顶层，这一步会把自定义域从旧 Worker 抢过来
npx wrangler deploy

# 7) 验证通了再删旧的
curl https://你的域名/v1/health
npx wrangler delete --name 旧Worker名
npx wrangler d1 delete 旧库名 -y
```

---

## 坑（都踩过）

- **`routes` 必须是顶层键。** 写在 `[[d1_databases]]` 下面会被 TOML 吞进那个表，
  wrangler 只 warning 一句 `Unexpected fields found in d1_databases[0]: routes`，
  部署显示成功、域名根本没绑上 —— 线上还是老 Worker 在应答。

- **`wrangler versions list` 不列 `wrangler deploy` 产生的版本。**
  判断线上跑的是哪版，用：

  ```bash
  npx wrangler deployments status --name starport-sync
  ```

  或者直接看 `/v1/health` 返回的 `service` 字段。

- **同名覆盖才有效。** 换名部署会新建一个空 Worker，自定义域还挂在旧的上面，
  客户端连不上。要换名就按上面「搬家」整套走。

---

[← 回网页部署说明](DEPLOY.md) · [内部细节](INTERNALS.md) · [命令行速查](README.md)
