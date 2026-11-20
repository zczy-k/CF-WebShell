# 构建与发布

这份文档管「怎么把 App 打出来」：CI 出包、白标参数、图标、签名、本机开发、依赖、构建阶段的排错。

只想**用**这个 App、或者只想部署自动同步，看 [README](../README.md) 就够了。

---

## 一、出包

### A. 通用壳（不用填任何东西）

改 `app/`、`core/`、`tools/` 下的代码并 push 到 `main`（或对这几个目录发 PR），`build` 流水线自动跑，
产物在 Actions 那次运行的 **Artifacts** 里：

- `webshell-android-apk` → `webshell-<包名>-<构建号>.apk`
- `webshell-windows-x64` → `webshell-windows-<包名>.zip`

> GitHub 的 Actions 日志和产物**必须登录**才能看/下。

### B. 白标版（手动填参数）

仓库 **Actions → build → Run workflow**，填下表后运行。只有这条入口能带参数。

| 输入 | 留空时 | 说明 |
| --- | --- | --- |
| `app_name` | `WebShell` | App 显示名。安卓桌面图标名、Windows 窗口标题、**Windows 的 exe 文件名**都用它。**可以中文** |
| `app_id` | `dev.webshell.webshell` | 包名/应用 ID，如 `com.corp.oa`。最后一段会规整成合法标识符（小写、字母数字下划线、不以数字开头）。只影响包名与内部标识，**不影响 exe 文件名** |
| `preset_url` | 无预置站点（= 通用壳） | 预置站点入口，如 `oa.corp.com`、`http://192.168.1.10:8080`。只写域名会自动补 `https://` |
| `preset_name` | 用域名 | 预置站点在列表里显示的名字 |
| `theme_color` | `#2962FF` | 主题色，`#RRGGBB` |
| `logo_url` | 自动（见下） | 图标图片地址（PNG/JPG/ICO）。⚠️ 必须是**直链**，不能是网页 |
| `logo_path` | 自动（见下） | 仓库里的图标文件路径。先把图片提交到仓库，再填 `branding/logo.png` |
| `auto_icon` | 开 | 没给图标时，抓预置站点的 `apple-touch-icon` / `favicon.ico` / `favicon.png` |
| `allow_add_site` | 开 | 白标版是否允许用户自己再加站点 |

三个常见用法：

1. **只要一个专属 App**：`app_name=公司OA`、`app_id=com.corp.oa`、`preset_url=oa.corp.com`、`theme_color=#0B6BCB`
2. **用自己的图标**：再填 `logo_url=https://cdn.corp.com/logo.png`（或把图片提交进仓库后填 `logo_path`）
3. **内网 http 站点**：`preset_url=http://192.168.1.10:8080` —— 已经默认允许明文 http，不用额外配置

---

## 二、图标是怎么定的（优先级从高到低）

1. `logo_path` 指定的仓库文件；
2. `logo_url` 下载的图片；
3. `auto_icon=true` 且给了 `preset_url`：先读首页 HTML 里 `<link rel="...icon...">` 声明的图标
   （`apple-touch-icon` 优先 → 其他位图 → `svg` 放最后），拿不到再兜底试站点根目录的
   `apple-touch-icon.png` / `apple-touch-icon-precomposed.png` / `favicon.ico` / `favicon.png`；
   **顺序是刻意的**：现在多数站点不在固定路径放图标（`flutter.dev/favicon.ico` 是 404），
   而写在 HTML 里的通常分辨率更高（`php.net` 声明了 196×196，根目录的 `favicon.ico` 只有 32×32）；
4. 都没有：用 App 名（或域名）的首字母 + 主题色画一个。

第 4 条是刻意的：**永远不会打出没有图标的包**。生成的是 Android 五档 `mipmap` + 自适应图标
（前景按 2/3 缩进安全区）+ 多尺寸 Windows `.ico`。

> 想换图标又懒得重新出包：Android 端卸载重装才会刷新桌面图标（系统缓存，不是 bug）。

---

## 三、签名（重要）

CI 打的是 **debug keystore 签名**的 release 包，能侧载安装、能正常使用，但**不能上架应用商店**，
而且和别的机器打的同包名包互相覆盖安装会失败。要正式签名：把 keystore 放进仓库 Secrets，
在生成的 `android/app/build.gradle(.kts)` 里加 `signingConfigs` 并让 `release` 用它
（这几行得在 `build.yml` 的 Android job 里加，因为 `android/` 是 CI 现生成的）。

---

## 四、本机开发

```bash
# 纯逻辑（秒级，190 个用例）
cd core && dart pub get && dart test

# 壳 App（需要 Flutter 3.44+）
cd app && flutter pub get
flutter run -d windows      # 或 -d <安卓设备>

# 界面流程测试（几秒钟，不需要设备；不联网）
cd app && flutter test
```

注意几点：

- **`app/android/` 和 `app/windows/` 不在仓库里**，需要在本地生成一次：
  在 `app` 下跑 `flutter create --platforms=android,windows --org dev.webshell --project-name webshell .`
  （CI 也是这么做的；仓库只保留 `lib/` 作为唯一真相源）。
- **静态分析的 flag 不一样**：`dart analyze` 从 Dart 3.13 起**不能**传 `--no-fatal-infos`（传了直接退出 64），
  而 `flutter analyze` 默认把 info 也算致命，必须传 `--no-fatal-infos --no-fatal-warnings`。
  两边 CI 都按这个写了，本地跟着来就不会被"假报错"骗。
