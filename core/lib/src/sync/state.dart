/// 同步引擎 —— 把「本机配置」「本地缓存文档」「远端文档」三者拧在一起。
///
/// 一次同步（[SyncEngine.runOnce]）做的事：
///
/// ```
/// 1. 把本机配置的变化折进 local（含删除 → 墓碑）
/// 2. 问服务端当前版本号（几十字节）
/// 3. 本地没改动、版本号也一样 → 直接结束（绝大多数轮询走这条）
/// 4. 否则拉整份远端文档，三方合并
/// 5. 合并结果写回本机配置 → 存盘 → 通知 UI
/// 6. 本地领先就把合并结果推上去；被版本号挡回来（409）就带着最新远端重来一轮
/// ```
///
/// 这里刻意**没有**定时器、没有 Flutter、没有全局单例：调度（8 秒防抖、
/// 启动拉一次、回前台拉一次、60→180 秒轮询）归 App 层管。
/// 分开的好处是这一个文件能纯逻辑测，CI 上不需要模拟器。
library;

import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../models.dart';
import 'client.dart';
import 'doc.dart';

/// 同步的整体状态，UI 上就按这个换图标/换文案。
enum SyncStatus {
  /// 没配置或没打开。
  disabled,

  /// 正在跑。
  running,

  /// 一切正常。
  ok,

  /// 连不上服务（断网、服务挂了）。会自己重试，不用用户操心。
  offline,

  /// 凭证失效 / 被踢出 —— 必须重新配对，重试没用。
  authFailed,

  /// 其它错误。
  error,
}

/// 一次同步的结果。
class SyncRunResult {
  const SyncRunResult({
    required this.status,
    this.message = '',
    this.conflicts = 0,
    this.version = 0,
    this.configChanged = false,
    this.pushed = false,
    this.pulled = false,
  });

  final SyncStatus status;
  final String message;

  /// 两边都改过的站点条数。>0 说明这次合并不是"照抄"，两个改动都保住了。
  final int conflicts;
  final int version;

  /// 本机配置被改写过 —— 调用方要存盘并刷新界面。
  final bool configChanged;

  /// 这次真的推了东西上去 / 真的从上面拿下了新东西。
  final bool pushed;
  final bool pulled;

  bool get ok => status == SyncStatus.ok;

  static const SyncRunResult disabled =
      SyncRunResult(status: SyncStatus.disabled, message: '同步未开启');
}

/// 落盘的本地同步状态。
///
/// 三个字段各有用处，缺一个都会出 bug：
/// * [base] —— 上一次和服务端一致的那版。**没有它就没法三方合并**，
///   只能"谁新听谁的"，A 改名字 B 改图标必丢一个。
/// * [local] —— 本机现在的样子，含墓碑。删除只有靠墓碑才传得出去。
/// * [version] —— 服务端版本号，推送时的 CAS 基准。
class SyncLocalState {
  SyncLocalState({
    SyncDoc? base,
    SyncDoc? local,
    this.version = 0,
    this.lastSeenAt = 0,
    this.lastPushMs = 0,
    this.lastPullMs = 0,
  })  : base = base ?? SyncDoc(),
        local = local ?? SyncDoc();

  SyncDoc base;
  SyncDoc local;
  int version;

  /// 从远端见过的最大逻辑时间。本机生成新 at 时要压过它（HLC 的核心）。
  int lastSeenAt;

  int lastPushMs;
  int lastPullMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': 1,
        'version': version,
        'lastSeenAt': lastSeenAt,
        'lastPushMs': lastPushMs,
        'lastPullMs': lastPullMs,
        'base': base.toJson(),
        'local': local.toJson(),
      };

  static SyncLocalState fromJson(Object? raw) {
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    final SyncLocalState s = SyncLocalState(
      base: SyncDoc.fromJson(m['base']),
      local: SyncDoc.fromJson(m['local']),
      version: _i(m['version']),
      lastSeenAt: _i(m['lastSeenAt']),
      lastPushMs: _i(m['lastPushMs']),
      lastPullMs: _i(m['lastPullMs']),
    );
    return s;
  }
}

