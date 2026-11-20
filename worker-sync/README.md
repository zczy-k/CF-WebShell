# 同步服务（Cloudflare Worker + D1）

一台设备加的网站，另一台自动就有；一台删的，另一台跟着删（删除要二次确认）。
中间那一站就是这个小 Worker —— 架在**你自己的** Cloudflare 账号上，不经过任何第三方服务器。

相关文档：

- [**DEPLOY.md**](DEPLOY.md) —— 部署教程（网页点点点，推荐）；含「国内挂自定义域名」
- [**INTERNALS.md**](INTERNALS.md) —— 内部细节：鉴权模型、接口、历史版本、额度、改代码前必读

---

## 部署（命令行版）

> 不想碰命令行 → [DEPLOY.md](DEPLOY.md)，全程浏览器点，约 10 分钟。

需要 Node.js 18+，和 [Cloudflare 账号](https://dash.cloudflare.com)。

```bash
cd worker-sync

# 1) 建数据库，把输出里的 database_id 填进 wrangler.toml
npx wrangler d1 create starport-sync

# 2) 建表（--remote 才是真的建在线上库，别漏了）
npx wrangler d1 execute starport-sync --remote --file=schema.sql
#    已部署过旧版要重跑一次：全是 IF NOT EXISTS，跑第二遍不动已有数据。

# 3) 设"部署密钥" —— 自己编一串 32 位以上的随机字符，它就是门锁
npx wrangler secret put BOOTSTRAP_SECRET

# 4) 部署，记下输出的 https://starport-sync.<你的>.workers.dev
npx wrangler deploy
```

验证：

```bash
curl https://starport-sync.xxx.workers.dev/v1/health
# {"ok":true,"service":"starport-sync","schema":1}
```

## App 里连上

设置 → **自动同步** → 填服务地址 + 部署密钥 → 「开启并配对这台设备」。
其它设备：已配对的设备上点「显示配对码」，新设备输进去就完事。**设备数量不限**。

> ⚠️ **国内用户**：`*.workers.dev` 在国内基本不可用。给 Worker 挂自己的域名就能通
> （服务器在境外，不用备案），挂完在 App 里改一下服务地址即可，**不用重新配对**。
> 步骤见 [DEPLOY.md](DEPLOY.md) 第 7 步下面那节。