- **改 UI 流程就顺手跑一下 `flutter test`**：`app/test/` 里的用例会把"添加站点"这类
  流程真的点一遍。原因是有一次真漏过 —— 添加站点只建了档案、忘了写进配置，浏览页按 id
  查不到它，只显示"这个站点已经被删除了"，首页列表永远空着（用户看到的"空壳"）。
  这种"界面流程忘了调某个函数"的问题 `analyze` 和纯 Dart 单测都看不见，只有组件测试抓得到。
- 改了 `app/lib/` 之后**别只信本机 `dart format` 门禁**：本机没有 Flutter SDK 时无法跑
  `flutter analyze`，语义类错误（比如 `const` 套了非 const 构造函数）只有 CI 抓得到。

Windows 上跑还需要 **WebView2 运行时**（Win10/11 通常随 Edge 自带；没有的话装一次
[Evergreen Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)）。
本机 `flutter build windows` 还要求装了 **Visual Studio（含 C++ 桌面负载）** 和 CMake 用的 **nuget**。

---

## 五、用到的依赖（及为什么是它）

| 依赖 | 用途 | 为什么选它 |
| --- | --- | --- |
| `flutter_inappwebview ^6.1.5` | 两端引擎（Android WebView / Windows WebView2） | 6.x 是目前唯一在两端都暴露"下载事件 / 文件选择 / 新窗口 / Cookie / 注入脚本"的插件——这几项正是"残废壳"缺的东西 |
| `path_provider` | 应用私有目录、Android 外部目录 | 官方维护，Android/Windows 都有实现 |
| `url_launcher` | `tel:` / `mailto:` / 交给系统浏览器 | 同上 |
| `file_picker ^13.1.0` | Windows 选目录 | 版本必须 ≥12（Windows 实现要 `win32 ^6`），且与其它带 `win32` 的插件同升，否则冲突 |
| `flutter_file_dialog ^3.3.3` | Android "另存为"（系统 SAF 选择器） | 不需要存储权限就能写用户选的目录 |
| `open_filex ^5.0.0` | Android 打开下载好的文件 | 只支持 Android/iOS；Windows 端用 `explorer.exe` 自己实现 |
| `ffi ^2.1.0` | 调 Win32：窗口守卫 + **DPAPI 加密密码** | 不用额外插件就能拿到 `CryptProtectData`，密钥由系统托管（见 `local_secure_store.dart`） |

> **Basic Auth 密码怎么存的**：Windows 上 `secrets.bin` 整份内容走 DPAPI（`CryptProtectData`
> + 本程序专属 entropy），换机器 / 换用户就解不开；Android / iOS 上是掩码混淆，真正的
> 防线落在 App 私有目录 + 构建期关掉 `android:allowBackup`。逐项对照见
> [`ARCHITECTURE.md`](../ARCHITECTURE.md) §6.1。

---

## 六、构建阶段的排错

| 症状 | 原因 | 怎么办 |
| --- | --- | --- |
| release APK 里所有请求都失败 | 安卓模板的 release 清单**默认没有** INTERNET 权限（只有 debug/profile 有） | 流水线已自动加上；如果你手动改过清单，检查这一条 |
| Windows 构建报找不到 `nuget` / 拉 WebView2 SDK 失败 | 插件在 CMake 阶段要拉 nuget 包 | 流水线已确保 nuget 可用；网络抖动重跑一次 |
| Windows 编译插件报 `error C2338: static assertion failed: 'error STL1011'`（提到 `/await`、`<experimental/coroutine>`） | MSVC 14.51（VS 18）起把这些判成硬错误，而上游 `flutter_inappwebview_windows`（经 WebView2/WIL）还在用 | 流水线会往 `windows/CMakeLists.txt` 注入 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`（微软报错里给的逃生宏）。哪天上游改用 C++20 coroutine 就能删掉 |
| Android 构建报 `` `getDefaultProguardFile('proguard-android.txt')` is no longer supported `` | 上游 `flutter_inappwebview_android` 的 `build.gradle` 写法过旧，Flutter 模板自带的新 AGP 直接当硬错误 | 流水线会把它换成 `proguard-android-optimize.txt`（只改这一个文件；上游发版修好后该步自动跳过） |
| Windows 步骤报 "Python was not found" / 只退 1 不给原因 | 机器上的 `python` 可能只是微软商店的"应用执行别名"占位符 | 流水线不是查 PATH 而是**实跑一遍**探测 `python` / `py -3` / `python3`，挑真能用的那个 |
| CI 里 `dart analyze --no-fatal-infos` 报 "Cannot negate option" | Dart 3.13 起该选项已移除 | 别传它（本仓库的流水线已修正） |
| 静态分析报 `const_with_non_const` / 类型错误，本机却看不出来 | 本机没装 Flutter SDK，只跑 `dart format --output=none` 只能验语法，验不出语义 | 以 CI 的 `flutter analyze` 为准；改完 App 层就直接 push 让它验 |
| 看不到 CI 日志 / 下不了产物 | 未登录时拿不到 Actions 原始日志 | **失败原因无需登录**：流水线把各步骤日志尾部打成 check-run 注解，`GET /repos/zczy-k/CF-WebShell/commits/<sha>/check-runs` → `.../check-runs/<id>/annotations` 即可读；产物要登录才能下 |

---

[← 回 README](../README.md) · [自动同步部署](../worker-sync/DEPLOY.md) · [使用与排错](USAGE.md) · [架构](../ARCHITECTURE.md)
