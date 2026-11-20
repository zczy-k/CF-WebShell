/// 同步文档 —— 设备之间真正交换的那一份数据。
///
/// 设计上的三条硬规矩：
///
/// 1. **站点身份是地址，不是 id。**
///    `id` 是本机生成的（[newId]），两台设备给同一个预置站点建出来的 id 必然不同。
///    要是拿 id 当身份，两台手机一配对就会看到同一个网站出现两遍。
///    所以整份文档用「规整后的 startUrl」当 key，`id` 只在本机用、不上传。
///    代价：同一台机器上故意加两个同地址但不同名字的站点，同步后会合成一个。
///    `addSite` 本来就只是"提示重复"不阻止，这个代价可以接受。
///
/// 2. **删除靠墓碑，不靠"没看见"。**
///    "远端没有这个站点"永远有两种解释：对方删了、或者对方还没收到。
///    没法区分就会互相复活 —— A 删掉，B 推一次全套，网站又回来了。
///    所以删除写成 `deleted: true` 的墓碑，带时间戳，和新增一样参与合并。
///
/// 3. **时间戳只用来判先后，不用来判对错。**
///    两台设备的系统时钟可以差好几分钟，所以真正决定"谁赢"的是三方比较
///    （base / local / remote），时钟只在两边都改过、上下文已经没法判断时才出场。
///    这就是 [SyncDoc.merge] 里的 HLC（`at = max(nowMs(), 见过的最大 at + 1)`）。
library;

import 'dart:convert';

import '../config.dart';
import '../models.dart';
import '../url_utils.dart';

/// 文档格式版本。字段只增不删，老客户端读到新字段直接忽略。
const int kSyncSchemaVersion = 1;

/// 偏好设置里**会同步**的键。
///
/// 刻意排除掉的东西，每一条都有理由：
/// * `saveLogin` —— 关掉它的瞬间 [ShellState] 会把本机所有登录态抹掉，
///   从别的设备同步一个 `false` 过来等于远程替用户登出，太吓人。
/// * `downloadDir` —— Windows 是 `D:\下载`，Android 是 `content://…`，
///   同步过去是个死路径。
/// * `activeSiteId` —— 每台设备正在看哪个网站是它自己的事。
/// * `lastUpdateCheckMs` —— 本机的更新检查节流，不是用户偏好。
const List<String> kSyncedPrefKeys = <String>[
  'loadImages',
  'wifiOnlyDownloads',
  'askWhereToSave',
  'closeToTray',
  'maxConcurrentDownloads',
];

/// 墓碑保留上限：超过这个数量就从最老的开始丢（见 [SyncDoc.prune]）。
const int kMaxTombstones = 300;

/// 墓碑保留时长：180 天。比这更老的删除记录已经不可能再有设备会"复活"它。
const int kTombstoneTtlMs = 180 * 24 * 60 * 60 * 1000;

/// 一个站点在同步文档里的样子。
///
/// [at] 是这条记录的逻辑时间；[deleted] 为真时其余字段全部无意义（墓碑）。
class SyncSite {
  SyncSite({
    required this.key,
    required this.startUrl,
    this.name = '',
    this.iconUrl = '',
    this.themeColor = SiteProfile.defaultThemeColor,
    this.userAgent = '',
    Map<String, String>? headers,
    this.hasBasicAuth = false,
    this.basicUser = '',
    this.stayInSite = false,
    this.allowSelfSignedCert = false,
    this.createdAtMs = 0,
    this.at = 0,
    this.deleted = false,
  }) : headers = _sortedHeaders(headers);

  /// 身份键：`normalizeUrl(startUrl)`，规整失败时退化成原始串。
  final String key;

  String startUrl;
  String name;
  String iconUrl;
  int themeColor;
  String userAgent;

  /// 自定义请求头（如 `Authorization`）。**Basic Auth 的密码不在里面**，
  /// 那个在系统安全存储里，永远不上传。
  final Map<String, String> headers;

  bool hasBasicAuth;
  String basicUser;
  bool stayInSite;
  bool allowSelfSignedCert;
  int createdAtMs;

