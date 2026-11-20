# 同步服务（Cloudflare Worker + D1）

一台设备加的网站，另一台自动就有；一台删的，另一台跟着删（删除要二次确认）。
中间那一站就是这个小 Worker —— 架在**你自己的** Cloudflare 账号上，不经过任何第三方服务器。

相关文档：

- [**DEPLOY.md**](DEPLOY.md) —— 网页部署教程（点点点，推荐，不用装工具）
- [DEPLOY-CLI.md](DEPLOY-CLI.md) —— 命令行部署、改名搬家、踩过的坑
- [**INTERNALS.md**](INTERNALS.md) —— 内部细节：鉴权模型、接口、历史版本、额度、改代码前必读

---

## 部署（命令行速查）

> 不想碰命令行 → [DEPLOY.md](DEPLOY.md)，全程浏览器点，约 10 分钟。
> 命令行完整版（改名搬家、踩坑）→ [DEPLOY-CLI.md](DEPLOY-CLI.md)。

需要 Node.js 18+，和 [Cloudflare 账号](https://dash.cloudflare.com)。

```bash
cd worker-sync

# wrangler.toml 两样都填好了：
#   database_id = "4f6150aa-4580-479c-87f5-1e7ca6fb7e28"  ← 线上那个 D1 库
#   routes      = [{ pattern = "starport.zczy6.dpdns.org", custom_domain = true }]  ← 顶层键

# 1) 建表（--remote 才是真的建在线上库，别漏了）
npx wrangler d1 execute starport-sync --remote --file=schema.sql
#    已部署过旧版要重跑一次：全是 IF NOT EXISTS，跑第二遍不动已有数据。

# 2) 设"部署密钥" —— 自己编一串 40 位以上的随机字符，它就是门锁
npx wrangler secret put BOOTSTRAP_SECRET

# 3) 部署。域名跟着 routes 一起绑好，不用再去后台点 Domains & Routes
npx wrangler deploy
#    输出末行：starport.zczy6.dpdns.org (custom domain)
```

后台 Settings → Variables and Secrets 里会看到 8 个变量：1 个 Secret
（`BOOTSTRAP_SECRET`）加 7 个 Text。那 7 个是 `wrangler.toml` 的 `[vars]` 自动上传的，
值见文件里的注释；不部署 toml（网页点点点）时它们不会出现，因为代码里有同值默认值兜底。

验证：

```bash
curl https://starport.zczy6.dpdns.org/v1/health
# {"ok":true,"service":"starport-sync","schema":1}
```

换自己的库 / 域名时，只改 `wrangler.toml` 的 `database_id` 和顶层 `routes` 的 `pattern`。
`routes` 千万别写在 `[[d1_databases]]` 下面 —— TOML 会吞掉它，域名绑不上还只给一句 warning。

## App 里连上

设置 → **自动同步** → 填服务地址 + 部署密钥 → 「开启并配对这台设备」。
其它设备：已配对的设备上点「显示配对码」，新设备输进去就完事。**设备数量不限**。

> ⚠️ **国内用户**：`*.workers.dev` 在国内基本不可用，本配置已经把自定义域
> `starport.zczy6.dpdns.org` 写进 `routes`，`deploy` 后直接用这个域名。
> 要换自己的域名，改 `routes[0].pattern` 再 `deploy`；App 里跟着改服务地址即可，
> **不用重新配对**。步骤见 [DEPLOY.md](DEPLOY.md) 第 7 步。