/// 同步状态的落盘位置：和 `webshell.json` 放一起，叫 `webshell.sync.json`。
///
/// 为什么单独一个文件而不是塞进主配置：这份东西是缓存，坏了可以直接删掉重来
/// （最多丢一次合并上下文，站点列表不会丢）—— 但要是塞进主配置，一份坏缓存就能
/// 让用户的站点列表看起来像被清空了。隔离风险。
class SyncStateFile {
  SyncStateFile(this.file);

  final File file;

  static const String defaultFileName = 'webshell.sync.json';

  SyncLocalState load() {
    if (!file.existsSync()) return SyncLocalState();
    try {
      return SyncLocalState.fromJson(jsonDecode(file.readAsStringSync()));
    } catch (_) {
      // 缓存坏了就当没有。绝不能让它影响启动。
      return SyncLocalState();
    }
  }

  void save(SyncLocalState state) {
    try {
      final Directory dir = file.parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final File tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(state.toJson()), flush: true);
      if (file.existsSync()) file.deleteSync();
      tmp.renameSync(file.path);
    } catch (_) {
      // 目录只读 / 磁盘满 / 文件被占用（Windows 上很常见）：写不进缓存不该
      // 让整轮同步失败。最坏情况是下次启动没了合并基准，退化成一整份覆盖 ——
      // 站点列表本身不会丢，可接受。
    }
  }
}

/// 凭证的存取接口。
///
/// 放在 core 里当抽象，是因为**存到哪儿**必须由 App 决定：Windows 上要走 DPAPI，
/// Android 上要走 Keystore，两者都在平台层。core 只约定"能存能取"。
abstract class SyncCredentialStore {
  Future<SyncCredentials?> read();
  Future<void> write(SyncCredentials? credentials);
}

/// 内存版（测试 / 无安全存储的降级路径）。
class MemorySyncCredentialStore implements SyncCredentialStore {
  MemorySyncCredentialStore([this._credentials]);

  SyncCredentials? _credentials;

  @override
  Future<SyncCredentials?> read() async => _credentials;

  @override
  Future<void> write(SyncCredentials? credentials) async {
    _credentials = credentials;
  }
}

/// 同步引擎。
class SyncEngine {
  SyncEngine({
    required this.config,
    required this.stateFile,
    required this.credentials,
    required this.state,
    this.onConfigChanged,
    this.maxAttempts = 3,
  });

  /// 本机配置。引擎会就地改写它（合并结果落进去）。
  final ShellConfig config;

  final SyncStateFile stateFile;
  final SyncCredentialStore credentials;

  /// 本地状态。引擎每轮结束会把它写回 [stateFile]。
  SyncLocalState state;

  /// 配置被改写后的回调 —— App 在这里存盘 + `notifyListeners()`。
  final void Function()? onConfigChanged;

  /// 推送被 409 顶回来时最多重试几轮。3 轮足够：真在同时改同一台设备的人，
  /// 多试几轮也只是浪费请求。
  final int maxAttempts;

  /// 上一次跑的结果，给 UI 看。
  SyncRunResult lastResult = SyncRunResult.disabled;

  /// 正在跑（防止定时器和"用户手动点一下"撞在一起）。
  bool get busy => _busy;
  bool _busy = false;

  int _now() => DateTime.now().millisecondsSinceEpoch;

  /// 本机生成时间戳的基准：必须压过"从远端见过的最大 at"。
  ///
  /// 这一行就是 HLC 的全部秘密。没有它，一台时钟慢 5 分钟的设备（Windows 时间
  /// 服务抽风、手机手动改过时间）就会陷入"我改完它自己变回去"——
  /// 因为它的每次编辑时间戳都比别人小。
  int _clock() {
    final int now = _now();
    return now > state.lastSeenAt ? now : state.lastSeenAt + 1;
  }

