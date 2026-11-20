import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'local_secure_store.dart';
import 'package:file_picker/file_picker.dart';
import 'package:webshell_core/webshell_core.dart';

import 'icons.dart';
import 'paths.dart';
import 'sync_credentials.dart';

/// `assets/preset.json` 读取或解析失败的原因（null = 正常）。
///
/// 只在站点列表为空时用得上：白标包装上去一个站点都没有，用户除了"空白页"
/// 看不到任何线索，只能猜是不是构建坏了。把这个原因直接写在空状态页上，
/// 至少能一眼看出是"预置配置没读进来"而不是"App 没打包站点"。
String? presetLoadError;

/// 一个正在接收的 `blob:` 下载（前端生成的文件走这条通道）。
class _BlobSession {
  _BlobSession({required this.task, required this.sink});

  final DownloadTask task;
  final DownloadSink sink;
}

/// App 的全部运行时状态：站点、配置、下载队列、图标缓存、密码。
///
/// 逻辑尽量放在 core（可单测），这里只做"接线"：把 core 的下载队列接到引擎的
/// Cookie / UA 上，把配置落到磁盘，把变化通知给 UI。
class ShellState extends ChangeNotifier {
  ShellState._({
    required this.branding,
    required this.config,
    required this.configFile,
    required this.downloads,
    required this.icons,
    required this.secure,
    required this.downloadsFile,
    this.syncFile,
  });

  final Branding branding;
  final ShellConfig config;
  final ConfigFile configFile;
  final DownloadManager downloads;
  final IconFetcher icons;
  final LocalSecureStore secure;
  final File downloadsFile;

  /// 同步缓存的落盘位置（`webshell.sync.json`）。为 null = 这个实例不参与同步
  /// （单测构造走这条路，免得每条用例都要 mock 一次磁盘）。
  final SyncStateFile? syncFile;

  /// 同步调度器。`config.syncConfigured` 为假时它照样存在，只是不干活 ——
  /// 这样界面不用到处判空。
  SyncService? sync;

  /// 正在把远端合并结果写回配置。
  ///
  /// 用来掐掉"同步自己引起的改动又触发一次同步"的回音：合并写回配置时如果
  /// 顺手 `markDirty()`，我们会立刻把刚收到的东西再推回去，两台设备就乒乓起来。
  bool _writingRemote = false;

  /// 引擎的真实 UA（向 WebView 问来的）。下载时带上它，站点才不会把我们当爬虫。
  String? engineUserAgent;

  /// 当前浏览页的控制器（由 BrowserPage 挂上 / 摘掉）。清某个站点的
  /// localStorage / IndexedDB 时要用它在页面里跑一段 JS —— 这几样东西在引擎侧
  /// 没有"按域删除"的接口。为 null（没开浏览页）时只清 Cookie。
  InAppWebViewController? activeController;

  final Map<String, _BlobSession> _blobs = <String, _BlobSession>{};

  /// blob 通道的进度广播节流表（key → 上次广播时刻），见 [onBlobData]。
  final Map<String, int> _blobLastNotifyMs = <String, int>{};
  Timer? _configTimer;
  Timer? _downloadsTimer;

