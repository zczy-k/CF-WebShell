/// 同步合并内核的单测。
///
/// 这里只测纯逻辑（不联网、不碰文件系统）—— 同步最怕的不是"没同步上"，
/// 而是"同步上了但把用户的东西弄丢了"。下面每一条都是那种一旦错了
/// 用户会直接骂人的场景。
library;

import 'package:test/test.dart';
import 'package:starport_core/starport_core.dart';

const String kUrlA = 'https://a.example.com';
const String kUrlB = 'https://b.example.com';

SiteProfile site(String url, {String name = '', int updatedAtMs = 0}) => SiteProfile(
      id: 'id-$url',
      name: name,
      startUrl: url,
      updatedAtMs: updatedAtMs,
    );

SyncSite entry(
  String url, {
  String name = '',
  String iconUrl = '',
  int at = 0,
}) {
  return SyncSite(
    key: url,
    startUrl: url,
    name: name,
    iconUrl: iconUrl,
    at: at,
  );
}

SyncDoc docWith(List<SyncSite> list) {
  final SyncDoc d = SyncDoc();
  for (final SyncSite s in list) {
    d.sites[s.key] = s;
  }
  return d;
}

SyncDoc tombDoc(String url, String startUrl, int at) {
  final SyncDoc d = SyncDoc();
  d.sites[url] = SyncSite.tombstone(url, startUrl, at);
  return d;
}