  /// 把本机配置的变化折进 [state.local]（不联网）。
  ///
  /// 界面上的增删改都可以只调这个然后去防抖，不必等网络。
  void markDirty() {
    state.local.refreshFromConfig(config, now: _clock());
  }

  /// 跑一轮完整同步。并发调用会被直接忽略（返回上一轮的结果）。
  Future<SyncRunResult> runOnce() async {
    if (_busy) return lastResult;
    if (!config.syncConfigured) {
      lastResult = SyncRunResult.disabled;
      return lastResult;
    }

    final SyncCredentials? creds = await credentials.read();
    if (creds == null) {
      lastResult = const SyncRunResult(
        status: SyncStatus.authFailed,
        message: '这台设备还没有配对',
      );
      return lastResult;
    }

    _busy = true;
    try {
      final SyncRunResult result = await _run(creds);
      lastResult = result;
      return result;
    } on _SyncAbort catch (e) {
      // 已经翻成用户能看懂的状态了，这里只负责记下来。
      lastResult = e.result;
      return e.result;
    } finally {
      _busy = false;
    }
  }

  Future<SyncRunResult> _run(SyncCredentials creds) async {
    final SyncClient client = SyncClient(creds);

    // 1) 本机变化折进 local（含删除 → 墓碑）
    markDirty();

    // 2) 版本号探一下
    final SyncHead head = await _guard<SyncHead>(() => client.head());
    final bool dirty = state.local.contentHash() != state.base.contentHash();
    if (!dirty && head.version == state.version) {
      // 3) 双方都没动 —— 最常见的情况，一次请求结束
      stateFile.save(state);
      return SyncRunResult(
        status: SyncStatus.ok,
        version: state.version,
      );
    }

    // 4) 拉远端 + 合并（冲突就重来，最多 maxAttempts 轮）
    SyncDoc remoteDoc;
    int remoteVersion;
    if (head.version == state.version && dirty) {
      // 远端没动，本地动了：不必拉整份文档，直接在本地基础上算
      remoteDoc = state.base;
      remoteVersion = state.version;
    } else {
      final SyncEnvelope env = await _guard<SyncEnvelope>(() => client.fetchDoc());
      remoteDoc = env.doc;
      remoteVersion = env.version;
    }

    SyncMergeResult merged =
        SyncDoc.merge(base: state.base, local: state.local, remote: remoteDoc, now: _clock());
    merged.doc.prune(now: _now());

    bool pushed = false;
    int finalVersion = remoteVersion;
    final bool remoteAhead = remoteVersion != state.version;

    /// 最后一次见到的**服务端**文档。冲突重试用它 —— 见下面 base 的赋值。
    SyncDoc remoteLatest = remoteDoc;

    // 推的条件：本地相对 base 有改动。远端只是更新、本地没改的话推一遍
    // 内容一样的文档纯属浪费额度（D1 免费额度是按写行数算的）。
    if (dirty) {
      for (int attempt = 0; attempt < maxAttempts; attempt++) {
        final SyncPutResult put =
            await _guard<SyncPutResult>(() => client.putDoc(merged.doc, remoteVersion));
        if (put.ok) {
          pushed = true;
          finalVersion = put.version;
          break;
        }
        // 409：别人先推了。拿着最新远端重新合并一轮。
        final SyncDoc? latest = put.doc;
        if (latest == null) {
          throw SyncException('同步冲突但服务端没返回文档');
        }
        remoteLatest = latest;
        remoteVersion = put.version;
        merged = SyncDoc.merge(
          base: state.base,
          local: state.local,
          remote: latest,
          now: _clock(),
        );
        merged.doc.prune(now: _now());
      }
    }

    // 5) 合并结果写回本机配置
    final String hashBefore = _configHash(config);
    merged.doc.spaceId = creds.spaceId;
    merged.doc.applyTo(config);
    final bool configChanged = _configHash(config) != hashBefore;
    if (configChanged) onConfigChanged?.call();

    // 6) 记账
    //
    // **推失败时 base 必须是服务端那一版，不能是 merged。**
    // 要是写成 merged，下一轮的 dirty 会算成"本地和 base 一样"= 没改动 → 永远
    // 不再推，本机这几条改动就静静地丢了。改成记服务端版本，dirty 依然为真，
    // 下一轮（几十秒后）会带着新的远端再合一次再推。
    final bool pushFailed = dirty && !pushed;
    state.base = pushFailed ? remoteLatest.copy() : merged.doc.copy();
    state.local = merged.doc.copy();
    state.version = pushed ? finalVersion : remoteVersion;
    final int seen = merged.doc.maxAt;
    if (seen > state.lastSeenAt) state.lastSeenAt = seen;
    final int now = _now();
    if (pushed) state.lastPushMs = now;
    if (remoteAhead) state.lastPullMs = now;
    stateFile.save(state);

    return SyncRunResult(
      status: SyncStatus.ok,
      version: state.version,
      conflicts: merged.conflicts,
      configChanged: configChanged,
      pushed: pushed,
      pulled: remoteAhead || configChanged,
      // 冲突重试用完了还没推上去：东西都在本机，下一轮会再试，别让用户以为丢了。
      message: pushFailed
          ? '别处改得太频繁，本机改动稍后重试'
          : (pushed || remoteAhead ? '已同步' : ''),
    );
  }

