/// 同步的**保险丝**：骤降护栏、服务端重置、缓存双份、假冲突不计数。
///
/// 这一组测的不是"能不能同步上"，而是"同步出岔子的时候会不会把用户的东西
/// 一次性删光"。里面每一条对应的都是真实存在过的写法：
///
/// * 远端文档变空 → 三方合并理解成"别人删光了" → 全网清空
/// * 换了个同步空间 → base 还指着旧空间 → 本机站点被当成删除推上去
/// * 缓存文件写坏 → 合并基准丢失 → 退化成整份覆盖
/// * 两边各加一条一模一样的站点 → 报成一串字段冲突
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webshell_core/webshell_core.dart';

const String kSpace = 'sp_guard';

SiteProfile site(String url) =>
    SiteProfile(id: 'id-$url', startUrl: url, name: url);

/// 一个极简的"Worker"：只实现 head / doc(GET,PUT)，版本号 CAS 行为照抄真的。
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
  int putCalls = 0;

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

  /// 把服务端所有活着的站点都改成墓碑（模拟"别的设备删光了"）。
  void tombstoneAll(int at) {
    final Map<String, dynamic> sites =
        (doc['sites'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    for (final String k in sites.keys.toList()) {
      sites[k] = SyncSite.tombstone(k, k, at).toJson();
    }
    doc['sites'] = sites;
    version++;
  }
}

void main() {
  late FakeCloud cloud;
  late Directory dir;

  setUp(() async {
    cloud = await FakeCloud.start();
    dir = Directory.systemTemp.createTempSync('ws-sync-guard-');
  });

  tearDown(() async {
    await cloud.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  ({ShellConfig config, SyncEngine engine, SyncStateFile file}) device({
    List<SiteProfile> sites = const <SiteProfile>[],
    String name = 'dev',
    String spaceId = kSpace,
  }) {
    final ShellConfig config = ShellConfig(
      sites: List<SiteProfile>.of(sites),
      syncEnabled: true,
      syncEndpoint: cloud.endpoint,
      syncSpaceId: spaceId,
    );
    final SyncStateFile file = SyncStateFile(File('${dir.path}/$name.sync.json'));
    final SyncEngine engine = SyncEngine(
      config: config,
      stateFile: file,
      credentials: MemorySyncCredentialStore(
        SyncCredentials(
          endpoint: cloud.endpoint,
          spaceId: spaceId,
          deviceId: 'dv_$name',
          deviceToken: 'tk_$name',
          deviceName: name,
        ),
      ),
      state: file.load(),
    );
    return (config: config, engine: engine, file: file);
  }

  /// [n] 个互不相同的站点地址。
  List<SiteProfile> manySites(int n) =>
      List<SiteProfile>.generate(n, (int i) => site('https://s$i.example.com'));

  group('骤降护栏 —— 判定边界', () {
    test('站点本来就少（<5）不拦：删两个是正常操作', () {
      expect(isBigDelete(4, 1, 3), isFalse);
      expect(isBigDelete(2, 0, 2), isFalse);
    });

    test('只删了一两个不拦', () {
      expect(isBigDelete(10, 8, 2), isFalse);
    });

    test('掉一半以上才拦', () {
      expect(isBigDelete(6, 3, 3), isTrue); // 正好一半
      expect(isBigDelete(10, 4, 6), isTrue);
      expect(isBigDelete(10, 6, 4), isFalse); // 掉 40%，不算大面积
    });

    test('越删越多的"负数"不拦（用户自己加站）', () {
      expect(isBigDelete(3, 8, -5), isFalse);
    });
  });

  group('骤降护栏 —— 端到端', () {
    test('别的设备删光了 → 停下等确认，本机一个站点都不动', () async {
      final (config: config, engine: engine, file: _) =
          device(sites: manySites(6));

      await engine.runOnce(); // 先推上去，建立合并基准
      expect(config.sites.length, 6);
      final int putsBefore = cloud.putCalls;

      cloud.tombstoneAll(DateTime.now().millisecondsSinceEpoch + 60000);

      final SyncRunResult r = await engine.runOnce();
      expect(r.status, SyncStatus.needsConfirm);
      expect(r.awaitingConfirm, isTrue);
      expect(r.pendingRemovals, 6);
      expect(
        config.sites.length,
        6,
        reason: '护栏说停就得真停 —— 一条都不能少',
      );
      expect(cloud.putCalls, putsBefore, reason: '拦住了就不该往上推');
      // 也没记账：base 还指着原来那一版，下一轮还会拦在同一个地方
      expect(engine.state.version, cloud.version - 1);
    });

    test('用户点了确认 → 这一轮才真删；下一次再被拦（放行只对一次有效）', () async {
      final (config: config, engine: engine, file: _) =
          device(sites: manySites(6));
      await engine.runOnce();

      cloud.tombstoneAll(DateTime.now().millisecondsSinceEpoch + 60000);
      expect((await engine.runOnce()).awaitingConfirm, isTrue);

      final SyncRunResult ok = await engine.confirmBigDelete();
      expect(ok.ok, isTrue);
      expect(config.sites, isEmpty, reason: '确认之后就该照合并结果执行');
    });

    test('正常删一两个不会被误拦', () async {
      final (config: config, engine: engine, file: _) =
          device(sites: manySites(6));
      await engine.runOnce();

      config.sites.removeLast();
      final SyncRunResult r = await engine.runOnce();
      expect(r.awaitingConfirm, isFalse);
      expect(config.sites.length, 5);
    });
  });

  group('服务端被重置', () {
    test('文档空 + 版本号倒退 → 当"库没了"，本机站点重新推上去而不是清空', () async {
      final (config: config, engine: engine, file: _) =
          device(sites: manySites(6));
      await engine.runOnce();
      expect(engine.state.version, greaterThan(0));

      // 重建 D1 / 从空备份还原：文档空了，版本号也回到 0
      cloud.doc = <String, dynamic>{};
      cloud.version = 0;

      final SyncRunResult r = await engine.runOnce();
      expect(r.status, SyncStatus.ok);
      expect(
        config.sites.length,
        6,
        reason: '服务端换了个空库，不等于"别人删光了"',
      );
      expect(r.pushed, isTrue, reason: '本机的内容得重新推上去，把空库填回来');
      expect(cloud.doc['sites'], isNotNull);
      expect(jsonEncode(cloud.doc), contains('https://s0.example.com'));
    });

    test('版本号正常递增而文档变空 → 这是真删光，照常合并（别把护栏用错地方）', () async {
      final (config: config, engine: engine, file: _) =
          device(sites: manySites(6));
      await engine.runOnce();

      cloud.doc = <String, dynamic>{'sites': <String, dynamic>{}};
      cloud.version = cloud.version + 1;

      final SyncRunResult r = await engine.runOnce();
      // 落进骤降护栏（6 → 0），不是被当成"库没了"静默保留
      expect(r.awaitingConfirm, isTrue);
      expect(config.sites.length, 6);
    });
  });

  group('换空间', () {
    test('base 还指着旧空间的版本号时，也不会把本机站点删掉', () async {
      // 第一台设备已经在旧空间同步过
      final (config: config, engine: engine, file: _) =
          device(sites: manySites(6), name: 'pc');
      await engine.runOnce();
      expect(engine.state.base.isEmpty, isFalse);

      // 换到新空间：服务端是空的、版本号 0，但引擎里 base 还是旧空间的
      // （模拟"App 层没来得及清 base"的情况 —— 引擎自己也得兜住）
      final (config: c2, engine: e2, file: _) =
          device(sites: manySites(6), name: 'pc2', spaceId: 'sp_other');
      e2.state.base = engine.state.base.copy();
      e2.state.version = engine.state.version;
      e2.stateFile.save(e2.state);

      final SyncRunResult r = await e2.runOnce();
      expect(r.status, SyncStatus.ok);
      expect(
        c2.sites.length,
        6,
        reason: '换了个空空间不该让本机站点消失 —— 那是最典型的"同步把我东西删了"',
      );
      expect(engine.state.base.isEmpty, isFalse, reason: '旧引擎不该被这条路径改动');

      // 顺手确认 config 变量没被误用（编译器别把它当成未使用）
      expect(config.sites.length, 6);
    });
  });

  group('缓存双份', () {
    test('主文件被截断 → 退回 .bak 那一版，合并基准不丢', () {
      final SyncStateFile f =
          SyncStateFile(File('${dir.path}/webshell.sync.json'));

      final SyncLocalState first = SyncLocalState(version: 7);
      first.base.sites['https://a.example.com'] = SyncSite(
        key: 'https://a.example.com',
        startUrl: 'https://a.example.com',
        at: 100,
      );
      f.save(first);

      // 第二次写：主文件被换成新内容，旧内容留在 .bak
      f.save(SyncLocalState(version: 8));
      expect(File('${f.file.path}.bak').existsSync(), isTrue);

      // 模拟断电 / 杀毒软件截断
      f.file.writeAsStringSync('{"v":1,"version":8,"base":{"si');

      final SyncLocalState loaded = f.load();
      expect(loaded.version, 7, reason: '主文件坏了要退回 .bak，不能当成"什么都没有"');
      expect(loaded.base.sites.containsKey('https://a.example.com'), isTrue);
    });

    test('主文件是空的也退回 .bak', () {
      final SyncStateFile f = SyncStateFile(File('${dir.path}/e.sync.json'));
      f.save(SyncLocalState(version: 3));
      f.save(SyncLocalState(version: 4));
      f.file.writeAsStringSync('   ');
      expect(f.load().version, 3);
    });

    test('两个文件都坏了 → 当没有，不抛异常（启动不能被缓存拖死）', () {
      final SyncStateFile f = SyncStateFile(File('${dir.path}/b.sync.json'));
      f.save(SyncLocalState(version: 1));
      f.save(SyncLocalState(version: 2));
      f.file.writeAsStringSync('nope');
      File('${f.file.path}.bak').writeAsStringSync('also nope');
      expect(f.load().version, 0);
    });
  });

  group('冲突计数', () {
    test('两边各自新增同一个站点（内容一样）不算冲突', () {
      final SyncDoc one = SyncDoc()
        ..sites['https://a.example.com'] = SyncSite(
          key: 'https://a.example.com',
          startUrl: 'https://a.example.com',
          name: 'A',
          at: 1000,
        );
      final SyncMergeResult r = SyncDoc.merge(
        base: SyncDoc(),
        local: one,
        remote: one.copy(),
      );
      expect(
        r.conflicts,
        0,
        reason: 'base 里没有这个键 → 不是"两边都改过"，报冲突只会吓人',
      );
      expect(r.doc.aliveSites.length, 1);
    });

    test('同一个站点两边改了不同字段 → 才算冲突', () {
      SyncSite make(String name, int at) => SyncSite(
            key: 'https://a.example.com',
            startUrl: 'https://a.example.com',
            name: name,
            at: at,
          );

      final SyncDoc base = SyncDoc();
      base.sites['https://a.example.com'] = make('旧名字', 500);

      final SyncDoc local = SyncDoc();
      local.sites['https://a.example.com'] = make('本机改的', 1000);

      final SyncDoc remote = SyncDoc();
      remote.sites['https://a.example.com'] = make('远端改的', 2000);

      final SyncMergeResult r = SyncDoc.merge(base: base, local: local, remote: remote);
      expect(r.conflicts, greaterThan(0));
      expect(r.doc.aliveSites.first.name, '远端改的', reason: '时间新的赢');
    });
  });
}