  /// 逻辑时间（HLC），越大越新。
  int at;

  bool deleted;

  bool get alive => !deleted;

  /// 从本机档案造一条记录。
  ///
  /// [at] 传 0 时用 `updatedAtMs`，再退到 `createdAtMs` —— 老配置这两个都可能为 0，
  /// 那就只能是 0（比任何真实时间都小，第一次合并时会被远端盖掉，这是对的）。
  factory SyncSite.fromProfile(String key, SiteProfile p, {int at = 0}) {
    return SyncSite(
      key: key,
      startUrl: p.startUrl,
      name: p.name,
      iconUrl: p.iconUrl ?? '',
      themeColor: p.themeColor,
      userAgent: p.userAgent ?? '',
      headers: p.headers,
      hasBasicAuth: p.hasBasicAuth,
      basicUser: p.basicUser ?? '',
      stayInSite: p.stayInSite,
      allowSelfSignedCert: p.allowSelfSignedCert,
      createdAtMs: p.createdAtMs,
      at: at > 0 ? at : (p.updatedAtMs > 0 ? p.updatedAtMs : p.createdAtMs),
    );
  }

  /// 这条记录"内容"的稳定指纹 —— **不含 [at]**。
  ///
  /// 合并时判断"这一边到底改没改"全靠它，所以键的顺序必须固定，
  /// 不能直接 `jsonEncode(toJson())` 了事。
  Map<String, dynamic> fieldsJson() => <String, dynamic>{
        'startUrl': startUrl,
        'name': name,
        'iconUrl': iconUrl,
        'themeColor': themeColor,
        'userAgent': userAgent,
        'headers': headers,
        'hasBasicAuth': hasBasicAuth,
        'basicUser': basicUser,
        'stayInSite': stayInSite,
        'allowSelfSignedCert': allowSelfSignedCert,
        'createdAtMs': createdAtMs,
      };

  String get fingerprint => jsonEncode(fieldsJson());

  void applyFields(Map<String, dynamic> f) {
    final Object? v = f['startUrl'];
    if (v is String && v.trim().isNotEmpty) startUrl = v.trim();
    name = _str(f['name']);
    iconUrl = _str(f['iconUrl']);
    themeColor = _int(f['themeColor'], SiteProfile.defaultThemeColor);
    userAgent = _str(f['userAgent']);
    headers
      ..clear()
      ..addAll(_headers(f['headers']));
    hasBasicAuth = _bool(f['hasBasicAuth']);
    basicUser = _str(f['basicUser']);
    stayInSite = _bool(f['stayInSite']);
    allowSelfSignedCert = _bool(f['allowSelfSignedCert']);
    createdAtMs = _int(f['createdAtMs'], 0);
  }

  SyncSite copy() => SyncSite(
        key: key,
        startUrl: startUrl,
        name: name,
        iconUrl: iconUrl,
        themeColor: themeColor,
        userAgent: userAgent,
        headers: headers,
        hasBasicAuth: hasBasicAuth,
        basicUser: basicUser,
        stayInSite: stayInSite,
        allowSelfSignedCert: allowSelfSignedCert,
        createdAtMs: createdAtMs,
        at: at,
        deleted: deleted,
      );

  Map<String, dynamic> toJson() {
    if (deleted) {
      return <String, dynamic>{'startUrl': startUrl, 'at': at, 'deleted': true};
    }
    final Map<String, dynamic> m = fieldsJson();
    m['at'] = at;
    m['deleted'] = false;
    return m;
  }

  /// 宽容解析：坏数据返回 null，绝不让一条烂记录拖垮整份文档。
  static SyncSite? tryFromJson(String key, Object? raw) {
    if (raw is! Map) return null;
    final Object? rawUrl = raw['startUrl'];
    final String startUrl =
        rawUrl is String && rawUrl.trim().isNotEmpty ? rawUrl.trim() : key;
    final SyncSite s = SyncSite(
      key: key,
      startUrl: startUrl,
      at: _int(raw['at'], 0),
      deleted: _bool(raw['deleted']),
    );
    if (!s.deleted) s.applyFields(raw.cast<String, dynamic>());
    return s;
  }