  /// 把异常翻成状态：网络类错误 → [SyncStatus.offline]（会自动重试），
  /// 401/403 → [SyncStatus.authFailed]（重试没用，得重新配对）。
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on SyncException catch (e) {
      if (e.status == 401 || e.status == 403) {
        throw _SyncAbort(
          SyncRunResult(
            status: SyncStatus.authFailed,
            message: e.message,
            version: state.version,
          ),
        );
      }
      if (e.status == 0 || e.status >= 500 || e.status == 429) {
        throw _SyncAbort(
          SyncRunResult(
            status: SyncStatus.offline,
            message: e.message,
            version: state.version,
          ),
        );
      }
      throw _SyncAbort(
        SyncRunResult(
          status: SyncStatus.error,
          message: e.message,
          version: state.version,
        ),
      );
    }
  }

  /// 断开同步：清掉凭证，但**保留本地缓存**。
  ///
  /// 保留的理由：用户可能只是临时关掉同步，再打开时还能接着上次的 base 合并，
  /// 不用从头猜。凭证才是"身份"，它是必须清的。
  Future<void> disconnect() async {
    await credentials.write(null);
    stateFile.save(state);
    lastResult = SyncRunResult.disabled;
  }
}

/// 内部用的中止信号 —— 把 [_guard] 里翻好的结果直接抛到 [SyncEngine.runOnce]。
class _SyncAbort implements Exception {
  _SyncAbort(this.result);
  final SyncRunResult result;
}

/// 配置的内容指纹，用来判断"合并到底改没改本机配置"。
///
/// 只算会影响同步的字段 —— 拿整个 toJson() 去比会把 lastOpenedMs、
/// lastUpdateCheckMs 这些本机行为也算进去，于是每次都报"变了"，界面白刷新一遍。
String _configHash(ShellConfig config) {
  final StringBuffer sb = StringBuffer();
  for (final SiteProfile s in config.sites) {
    sb
      ..write(s.startUrl)
      ..write('\u0001')
      ..write(s.name)
      ..write('\u0001')
      ..write(s.iconUrl ?? '')
      ..write('\u0001')
      ..write(s.themeColor)
      ..write('\u0001')
      ..write(s.userAgent ?? '')
      ..write('\u0001')
      ..write(s.hasBasicAuth)
      ..write('\u0001')
      ..write(s.basicUser ?? '')
      ..write('\u0001')
      ..write(s.stayInSite)
      ..write('\u0001')
      ..write(s.allowSelfSignedCert)
      ..write('\u0002');
  }
  sb
    ..write(config.loadImages)
    ..write(config.wifiOnlyDownloads)
    ..write(config.askWhereToSave)
    ..write(config.closeToTray)
    ..write(config.maxConcurrentDownloads);
  return sb.toString();
}

int _i(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}
