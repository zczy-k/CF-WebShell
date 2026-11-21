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

  /// 合并结果是一次"大面积删除"，为了不误删先停下等用户点头。
  ///
  /// 这一条不是错误，是护栏：正常用户不会一口气删掉一半站点，会这么干的只有
  /// 代码（跨空间残留、服务端被重置、文档损坏被当成空）。停一次让人看一眼，
  /// 比事后从备份里捞强得多。
  needsConfirm,

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
    this.pendingRemovals = 0,
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

  /// 被护栏拦下的那一轮里，合并**打算**删掉几个站点。只在
  /// [SyncStatus.needsConfirm] 时有意义 —— 界面拿它写"检测到一次大量删除（13 个）"。
  final int pendingRemovals;

  bool get ok => status == SyncStatus.ok;

  /// 需要用户点一下头才能继续。
  bool get awaitingConfirm => status == SyncStatus.needsConfirm;

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

/// 同步状态的落盘位置：和 `starport.json` 放一起，叫 `starport.sync.json`。
///
/// 为什么单独一个文件而不是塞进主配置：这份东西是缓存，坏了可以直接删掉重来
/// （最多丢一次合并上下文，站点列表不会丢）—— 但要是塞进主配置，一份坏缓存就能
/// 让用户的站点列表看起来像被清空了。隔离风险。
class SyncStateFile {
  SyncStateFile(this.file);

  final File file;

  static const String defaultFileName = 'starport.sync.json';

  /// 上一次真正写进磁盘的那份内容（null = 这个实例还没写过）。
  String? _lastSavedText;

  void save(SyncLocalState state) {
    try {
      final Directory dir = file.parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final String text = jsonEncode(state.toJson());
      // 内容一模一样就别动了。同步的"双方都没变化"分支（见 SyncEngine._run）
      // 每轮都会走到这里，以前每轮都要拷一次 .bak + 全量重写 + fsync —— 那只是
      // 把同样的字节再落一遍盘。文件被外部删掉时 `_lastSavedText` 还在，
      // 所以要连着 existsSync 一起判，不能只比字符串。
      if (text == _lastSavedText && file.existsSync()) return;
      // 先把上一版留成 .bak：缓存文件要是哪天写坏了（断电、杀毒软件截断），
      // 下次启动能退回上一份，而不是从"什么都没有"重新猜合并基准。
      try {
        if (file.existsSync()) {
          final File bak = File('${file.path}.bak');
          file.copySync(bak.path);
        }
      } catch (_) {
        // 备份失败不影响主流程
      }
      // 直接覆盖而不是 tmp + rename：Windows 上 delete + rename 之间有个窗口，
      // rename 要是被文件锁挡回来，原来的文件已经没了 —— 那是真丢基准。
      // 缓存文件只有几十 KB，覆盖写的原子性够用（进程被强杀也会留下完整旧内容）。
      file.writeAsStringSync(text, flush: true);
      // 写在成功之后才记账：目录只读 / 磁盘满 / 文件被占用时不能把这份内容
      // 当成"已经在盘上了"。
      _lastSavedText = text;
    } catch (_) {
      // 目录只读 / 磁盘满 / 文件被占用（Windows 上很常见）：写不进缓存不该
      // 让整轮同步失败。最坏情况是下次启动没了合并基准，退化成一整份覆盖 ——
      // 站点列表本身不会丢，可接受。
    }
  }

  /// 读缓存。主文件坏了自动试 `.bak`，两个都坏就当没有。
  SyncLocalState load() {
    final SyncLocalState? main = _tryLoad(file);
    if (main != null) return main;
    final SyncLocalState? bak = _tryLoad(File('${file.path}.bak'));
    if (bak != null) return bak;
    return SyncLocalState();
  }

  SyncLocalState? _tryLoad(File f) {
    try {
      if (!f.existsSync()) return null;
      final String text = f.readAsStringSync();
      if (text.trim().isEmpty) return null;
      return SyncLocalState.fromJson(jsonDecode(text));
    } catch (_) {
      // 缓存坏了就当没有。绝不能让它影响启动。
      return null;
    }
  }
}

