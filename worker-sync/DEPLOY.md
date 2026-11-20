# 部署同步服务（照着点就行）

这份教程是给**不想碰命令行**的人看的。全程在浏览器里点，大约 10 分钟，不用花钱，不用绑银行卡。

做完你会拿到一个网址，形如 `https://cf-webshell-sync.你的名字.workers.dev`。
把这个网址填进软件的「设置 → 同步」里，多设备同步就能用了。

---

## 开始之前，先确认两件事

1. 你有一个 **Cloudflare 账号**（没有就注册一个，邮箱就行，免费）
   👉 https://dash.cloudflare.com/sign-up

2. 你手上有这两份东西（都在项目里，打开就能复制）
   - `worker-sync/schema.sql` —— 建表用
   - `worker-sync/src/index.js` —— 程序本体

   打不开本地文件的话，用这两个网址（打开就是纯文本，Ctrl+A 全选、Ctrl+C 复制）：

   - https://raw.githubusercontent.com/zczy-k/CF-WebShell/main/worker-sync/schema.sql
   - https://raw.githubusercontent.com/zczy-k/CF-WebShell/main/worker-sync/src/index.js

---

## 第 1 步：建一个"仓库"（数据库）

登录 Cloudflare 后，在左侧菜单找：

```
Storage & Databases  →  D1 SQL Database  →  Create database
```

> 菜单英文界面。找不到就用顶部搜索框搜 **D1**。

- **Database name** 填：`cf-webshell-sync`
- 点 **Create**

✅ **做完你会看到**：多了一个叫 `cf-webshell-sync` 的库，点进去有个 **Console** 标签。

---

## 第 2 步：建表（粘贴一段 SQL）

点刚建好的那个库 → 切到 **Console** 标签。

把 `schema.sql` 的**全部内容**粘进去 → 点 **Execute**（或者 Run）。

✅ **做完你会看到**：下面出来一片执行结果，没有红色报错。

回到库的 **Tables** 标签，应该看到 5 张表：

```
spaces          devices         pair_codes
space_history   rate
```

> 少一张也没关系，只要没报错就行。这几张表是同步的全部家当。

---

## 第 3 步：建程序（Worker）

左侧菜单：

```
Workers & Pages  →  Create  →  Workers  →  Create Worker
```

- 名字填：`cf-webshell-sync`（**必须一模一样**，后面地址就是它）
- 点 **Deploy**（它先给你部署一个默认的 Hello World，别管）

✅ **做完你会看到**：一个写着 "Hello World" 的页面。

---

## 第 4 步：换成真正的程序

在那个 Hello World 页面上，点右上角 **Edit code**（编辑代码）。

1. 左边代码框里**全选、删除**（Ctrl+A、Delete），删干净
2. 把 `index.js` 的**全部内容**粘进去
3. 点右上角 **Deploy**（部署）

✅ **做完你会看到**：提示部署成功。

---

## 第 5 步：把程序和数据库接上

这一步最容易漏，漏了所有请求都会报错。

回到这个 Worker 的页面 → **Settings**（设置）→ 找 **Bindings**（绑定）→ **Add** → 选 **D1 database**

- **Variable name**（变量名）填：`DB` ← **只能是大写 DB，填别的程序找不到库**
- **D1 database** 选第 1 步建的那个 `cf-webshell-sync`
- 保存（Save / Deploy）

✅ **做完你会看到**：Bindings 列表里有一行，名字是 `DB`。

---

## 第 6 步：设一个"门锁密码"

这个密码决定**只有你能开启同步空间**。别人就算知道了你的网址，没有它也接不进来。

同一个页面的 **Settings** → **Variables and Secrets**（变量和密钥）→ **Add**

- **Type**（类型）选 **Secret**（密钥）← ⚠️ 千万别选 Text，选错了密码会明文显示
- **Variable name** 填：`BOOTSTRAP_SECRET`
- **Value** 填一串你自己编的随机字符，**至少 40 位**

> **怎么弄一串够乱的？** 随便敲键盘，别用生日、手机号、`123456`。
> 比如：`kR7pXq2mWz9vTn4bLs8dYf6hJc3gVa5uNe1oQi0tMrPx`
>
> **这串东西丢了怎么办？** 重新设一次就行，已经配好对的设备不受影响 ——
> 它只在"第一次开启同步空间"的时候用一次。

保存。

---

## 第 7 步：拿到你的网址

回到 Worker 的首页（Overview），页面上会有一个网址，长这样：

```
https://cf-webshell-sync.你的账号名.workers.dev
```

**复制下来**。这就是软件要填的「服务地址」。

> 如果提示你还没启用 `workers.dev`，页面上会有一个按钮让你启用/设置子域名，
> 点一下、随便起个名字就行。