  /// 写回本机档案。**不碰** [SiteProfile.iconPath]（本机缓存路径）
  /// 和 [SiteProfile.lastOpenedMs]（本机行为）。
  void applyToProfile(SiteProfile p) {
    p.startUrl = startUrl;
    p.name = name;
    p.iconUrl = iconUrl.isEmpty ? null : iconUrl;
    p.themeColor = themeColor;
    p.userAgent = userAgent.isEmpty ? null : userAgent;
    p.headers
      ..clear()
      ..addAll(headers);
    p.hasBasicAuth = hasBasicAuth;
    p.basicUser = basicUser.isEmpty ? null : basicUser;
    p.stayInSite = stayInSite;
    p.allowSelfSignedCert = allowSelfSignedCert;
    p.updatedAtMs = at;
  }

  /// 墓碑工厂。
  factory SyncSite.tombstone(String key, String startUrl, int at) =>
      SyncSite(key: key, startUrl: startUrl, deleted: true, at: at);
}

/// 一条偏好设置在文档里的样子：值 + 它自己的逻辑时间。
///
/// 为什么每条偏好单独记时间：`loadImages` 在 A 上改、`closeToTray` 在 B 上改，
/// 用一个整文件时间戳会让后推的一方把对方那一条覆盖掉。
class SyncPref {
  const SyncPref(this.value, this.at);

  final Object? value;
  final int at;

  bool sameValue(Object? other) => jsonEncode(other) == jsonEncode(value);

  Map<String, dynamic> toJson() => <String, dynamic>{'v': value, 'at': at};

  static SyncPref? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    return SyncPref(raw['v'], _int(raw['at'], 0));
  }
}

/// 一份完整的同步文档。
class SyncDoc {
  SyncDoc({
    this.spaceId = '',
    Map<String, SyncSite>? sites,
    Map<String, SyncPref>? prefs,
    Set<String>? suppressed,
    this.updatedAt = 0,
  })  : sites = sites ?? <String, SyncSite>{},
        prefs = prefs ?? <String, SyncPref>{},
        suppressed = suppressed ?? <String>{};

  String spaceId;

  /// key = 规整后的地址。Dart 的 Map 保插入顺序，合并结果的顺序也就稳定了。
  final Map<String, SyncSite> sites;

  /// key ∈ [kSyncedPrefKeys]。
  final Map<String, SyncPref> prefs;

  /// 用户删掉、但地址还在这版白标配里的站点地址。
  ///
  /// 存在的唯一理由：[ShellConfig.syncPresetSites] 会在每次启动时把"这一版预置
  /// 有、列表里没有"的站点补回来。用户删掉一个预置站点后，下次启动它就复活了。
  /// 这份名单让 `syncPresetSites` 能跳过它 —— 删除必须是永久的。
  final Set<String> suppressed;

  /// 文档级时间戳，只作参考（服务端的版本号才是权威）。
  int updatedAt;

  bool get isEmpty => sites.isEmpty && prefs.isEmpty;

  /// 活跃站点（按 key 的插入顺序）。
  Iterable<SyncSite> get aliveSites =>
      sites.values.where((SyncSite s) => s.alive);

  /// 内容指纹：用于"这次到底有没有变化"的判断，省掉无意义的推送。
  ///
  /// 两个 32 位哈希拼成 64 位。不用 crypto 包是为了守住 core 零依赖这条线；
  /// 这里只做"要不要推"的启发式判断，撞了也只是多推一次或少推一次，
  /// 真正的冲突由服务端版本号兜底。
  String contentHash() {
    final List<String> keys = sites.keys.toList()..sort();
    final StringBuffer sb = StringBuffer();
    for (final String k in keys) {
      final SyncSite s = sites[k]!;
      sb.write(k);
      sb.write('\u0001');
      sb.write(s.deleted ? 'D' : s.fingerprint);
      sb.write('\u0002');
    }
    final List<String> pkeys = prefs.keys.toList()..sort();
    for (final String k in pkeys) {
      sb.write(k);
      sb.write('\u0001');
      sb.write(jsonEncode(prefs[k]!.value));
      sb.write('\u0002');
    }
    final List<String> sup = suppressed.toList()..sort();
    sb.write(sup.join('\u0001'));

    final String text = sb.toString();
    int h1 = 0x811c9dc5;
    int h2 = 5381;
    for (int i = 0; i < text.length; i++) {
      final int c = text.codeUnitAt(i);
      h1 = (h1 ^ c) & 0xffffffff;
      h1 = (h1 * 0x01000193) & 0xffffffff;
      h2 = ((h2 * 33) & 0xffffffff) ^ c;
    }
    String hex(int v) => v.toRadixString(16).padLeft(8, '0');
    return '${hex(h1)}${hex(h2)}';
  }