/// 凭证的存取接口。
///
/// 放在 core 里当抽象，是因为**存到哪儿**必须由 App 决定：Windows 上要走 DPAPI，
/// Android 上要走 Keystore，两者都在平台层。core 只约定"能存能取"。
abstract class SyncCredentialStore {
  Future<SyncCredentials?> read();

  /// 返回 false 表示"没写进去"（磁盘只读、权限被改、加密失败）。
  ///
  /// **这个返回值必须有人看**：凭证没落盘、配置里却写着"已开启"，用户看到的是
  /// 一个永远报「这台设备还没有配对」的开关 —— 比直接告诉他失败难查得多。
  Future<bool> write(SyncCredentials? credentials);
}

/// 内存版（测试 / 无安全存储的降级路径）。
class MemorySyncCredentialStore implements SyncCredentialStore {
  MemorySyncCredentialStore([this._credentials]);

  SyncCredentials? _credentials;

  @override
  Future<SyncCredentials?> read() async => _credentials;

  @override
  Future<bool> write(SyncCredentials? credentials) async {
    _credentials = credentials;
    return true;
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

  /// Incremented whenever a local snapshot is refreshed. A PUT may be in flight
  /// while the UI edits [config]; the revision prevents that older PUT result
  /// from being applied over the newer local snapshot.
  int _localRevision = 0;

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
    _localRevision++;
  }

  /// 跑一轮完整同步。并发调用会被直接忽略（返回上一轮的结果）。
  ///
  /// [_busy] 在**第一个 await 之前**就立起来。放在 `await credentials.read()`
  /// 之后是个窄缝：两个调用能双双通过开头的检查，然后在 await 处一起把标记置真，
  /// 接着并行跑两份 `_run` —— 合并结果交错写进 state，版本号互相踩。
  /// 现在唯一调用方 `SyncService` 自己还有 `_running` 挡着，但缝不该留着。
  Future<SyncRunResult> runOnce() async {
    if (_busy) return lastResult;
    _busy = true;
    try {
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

      final SyncRunResult result = await _run(creds);
      lastResult = result;
      return result;
    } on _SyncAbort catch (e) {
      // 已经翻成用户能看懂的状态了，这里只负责记下来。
      lastResult = e.result;
      return e.result;
    } finally {
      _busy = false;
      // 放行标记只在"确认删除"的那一轮里有效。这一轮不管走到哪（提前返回、
      // 出错、没变化），标记都作废，免得下一次轮询莫名其妙绕过护栏。
      _allowBigDelete = false;
    }
  }

  /// 用户点了"确认删除" —— 放行下一轮的大面积删除护栏。
  ///
  /// 实现上不复用上一轮的合并结果，直接重跑一轮更稳：远端可能在这几秒里又动了，
  /// 拿旧的 merged 去写会把别人的新改动盖掉。
  Future<SyncRunResult> confirmBigDelete() async {
    _allowBigDelete = true;
    return runOnce();
  }

  /// 一次性放行标记（[confirmBigDelete] 用）。
  bool _allowBigDelete = false;

  /// 拿一份能用的客户端。没配对就抛出去 —— 这两个接口是用户主动点的，
  /// 不该像轮询那样静默返回一个状态码了事。
  Future<SyncClient> _pairedClient() async {
    final SyncCredentials? creds = await credentials.read();
    if (creds == null) {
      throw SyncException('这台设备还没有配对');
    }
    return SyncClient(creds);
  }

  /// 云端历史版本清单（新的在前）。
  ///
  /// 这是"备份"那一侧的入口：合并把数据搞乱了、或者用户手滑删了一片，
  /// 至少还能退回到之前某一版。
  Future<List<SyncHistoryEntry>> history() async {
    final SyncClient client = await _pairedClient();
    return client.history();
  }

  /// 把第 [version] 版恢复成当前版本。
  ///
  /// 服务端把它写成**新的一版**（版本号 +1），所以恢复完之后调用方应该再跑一轮
  /// [runOnce] —— 这一轮会被 `HEAD` 的版本号带着把内容拉下来，其它设备同理。
  Future<SyncPutResult> restoreHistory(int version) async {
    final SyncClient client = await _pairedClient();
    final SyncPutResult r = await client.restoreHistory(version);
    if (!r.ok) {
      // 409 说明这中间别人又推了一版。不重试：让调用方再列一次历史，
      // 用户看着最新清单重新选，比在后台猜更靠谱。
      throw SyncException('云端刚刚又有新改动，历史没恢复，请重新选一次');
    }
    return r;
  }