  static Future<ShellState> create(Branding branding) async {
    final Directory dir = await appDataDir();
    final ConfigFile configFile =
        ConfigFile(File(joinPath(dir.path, ConfigFile.defaultFileName)));

    // 同步缓存。**必须在 configFile.load() 之前读**：里面记着"用户亲手删掉的
    // 白标预置站点地址"，而 load() 会把这一版预置里有、列表里没有的站点补回来。
    // 顺序反了的话，用户删掉的站点在下次启动就复活了。
    final SyncStateFile syncFile =
        SyncStateFile(File(joinPath(dir.path, SyncStateFile.defaultFileName)));
    final SyncLocalState syncState = syncFile.load();
    if (syncState.local.suppressed.isNotEmpty) {
      configFile.suppressedUrls = Set<String>.of(syncState.local.suppressed);
    }

    final ShellConfig config = configFile.load(branding);

    if (config.downloadDir == null || config.downloadDir!.isEmpty) {
      // 首次启动：探测默认下载目录（Android 是公共 Download/<App 名文件夹>，
      // 中文名取拼音首字母，如「成都」→ Download/cd），结果写进配置，
      // 下载时不再反复探测。
      config.downloadDir = await defaultDownloadDirectory(branding.appName);
      configFile.save(config);
    } else if (portableMode && !isInPortableRoot(config.downloadDir!)) {
      // 便携版：老配置里的下载目录还指向 C 盘（用户的「下载」文件夹），
      // 统一挪到程序目录里的 data-user\Download，跟其它数据一起搬走。
      config.downloadDir = await defaultDownloadDirectory(branding.appName);
      configFile.save(config);
    } else if (Platform.isAndroid) {
      // 升级迁移：老版本的 Android 落点是 Android/data/<包名>/files/Download，
      // Android 11+ 文件管理器看不到它（用户以为"文件没下到手机上"）。
      // 只要配的是应用私有目录，就悄悄换成可见的 Android/media/<包名>/Download。
      final String old = config.downloadDir!;
      final String? media = androidMediaDirOf(old);
      if (media != null && old.contains('/Android/data/')) {
        config.downloadDir = joinPath(media, 'Download');
        try {
          Directory(config.downloadDir!).createSync(recursive: true);
          configFile.save(config);
        } catch (_) {
          // 建不出来就保持原样，写文件时会给出更清楚的错误
          config.downloadDir = old;
        }
      }
    }

    late final ShellState state;
    final DownloadManager downloads = DownloadManager(
      transport: FileDownloadTransport(),
      maxConcurrent: config.maxConcurrentDownloads,
      resolvePath: (DownloadTask task, String name) => state.resolveDownloadPath(name),
      headers: (DownloadTask task) => state.downloadHeaders(task),
    );

    state = ShellState._(
      branding: branding,
      config: config,
      configFile: configFile,
      downloads: downloads,
      icons: IconFetcher(await iconCacheDir()),
      // 密码改存程序目录里的 secrets.bin，不用 flutter_secure_storage ——
      // 后者在 Windows 上固定落 %APPDATA%，迁移时会漏掉（详见 local_secure_store.dart）。
      secure: LocalSecureStore(File(joinPath(dir.path, 'secrets.bin'))),
      downloadsFile: File(joinPath(dir.path, 'downloads.json')),
      syncFile: syncFile,
    );
    downloads.onChanged = (DownloadTask task) => state._onDownloadsChanged();
    state.restoreDownloads();
    state._initSync(syncState);
    return state;
  }

  @override
  void dispose() {
    _configTimer?.cancel();
    _downloadsTimer?.cancel();
    // 先掐定时器：同步的轮询/防抖要是还在跑，dispose 之后它会继续调
    // notifyListeners，Flutter 会抛 "was used after being disposed"。
    sync?.dispose();
    downloads.close();
    saveNow();
    saveDownloadsNow();
    // 退出即不保留：关了"保持登录"就把痕迹擦掉（浏览页侧还有 incognito 兜底）。
    if (!config.saveLogin) unawaited(_wipeAllLoginState());
    super.dispose();
  }

  /// 只给单测用的构造：绕开 path_provider / 安全存储这些平台插件。
  ///
  /// 为什么要留这么一个口子：这台机器上真的漏过一次"添加站点只建了档案、没有写进
  /// 配置"，用户看到的是浏览页一句"这个站点已经被删除了"、首页永远空着。这类
  /// "UI 流程忘了调某个函数"的 bug，`flutter analyze` 和纯 Dart 单测都抓不到，
  /// 只有能把界面流程跑一遍的测试才抓得到 —— 见 `test/add_site_test.dart`。
  /// 传入的 [icons] 可以换成不联网的替身，避免测试里真的发 HTTP 请求。
  @visibleForTesting
  static ShellState forTest({
    required ShellConfig config,
    required File configFile,
    required File downloadsFile,
    Branding branding = Branding.generic,
    DownloadTransport? transport,
    IconFetcher? icons,
  }) {
    late final ShellState state;
    final DownloadManager downloads = DownloadManager(
      transport: transport ?? FileDownloadTransport(),
      maxConcurrent: config.maxConcurrentDownloads,
      resolvePath: (DownloadTask task, String name) => state.resolveDownloadPath(name),
      headers: (DownloadTask task) => state.downloadHeaders(task),
    );
    state = ShellState._(
      branding: branding,
      config: config,
      configFile: ConfigFile(configFile),
      downloads: downloads,
      icons: icons ?? IconFetcher(Directory.systemTemp),
      secure: LocalSecureStore(File(joinPath(downloadsFile.parent.path, 'secrets.bin'))),
      downloadsFile: downloadsFile,
    );
    downloads.onChanged = (DownloadTask task) => state._onDownloadsChanged();
    return state;
  }

  // ------------------------------------------------------------------ 配置

  void saveSoon() {
    _configTimer?.cancel();
    _configTimer = Timer(const Duration(milliseconds: 400), saveNow);
    // 设置页里改的偏好（省流、托盘、并发数）都走这里 —— 挂在这儿一处就够了，
    // 不用在每个开关的 onChanged 里各补一次。
    _touchSync();
  }

  void saveNow() {
    try {
      configFile.save(config);
    } catch (_) {
      // 存不下去不该让 App 挂掉（磁盘满、权限被改），下次改动会再试
    }
  }

