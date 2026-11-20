# Starport —— 星港

<img src="docs/hero.png" alt="把任意网站装进自己的 App" width="220" align="right">

把**任意网站**装进一个自己的 Android / Windows App 里：翻页、登录、上传、下载都和浏览器一样，
而且下载直接落到本机。不依赖用户装没装浏览器（用的是系统自带的网页引擎：Android WebView / Windows WebView2）。

---

## 从这里开始

一共四条路，按你想干的事挑一条：

| 我想…… | 去哪儿 |
| --- | --- |
| **打出自己的 App**（改个名字、图标、预置站点） | [**docs/BUILD.md**](docs/BUILD.md) —— CI 出包、白标参数表、图标规则、签名 |
| **开多设备自动同步**（电脑加的站手机自动有） | [**worker-sync/DEPLOY.md**](worker-sync/DEPLOY.md) —— 全程浏览器点，9 步，10 分钟，免费 |
| **装上之后怎么用 / 出问题怎么查** | [**docs/USAGE.md**](docs/USAGE.md) —— 界面说明、功能清单、排错对照表 |
| **搞懂为什么这么设计** | [**ARCHITECTURE.md**](ARCHITECTURE.md) —— 平台限制、能力矩阵、每一步取舍的来龙去脉 |

最快的一条：**fork 这个仓库 → 改代码 push → Actions 里下 APK / ZIP**，不用配任何参数。

---

## 两样东西，一份代码

| | 通用版 | 白标版 |
| --- | --- | --- |
| 启动后 | 站点列表（空的），自己点"添加站点" | 直接是那个网站，名字/图标/主题色都是它的 |
| 适合 | 自用浏览器壳、内网多系统入口 | 给客户/同事发一个"专属 App" |
| 怎么出 | push 就自动打 | Actions → Run workflow，填 10 个参数 |

白标版不是另开分支 —— 只是构建时覆盖了 `assets/preset.json`、`pubspec.yaml` 的版本行和图标。
参数说明、图标优先级、**版本号怎么定**见 [BUILD.md](docs/BUILD.md) §一。

---

## 自动同步要自己架一个中转站

一台设备加了站点，另一台自动就有；一台删了，另一台跟着删（删除要二次确认）。
偏好设置、图标一起同步。**设备数量不限**，配对过就行。

中转站是一个 Cloudflare Worker + D1，架在**你自己的**账号上：数据是你的，
不经过任何第三方服务器，免费额度十台设备一年都跑不满。

- 不想碰命令行 → [**DEPLOY.md**](worker-sync/DEPLOY.md)（推荐，纯网页点点点）
- 习惯终端 → [worker-sync/README.md](worker-sync/README.md)（wrangler 四条命令）
- 想改协议/看接口 → [worker-sync/INTERNALS.md](worker-sync/INTERNALS.md)

> ⚠️ **国内用户必看**：`*.workers.dev` 在国内基本不可用（转圈、超时、连接被重置）。
> 给 Worker 挂一个自己的域名就能通，服务器在境外**不用备案**，
> 挂完在 App 里改一下服务地址即可，**不用重新配对**。步骤见 DEPLOY.md 第 7 步。

---

## 仓库里有什么

| 路径 | 作用 |
| --- | --- |
| `core/` | 纯 Dart 核心（站点档案、配置持久化、URL 规则、请求头、下载队列、同步引擎），`dart test` 190 个用例 |
| `app/` | Flutter 壳（只有 `lib/`，`android/` `windows/` 由 `flutter create` 现生成） |
| `app/test/` | 界面流程组件测试（`flutter test`），抓 `analyze` 看不见的"点到没存"类 bug |
| `worker-sync/` | 同步中转站（Cloudflare Worker + D1，零 npm 依赖） |
| `tools/` | 白标工具：图标生成、平台清单补丁 |
| `.github/workflows/build.yml` | `test-core → branding → android / windows` |

---

## 这个仓库只管壳，不管内容

壳本身不认识任何具体网站 —— 站点、图标、名字、主题色都是构建参数或用户自己加的。

它之前和 Cloudflare 笔记后端（`worker.js`）、那个笔记的原生客户端挤在同一个仓库里，
现在拆开了：那边是 [`zczy-k/CF-Workers-TXT`](https://github.com/zczy-k/CF-Workers-TXT)，
这边只留壳。两边没有代码依赖，可以各自独立发版。

---

## 许可证

**GNU General Public License v3.0**（全文见 [`LICENSE`](./LICENSE)）。

这个选择是刻意的：壳的价值在于"任何人都能把自己的网站装成 App"，要是谁都能拿它改个名字、
换个图标就闭源卖，这件事就变味了。GPL-3.0 只在你**对外分发**时生效 —— 分出去的版本必须同样
开源、必须给接收者同样的自由。你自己内部用、自己改、不发给别人，不受任何约束。

> 想要闭源商用版？那得另外授权，开个 issue 谈。
>
> GPL-3.0 与 Apache-2.0 是**兼容**的（FSF 认可；真正不兼容的是 GPLv2），所以理论上能和
> 笔记仓库（[CF-Workers-TXT](https://github.com/zczy-k/CF-Workers-TXT)）互相搬代码 ——
> 不过它们本来就零依赖：一个是服务端 JS，一个是 Flutter 壳。