  Future<SyncRunResult> _run(SyncCredentials creds) async {
    final SyncClient client = SyncClient(creds);

    // 1) 本机变化折进 local（含删除 → 墓碑）
    markDirty();

    // 2) 版本号探一下
    final SyncHead head = await _guard<SyncHead>(() => client.head());
    // 可变：下面"服务端被重置"那条路要把它改成 true。
    bool dirty = state.local.contentHash() != state.base.contentHash();
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

    // 4.5) 服务端被重置了吗
    //
    // 重建 D1、从备份还原了个空库、手工删了 spaces 那行 —— 都会让服务端文档
    // 变空、版本号变小。这时"远端没有站点"不是因为"远端把它们删了"，而是因为
    // 远端换了一个空库。要是照三方合并的字面意思走，本机每一条都会被判成
    // "远端删除"，然后全量墓碑推上去，所有设备跟着清空。
    //
    // 判据用版本号：它只会在 CAS 成功时 +1，变小只可能是库被换了。版本号正常
    // 递增而文档变空，才是"别人真的删光了"，那种情况照常合并。
    final bool remoteEmpty = remoteDoc.sites.isEmpty && remoteDoc.prefs.isEmpty;
    if (remoteEmpty && !state.base.isEmpty && remoteVersion < state.version) {
      state.base = SyncDoc();
      state.version = 0;
      // base 一清，本机这份内容就成了"唯一的一份"，必须推上去把空库填回来。
      //
      // 不重算 dirty 会掉进一个死循环：dirty 是清 base **之前**算的
      // （local 和 base 一样 → false），于是这一轮不推；记账又把 version 写成
      // 远端的 0、base 写成 merged，下一轮 head.version(0) == state.version(0)
      // 且 dirty 仍为 false → 直接 return。空库永远填不回来，其它设备全空。
      dirty = true;
    }

    SyncMergeResult merged =
        SyncDoc.merge(base: state.base, local: state.local, remote: remoteDoc, now: _clock());
    merged.doc.prune(now: _now());

    // 4.6) 大面积删除护栏
    //
    // 正常用户不会一口气删掉一半站点。会这么干的只有代码：跨空间残留、服务端
    // 被重置、远端文档损坏被当成空…… 这一道不修任何具体 bug，它拦的是
    // "本机站点数要掉一半以上"这个**结果**，所以对将来新出现的 bug 一样有效。
    // 停一轮让人看一眼，比事后从历史版本里捞强得多。
    SyncRunResult? checkBigDeleteGuard(SyncMergeResult candidate) {
      final int beforeAlive = config.sites.length;
      final int afterAlive = candidate.doc.aliveSites.length;
      final int willRemove = beforeAlive - afterAlive;
      if (_allowBigDelete || !isBigDelete(beforeAlive, afterAlive, willRemove)) {
        return null;
      }
      // 什么都不写：不推、不改配置、不动 base/local。下一轮还会拦在这里，
      // 直到用户点"确认删除"或者自己把站点加回来。
      return SyncRunResult(
        status: SyncStatus.needsConfirm,
        message: '检测到一次大量删除（$willRemove 个站点），已暂停执行',
        conflicts: candidate.conflicts,
        version: state.version,
        pendingRemovals: willRemove,
      );
    }

    final SyncRunResult? initialGuard = checkBigDeleteGuard(merged);
    if (initialGuard != null) return initialGuard;
    int mergedLocalRevision = _localRevision;
    String mergedLocalHash = state.local.contentHash();

    bool pushed = false;
    int finalVersion = remoteVersion;
    final bool remoteAhead = remoteVersion != state.version;

    /// 最后一次见到的**服务端**文档。冲突重试用它 —— 见下面 base 的赋值。
    SyncDoc remoteLatest = remoteDoc;

    // 推的条件：本地相对 base 有改动。远端只是更新、本地没改的话推一遍
    // 内容一样的文档纯属浪费额度（D1 免费额度是按写行数算的）。
    if (dirty) {
      for (int attempt = 0; attempt < maxAttempts; attempt++) {
        final int putRevision = _localRevision;
        final String putConfigHash = _configHash(config);
        final SyncPutResult put =
            await _guard<SyncPutResult>(() => client.putDoc(merged.doc, remoteVersion));
        // Normally the UI calls markDirty after editing. Also catch a config
        // mutation without that notification so it is not lost on completion.
        if (_localRevision != putRevision ||
            _configHash(config) != putConfigHash) {
          markDirty();
        }
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
        mergedLocalRevision = _localRevision;
        mergedLocalHash = state.local.contentHash();

        // The remote document may turn a previously safe merge into a large
        // deletion. Recheck before another PUT and before applying it locally.
        final SyncRunResult? retryGuard = checkBigDeleteGuard(merged);
        if (retryGuard != null) return retryGuard;
      }
    }

    // A newer local snapshot may have arrived while the last PUT was pending.
    // Keep current config/local and retain the pre-PUT remote base/version so
    // the next run fetches the accepted document and merges the pending edit.
    final bool preserveNewerLocal =
        _localRevision != mergedLocalRevision &&
        state.local.contentHash() != mergedLocalHash;

    // 5) 合并结果写回本机配置
    final String hashBefore = _configHash(config);
    merged.doc.spaceId = creds.spaceId;
    if (!preserveNewerLocal) merged.doc.applyTo(config);
    final bool configChanged = _configHash(config) != hashBefore;
    if (configChanged) onConfigChanged?.call();

    // 6) 记账
    //
    // **推失败时 base 必须是服务端那一版，不能是 merged。**
    // 要是写成 merged，下一轮的 dirty 会算成"本地和 base 一样"= 没改动 → 永远
    // 不再推，本机这几条改动就静静地丢了。改成记服务端版本，dirty 依然为真，
    // 下一轮（几十秒后）会带着新的远端再合一次再推。
    final bool pushFailed = dirty && !pushed;
    state.base = pushFailed || preserveNewerLocal
        ? remoteLatest.copy()
        : merged.doc.copy();
    if (!preserveNewerLocal) state.local = merged.doc.copy();
    state.version =
        pushed && !preserveNewerLocal ? finalVersion : remoteVersion;
    final int mergedSeen = merged.doc.maxAt;
    final int localSeen = state.local.maxAt;
    final int seen = mergedSeen > localSeen ? mergedSeen : localSeen;
    if (seen > state.lastSeenAt) state.lastSeenAt = seen;
    final int now = _now();
    if (pushed) state.lastPushMs = now;
    if (remoteAhead && !preserveNewerLocal) state.lastPullMs = now;
    stateFile.save(state);

    return SyncRunResult(
      status: SyncStatus.ok,
      version: state.version,
      conflicts: merged.conflicts,
      configChanged: configChanged,
      pushed: pushed,
      pulled: !preserveNewerLocal && (remoteAhead || configChanged),
      // 冲突重试用完了还没推上去：东西都在本机，下一轮会再试，别让用户以为丢了。
      message: preserveNewerLocal
          ? '本机在推送期间有新改动，稍后重试'
          : (pushFailed
              ? '别处改得太频繁，本机改动稍后重试'
              : (pushed || remoteAhead ? '已同步' : '')),
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

/// 大面积删除护栏的门槛：本机原本至少这么多站点才会开始判断。
const int kBigDeleteMinAlive = 5;

/// 一次要删掉至少这么多个才拦。
const int kBigDeleteMinRemoved = 3;

/// [before] 原本有几个站点、[after] 合并后剩几个、[willRemove] 这次打算删几个。
///
/// 判定条件是"删掉一半以上、且至少 3 个"。为什么不是"删掉 N 个就拦"：
/// 站点少的时候误报太吵（一个人只有 4 个站，删 1 个就弹窗）。为什么不是
/// "百分比"：站点多了以后 10% 也可能是十几个，那时候也该拦。
/// 两个条件取交集，实际效果是"量变到能被察觉的程度才问一句"。
bool isBigDelete(int before, int after, int willRemove) {
  if (before < kBigDeleteMinAlive) return false;
  if (willRemove < kBigDeleteMinRemoved) return false;
  return after * 2 <= before;
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