  /// 站点被改动过（改名、改地址、改头…），存盘并刷新界面。
  ///
  /// 传 [site] 时顺手把它的 `updatedAtMs` 抬到现在 —— 合并时"两边都改过"靠这个
  /// 时间戳判先后。不传表示这次改动不参与同步（比如本机图标缓存路径变了，
  /// `iconPath` 是本地文件路径，本来就不上传）。
  void siteEdited([SiteProfile? site]) {
    if (site != null) site.updatedAtMs = nowMs();
    configFile.save(config);
    notifyListeners();
    if (site != null) _touchSync();
  }

  Future<void> addSite(SiteProfile site) async {
    final bool added = config.addSite(site);
    if (added) site.updatedAtMs = nowMs();
    saveNow();
    notifyListeners();
    // 重复提交（同一个 id 已经在列表里）就不必再抓一次图标了
    if (added) {
      _touchSync();
      unawaited(refreshIcon(site));
    }
  }

  void removeSite(String id) {
    config.removeSite(id);
    saveNow();
    notifyListeners();
    _touchSync();
  }

  /// 打开站点：更新"最近使用"，顺手把它设为当前站点。
  void openSite(SiteProfile site) {
    config.touch(site);
    saveNow();
    notifyListeners();
  }

  /// 抓站点图标（走缓存，失败就退化成首字母方块）。
  Future<void> refreshIcon(SiteProfile site) async {
    final String? path = await icons.fetch(site);
    if (path == null) return;
    site.iconPath = path;
    saveNow();
    notifyListeners();
  }

  /// 清掉某个站点的登录态：这个域的 Cookie，**以及**页面自己存的会话数据。
  ///
  /// 只清这个域名，别的站点不受影响。localStorage / IndexedDB 在引擎侧没有
  /// "按域删除"的接口，所以靠一段注入的 JS 在页面里逐个删 —— 不少站点把登录
  /// 令牌放在 localStorage，只清 Cookie 会出现"Cookie 没了、一刷新又自动登录
  /// 回去"的假退出。
  Future<void> clearSiteData(SiteProfile site) async {
    final Uri? u = Uri.tryParse(site.startUrl);
    if (u == null) return;
    try {
      await CookieManager.instance()
          .deleteCookies(url: WebUri('${u.scheme}://${u.authority}'));
    } catch (_) {
      // 引擎不支持就算了，别把 UI 卡住
    }
    await _clearWebStorage(u);
  }

  /// 如果当前浏览页正好是这个来源，就在页面里清掉它的本地存储。
  Future<void> _clearWebStorage(Uri origin) async {
    final InAppWebViewController? c = activeController;
    if (c == null) return;
    try {
      final WebUri? current = await c.getUrl();
      if (current == null || current.host != origin.host) return;
      await c.evaluateJavascript(source: _clearStorageScript);
    } catch (_) {
      // 页面已经销毁 / 引擎不支持，忽略
    }
  }

  /// 清空所有站点的登录态（设置里的"清空所有 Cookie"、关闭"保持登录状态"）。
  Future<void> clearAllCookies() => _wipeAllLoginState();

  /// 把整个 App 的登录痕迹擦干净：Cookie + 全部 Web Storage。
  ///
  /// [WebStorageManager.deleteAllData] 覆盖所有来源的 localStorage /
  /// sessionStorage / IndexedDB / CacheStorage，一步到位。
  Future<void> _wipeAllLoginState() async {
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (_) {}
    try {
      await WebStorageManager.instance().deleteAllData();
    } catch (_) {
      // Windows 等平台可能没实现，忽略；Cookie 已经清了
    }
    try {
      await InAppWebViewController.clearAllCache();
    } catch (_) {
      // 没有打开的浏览页 / 平台没实现：拿不到 controller 就跳过
    }
  }

  /// 切换"保持登录"。关掉时**立刻**擦掉已经落地的登录态，否则 Cookie 还留在
  /// 磁盘上，用户以为关了、重启后却仍是登录状态 —— 开关形同虚设。
  Future<void> setSaveLogin(bool value) async {
    if (config.saveLogin == value) return;
    config.saveLogin = value;
    saveNow();
    notifyListeners();
    if (!value) await _wipeAllLoginState();
  }

  /// 在页面里清掉当前来源的本地存储（localStorage / sessionStorage /
  /// IndexedDB / caches）。引擎没有按域清这些的 API，只能走 JS。
  static const String _clearStorageScript = r'''
(function () {
  try { localStorage.clear(); } catch (e) {}
  try { sessionStorage.clear(); } catch (e) {}
  try {
    if (window.caches && caches.keys) {
      caches.keys().then(function (ks) {
        ks.forEach(function (k) { try { caches.delete(k); } catch (e) {} });
      });
    }
  } catch (e) {}
  try {
    if (window.indexedDB && indexedDB.databases) {
      indexedDB.databases().then(function (dbs) {
        dbs.forEach(function (db) {
          try { indexedDB.deleteDatabase(db.name); } catch (e) {}
        });
      });
    }
  } catch (e) {}
  return true;
})();
''';