  SyncDoc copy() {
    final Map<String, SyncSite> s = <String, SyncSite>{};
    for (final MapEntry<String, SyncSite> e in sites.entries) {
      s[e.key] = e.value.copy();
    }
    return SyncDoc(
      spaceId: spaceId,
      sites: s,
      prefs: Map<String, SyncPref>.of(prefs),
      suppressed: Set<String>.of(suppressed),
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> siteMap = <String, dynamic>{};
    for (final MapEntry<String, SyncSite> e in sites.entries) {
      siteMap[e.key] = e.value.toJson();
    }
    final Map<String, dynamic> prefMap = <String, dynamic>{};
    for (final MapEntry<String, SyncPref> e in prefs.entries) {
      prefMap[e.key] = e.value.toJson();
    }
    return <String, dynamic>{
      'schema': kSyncSchemaVersion,
      'spaceId': spaceId,
      'updatedAt': updatedAt,
      'sites': siteMap,
      'prefs': prefMap,
      'suppressed': suppressed.toList(),
    };
  }

  static SyncDoc fromJson(Object? raw) {
    final Map<dynamic, dynamic> map =
        raw is Map ? raw : const <dynamic, dynamic>{};
    final SyncDoc doc = SyncDoc(
      spaceId: _str(map['spaceId']),
      updatedAt: _int(map['updatedAt'], 0),
    );

    final Object? rawSites = map['sites'];
    if (rawSites is Map) {
      rawSites.forEach((Object? k, Object? v) {
        if (k is! String || k.trim().isEmpty) return;
        final SyncSite? s = SyncSite.tryFromJson(k, v);
        if (s != null) doc.sites[k] = s;
      });
    } else if (rawSites is List) {
      // 兼容更宽松的写法（数组形态）：key 从 startUrl 推出来。
      for (final Object? e in rawSites) {
        if (e is! Map) continue;
        final Object? u = e['startUrl'];
        if (u is! String) continue;
        final String? k = normalizeUrl(u);
        if (k == null) continue;
        final SyncSite? s = SyncSite.tryFromJson(k, e);
        if (s != null) doc.sites[k] = s;
      }
    }

    final Object? rawPrefs = map['prefs'];
    if (rawPrefs is Map) {
      rawPrefs.forEach((Object? k, Object? v) {
        if (k is! String) return;
        if (!kSyncedPrefKeys.contains(k)) return;
        final SyncPref? p = SyncPref.tryFromJson(v);
        if (p != null) doc.prefs[k] = p;
      });
    }

    final Object? rawSup = map['suppressed'];
    if (rawSup is List) {
      for (final Object? e in rawSup) {
        if (e is String && e.trim().isNotEmpty) doc.suppressed.add(e.trim());
      }
    }
    return doc;
  }

  // ---------------------------------------------------------------------
  // 本机配置 <-> 文档
  // ---------------------------------------------------------------------

  /// 用本机配置刷新一份文档（文档本身被修改）。
  ///
  /// 三条规则：
  /// * 配置里有、文档里也有、内容没变 → **保留原来的 at**。
  ///   这一条是防回音的关键：远端改动刚被应用到配置上，如果这里又抬一次 at，
  ///   我们就会把自己刚收到的东西当成"新改动"推回去，两边乒乓。
  /// * 内容变了（或新站点） → at 抬到 `max(now, updatedAtMs, 老at+1)`。
  /// * 文档里活着、配置里没了 → 改写成墓碑，at = now。
  ///   这就是"删除"唯一被记录下来的地方。
  void refreshFromConfig(ShellConfig config, {required int now, Set<String>? suppressedUrls}) {
    if (suppressedUrls != null) {
      suppressed
        ..clear()
        ..addAll(suppressedUrls);
    }

    // 这一版白标预置的地址 —— 下面删掉站点时要用它判断"这是不是预置站点"。
    final Set<String> presetUrls = <String>{};
    for (final PresetSite item in config.branding.effectivePresetSites) {
      final String? u = normalizeUrl(item.url.trim());
      if (u != null) presetUrls.add(u);
    }

    final Set<String> live = <String>{};
    for (final SiteProfile p in config.sites) {
      final String? k = normalizeUrl(p.startUrl);
      if (k == null) continue;
      live.add(k);
      final SyncSite? old = sites[k];
      final SyncSite fresh = SyncSite.fromProfile(k, p);
      if (old != null && old.alive && old.fingerprint == fresh.fingerprint) {
        continue; // 没变，保留老 at
      }
      int at = now;
      if (p.updatedAtMs > at) at = p.updatedAtMs;
      if (old != null && old.at + 1 > at) at = old.at + 1;
      fresh.at = at;
      sites[k] = fresh;
    }

    for (final String k in sites.keys.toList()) {
      final SyncSite e = sites[k]!;
      if (e.deleted) continue;
      if (live.contains(k)) continue;
      sites[k] = SyncSite.tombstone(k, e.startUrl, now);
      // 删掉的是白标预置站点 → 记进抑制名单，否则下次启动
      // ShellConfig.syncPresetSites 会把它原样补回来。
      if (presetUrls.contains(k)) suppressed.add(k);
    }

    // 用户又手动加回来的地址不该继续被抑制
    suppressed.removeWhere((String k) => live.contains(k));

    // 偏好设置
    final Map<String, Object?> current = <String, Object?>{
      'loadImages': config.loadImages,
      'wifiOnlyDownloads': config.wifiOnlyDownloads,
      'askWhereToSave': config.askWhereToSave,
      'closeToTray': config.closeToTray,
      'maxConcurrentDownloads': config.maxConcurrentDownloads,
    };
    for (final String key in kSyncedPrefKeys) {
      final Object? v = current[key];
      if (v == null) continue;
      final SyncPref? old = prefs[key];
      if (old != null && old.sameValue(v)) continue;
      prefs[key] = SyncPref(v, now);
    }

    updatedAt = now;
  }

  /// 把文档写回本机配置（文档不被修改）。
  ///
  /// 顺序：先删墓碑，再按文档顺序更新/追加，最后收尾 `activeSiteId`。
  /// 新站点追加在末尾 —— 手动拖出来的顺序是本机习惯，不同步它。
  List<String> applyTo(ShellConfig config) {
    final List<String> removed = <String>[];

    // 1) 删除
    config.sites.removeWhere((SiteProfile p) {
      final String? k = normalizeUrl(p.startUrl);
      if (k == null) return false;
      final SyncSite? e = sites[k];
      final bool drop = e != null && e.deleted;
      if (drop) removed.add(k);
      return drop;
    });

    // 2) 更新 / 追加
    for (final SyncSite e in aliveSites) {
      SiteProfile? target;
      for (final SiteProfile p in config.sites) {
        if (normalizeUrl(p.startUrl) == e.key) {
          target = p;
          break;
        }
      }
      if (target == null) {
        target = SiteProfile(
          id: newId(),
          name: e.name,
          startUrl: e.startUrl,
          createdAtMs: e.createdAtMs > 0 ? e.createdAtMs : nowMs(),
        );
        config.sites.add(target);
      }
      e.applyToProfile(target);
    }

    // 3) 偏好设置
    final SyncPref? loadImages = prefs['loadImages'];
    if (loadImages != null && loadImages.value is bool) {
      config.loadImages = loadImages.value! as bool;
    }
    final SyncPref? wifi = prefs['wifiOnlyDownloads'];
    if (wifi != null && wifi.value is bool) {
      config.wifiOnlyDownloads = wifi.value! as bool;
    }
    final SyncPref? ask = prefs['askWhereToSave'];
    if (ask != null && ask.value is bool) {
      config.askWhereToSave = ask.value! as bool;
    }
    final SyncPref? tray = prefs['closeToTray'];
    if (tray != null && tray.value is bool) {
      config.closeToTray = tray.value! as bool;
    }
    final SyncPref? conc = prefs['maxConcurrentDownloads'];
    if (conc != null) {
      final int? n = _asInt(conc.value);
      if (n != null && n >= 1 && n <= 6) config.maxConcurrentDownloads = n;
    }

    // 4) 当前站点可能被删了
    if (config.sites.isEmpty) {
      config.activeSiteId = null;
    } else if (config.byId(config.activeSiteId) == null) {
      config.activeSiteId = config.sites.first.id;
    }
    return removed;
  }

  // ---------------------------------------------------------------------
  // 三方合并
  // ---------------------------------------------------------------------

  /// 三方合并。[base] 是上一次成功同步时的文档（本地存的），
  /// [local] 是现在本机的样子，[remote] 是服务端的最新版本。
  ///
  /// 判定顺序刻意这么排：
  /// 1. 只有一边动过 → 听动过的那边（最常见的路径，零猜测）；
  /// 2. 两边都动过但结果一样 → 无所谓，取本地；
  /// 3. 两边都动过且不一样 → 比 `at`；`at` 还相等就**删除优先**。
  ///    宁可多删一个（用户能再加回来），也不能让删掉的网站阴魂不散。
  static SyncMergeResult merge({
    required SyncDoc base,
    required SyncDoc local,
    required SyncDoc remote,
    int now = 0,
  }) {
    final SyncDoc out = SyncDoc(spaceId: local.spaceId.isNotEmpty ? local.spaceId : remote.spaceId);
    int conflicts = 0;

    final List<String> keys = <String>[];
    final Set<String> seen = <String>{};
    for (final Iterable<String> src in <Iterable<String>>[
      local.sites.keys,
      remote.sites.keys,
      base.sites.keys,
    ]) {
      for (final String k in src) {
        if (seen.add(k)) keys.add(k);
      }
    }

    for (final String k in keys) {
      final SyncSite? b = base.sites[k];
      final SyncSite? l = local.sites[k];
      final SyncSite? r = remote.sites[k];

      final bool bp = b != null && b.alive;
      final bool lp = l != null && l.alive;
      final bool rp = r != null && r.alive;
      final int bAt = b?.at ?? 0;
      final int lAt = l?.at ?? 0;
      final int rAt = r?.at ?? 0;

      bool useRemote;
      if (lp == bp && rp != bp) {
        useRemote = true; // 只有远端动过
      } else if (rp == bp && lp != bp) {
        useRemote = false; // 只有本地动过
      } else if (lp == rp) {
        useRemote = false; // 结果一致
      } else if (rAt != lAt) {
        useRemote = rAt > lAt;
      } else {
        useRemote = !rp; // 平手：删除优先
      }

      final bool winnerAlive = useRemote ? rp : lp;

      if (!winnerAlive) {
        final String url = (l?.startUrl ?? r?.startUrl ?? b?.startUrl) ?? k;
        out.sites[k] = SyncSite.tombstone(k, url, _max3(lAt, rAt, bAt));
        // 一边删、另一边在改 —— 这是一次真冲突，报给调用方（只用于显示个数）
        if (lp != rp && lp != bp && rp != bp) conflicts++;
        continue;
      }

      // 字段级冲突谁来赢：比 at，不看 useRemote。
      // useRemote 回答的是"这条记录还在不在"，和"这个字段谁新"是两件事。
      final bool preferRemote = rAt != lAt && rAt > lAt;
      final List<int> counter = <int>[0];
      final Map<String, dynamic> merged = _mergeFields(
        bp ? b.fieldsJson() : const <String, dynamic>{},
        lp ? l.fieldsJson() : const <String, dynamic>{},
        rp ? r.fieldsJson() : const <String, dynamic>{},
        preferRemote,
        counter,
      );
      conflicts += counter[0];

      final SyncSite entry = SyncSite(
        key: k,
        startUrl: (useRemote ? r!.startUrl : l!.startUrl),
        at: lAt > rAt ? lAt : rAt,
      );
      entry.applyFields(merged);
      if (entry.startUrl.trim().isEmpty) entry.startUrl = k;
      if (entry.at == 0) entry.at = now;
      out.sites[k] = entry;
    }

    // 偏好设置：每条独立 LWW
    //
    // 例外是"这台设备还没跟这个空间对过账"（base 里一条偏好都没有）：那时
    // 本地的偏好只可能是新装默认值，而它的 at 是刚才用本机时钟盖上去的 ——
    // 按 at 比大小，结果必然是"新设备一配对，把老设备的设置全刷回默认"。
    // 这条线上远端赢，本机的默认值等下一次用户真动手时才参与比较。
    final bool virginBase = base.prefs.isEmpty;
    final List<String> prefKeys = <String>[];
    final Set<String> prefSeen = <String>{};
    for (final Map<String, SyncPref> src in <Map<String, SyncPref>>[
      local.prefs,
      remote.prefs,
    ]) {
      for (final String k in src.keys) {
        if (prefSeen.add(k)) prefKeys.add(k);
      }
    }
    for (final String k in prefKeys) {
      final SyncPref? l = local.prefs[k];
      final SyncPref? r = remote.prefs[k];
      if (l == null) {
        out.prefs[k] = r!;
      } else if (r == null) {
        out.prefs[k] = l;
      } else if (virginBase || r.at > l.at) {
        out.prefs[k] = r;
      } else {
        out.prefs[k] = l;
      }
    }

    // 抑制名单：删除只累加，不抵消；已经在文档里活着的地址不抑制
    out.suppressed
      ..addAll(base.suppressed)
      ..addAll(local.suppressed)
      ..addAll(remote.suppressed);
    for (final SyncSite s in out.aliveSites) {
      out.suppressed.remove(s.key);
    }

    out.updatedAt = local.updatedAt > remote.updatedAt ? local.updatedAt : remote.updatedAt;
    return SyncMergeResult(out, conflicts);
  }

  /// 丢墓碑：先按时效（[kTombstoneTtlMs]），再按数量（[kMaxTombstones]）。
  ///
  /// 为什么不能一直留着：每删一个站就永久多一条记录，几年后文档比站点列表大得多。
  /// 为什么又不能立刻丢：丢了就分不清"删除"和"还没同步过来"，网站会复活。
  void prune({required int now}) {
    final List<SyncSite> dead = sites.values.where((SyncSite s) => s.deleted).toList()
      ..sort((SyncSite a, SyncSite b) => a.at.compareTo(b.at));
    int excess = dead.length - kMaxTombstones;
    for (final SyncSite s in dead) {
      final bool tooOld = s.at > 0 && now - s.at > kTombstoneTtlMs;
      if (tooOld || excess > 0) {
        sites.remove(s.key);
        if (excess > 0) excess--;
      }
    }
  }

  /// 把每条记录的 at 抬到"本机见过的最大值之上"。
  ///
  /// 系统时钟回拨（换电池、时区乱改、Windows 时间服务抽风）会让本机生成的 at
  /// 比已同步的都小，从此本机的每次编辑都输给远端 —— 表现为"我改了它自己变回去"。
  /// 这个函数把这种局面一次性修回来。
  void bumpClock(int seenMax) {
    for (final SyncSite s in sites.values) {
      if (s.at <= seenMax) s.at = seenMax + 1;
    }
    for (final String k in prefs.keys.toList()) {
      final SyncPref p = prefs[k]!;
      if (p.at <= seenMax) prefs[k] = SyncPref(p.value, seenMax + 1);
    }
  }

  /// 文档里出现过的最大 at。
  int get maxAt {
    int m = 0;
    for (final SyncSite s in sites.values) {
      if (s.at > m) m = s.at;
    }
    for (final SyncPref p in prefs.values) {
      if (p.at > m) m = p.at;
    }
    return m;
  }
}

/// [SyncDoc.merge] 的返回值。
class SyncMergeResult {
  const SyncMergeResult(this.doc, this.conflicts);