void main() {
  group('新站点', () {
    test('只有本地新增 → 合并后留下', () {
      final SyncMergeResult r = SyncDoc.merge(
        base: SyncDoc(),
        local: docWith(<SyncSite>[entry(kUrlA, name: 'A', at: 1000)]),
        remote: SyncDoc(),
      );
      expect(r.doc.aliveSites.length, 1);
      expect(r.doc.aliveSites.first.name, 'A');
    });

    test('只有远端新增 → 合并后留下', () {
      final SyncMergeResult r = SyncDoc.merge(
        base: SyncDoc(),
        local: SyncDoc(),
        remote: docWith(<SyncSite>[entry(kUrlB, name: 'B', at: 1000)]),
      );
      expect(r.doc.aliveSites.length, 1);
      expect(r.doc.aliveSites.first.startUrl, kUrlB);
    });

    test('两边各自加了不同的站点 → 两份都在', () {
      final SyncMergeResult r = SyncDoc.merge(
        base: SyncDoc(),
        local: docWith(<SyncSite>[entry(kUrlA, name: 'A', at: 1000)]),
        remote: docWith(<SyncSite>[entry(kUrlB, name: 'B', at: 1001)]),
      );
      expect(r.doc.aliveSites.length, 2);
    });
  });

  group('改同一个站点', () {
    test('本机改名 + 远端换图标 → 两个改动都保住', () {
      final SyncDoc base = docWith(<SyncSite>[entry(kUrlA, name: '旧名字', iconUrl: 'old.png', at: 100)]);
      final SyncDoc local = docWith(<SyncSite>[entry(kUrlA, name: '新名字', iconUrl: 'old.png', at: 200)]);
      final SyncDoc remote = docWith(<SyncSite>[entry(kUrlA, name: '旧名字', iconUrl: 'new.png', at: 300)]);

      final SyncMergeResult r = SyncDoc.merge(base: base, local: local, remote: remote);
      final SyncSite s = r.doc.sites[kUrlA]!;
      // 这一条是整套同步"用起来不像冲突"的核心：整条取一边必然丢一个改动。
      expect(s.name, '新名字');
      expect(s.iconUrl, 'new.png');
    });

    test('只有远端改名 → 本机跟着变', () {
      final SyncDoc base = docWith(<SyncSite>[entry(kUrlA, name: '旧', at: 100)]);
      final SyncDoc remote = docWith(<SyncSite>[entry(kUrlA, name: '新', at: 200)]);

      final SyncMergeResult r = SyncDoc.merge(base: base, local: base.copy(), remote: remote);
      expect(r.doc.sites[kUrlA]!.name, '新');
      expect(r.conflicts, 0);
    });

    test('两边改同一字段且值不同 → 时间戳大的赢', () {
      final SyncDoc base = docWith(<SyncSite>[entry(kUrlA, name: '原', at: 100)]);
      final SyncDoc local = docWith(<SyncSite>[entry(kUrlA, name: '本机', at: 200)]);
      final SyncDoc remote = docWith(<SyncSite>[entry(kUrlA, name: '远端', at: 300)]);

      final SyncMergeResult r = SyncDoc.merge(base: base, local: local, remote: remote);
      expect(r.doc.sites[kUrlA]!.name, '远端');
      expect(r.conflicts, 1);
    });
  });

  group('删除', () {
    test('远端删除、本机没动 → 本机跟着删', () {
      final SyncDoc base = docWith(<SyncSite>[entry(kUrlA, at: 100)]);
      final SyncMergeResult r = SyncDoc.merge(
        base: base,
        local: base.copy(),
        remote: tombDoc(kUrlA, kUrlA, 200),
      );
      expect(r.doc.sites[kUrlA]!.deleted, isTrue);
      expect(r.doc.aliveSites, isEmpty);
    });

    test('本机删除、远端没动 → 删除保留下来（会被推上去）', () {
      final SyncDoc base = docWith(<SyncSite>[entry(kUrlA, at: 100)]);
      final SyncMergeResult r = SyncDoc.merge(
        base: base,
        local: tombDoc(kUrlA, kUrlA, 200),
        remote: base.copy(),
      );
      expect(r.doc.sites[kUrlA]!.deleted, isTrue);
    });

    test('删除比修改新 → 删掉；这正是"删了必须真删"的兜底', () {
      final SyncDoc base = docWith(<SyncSite>[entry(kUrlA, name: '原', at: 100)]);
      final SyncDoc local = docWith(<SyncSite>[entry(kUrlA, name: '刚改的', at: 500)]);
      final SyncDoc remote = tombDoc(kUrlA, kUrlA, 600);
      final SyncMergeResult r = SyncDoc.merge(base: base, local: local, remote: remote);
      expect(r.doc.sites[kUrlA]!.deleted, isTrue);
    });

    test('时间戳平手时删除优先 —— 宁可多删一个也不能让删掉的网站复活', () {
      final SyncDoc base = docWith(<SyncSite>[entry(kUrlA, name: '原', at: 100)]);
      final SyncDoc local = docWith(<SyncSite>[entry(kUrlA, name: '改过', at: 200)]);
      final SyncDoc remote = tombDoc(kUrlA, kUrlA, 200);
      final SyncMergeResult r = SyncDoc.merge(base: base, local: local, remote: remote);
      expect(r.doc.sites[kUrlA]!.deleted, isTrue);
    });

    test('墓碑不会被"一整份旧文档推上来"复活', () {
      // 场景：A 删掉站点后离线，B 拿着删除前的完整文档推了一次。
      // 没有墓碑的话这里就会复活，用户会以为"删不掉"。
      final SyncDoc base = docWith(<SyncSite>[entry(kUrlA, name: '原', at: 100)]);
      final SyncDoc local = tombDoc(kUrlA, kUrlA, 200);
      final SyncDoc remote = docWith(<SyncSite>[entry(kUrlA, name: '原', at: 100)]);

      final SyncMergeResult r = SyncDoc.merge(base: base, local: local, remote: remote);
      expect(r.doc.sites[kUrlA]!.deleted, isTrue);
      expect(r.doc.aliveSites, isEmpty);
    });

    test('两边都删了 → 墓碑在，且不会报冲突', () {
      final SyncDoc base = docWith(<SyncSite>[entry(kUrlA, at: 100)]);
      final SyncMergeResult r = SyncDoc.merge(
        base: base,
        local: tombDoc(kUrlA, kUrlA, 200),
        remote: tombDoc(kUrlA, kUrlA, 200),
      );
      expect(r.doc.sites[kUrlA]!.deleted, isTrue);
      expect(r.conflicts, 0);
    });
  });

  group('墓碑回收', () {
    test('过期的墓碑会被清掉', () {
      final SyncDoc d = tombDoc(kUrlA, kUrlA, 1000);
      final int now = 1000 + kTombstoneTtlMs + 1;
      d.prune(now: now);
      expect(d.sites.containsKey(kUrlA), isFalse);
    });

    test('新鲜的墓碑必须留着', () {
      final SyncDoc d = tombDoc(kUrlA, kUrlA, 1000);
      d.prune(now: 1000 + 60 * 1000);
      expect(d.sites.containsKey(kUrlA), isTrue);
    });

    test('墓碑过多时从最老的开始丢', () {
      final SyncDoc d = SyncDoc();
      for (int i = 0; i < kMaxTombstones + 5; i++) {
        final String url = 'https://x$i.example.com';
        d.sites[url] = SyncSite.tombstone(url, url, 1000 + i);
      }
      d.prune(now: 2000);
      int dead = 0;
      for (final SyncSite s in d.sites.values) {
        if (s.deleted) dead++;
      }
      expect(dead, kMaxTombstones);
      // 最老的那几条应该先没
      expect(d.sites.containsKey('https://x0.example.com'), isFalse);
      expect(d.sites.containsKey('https://x${kMaxTombstones + 4}.example.com'), isTrue);
    });
  });

  group('本机配置 <-> 文档', () {
    test('refreshFromConfig 记下删除（墓碑）', () {
      final ShellConfig config = ShellConfig(sites: <SiteProfile>[site(kUrlA, name: 'A')]);
      final SyncDoc doc = SyncDoc();
      doc.refreshFromConfig(config, now: 1000);
      expect(doc.aliveSites.length, 1);

      config.removeSite('id-$kUrlA');
      doc.refreshFromConfig(config, now: 2000);
      expect(doc.sites[kUrlA]!.deleted, isTrue);
      expect(doc.sites[kUrlA]!.at, 2000);
    });

    test('内容没变时 at 不动（否则两边会乒乓互推）', () {
      final ShellConfig config = ShellConfig(sites: <SiteProfile>[site(kUrlA, name: 'A')]);
      final SyncDoc doc = SyncDoc();
      doc.refreshFromConfig(config, now: 1000);
      final int first = doc.sites[kUrlA]!.at;
      doc.refreshFromConfig(config, now: 5000);
      expect(doc.sites[kUrlA]!.at, first);
    });

    test('applyTo 会把远端站点写进配置，且不碰本机私有字段', () {
      final ShellConfig config = ShellConfig(
        sites: <SiteProfile>[site(kUrlA, name: '旧')],
        downloadDir: 'D:\\下载',
      );
      config.saveLogin = false;

      final SyncDoc doc = docWith(<SyncSite>[
        entry(kUrlA, name: '新', at: 200),
        entry(kUrlB, name: '追加的', at: 300),
      ]);
      doc.applyTo(config);

      expect(config.sites.length, 2);
      expect(config.byId('id-$kUrlA')!.name, '新');
      // 站点清单同步不能顺手把"下载目录/保持登录"这种本机设置改掉
      expect(config.downloadDir, 'D:\\下载');
      expect(config.saveLogin, isFalse);
    });

    test('applyTo 会删掉墓碑对应的站点', () {
      final ShellConfig config = ShellConfig(sites: <SiteProfile>[site(kUrlA)]);
      tombDoc(kUrlA, kUrlA, 200).applyTo(config);
      expect(config.sites, isEmpty);
      expect(config.activeSiteId, isNull);
    });

    test('偏好设置按条同步（loadImages 进、saveLogin 不进）', () {
      final ShellConfig config = ShellConfig();
      config.loadImages = false;
      config.saveLogin = true;
      final SyncDoc doc = SyncDoc();
      doc.refreshFromConfig(config, now: 1000);
      expect(doc.prefs['loadImages']!.value, isFalse);
      expect(doc.prefs.containsKey('saveLogin'), isFalse);
      expect(doc.prefs.containsKey('downloadDir'), isFalse);
    });
  });

  group('新设备第一次同步', () {
    // base 空 = 这台设备还没跟这个空间对过账。它本地的偏好只可能是新装默认值，
    // 而 at 是刚才用本机时钟盖上去的 —— 让它按 at 赢，结果就是"新手机一配对，
    // 把电脑上设好的省流/并发数全刷回默认"。
    test('本机的默认偏好不能盖掉远端已经设好的值', () {
      final SyncDoc local = SyncDoc();
      local.prefs['loadImages'] = SyncPref(true, 9999); // 默认值，时间戳反而更大
      final SyncDoc remote = SyncDoc();
      remote.prefs['loadImages'] = SyncPref(false, 10); // 老设备早先设的

      final SyncMergeResult r =
          SyncDoc.merge(base: SyncDoc(), local: local, remote: remote);
      expect(r.doc.prefs['loadImages']!.value, isFalse);
    });

    test('对过账之后就按时间取新的', () {
      final SyncDoc base = SyncDoc();
      base.prefs['loadImages'] = SyncPref(false, 10);
      final SyncDoc local = SyncDoc();
      local.prefs['loadImages'] = SyncPref(true, 20); // 用户真的刚改成 true
      final SyncDoc remote = SyncDoc();
      remote.prefs['loadImages'] = SyncPref(false, 10);

      final SyncMergeResult r =
          SyncDoc.merge(base: base, local: local, remote: remote);
      expect(r.doc.prefs['loadImages']!.value, isTrue);
    });
  });

  group('白标预置站点不被同步复活', () {
    const Branding branding = Branding(
      presetSites: <PresetSite>[PresetSite(url: kUrlA, name: 'OA')],
    );

    test('用户删掉预置站点后，下一版白标不会把它加回来', () {
      final ShellConfig config = ShellConfig(
        sites: <SiteProfile>[site(kUrlA, name: 'OA')],
        branding: branding,
        presetSignature: 'v1',
      );
      config.presetIds.add('id-$kUrlA');

      final SyncDoc doc = SyncDoc();
      doc.refreshFromConfig(config, now: 1000);
      expect(doc.suppressed, isEmpty);

      config.removeSite('id-$kUrlA');
      doc.refreshFromConfig(config, now: 2000);
      expect(doc.suppressed, contains(kUrlA));

      // 白标升级：指纹变了，进入"补回缺的预置站点"分支
      final ShellConfig upgraded = ShellConfig(
        sites: <SiteProfile>[],
        branding: branding,
        presetSignature: 'v1',
      );
      upgraded.presetIds.add('id-$kUrlA');
      upgraded.presetSignature = 'v0';
      final ShellConfig synced = ShellConfig.syncPresetSites(
        upgraded,
        branding,
        suppressed: doc.suppressed,
      );
      expect(synced.sites, isEmpty);
    });
  });

  group('鲁棒性', () {
    test('坏 JSON 不会把整份文档搞崩', () {
      final SyncDoc d = SyncDoc.fromJson(<String, dynamic>{
        'sites': <String, dynamic>{
          kUrlA: <String, dynamic>{'name': '好的', 'at': 10},
          'https://bad': '这不是对象',
          kUrlB: <String, dynamic>{'name': '也好的', 'at': 20},
        },
        'prefs': <String, dynamic>{
          'loadImages': <String, dynamic>{'v': false, 'at': 5},
          'saveLogin': <String, dynamic>{'v': false, 'at': 5},
        },
      });
      expect(d.sites.length, 2);
      expect(d.prefs.containsKey('loadImages'), isTrue);
      // saveLogin 永远不该出现在文档里
      expect(d.prefs.containsKey('saveLogin'), isFalse);
    });

    test('文档往返一次内容不变', () {
      final ShellConfig config = ShellConfig(
        sites: <SiteProfile>[site(kUrlA, name: 'A', updatedAtMs: 500)],
      );
      final SyncDoc doc = SyncDoc();
      doc.refreshFromConfig(config, now: 1000);
      final SyncDoc round = SyncDoc.fromJson(doc.toJson());
      expect(round.contentHash(), doc.contentHash());
    });

    test('contentHash 对内容变化敏感', () {
      final SyncDoc a = docWith(<SyncSite>[entry(kUrlA, name: 'A', at: 1)]);
      final SyncDoc b = docWith(<SyncSite>[entry(kUrlA, name: 'A', at: 1)]);
      final SyncDoc c = docWith(<SyncSite>[entry(kUrlA, name: 'B', at: 1)]);
      expect(a.contentHash(), b.contentHash());
      expect(a.contentHash(), isNot(c.contentHash()));
    });
  });

  group('设备凭证', () {
    test('凭证往返', () {
      const SyncCredentials c = SyncCredentials(
        endpoint: 'https://sync.example.com/',
        spaceId: 'sp_1',
        deviceId: 'dv_1',
        deviceToken: 'tok_abcdefghijklmnop',
      );
      final SyncCredentials? back = SyncCredentials.tryFromJson(c.toJson());
      expect(back, isNotNull);
      // 末尾斜杠要规整掉，否则拼出来的地址会变成 //v1/head
      expect(back!.endpoint, 'https://sync.example.com');
    });

    test('缺字段的凭证当没有', () {
      expect(SyncCredentials.tryFromJson(<String, dynamic>{'endpoint': 'https://x'}), isNull);
    });
  });
}