  // ------------------------------------------------------------ Basic Auth

  String _basicKey(String siteId) => 'basic:$siteId';

  Future<void> setBasicPassword(String siteId, String? password) async {
    try {
      if (password == null || password.isEmpty) {
        await secure.delete(key: _basicKey(siteId));
      } else {
        await secure.write(key: _basicKey(siteId), value: password);
      }
    } catch (_) {}
  }

  Future<String?> basicPassword(String siteId) async {
    try {
      return await secure.read(key: _basicKey(siteId));
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------ 同步

  SecureSyncCredentialStore? _credStoreInstance;

  SecureSyncCredentialStore get _credStore =>
      _credStoreInstance ??= SecureSyncCredentialStore(secure);

  /// 建好 [SyncService]。只有 [create] 会调它；单测里 [syncFile] 为 null 直接跳过。
  void _initSync(SyncLocalState cached) {
    final SyncStateFile? file = syncFile;
    if (file == null) return;
    final SyncEngine engine = SyncEngine(
      config: config,
      stateFile: file,
      credentials: _credStore,
      state: cached,
      onConfigChanged: _onRemoteApplied,
    );
    sync = SyncService(engine: engine, onChanged: notifyListeners);
  }

  /// 合并结果已经写进 [config]：存盘 + 刷新界面。
  ///
  /// 全程把 [_writingRemote] 立起来 —— 这期间任何"配置变了 → 待同步"的路径都要
  /// 让路，否则会把刚拉下来的东西当成新改动推回去，两台设备开始乒乓。
  void _onRemoteApplied() {
    _writingRemote = true;
    try {
      configFile.save(config);
    } catch (_) {
      // 和 saveNow 一样的道理：写不进去不该让同步整轮失败
    } finally {
      _writingRemote = false;
    }
    notifyListeners();
  }

  void _touchSync() {
    if (_writingRemote) return;
    sync?.markDirty();
  }

  /// 设备名。显示在"已配对设备"列表里，用来分清哪台是哪台。
  String get syncDeviceName {
    final String os = Platform.isWindows
        ? 'Windows'
        : Platform.isAndroid
            ? 'Android'
            : Platform.isMacOS
                ? 'macOS'
                : Platform.isLinux
                    ? 'Linux'
                    : Platform.isIOS
                        ? 'iOS'
                        : '设备';
    return '${branding.appName} · $os';
  }

  /// 同步总状态（在跑的时候优先显示"运行中"）。
  SyncStatus get syncStatus {
    final SyncService? s = sync;
    if (s == null) return SyncStatus.disabled;
    if (s.busy) return SyncStatus.running;
    return s.status;
  }

  /// 有本机改动还没同步出去。
  bool get syncPending => sync?.pending ?? false;

  /// 骤降护栏拦下来的"待确认删除数"（0 = 没有待确认的删除）。
  ///
  /// 界面拿它来决定要不要出那条黄色警告条。
  int get syncPendingRemovals {
    final SyncRunResult? r = sync?.lastResult;
    if (r == null || !r.awaitingConfirm) return 0;
    return r.pendingRemovals;
  }

  /// 上次同步跑完的时刻（0 = 还没跑过）。
  int get syncLastRunMs => sync?.lastRunMs ?? 0;

  /// 给界面看的一句话状态。
  String get syncStatusText {
    final SyncService? s = sync;
    switch (syncStatus) {
      case SyncStatus.disabled:
        // 已经配好了但这一轮还没跑过 —— 别写成"未开启"，用户会以为开关没生效
        return config.syncConfigured ? '等待首次同步' : '未开启';
      case SyncStatus.running:
        return '正在同步…';
      case SyncStatus.ok:
        final SyncRunResult r = s?.lastResult ?? SyncRunResult.disabled;
        // 冲突数必须先说。放在 pushed/pulled 后面会被那两个吃掉 ——
        // "已上传本机改动"说完就 return 了，用户永远看不到"有 3 处两边都改过"，
        // 而那正是他最需要知道的一句。
        if (r.conflicts > 0) return '已同步（${r.conflicts} 处两边都改过，按时间取新）';
        if (r.pushed && r.pulled) return '已同步（本机与其它设备都有改动）';
        if (r.pushed) return '已上传本机改动';
        if (r.pulled) return '已接收其它设备的改动';
        return '已是最新';
      case SyncStatus.needsConfirm:
        final int n = syncPendingRemovals;
        return n > 0
            ? '检测到一次大量删除（$n 个站点），已暂停执行'
            : '检测到一次大量删除，已暂停执行';
      case SyncStatus.offline:
        return '连不上同步服务，稍后自动重试';
      case SyncStatus.authFailed:
        return '这台设备已被移出同步空间，需要重新配对';
      case SyncStatus.error:
        return s?.message ?? '同步出错';
    }
  }

  /// 用户点了"确认删除"：放行一轮骤降护栏，然后照常同步。
  Future<void> syncConfirmBigDelete() async {
    final SyncService? s = sync;
    if (s == null) return;
    await s.confirmBigDelete();
    notifyListeners();
  }

  /// 云端历史版本清单。失败返回空列表 + 把错误信息交给调用方。
  Future<List<SyncHistoryEntry>> syncHistory() async {
    final SyncService? s = sync;
    if (s == null) return const <SyncHistoryEntry>[];
    return s.history();
  }

  /// 把第 [version] 版恢复成当前版本，然后立刻拉一轮把内容取回来。
  Future<void> syncRestoreHistory(int version) async {
    final SyncService? s = sync;
    if (s == null) return;
    await s.restoreHistory(version);
    await s.syncNow(manual: true);
    notifyListeners();
  }

  /// 第一台设备：用部署时设的密钥开一个空间。返回 null = 成功。
  Future<String?> syncEnableFirstDevice({
    required String endpoint,
    required String bootstrapSecret,
  }) async {
    try {
      final SyncCredentials creds = await SyncClient.bootstrap(
        endpoint: endpoint,
        bootstrapSecret: bootstrapSecret,
        deviceName: syncDeviceName,
      );
      await _adoptCredentials(creds);
      return null;
    } on SyncException catch (e) {
      return e.message;
    } catch (e) {
      return '开启失败：$e';
    }
  }

  /// 新设备：用别人给的配对码换自己的凭证。返回 null = 成功。
  Future<String?> syncJoinWithCode({
    required String endpoint,
    required String code,
  }) async {
    try {
      final SyncCredentials creds = await SyncClient.pair(
        endpoint: endpoint,
        code: code,
        deviceName: syncDeviceName,
      );
      await _adoptCredentials(creds);
      return null;
    } on SyncException catch (e) {
      return e.message;
    } catch (e) {
      return '配对失败：$e';
    }
  }

  /// 收下凭证 → 打开开关 → 立刻同步一轮。
  Future<void> _adoptCredentials(SyncCredentials creds) async {
    final bool stored = await _credStore.write(creds);
    if (!stored) {
      throw const SyncException('凭证写不进安全存储（目录只读或磁盘满），这次没有开启同步');
    }

    // 换了**空间**才等于换了参照系。
    //
    // 本地缓存里的 base/local/version 说的全是**上一个空间**的事。要是原样留着，
    // 第一轮合并看到"远端什么都没有、base 里全是站点"，会判定成"远端把这些站点
    // 全删了"，然后把本机清空、把墓碑推上去 —— 断开同步再加入另一个空间，
    // 用户的站点就当场没了。
    //
    // 只清 base 和 version，**留着 local**：local 是本机现状，保住它，第一轮就会
    // 判成"本地有、远端空 = 本地新增"，站点正常推上去。
    //
    // 判据只看 spaceId，**不看服务地址**。真事：`xxx.workers.dev` 在国内被墙，
    // 用户给 Worker 挂上自定义域名后重新连一次 —— 那是同一台 Worker、同一个 D1、
    // 同一份数据，只是换了门牌号。以前把"地址变了"也当成换空间，会连墓碑一起清掉，
    // 于是以前删过的站点从云端复活一遍。地址变但空间没变，base 继续有效。
    //
    // 那"同一个 spaceId、却指向一个空库"怎么办？不用在这儿防：
    // 引擎里那条「服务端被重置」的护栏会清 base、重算 dirty，然后把本机整份推上去。
    final String oldSpace = config.syncSpaceId;
    if (oldSpace.isNotEmpty && oldSpace != creds.spaceId) {
      final SyncEngine? engine = sync?.engine;
      if (engine != null) {
        // 墓碑也一起丢掉。它的全部意义是"告诉**同一个空间**里的其它设备这条删了"，
        // 换空间以后这个上下文不存在了 —— 留着它，万一新空间里恰好有同地址的
        // 站点，第一轮就会把它按"本地更早的删除"给删掉。
        engine.state.local.sites.removeWhere((_, SyncSite s) => s.deleted);
        engine.state
          ..base = SyncDoc()
          ..version = 0;
        engine.stateFile.save(engine.state);
      }
    }

    config.syncEnabled = true;
    config.syncEndpoint = creds.endpoint;
    config.syncSpaceId = creds.spaceId;
    saveNow();
    notifyListeners();
    // 不 await：界面先回去，结果通过 syncStatusText 反映出来。
    final SyncService? s = sync;
    if (s != null) unawaited(s.syncNow(manual: true));
  }

  /// 换服务地址（典型场景：`xxx.workers.dev` 在国内被墙，给 Worker 挂了自定义域名）。
  ///
  /// 为什么不能只改 `config.syncEndpoint`：那个只是**界面上的显示值**。
  /// 真正发请求用的是安全存储里那份凭证自带的 endpoint
  /// （见 `SyncClient` 构造，`credentials.endpoint`）。只改显示值 = 界面变了、
  /// 流量还走老地址，用户会看到"地址明明改对了，还是一条都同步不上"。
  ///
  /// 反过来也**不能顺手清 base / version**：同一台 Worker、同一个 D1、
  /// 同一个 spaceId，只是换了门牌号，数据是同一份。清了 base 会让本机把现有站点
  /// 当成"全新的一批"整份重推，版本号白涨一轮，其它设备白抖一次。
  ///
  /// 返回 null = 成功。
  Future<String?> syncChangeEndpoint(String raw) async {
    final String endpoint = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (endpoint.isEmpty) {
      config.syncEndpoint = '';
      saveNow();
      notifyListeners();
      return null;
    }

    final SyncCredentials? creds = await _credStore.read();
    // 还没配对：只记下地址，等用户去开启/配对时自然会带进凭证。
    if (creds == null) {
      config.syncEndpoint = endpoint;
      saveNow();
      notifyListeners();
      return null;
    }
    if (creds.endpoint == endpoint) {
      config.syncEndpoint = endpoint;
      saveNow();
      notifyListeners();
      return null;
    }

    final bool stored = await _credStore.write(creds.copyWith(endpoint: endpoint));
    if (!stored) return '新地址写不进安全存储，这次没改（地址还是原来那个）';

    config.syncEndpoint = endpoint;
    saveNow();
    notifyListeners();
    // 立刻用新地址试一轮，成败都会体现在 syncStatusText 上。
    final SyncService? s = sync;
    if (s != null) unawaited(s.syncNow(manual: true));
    return null;
  }

  /// 最近一次生成的配对码（给设置页弹窗用）。
  SyncPairCode? syncPairCode;

  /// 生成一次性配对码（默认 10 分钟有效）。返回 null = 成功。
  Future<String?> syncNewPairCode() async {
    final SyncCredentials? creds = await _credStore.read();
    if (creds == null) return '这台设备还没有配对';
    try {
      syncPairCode = await SyncClient(creds).newPairCode();
      return null;
    } on SyncException catch (e) {
      return e.message;
    } catch (e) {
      return '生成配对码失败：$e';
    }
  }

  /// 已配对设备列表（设置页的"管理设备"）。
  List<SyncDeviceInfo> syncDevices = const <SyncDeviceInfo>[];

  Future<String?> syncLoadDevices() async {
    final SyncCredentials? creds = await _credStore.read();
    if (creds == null) return '这台设备还没有配对';
    try {
      syncDevices = await SyncClient(creds).devices();
      notifyListeners();
      return null;
    } on SyncException catch (e) {
      return e.message;
    } catch (e) {
      return '读取设备列表失败：$e';
    }
  }

  /// 把某台设备踢出同步空间（它下次带令牌来就会被拒）。
  Future<String?> syncRevokeDevice(String deviceId) async {
    final SyncCredentials? creds = await _credStore.read();
    if (creds == null) return '这台设备还没有配对';
    try {
      await SyncClient(creds).revoke(deviceId);
      final String? err = await syncLoadDevices();
      return err;
    } on SyncException catch (e) {
      return e.message;
    } catch (e) {
      return '移除设备失败：$e';
    }
  }

  /// 手动"立即同步"。
  Future<SyncRunResult> syncNow() async {
    final SyncService? s = sync;
    if (s == null) return SyncRunResult.disabled;
    return s.syncNow(manual: true);
  }

  /// 断开同步：清凭证、关开关，但**保留本地缓存**（再打开时能接着合并）。
  Future<void> syncDisconnect() async {
    await sync?.engine.disconnect();
    await _credStore.write(null);
    syncPairCode = null;
    syncDevices = const <SyncDeviceInfo>[];
    config.syncEnabled = false;
    // 开关已关，顺手把还挂着的轮询掐掉（resetSchedule 在有开关判断的
    // _schedule 里会先 cancel 再返回），别让定时器空转到 App 退出。
    sync?.resetSchedule();
    saveNow();
    notifyListeners();
  }

  // ---------------------------------------------------------------- 下载

  DownloadTask enqueueDownload({
    required String url,
    required String siteId,
    String? suggestedName,
    String? referer,
  }) {
    final DownloadTask task = downloads.enqueue(
      url: url,
      siteId: siteId,
      fileName: (suggestedName ?? '').trim().isEmpty ? null : suggestedName,
      referer: referer,
    );
    saveDownloadsSoon();
    notifyListeners();
    return task;
  }

  /// 落盘位置：目录取自设置，文件名唯一化，避免覆盖上一次的同名文件。
  Future<String> resolveDownloadPath(String name) async {
    return uniquePath(joinPath(_effectiveDownloadDir(), sanitizeFileName(name)));
  }

  /// 当前生效的下载目录（给 UI 显示用：用户最常问的就是"文件存哪了"）。
  String get downloadDirectoryLabel => _effectiveDownloadDir();

  String _effectiveDownloadDir() {
    final String? dir = config.downloadDir;
    // `content://` 是 Android 的 SAF 目录（P3 支持），现在还用不了，先落到应用目录
    if (dir != null && dir.isNotEmpty && !dir.startsWith('content://')) return dir;
    // 兜底也必须是"用户找得到的地方"：以前这里退到系统临时目录，
    // 结果文件确实下下来了，但没人能找到 —— 比失败还糟（静默）。
    return defaultDownloadDir();
  }

  /// 下载要带的请求头：站点自定义头 + 引擎 UA + Referer + Cookie（向引擎要）。
  ///
  /// 这几样缺一样，很多站点就会回 403 —— 这也正是"网页转 APP"工具下载失败的主因。
  Future<Map<String, String>> downloadHeaders(DownloadTask task) async {
    final SiteProfile? site = config.byId(task.siteId);
    final List<ShellCookie> cookies = <ShellCookie>[];

    for (final String target in <String>[task.referer ?? '', task.url]) {
      if (target.isEmpty || !target.startsWith('http')) continue;
      try {
        final List<Cookie> found =
            await CookieManager.instance().getCookies(url: WebUri(target));
        for (final Cookie c in found) {
          cookies.add(ShellCookie(
            name: c.name,
            value: c.value,
            domain: c.domain,
            path: c.path ?? '/',
            secure: c.isSecure ?? false,
            httpOnly: c.isHttpOnly ?? false,
            expiresMs: c.expiresDate,
          ));
        }
      } catch (_) {}
    }

    String? password;
    if (site != null && site.hasBasicAuth) {
      password = await basicPassword(site.id);
    }

    return buildRequestHeaders(
      site: site ??
          SiteProfile(id: task.siteId, name: '', startUrl: task.url),
      cookies: cookies,
      referer: task.referer,
      userAgentOverride: site?.userAgent ?? engineUserAgent,
      basicUser: site?.basicUser,
      basicPassword: password,
    );
  }

  void pauseDownload(String id) {
    // blob/data 导出是页面把内存里的字节分片推过来，没有"暂停"可言（不能去暂停
    // 浏览器的 FileReader）。要中止只能取消；这里对 blob 任务不置状态，免得出现
    // "已暂停、文件却还在长"的假象。
    if (_blobKeyOf(id) != null) return;
    downloads.pause(id);
    _onDownloadsChanged();
  }

  void resumeDownload(String id) {
    downloads.resume(id);
    _onDownloadsChanged();
  }

  Future<void> cancelDownload(String id) async {
    // blob/data 导出不走网络下载管线（它由页面脚本分片 POST 过来），所以不能只靠
    // downloads.cancel：那样任务虽然标成"已取消"，脚本还在继续推数据、半截文件也
    // 留在磁盘上（假取消 + 文件泄漏）。这里先把这条 blob 会话收干净。
    final String? blobKey = _blobKeyOf(id);
    if (blobKey != null) {
      await _dropBlobSession(blobKey);
      downloads.cancel(id);
      _onDownloadsChanged();
      return;
    }
    await downloads.cancel(id);
    _onDownloadsChanged();
  }

  /// 这条下载任务对应的 blob 会话 key（不是 blob 任务就返回 null）。
  String? _blobKeyOf(String id) {
    for (final MapEntry<String, _BlobSession> e in _blobs.entries) {
      if (e.value.task.id == id) return e.key;
    }
    return null;
  }

  /// 关闭并丢弃一条 blob 会话：关掉写句柄、删掉半截文件。
  Future<void> _dropBlobSession(String key) async {
    final _BlobSession? session = _blobs.remove(key);
    if (session == null) return;
    try {
      await session.sink.close();
    } catch (_) {}
    try {
      final String? path = session.task.savePath;
      if (path != null && File(path).existsSync()) await File(path).delete();
    } catch (_) {}
  }

  void removeDownload(String id) {
    // 还在写的 blob 任务直接删记录会漏掉没关的文件句柄和半截文件，先收干净。
    final String? blobKey = _blobKeyOf(id);
    if (blobKey != null) unawaited(_dropBlobSession(blobKey));
    downloads.remove(id);
    _onDownloadsChanged();
  }

  void clearFinishedDownloads() {
    downloads.clearFinished();
    _onDownloadsChanged();
  }

  /// 「另存为」：Android 走系统选择器（SAF，不需要存储权限）；桌面端走系统保存对话框。
  /// 返回 null 表示成功（或用户取消），否则是错误信息。
  Future<String?> exportDownload(DownloadTask task) async {
    final String? path = task.savePath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      return '文件还没下载完';
    }
    try {
      if (Platform.isAndroid) {
        await FlutterFileDialog.saveFile(
          params: SaveFileDialogParams(
            sourceFilePath: path,
            fileName: task.fileName,
          ),
        );
        return null;
      }
      final String? target = await FilePicker.getDirectoryPath(
        dialogTitle: '另存为：选择目标文件夹',
      );
      if (target == null || target.isEmpty) return null; // 用户取消
      await File(path).copy(uniquePath(joinPath(target, task.fileName)));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  // ------------------------------------------------- blob/data 导出通道

  Future<void> onBlobStart(Map<String, dynamic> payload) async {
    final String key = (payload['url'] as Object?)?.toString() ?? '';
    final String name = sanitizeFileName((payload['name'] as Object?)?.toString() ?? 'download');
    final int size = int.tryParse((payload['size'] as Object?)?.toString() ?? '') ?? 0;

    final String path = await resolveDownloadPath(name);
    final DownloadTask task = DownloadTask(
      id: 'blob-${DateTime.now().microsecondsSinceEpoch}',
      siteId: config.activeSiteId ?? '',
      url: key.isEmpty ? 'blob:' : key,
      fileName: name,
      savePath: path,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    task.status = DownloadStatus.running;
    if (size > 0) task.total = size;

    final DownloadSink sink =
        await FileDownloadTransport().openSink(path, append: false);
    _blobs[key] = _BlobSession(task: task, sink: sink);
    downloads.tasks.insert(0, task);
    notifyListeners();
  }

  Future<void> onBlobData(Map<String, dynamic> payload) async {
    final String key = (payload['url'] as Object?)?.toString() ?? '';
    final _BlobSession? session = _blobs[key];
    if (session == null) return;
    final String data = (payload['data'] as Object?)?.toString() ?? '';
    if (data.isEmpty) return;
    try {
      final List<int> bytes = base64Decode(data);
      session.sink.add(bytes);
      session.task.received += bytes.length;
      // 节流（与 core 的 _notify 同策略）：blob 分片 256KB 一个，前端导出大文件
      // 时每秒几十次全 UI 广播会掉帧；收尾（onBlobEnd/Error）会强制刷一次，
      // 最终状态不受影响。
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (now - (_blobLastNotifyMs[key] ?? 0) >= 200) {
        _blobLastNotifyMs[key] = now;
        notifyListeners();
      }
    } catch (e) {
      await onBlobError(<String, dynamic>{
        'url': (payload['url'] as Object?)?.toString() ?? '',
        'message': '解码失败：$e',
      });
    }
  }

  Future<void> onBlobEnd(Map<String, dynamic> payload) async {
    final String key = (payload['url'] as Object?)?.toString() ?? '';
    final _BlobSession? session = _blobs.remove(key);
    if (session == null) return;
    _blobLastNotifyMs.remove(key);
    await session.sink.close();
    session.task.status = DownloadStatus.done;
    _onDownloadsChanged();
  }

  Future<void> onBlobError(Map<String, dynamic> payload) async {
    final String key = (payload['url'] as Object?)?.toString() ?? '';
    final _BlobSession? session = _blobs.remove(key);
    if (session == null) return;
    _blobLastNotifyMs.remove(key);
    await session.sink.close();
    session.task.status = DownloadStatus.failed;
    session.task.error = (payload['message'] as Object?)?.toString() ?? '导出失败';
    try {
      final String? path = session.task.savePath;
      if (path != null) await File(path).delete();
    } catch (_) {}
    _onDownloadsChanged();
  }

  // ------------------------------------------------------------ 下载历史

  void restoreDownloads() {
    try {
      if (!downloadsFile.existsSync()) return;
      final Object? raw = jsonDecode(downloadsFile.readAsStringSync());
      if (raw is! List) return;
      final List<DownloadTask> restored = <DownloadTask>[];
      for (final Object? entry in raw) {
        final DownloadTask? t = DownloadTask.tryFromJson(entry);
        if (t != null) restored.add(t);
      }
      downloads.restore(restored);
    } catch (_) {
      // 历史坏了不影响使用
    }
  }

  void _onDownloadsChanged() {
    saveDownloadsSoon();
    notifyListeners();
  }

  void saveDownloadsSoon() {
    _downloadsTimer?.cancel();
    _downloadsTimer = Timer(const Duration(milliseconds: 400), saveDownloadsNow);
  }

  void saveDownloadsNow() {
    try {
      final List<Map<String, dynamic>> list = downloads.tasks
          .take(200)
          .map((DownloadTask t) => t.toJson())
          .toList();
      downloadsFile.writeAsStringSync(jsonEncode(list));
    } catch (_) {}
  }

  int get activeDownloadCount =>
      downloads.tasks.where((DownloadTask t) => t.isActive).length;
}
