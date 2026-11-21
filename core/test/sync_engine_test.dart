/// 同步引擎（[SyncEngine]）的端到端单测。
///
/// 起一个真的 `HttpServer` 冒充 Cloudflare Worker —— 走的是真 HTTP、真的
/// CAS 版本号、真的 JSON 往返，只是把网络换成了回环口。这样这一整套
/// "head → 拉 → 合并 → 推 → 409 重试 → 记账" 的逻辑在 CI 上两秒钟就能验完，
/// 不用等 APK/EXE 打出来拿两台设备对着点。
///
/// 重点覆盖三类用户真的会遇到的事故：
///   * 别的设备加了站 / 删了站，这台设备能不能跟上（含墓碑）
///   * 两边同时改，谁赢，会不会丢
///   * **推失败时本地改动会不会被静默吞掉**（下面「409 重试用尽」那组，
///     就是为一个真实存在过的数据丢失写法补的回归测试）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:starport_core/starport_core.dart';

const String kUrlA = 'https://a.example.com';
const String kUrlB = 'https://b.example.com';
const String kSpace = 'sp_test';

SiteProfile site(String url, {String id = '', String name = '', int updatedAtMs = 0}) =>
    SiteProfile(
      id: id.isEmpty ? 'id-$url' : id,
      name: name,
      startUrl: url,
      updatedAtMs: updatedAtMs,
    );

/// 一个极简的"Worker"：只实现同步用到的四个接口，版本号 CAS 行为照抄真的。
class FakeCloud {
  FakeCloud._(this._server) {
    _server.listen(_handle);
  }

  static Future<FakeCloud> start() async {
    final HttpServer s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return FakeCloud._(s);
  }

  final HttpServer _server;

  String get endpoint => 'http://127.0.0.1:${_server.port}';

  int version = 0;
  Map<String, dynamic> doc = <String, dynamic>{};

  /// 收到的 PUT 次数（用来验证"没变化就不推"真的省下额度）。
  int putCalls = 0;

  /// 接下来的 N 次 PUT 强制回 409，并在每次顺便"让别的设备"改点东西。
  int forceConflicts = 0;

  /// 可选的确定性冲突文档，用于构造特定的重合并结果。
  SyncDoc? forcedConflictDoc;

  /// PUT 屏障：测试可等待请求抵达，再编辑本地配置后放行响应。
  Completer<void>? putReceived;
  Completer<void>? releasePut;

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final String path = req.uri.path;
    try {
      if (req.method == 'GET' && path == '/v1/head') {
        _json(req, <String, dynamic>{'v': version, 'updatedAt': 0});
        return;
      }
      if (req.method == 'GET' && path == '/v1/doc') {
        _json(req, <String, dynamic>{'v': version, 'updatedAt': 0, 'doc': doc});
        return;
      }
      if (req.method == 'PUT' && path == '/v1/doc') {
        putCalls++;
        final String text = await utf8.decoder.bind(req).join();
        final Map<String, dynamic> body = jsonDecode(text) as Map<String, dynamic>;
        final int baseV = body['baseV'] as int? ?? -1;
        final Completer<void>? received = putReceived;
        if (received != null) {
          putReceived = null;
          received.complete();
          final Completer<void>? release = releasePut;
          if (release != null) await release.future;
          releasePut = null;
        }

        if (forcedConflictDoc != null) {
          doc = forcedConflictDoc!.toJson();
          forcedConflictDoc = null;
          version++;
          _json(req, <String, dynamic>{'ok': false, 'v': version, 'doc': doc}, 409);
          return;
        }
        if (forceConflicts > 0) {
          forceConflicts--;
          version++;
          // 别的设备插了一条，制造真的冲突（不是空转）
          final Map<String, dynamic> other =
              (doc['sites'] as Map<String, dynamic>?) ?? <String, dynamic>{};
          other['https://other-$version.example.com'] = <String, dynamic>{
            'startUrl': 'https://other-$version.example.com',
            'name': '别人的站$version',
            'at': DateTime.now().millisecondsSinceEpoch + version,
          };
          doc['sites'] = other;
          _json(req, <String, dynamic>{'ok': false, 'v': version, 'doc': doc}, 409);
          return;
        }
        if (baseV != version) {
          _json(req, <String, dynamic>{'ok': false, 'v': version, 'doc': doc}, 409);
          return;
        }
        doc = body['doc'] as Map<String, dynamic>;
        version++;
        _json(req, <String, dynamic>{'ok': true, 'v': version});
        return;
      }
      _json(req, <String, dynamic>{'error': 'not_found'}, 404);
    } catch (e) {
      _json(req, <String, dynamic>{'error': 'server_error', 'e': '$e'}, 500);
    }
  }

  void _json(HttpRequest req, Object body, [int status = 200]) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body))
      ..close();
  }

  /// 文档里有没有某个地址（不管死活）。
  bool hasUrl(String url) => jsonEncode(doc).contains(url);

  /// 某个地址在服务端是不是墓碑。
  bool isDeleted(String url) {
    final Map<String, dynamic>? sites = doc['sites'] as Map<String, dynamic>?;
    final Object? e = sites?[url];
    if (e is! Map) return false;
    return e['deleted'] == true;
  }
}