  final SyncDoc doc;

  /// 两边都改过、结果又不一样的站点条数 —— 只用来在 UI 上报个数，不阻断同步。
  final int conflicts;
}

/// 逐字段三方合并。
///
/// 为什么不用"整条取一边"：A 改了名字、B 换了图标，整条取一边必然丢掉另一个。
/// 逐字段比较以后两条改动都能留下 —— 这是这套同步"用起来不像冲突"的关键。
///
/// [conflicts] 是个长度为 1 的计数器：真正"两边都改了同一字段且值不同"的
/// 字段数会被累加进去。只有这种才值得在界面上提一句，其余都是无感合并。
Map<String, dynamic> _mergeFields(
  Map<String, dynamic> base,
  Map<String, dynamic> local,
  Map<String, dynamic> remote,
  bool preferRemote,
  List<int> conflicts,
) {
  final List<String> keys = <String>[];
  final Set<String> seen = <String>{};
  for (final Map<String, dynamic> m in <Map<String, dynamic>>[base, local, remote]) {
    for (final String k in m.keys) {
      if (seen.add(k)) keys.add(k);
    }
  }

  final Map<String, dynamic> out = <String, dynamic>{};
  for (final String k in keys) {
    final Object? bv = base[k];
    final Object? lv = local[k];
    final Object? rv = remote[k];
    if (_eq(lv, bv)) {
      out[k] = rv;
    } else if (_eq(rv, bv)) {
      out[k] = lv;
    } else {
      out[k] = preferRemote ? rv : lv;
      // 只有 base 里**本来就有这个键**、两边又改成了不同的值，才算真冲突。
      //
      // 少了这个判断，"两台设备各自新增同一个地址"会被判成一整串字段冲突：
      // base 里没有这个键 → bv 是 null → 两个 _eq 全 false → 十个字段逐个报冲突
      // → 界面弹出"11 处两边都改过"。可实际是两边加了一模一样的东西。
      if (base.containsKey(k)) conflicts[0] = conflicts[0] + 1;
    }
  }
  return out;
}

/// 深比较：统一成 canonical JSON 再比。
///
/// 自己写而不是 `==`：`headers` 是 Map，`==` 比的是引用，永远返回 false，
/// 合并就会把没变的字段也当成"改过"，然后逐条报冲突。
bool _eq(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return jsonEncode(_canon(a)) == jsonEncode(_canon(b));
}

Object? _canon(Object? v) {
  if (v is Map) {
    final List<String> keys = v.keys.map((Object? k) => k.toString()).toList()..sort();
    final Map<String, Object?> out = <String, Object?>{};
    for (final String k in keys) {
      out[k] = _canon(v[k]);
    }
    return out;
  }
  if (v is List) return v.map(_canon).toList();
  return v;
}

Map<String, String> _sortedHeaders(Map<String, String>? raw) {
  if (raw == null || raw.isEmpty) return <String, String>{};
  final List<String> keys = raw.keys.toList()..sort();
  final Map<String, String> out = <String, String>{};
  for (final String k in keys) {
    if (k.trim().isEmpty) continue;
    out[k] = raw[k] ?? '';
  }
  return out;
}

int _max3(int a, int b, int c) {
  int m = a;
  if (b > m) m = b;
  if (c > m) m = c;
  return m;
}

String _str(Object? v) => v is String ? v.trim() : '';

int _int(Object? v, int fallback) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? fallback;
  return fallback;
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

bool _bool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.trim().toLowerCase() == 'true';
  return false;
}

Map<String, String> _headers(Object? raw) {
  if (raw is! Map) return <String, String>{};
  final Map<String, String> out = <String, String>{};
  raw.forEach((Object? k, Object? v) {
    if (k is String && k.trim().isNotEmpty && v is String) out[k] = v;
  });
  return out;
}
