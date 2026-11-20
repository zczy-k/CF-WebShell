# 部署同步服务（照着点就行）

这份教程是给**不想碰命令行**的人看的。全程在浏览器里点，大约 10 分钟，不用花钱，不用绑银行卡。

做完你会拿到一个网址，形如 `https://starport-sync.你的名字.workers.dev`。
把这个网址填进软件的「设置 → 同步」里，多设备同步就能用了。

---

## 开始之前，先确认两件事

1. 你有一个 **Cloudflare 账号**（没有就注册一个，邮箱就行，免费）
   👉 https://dash.cloudflare.com/sign-up

2. 你手上有这两份东西（都在项目里，打开就能复制）
   - `worker-sync/schema-plain.sql` —— 建表用（**无注释版，推荐用这个**）
   - `worker-sync/src/index.js` —— 程序本体

   打不开本地文件的话，用这两个网址（打开就是纯文本，Ctrl+A 全选、Ctrl+C 复制）：

   - https://raw.githubusercontent.com/zczy-k/Starport/main/worker-sync/schema-plain.sql
   - https://raw.githubusercontent.com/zczy-k/Starport/main/worker-sync/src/index.js

---

## 第 1 步：建一个"仓库"（数据库）

登录 Cloudflare 后，在左侧菜单找：

```
Storage & Databases  →  D1 SQL Database  →  Create database
```

> 菜单英文界面。找不到就用顶部搜索框搜 **D1**。

- **Database name** 填：`starport-sync`
- 点 **Create**

✅ **做完你会看到**：多了一个叫 `starport-sync` 的库，点进去有个 **Console** 标签。

---

## 第 2 步：建表（粘贴一段 SQL）

点刚建好的那个库 → 切到 **Console**（控制台）标签。

> ⚠️ 是 **Console / 控制台**标签，不是「概览」「查询数据」。
> 概览页只有数字，没有输入框，粘进去什么都不会发生。

**先把光标点进输入框**（点一下空白处，光标开始闪），再 Ctrl+A 全选、Ctrl+V 粘贴。
最后点 **Execute / 执行**。

用哪一份？**推荐右边的**：

- 左边这份 `schema.sql` 带大量中文注释，粘到网页输入框里偶尔会粘不全
- 右边 `schema-plain.sql` 是**无注释版**，只有 8 条语句、每条一行，
  肉眼能数清楚有没有粘全，粘不进去的概率低得多

两份效果完全一样，用哪份都行。

- `worker-sync/schema-plain.sql` ← https://raw.githubusercontent.com/zczy-k/Starport/main/worker-sync/schema-plain.sql
- `worker-sync/schema.sql` ← https://raw.githubusercontent.com/zczy-k/Starport/main/worker-sync/schema.sql

✅ **做完你会看到**：下面出来一片执行结果，没有红色报错。

回到 **概览** 标签（或者刷新一下），**表数量** 应该变成 **5**：

```
spaces          devices         pair_codes
space_history   rate
```

> 少一张也没关系，只要没报错就行。这几张表是同步的全部家当。

### 如果提示 `No SQL statements detected.`

这句的意思是：**控制台在输入框里没读到任何一条能执行的语句**。不是 SQL 写错了，
是它根本没收到内容（或者只收到了一堆注释）。按顺序试：

1. **确认点对了地方** —— 必须是 `库 → 控制台` 那个带输入框的标签。
   点在「概览」页上是没有任何反应的地方。
2. **确认输入框里真有字** —— 粘完先别看按钮，先抬眼看一下输入框：
   里面应该有 `CREATE TABLE` 字样。空的就再点一下输入框、重新粘。
3. **换 `schema-plain.sql`** —— 短、无注释，粘不全的概率低很多。
4. **还不行就一条一条来** —— 把 `schema-plain.sql` 里那 8 条，
   每条单独粘一次、单独点执行。8 次点完也是 5 张表，慢但不挑浏览器。


---

## 第 3 步：建程序（Worker）

左侧菜单：

```
Workers & Pages  →  Create  →  Workers  →  Create Worker
```