### 先自己验一下（很重要）

浏览器新开一个标签，访问：

```
https://你的地址/v1/health
```

✅ **应该看到**：`{"ok":true,"service":"cf-webshell-sync","schema":1}`

看到这行就说明服务活了。看到别的（尤其 404 或 500）先别往下走，看最后一节「出问题怎么办」。

---

## 第 8 步：在软件里开启

1. 打开软件 → **设置** → **同步**
2. **服务地址**：粘贴第 7 步那个网址（**末尾不要带斜杠 `/`**）
3. **部署密钥**：填第 6 步那串
4. 点 **「开启同步（本机作为第一台设备）」**

✅ **做完你会看到**：状态变成「已上传本机改动」，下面写着上次同步时间。

---

## 第 9 步：第二台设备接进来

在**已经同步的那台**设备上：

```
设置 → 同步 → 显示配对码
```

会出来一组 **8 位码**，10 分钟内有效、只能用一次。

在**新设备**上：

```
设置 → 同步 → 服务地址填同一个网址 → 用配对码加入 → 填那 8 位码
```

✅ **做完你会看到**：两台设备的站点列表变成一样。

之后再怎么加站、删站、改设置，两边都会自己跟上（一般几十秒内）。
**设备数量不限**，配对过的都能连。

---

## 出问题怎么办

先看这个表，八成能自己对上：

| 你看到的 | 原因 | 怎么办 |
| --- | --- | --- |
| 网址打不开 / 404 | 没启用 `workers.dev` 子域名 | Worker 页面里点启用，或改用自定义域名 |
| `/v1/health` 返回 500，写着 `no such table` | 第 2 步没做，或者做在了本地库上 | 回去重做第 2 步，确认是在 D1 的 Console 里执行的 |
| `/v1/health` 返回 500，别的错 | 第 5 步的绑定没加，或者变量名不是 `DB` | 检查 Bindings 里是不是正好一个 `DB` |
| 软件里点开启，提示「密钥不对」 | 第 6 步的名字打错了 | 变量名必须正好是 `BOOTSTRAP_SECRET`，全大写 |
| 软件里点开启，提示「连不上」 | 网址填错，或多了末尾斜杠 | 只填到 `.workers.dev` 为止 |
| 第二台设备配对码说「过期」 | 配对码只有 10 分钟 | 在那台设备上重新点一次「显示配对码」 |
| 同步了但站点没变 | 还在排队（最多几十秒） | 点一下「立即同步」按钮 |
| 突然所有站点都没了 | 触发了「大面积删除」保护 | 见下面 |

### 关于「检测到一次大量删除」

如果一次同步会让这台设备少掉一半以上的站点，程序会**停下来等你确认**，不会直接执行。
设置页会出现一条黄色警告，两个按钮：

- **确认删除 N 个** —— 是你自己在另一台设备上删的，点这个
- **恢复上一版** —— 不是你干的，点这个退回之前某一版

这是故意做的。同步最怕的不是"没同步上"，是"同步错了把你的东西删光"。

### 都不对劲

把下面三样贴给开发者，能省很多来回：

1. `/v1/health` 打出来的原文
2. 软件里「同步」那块显示的完整状态文字
3. Cloudflare 后台 → 你的 Worker → **Logs**（日志）里最近几条

---

## 附：会命令行的话，这样更快

```bash
cd worker-sync

npx wrangler login
npx wrangler d1 create cf-webshell-sync
# 把输出里的 database_id 填进 wrangler.toml

npx wrangler d1 execute cf-webshell-sync --remote --file=schema.sql
npx wrangler secret put BOOTSTRAP_SECRET
npx wrangler deploy
```

⚠️ `--remote` 不能漏：漏了就建在本地，线上还是空的。

---

## 附：以后想改配置

`wrangler.toml` 里那些数字（比如历史版本留几版 `HISTORY_KEEP`）**不填也能用**，程序里有默认值：

| 配置 | 默认 | 意思 |
| --- | --- | --- |
| `MAX_DOC_BYTES` | 512 KB | 一份站点清单最大多大 |
| `RATE_WRITES_PER_HOUR` | 60 | 每台设备每小时最多推几次 |
| `RATE_SPACE_PER_HOUR` | 2000 | 所有设备加起来每小时最多几次 |
| `MAX_DEVICES` | 0（不限） | 最多几台设备 |
| `PAIR_TTL_SECONDS` | 600 | 配对码几分钟有效 |
| `HISTORY_KEEP` | 20 | 历史版本留几版 |
| `HISTORY_TTL_DAYS` | 7 | 历史版本留几天 |

网页上改：Worker → Settings → Variables and Secrets，名字和值照抄，类型选 **Text**（不是 Secret）。
改完要重新 Deploy 一次才生效。