void main() {
  late FakeCloud cloud;
  late Directory dir;

  setUp(() async {
    cloud = await FakeCloud.start();
    dir = Directory.systemTemp.createTempSync('ws-sync-engine-');
  });

  tearDown(() async {
    await cloud.close();
    // 同步请求现在共用一个 HttpClient（连接池跟着进程走）。假云端关掉后
    // 它的临时端口会被下一个用例复用，池里那条空闲连接不能带过去。
    SyncClient.closeSharedClient();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 一台"设备"：配置 + 缓存文件 + 引擎。
  ({ShellConfig config, SyncEngine engine}) device({
    List<SiteProfile> sites = const <SiteProfile>[],
    String name = 'dev',
  }) {
    final ShellConfig config = ShellConfig(
      sites: List<SiteProfile>.of(sites),
      syncEnabled: true,
      syncEndpoint: cloud.endpoint,
      syncSpaceId: kSpace,
    );
    final SyncStateFile file = SyncStateFile(File('${dir.path}/$name.sync.json'));
    final SyncEngine engine = SyncEngine(
      config: config,
      stateFile: file,
      credentials: MemorySyncCredentialStore(
        SyncCredentials(
          endpoint: cloud.endpoint,
          spaceId: kSpace,
          deviceId: 'dv_$name',
          deviceToken: 'tk_$name',
          deviceName: name,
        ),
      ),
      state: file.load(),
    );
    return (config: config, engine: engine);
  }

  group('首次推送', () {
    test('本机的站点推上去，第二轮没变化就不再推（省额度）', () async {
      final (config: config, engine: engine) =
          device(sites: <SiteProfile>[site(kUrlA, name: 'A')]);

      final SyncRunResult first = await engine.runOnce();
      expect(first.status, SyncStatus.ok);
      expect(first.pushed, isTrue);
      expect(cloud.hasUrl(kUrlA), isTrue);
      expect(cloud.putCalls, 1);

      final SyncRunResult second = await engine.runOnce();
      expect(second.pushed, isFalse);
      expect(second.pulled, isFalse);
      expect(cloud.putCalls, 1, reason: '内容没变还推一遍就是白烧 D1 写额度');
      expect(config.sites.length, 1);
    });
  });

  group('跟别的设备', () {
    test('别的设备加了站 → 这台设备拉下来', () async {
      final SyncDoc remote = SyncDoc();
      remote.sites[kUrlB] = SyncSite(
        key: kUrlB,
        startUrl: kUrlB,
        name: 'B',
        at: DateTime.now().millisecondsSinceEpoch,
      );
      cloud.doc = remote.toJson();
      cloud.version = 1;

      final (config: config, engine: engine) =
          device(sites: <SiteProfile>[site(kUrlA, name: 'A')]);

      final SyncRunResult r = await engine.runOnce();
      expect(r.pulled, isTrue);
      expect(config.sites.map((SiteProfile s) => s.startUrl), contains(kUrlB));
      expect(config.sites.map((SiteProfile s) => s.startUrl), contains(kUrlA));
    });

    test('这台设备删了站 → 服务端留墓碑，另一台设备也跟着删', () async {
      // 两台设备先对齐：都只有 A
      final (config: config1, engine: engine1) =
          device(sites: <SiteProfile>[site(kUrlA, name: 'A')], name: 'pc');
      await engine1.runOnce();
      expect(cloud.hasUrl(kUrlA), isTrue);

      final (config: config2, engine: engine2) = device(
        sites: <SiteProfile>[site(kUrlA, name: 'A')],
        name: 'phone',
      );
      await engine2.runOnce();

      // 电脑上删掉
      config1.sites.removeWhere((SiteProfile s) => s.startUrl == kUrlA);
      final SyncRunResult delResult = await engine1.runOnce();
      expect(delResult.pushed, isTrue);
      expect(cloud.isDeleted(kUrlA), isTrue, reason: '删站要靠墓碑传出去，不能只是"没看见"');

      // 手机上拉一轮 → A 消失
      final SyncRunResult pullResult = await engine2.runOnce();
      expect(pullResult.ok, isTrue);
      expect(
        config2.sites.any((SiteProfile s) => s.startUrl == kUrlA),
        isFalse,
        reason: 'A 在别的设备上被删了，这台也得删',
      );
    });

    test('两边改同一个站点：时间新的赢', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;

      // 远端已经有一条"别人刚改过名字"的记录（时间更新）
      final SyncDoc remote = SyncDoc();
      remote.sites[kUrlA] = SyncSite(
        key: kUrlA,
        startUrl: kUrlA,
        name: '远端起的名字',
        at: now + 60000,
      );
      cloud.doc = remote.toJson();
      cloud.version = 3;

      final (config: config, engine: engine) = device(
        sites: <SiteProfile>[site(kUrlA, name: '本机起的名字', updatedAtMs: now)],
      );

      await engine.runOnce();
      final SiteProfile a = config.sites.firstWhere((SiteProfile s) => s.startUrl == kUrlA);
      expect(a.name, '远端起的名字');
    });
  });

  group('409 后重验大面积删除护栏', () {
    test('409 重合并出现大量删除时不再 PUT，也不改本机配置', () async {
      final List<SiteProfile> initialSites = <SiteProfile>[
        for (int i = 0; i < 6; i++) site('https://guard-$i.example.com', name: '站点$i'),
      ];
      final (config: config, engine: engine) = device(sites: initialSites);
      await engine.runOnce();
      final int callsBefore = cloud.putCalls;
      final int versionBefore = engine.state.version;

      config.sites.add(site('https://new.example.com', name: '本机新增'));
      final SyncDoc conflictingRemote = SyncDoc.fromJson(cloud.doc);
      final int deleteAt = DateTime.now().millisecondsSinceEpoch + 60000;
      for (final String key in conflictingRemote.sites.keys.toList()) {
        final SyncSite current = conflictingRemote.sites[key]!;
        conflictingRemote.sites[key] =
            SyncSite.tombstone(key, current.startUrl, deleteAt);
      }
      cloud.forcedConflictDoc = conflictingRemote;

      final SyncRunResult result = await engine.runOnce();
      expect(result.status, SyncStatus.needsConfirm);
      expect(result.pendingRemovals, 6);
      expect(config.sites.length, 7, reason: '护栏必须挡在 applyTo 之前');
      expect(cloud.putCalls, callsBefore + 1, reason: '409 后不该再发第二次 PUT');
      expect(engine.state.version, versionBefore, reason: '被拦下的合并不应记账');
    });
  });

  group('409 重试用尽', () {
    test('推失败时本地改动不能被静默吞掉（下一轮还能推上去）', () async {
      final (config: config, engine: engine) =
          device(sites: <SiteProfile>[site(kUrlA, name: 'A')]);

      // 连着三次都被顶回来 = maxAttempts 用尽
      cloud.forceConflicts = 3;
      final SyncRunResult failed = await engine.runOnce();
      expect(failed.status, SyncStatus.ok);
      expect(failed.pushed, isFalse);
      expect(failed.message, contains('稍后重试'));

      // 关键：base 不能等于 local，否则下一轮算成"没改动"就再也不推了
      expect(
        engine.state.local.contentHash(),
        isNot(engine.state.base.contentHash()),
        reason: '本地还欠着一次推送，必须让下一轮看得出来',
      );
      expect(cloud.hasUrl(kUrlA), isFalse);

      // 下一轮（冲突消失）应该把本机改动补上去
      final SyncRunResult retry = await engine.runOnce();
      expect(retry.pushed, isTrue);
      expect(cloud.hasUrl(kUrlA), isTrue, reason: '本机改动最终必须到服务端，不能丢');
    });
  });

  group('PUT 期间的本地编辑', () {
    test('成功响应不能覆盖 PUT 发出后 markDirty 的较新配置', () async {
      final (config: config, engine: engine) =
          device(sites: <SiteProfile>[site(kUrlA, name: 'A')]);
      await engine.runOnce();

      config.sites.first.name = 'PUT 快照';
      cloud.putReceived = Completer<void>();
      cloud.releasePut = Completer<void>();
      final Future<SyncRunResult> pending = engine.runOnce();
      await cloud.putReceived!.future;

      config.sites.first.name = 'PUT 期间的新编辑';
      engine.markDirty();
      cloud.releasePut!.complete();

      final SyncRunResult result = await pending;
      expect(result.pushed, isTrue);
      expect(config.sites.first.name, 'PUT 期间的新编辑');
      expect(
        engine.state.local.sites[kUrlA]!.name,
        'PUT 期间的新编辑',
        reason: '较新快照必须留在本地状态里',
      );
      expect(
        engine.state.local.contentHash(),
        isNot(engine.state.base.contentHash()),
        reason: '未被本次 PUT 覆盖的本地编辑要保持 dirty',
      );
      expect(
        engine.state.version,
        lessThan(cloud.version),
        reason: '下一轮应重新拉取本次 PUT 接受的远端文档',
      );

      final SyncRunResult retry = await engine.runOnce();
      expect(retry.pushed, isTrue);
      expect(jsonEncode(cloud.doc), contains('PUT 期间的新编辑'));
    });
  });

  group('偏好设置', () {
    test('本机改的偏好也会同步出去', () async {
      final (config: config, engine: engine) = device();
      config.loadImages = false;
      config.maxConcurrentDownloads = 4;

      await engine.runOnce();
      expect(jsonEncode(cloud.doc), contains('loadImages'));
      expect(jsonEncode(cloud.doc), contains('maxConcurrentDownloads'));

      // 另一台设备拉下来
      final (config: config2, engine: engine2) = device(name: 'phone');
      await engine2.runOnce();
      expect(config2.loadImages, isFalse);
      expect(config2.maxConcurrentDownloads, 4);
    });
  });
}