- 名字填：`starport-sync`（**必须一模一样**，后面地址就是它）
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
- **D1 database** 选第 1 步建的那个 `starport-sync`
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
https://starport-sync.你的账号名.workers.dev
```

**复制下来**。这就是软件要填的「服务地址」。

> 如果提示你还没启用 `workers.dev`，页面上会有一个按钮让你启用/设置子域名，
> 点一下、随便起个名字就行。

### 先自己验一下（很重要）

浏览器新开一个标签，访问：

```
https://你的地址/v1/health
```

✅ **应该看到**：`{"ok":true,"service":"starport-sync","schema":1}`

看到这行就说明服务活了。看到别的（尤其 404 或 500）先别往下走，看最后一节「出问题怎么办」。

### 国内打不开 `workers.dev`？那就挂个自己的域名

这是**国内用户几乎一定会遇到的一步**，不是你做错了什么。

`*.workers.dev` 这个域名在国内基本不可用：浏览器一直转圈、超时、或者 `连接被重置`。
挂上自己的域名就通了 —— Worker 还是那台 Worker，数据库还是那个数据库，
只是换了个门牌号。

需要什么：**一个自己的域名**（任何注册商买的都行，几十块一年）。
服务器在境外（Cloudflare 边缘节点），所以**不需要备案**。

1. **把域名加进 Cloudflare**：控制台首页 → **Add a site** → 填你的域名 → 选 **Free** 计划
2. **去域名注册商那里改 NS**：Cloudflare 会给你两个地址（形如 `xxx.ns.cloudflare.com`），
   到买域名那家网站的「DNS / 域名服务器」设置里，把原来的 NS 换成这两个
3. **等生效**：几分钟到 24 小时不等。Cloudflare 上那个域名从 `Pending` 变成 **Active** 就好了
4. **回 Worker 挂域名**：你的 Worker → **Settings** → **Domains & Routes** → **Add** →
   选 **Custom domain** → 填一个子域名，比如 `sync.你的域名.com`
5. **等证书**：一般 1~3 分钟，页面上那个域名旁边出现一把锁就好了
6. **验一下**：浏览器打开 `https://sync.你的域名.com/v1/health`，
   应该还是那行 `{"ok":true,...}`
7. **回软件改地址**：设置 → 同步 → 点「服务地址」那一行改成新域名

✅ **改完你会看到**：同步状态自己刷新一次，站点没变、配对没丢。

> **不用重新配对，也不用重新开同步空间。** 只是换了个地址，空间还是原来那个，
> 站点清单和历史版本都在。改地址时会立刻用新地址试同步一轮，成不成看状态文字就知道。
>
> 顺序上建议**先挂域名，再在软件里开启同步** —— 省得配好一堆设备再回头改地址。


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
| 建表时提示 `No SQL statements detected.` | 控制台没读到语句（粘到别处了 / 没粘全） | 见第 2 步下面那一小节，先换 `schema-plain.sql` |
| 概览里「表数量」还是 0 | 建表没真执行成功 | 回第 2 步重做，确认执行后有一片结果输出 |
| 网址打不开 / 404 | 没启用 `workers.dev` 子域名 | Worker 页面里点启用，或改用自定义域名 |
| `/v1/health` 一直转圈、超时、连接被重置 | **`workers.dev` 在国内不可用** | 见第 7 步下面那节，挂自己的域名 |
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
npx wrangler d1 create starport-sync
# 把输出里的 database_id 填进 wrangler.toml

npx wrangler d1 execute starport-sync --remote --file=schema.sql
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

---

## 附：想把 Worker / 数据库改名（改名 = 搬家，不是重命名）

这三样东西的名字**都是不可改的**，只能新建一个、把数据搬过去、再删旧的。
改名之前先把这段话看完，能省半天：

| 东西 | 能不能直接改名 | 正确做法 |
| --- | --- | --- |
| Worker 脚本 | 不能 | 改 `wrangler.toml` 的 `name` → `wrangler deploy` 会新建一个 |
| D1 数据库 | 不能（API 的 PATCH 只认 `read_replication`，传 `name` 直接 7400 报错） | `d1 create` 新库 → 导出旧库 → 导入新库 → 改 `database_id` |
| 自定义域 | 可以，跟着部署走 | 在 `wrangler.toml` 里写 `routes = [{ pattern = "...", custom_domain = true }]` |

完整顺序（照着做，中间别跳步）：

```bash
cd worker-sync

# 1) 先把旧库整份导出（这份文件就是你的全部数据，别删）
npx wrangler d1 export 旧库名 --remote --output /tmp/migrate.sql

# 2) 建新库，记下输出里的 database_id
npx wrangler d1 create 新库名

# 3) 先把 wrangler.toml 里的 database_id 改成新库的 uuid，再导入。
#    这一步漏了会报 Invalid uuid —— 因为文件里还是占位符 / 旧 uuid。
npx wrangler d1 execute 新库名 --remote --file=/tmp/migrate.sql

# 4) 对一遍行数，两库必须一模一样
npx wrangler d1 execute 新库名 --remote --command="SELECT COUNT(*) FROM spaces;"

# 5) 把 bootstrap 密钥补到新 Worker 上（密钥值读不出来，只能重设）
npx wrangler secret put BOOTSTRAP_SECRET --name 新Worker名

# 6) 部署。routes 写在 toml 里，这一步会把自定义域从旧 Worker 上抢过来
npx wrangler deploy

# 7) 验证通了再删旧的
curl https://你的域名/v1/health
npx wrangler delete --name 旧Worker名
npx wrangler d1 delete 旧库名 -y
```

两个坑，都踩过：

- **`routes` 必须是 `wrangler.toml` 的顶层键。** 写在 `[[d1_databases]]` 下面会被
  TOML 吞进那个表，wrangler 只 warning 一句 `Unexpected fields found in
  d1_databases[0]: routes`，然后域名根本没绑上 —— 部署"成功"，线上还是老 Worker。
- **`wrangler versions list` 不会列出 `wrangler deploy` 产生的版本。**
  判断线上到底跑的是哪版，用 `npx wrangler deployments status --name <名字>`，
  或者直接看 `/v1/health` 返回的 `service` 字段。
