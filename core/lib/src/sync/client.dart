/// 同步服务端的 HTTP 客户端。
///
/// 只用 `dart:io` 的 [HttpClient] —— 和 [UpdateChecker] 一样，core 包不许有
/// 第三方依赖，这样 `dart test` 在 CI 上几秒就跑完。
///
/// 三条设计约束：
/// * **每个请求都带超时。** 同步是后台行为，网断了不能让界面卡住。
/// * **409 不是错误，是分支。** 版本冲突是正常路径：服务端把最新文档一起返回，
///   调用方合并后重推即可，不需要用户知道发生过什么。
/// * **凭证只走 header。** 令牌绝不进 URL（会进浏览器历史、代理日志、
///   Cloudflare 的请求日志），一律 `Authorization: Bearer`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'doc.dart';

/// 同步相关的错误。故意只有一个类型 —— UI 上统一显示"同步失败：xxx"就够，
/// 用户不需要区分 HTTP 层和业务层的差别。
class SyncException implements Exception {
  // const：字段全是 final、默认值也是常量，本来就该是 const。
  // 不加的后果是真栽过一次 —— app 里 `throw const SyncException(...)` 编译报
  // const_with_non_const，而本机没有 Flutter SDK，这错只有 CI 才能撞出来。
  const SyncException(this.message, {this.status = 0});

  final String message;

  /// HTTP 状态码，0 = 还没拿到响应（DNS / 连接 / 超时）。
  final int status;

  @override
  String toString() => status == 0 ? message : 'HTTP $status · $message';
}

/// 一台设备的同步凭证。
///
/// [deviceToken] 是秘密：泄露等于别人能读写你的站点清单。所以它只存在
/// 系统安全存储里，不进 `starport.json`。
class SyncCredentials {
  const SyncCredentials({
    required this.endpoint,
    required this.spaceId,
    required this.deviceId,
    required this.deviceToken,
    this.deviceName = '',
  });

  /// 如 `https://sync.example.com`（末尾斜杠会被规整掉）。
  final String endpoint;
  final String spaceId;
  final String deviceId;
  final String deviceToken;
  final String deviceName;

  SyncCredentials copyWith({String? endpoint, String? spaceId, String? deviceId, String? deviceToken, String? deviceName}) {
    return SyncCredentials(
      endpoint: endpoint ?? this.endpoint,
      spaceId: spaceId ?? this.spaceId,
      deviceId: deviceId ?? this.deviceId,
      deviceToken: deviceToken ?? this.deviceToken,
      deviceName: deviceName ?? this.deviceName,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'endpoint': endpoint,
        'spaceId': spaceId,
        'deviceId': deviceId,
        'deviceToken': deviceToken,
        if (deviceName.isNotEmpty) 'deviceName': deviceName,
      };

  static SyncCredentials? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final String endpoint = _s(raw['endpoint']);
    final String spaceId = _s(raw['spaceId']);
    final String deviceId = _s(raw['deviceId']);
    final String token = _s(raw['deviceToken']);
    if (endpoint.isEmpty || spaceId.isEmpty || deviceId.isEmpty || token.isEmpty) {
      return null;
    }
    return SyncCredentials(
      endpoint: normalizeEndpoint(endpoint),
      spaceId: spaceId,
      deviceId: deviceId,
      deviceToken: token,
      deviceName: _s(raw['deviceName']),
    );
  }
}

/// 服务端"当前是第几版"。
class SyncHead {
  const SyncHead({required this.version, required this.updatedAtMs});

  final int version;
  final int updatedAtMs;

  static SyncHead fromJson(Object? raw) {
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    return SyncHead(version: _i(m['v']), updatedAtMs: _i(m['updatedAt']));
  }
}

/// 拉到的文档 + 版本号。
class SyncEnvelope {
  const SyncEnvelope({required this.version, required this.doc});

  final int version;
  final SyncDoc doc;
}

/// 推送结果。[ok] 为假表示版本冲突，[doc] 里是服务端的最新版本，
/// 调用方合并后再推一次。
class SyncPutResult {
  const SyncPutResult({required this.ok, required this.version, this.doc});

  final bool ok;
  final int version;
  final SyncDoc? doc;
}

/// 设备列表里的一项（用于「已配对设备」页和踢人）。
class SyncDeviceInfo {
  const SyncDeviceInfo({
    required this.id,
    required this.name,
    required this.createdAtMs,
    required this.lastSeenMs,
    required this.revoked,
    this.self = false,
  });

  final String id;
  final String name;
  final int createdAtMs;
  final int lastSeenMs;
  final bool revoked;

  /// 是不是当前正在用的这台设备。
  ///
  /// 服务端会带上来，客户端拿它把"移除"按钮藏掉 —— 自己踢自己会被服务端拒
  /// （`cannot_revoke_self`），不如一开始就不给这个按钮，用户少看一条报错。
  final bool self;

  String get displayName => name.trim().isEmpty ? id : name;

  static SyncDeviceInfo fromJson(Object? raw) {
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    return SyncDeviceInfo(
      id: _s(m['id']),
      name: _s(m['name']),
      createdAtMs: _i(m['createdAt']),
      lastSeenMs: _i(m['lastSeen']),
      revoked: m['revoked'] == true,
      self: m['self'] == true,
    );
  }
}

/// 历史版本的一条摘要（不带文档本体 —— 列表页只要版本号和时间）。
class SyncHistoryEntry {
  const SyncHistoryEntry({
    required this.version,
    required this.createdAtMs,
    required this.siteCount,
  });

  final int version;
  final int createdAtMs;

  /// 那一版里活着的站点数。用来在界面上写"12 个站点"。
  final int siteCount;

  static SyncHistoryEntry fromJson(Object? raw) {
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    return SyncHistoryEntry(
      version: _i(m['v']),
      createdAtMs: _i(m['createdAt']),
      siteCount: _i(m['sites']),
    );
  }
}

/// 配对码。
class SyncPairCode {
  const SyncPairCode({required this.code, required this.expiresAtMs});

  final String code;
  final int expiresAtMs;

  int get remainingMs => expiresAtMs - DateTime.now().millisecondsSinceEpoch;

  static SyncPairCode fromJson(Object? raw) {
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    return SyncPairCode(code: _s(m['code']), expiresAtMs: _i(m['expiresAt']));
  }
}

/// 所有同步请求共用一个 [HttpClient]：连接池 + TLS 会话复用。
///
/// 以前每个请求 new 一个、`finally` 里 `close(force: true)` —— 那等于每发一条
/// 请求就主动把 keep-alive 连接撕掉，下一轮同步再从头走一遍 DNS + TCP + TLS
/// 握手。一轮同步要发好几条（head / doc / put / devices…），省下来的正是这些
/// 握手，跨境或移动网络下一条握手就是几百毫秒。
///
/// 超时语义不受影响：这里的超时是**每次请求**上用 `.timeout()` 包的，
/// 不是 client 的属性；client 上只留连接超时与代理策略这两项全局设置。
HttpClient _sharedHttpClient = _newSharedHttpClient();

HttpClient _newSharedHttpClient() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 5)
  // Cloudflare 上跑的 Worker 不需要跟随重定向；跟了反而会把 Bearer 头
  // 带到别的主机上。
  ..findProxy = ((Uri _) => 'DIRECT');

/// 真正的 HTTP 客户端。
class SyncClient {
  /// 关掉并重建共享连接池。**生产代码不要调**：这份客户端的生存期就是进程的
  /// 生存期，Windows 退出走 TerminateProcess，socket 由系统统一回收。
  ///
  /// 它只为一件事存在：单测里每个用例都会 `HttpServer.close(force: true)`
  /// 关掉自己起的假云端并释放端口，而**端口会被下一个用例复用** —— 连接池里
  /// 那条"指向已经关掉的服务器"的空闲连接不能带过去。用例的 tearDown 调一次，
  /// 每个用例都从干净连接池开始。
  static void closeSharedClient() {
    final HttpClient dying = _sharedHttpClient;
    _sharedHttpClient = _newSharedHttpClient();
    // force = 立刻断开，不等 keep-alive 空闲连接超时（那是 15 秒）。
    // `HttpClient.close()` 本身是同步 void（返回 Future 的是 HttpServer.close），
    // 所以这里没有 await，也不需要。
    dying.close(force: true);
  }

  SyncClient(this.credentials, {this.timeout = const Duration(seconds: 15)});

  final SyncCredentials credentials;
  final Duration timeout;

  /// 服务地址里那个"空间"的概念只存在服务端；客户端每次请求带上 Bearer 就够了，
  /// 空间是从 token 里反查的 —— 这样即使有人拿到 spaceId 也读不到数据。
  Map<String, String> get _authHeaders => <String, String>{
        'Authorization': 'Bearer ${credentials.deviceToken}',
      };

  /// 只问版本号，不拉文档。轮询用这个 —— 没变化时就几十字节。
  Future<SyncHead> head() async {
    final Object? raw = await _request('GET', '/v1/head', headers: _authHeaders);
    return SyncHead.fromJson(raw);
  }

  /// 拉整份文档。
  Future<SyncEnvelope> fetchDoc() async {
    final Object? raw = await _request('GET', '/v1/doc', headers: _authHeaders);
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    return SyncEnvelope(version: _i(m['v']), doc: SyncDoc.fromJson(m['doc']));
  }

  /// 推文档。[baseVersion] 是这次改动基于的版本，服务端靠它做 CAS。
  ///
  /// 返回 `ok: false` 时把服务端的 `doc` 一起带回来 —— 调用方可以立刻在内存里
  /// 合并再推，用户完全看不到"同步冲突"这种字眼。
  Future<SyncPutResult> putDoc(SyncDoc doc, int baseVersion) async {
    final Object? raw = await _request(
      'PUT',
      '/v1/doc',
      headers: _authHeaders,
      body: <String, dynamic>{'baseV': baseVersion, 'doc': doc.toJson()},
      allowStatus: const <int>{409},
    );
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    final bool ok = m['ok'] == true;
    return SyncPutResult(
      ok: ok,
      version: _i(m['v']),
      doc: ok ? null : SyncDoc.fromJson(m['doc']),
    );
  }

  /// 列出这个空间里所有设备。
  Future<List<SyncDeviceInfo>> devices() async {
    final Object? raw = await _request('GET', '/v1/devices', headers: _authHeaders);
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    final Object? list = m['devices'];
    final List<SyncDeviceInfo> out = <SyncDeviceInfo>[];
    if (list is List) {
      for (final Object? e in list) {
        out.add(SyncDeviceInfo.fromJson(e));
      }
    }
    return out;
  }

  /// 踢掉一台设备（它下次带 token 来就会被拒）。
  Future<void> revoke(String deviceId) async {
    await _request(
      'POST',
      '/v1/devices/revoke',
      headers: _authHeaders,
      body: <String, dynamic>{'deviceId': deviceId},
    );
  }

  /// 历史版本清单（新的在前）。用来在界面上给"恢复"选一个点。
  Future<List<SyncHistoryEntry>> history() async {
    final Object? raw = await _request('GET', '/v1/history', headers: _authHeaders);
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    final Object? list = m['versions'];
    final List<SyncHistoryEntry> out = <SyncHistoryEntry>[];
    if (list is List) {
      for (final Object? e in list) {
        out.add(SyncHistoryEntry.fromJson(e));
      }
    }
    return out;
  }

  /// 把某一版历史**重新当成一次正常推送**写回去。
  ///
  /// 不走"直接覆盖库"的捷径，是为了让其它设备靠现有的轮询自然收到 ——
  /// 版本号单调递增，别人的 `HEAD` 一比对就知道该拉了，不需要额外的通知机制。
  Future<SyncPutResult> restoreHistory(int version) async {
    final Object? raw = await _request(
      'POST',
      '/v1/history/restore',
      headers: _authHeaders,
      body: <String, dynamic>{'v': version},
      allowStatus: const <int>{409},
    );
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    final bool ok = m['ok'] == true;
    return SyncPutResult(
      ok: ok,
      version: _i(m['v']),
      doc: ok ? null : SyncDoc.fromJson(m['doc']),
    );
  }

  // -------------------------------------------------------------------
  // 下面三个是"还没有凭证"时用的静态方法
  // -------------------------------------------------------------------

  /// 第一次部署：用部署时设的 bootstrap 密钥开一个空间，并把自己注册成第一台设备。
  ///
  /// 密钥只做一件事：证明"你确实拥有这个 Cloudflare 项目"。拿不到它的人
  /// 哪怕知道服务地址，也开不出空间，更配不了对。
  static Future<SyncCredentials> bootstrap({
    required String endpoint,
    required String bootstrapSecret,
    required String deviceName,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final Object? raw = await _requestStatic(
      endpoint,
      'POST',
      '/v1/bootstrap',
      headers: <String, String>{'X-Bootstrap': bootstrapSecret},
      body: <String, dynamic>{'deviceName': deviceName},
      timeout: timeout,
    );
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    final SyncCredentials? c = SyncCredentials.tryFromJson(<String, dynamic>{
      'endpoint': endpoint,
      'spaceId': _s(m['spaceId']),
      'deviceId': _s(m['deviceId']),
      'deviceToken': _s(m['deviceToken']),
      'deviceName': deviceName,
    });
    if (c == null) {
      throw SyncException('服务端返回的凭证不完整，检查服务地址是不是这个同步服务');
    }
    return c;
  }

  /// 在一台已经配好的设备上生成一次性配对码。
  Future<SyncPairCode> newPairCode() async {
    final Object? raw = await _request('POST', '/v1/pair/code', headers: _authHeaders, body: const <String, dynamic>{});
    return SyncPairCode.fromJson(raw);
  }

  /// 新设备用配对码换自己的凭证。
  ///
  /// 配对码一次性且有时效（默认 10 分钟）—— 在别人手机上生成的码过期就作废，
  /// 不需要跑一趟"撤销"。
  static Future<SyncCredentials> pair({
    required String endpoint,
    required String code,
    required String deviceName,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final Object? raw = await _requestStatic(
      endpoint,
      'POST',
      '/v1/pair',
      headers: const <String, String>{},
      body: <String, dynamic>{'code': code.trim(), 'deviceName': deviceName},
      timeout: timeout,
    );
    final Map<dynamic, dynamic> m = raw is Map ? raw : const <dynamic, dynamic>{};
    final SyncCredentials? c = SyncCredentials.tryFromJson(<String, dynamic>{
      'endpoint': endpoint,
      'spaceId': _s(m['spaceId']),
      'deviceId': _s(m['deviceId']),
      'deviceToken': _s(m['deviceToken']),
      'deviceName': deviceName,
    });
    if (c == null) {
      throw SyncException('配对失败：服务端返回的凭证不完整');
    }
    return c;
  }

  // -------------------------------------------------------------------

  Future<Object?> _request(
    String method,
    String path, {
    Map<String, String>? headers,
    Object? body,
    Set<int> allowStatus = const <int>{},
  }) {
    return _requestStatic(
      credentials.endpoint,
      method,
      path,
      headers: headers,
      body: body,
      timeout: timeout,
      allowStatus: allowStatus,
    );
  }

  static Future<Object?> _requestStatic(
    String endpoint,
    String method,
    String path, {
    Map<String, String>? headers,
    Object? body,
    Duration timeout = const Duration(seconds: 15),
    Set<int> allowStatus = const <int>{},
  }) async {
    final Uri uri = Uri.parse('${normalizeEndpoint(endpoint)}$path');

    try {
      final HttpClientRequest req =
          await _sharedHttpClient.openUrl(method, uri).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final String? userAgent = _ua();
      if (userAgent != null) req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      if (headers != null) {
        for (final MapEntry<String, String> e in headers.entries) {
          req.headers.set(e.key, e.value);
        }
      }
      if (body != null) {
        final List<int> bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.headers.contentLength = bytes.length;
        req.add(bytes);
      }

      final HttpClientResponse res = await req.close().timeout(timeout);
      final String text = await res.transform(utf8.decoder).join().timeout(timeout);

      if (res.statusCode >= 200 && res.statusCode < 300) {
        return _decode(text);
      }
      if (allowStatus.contains(res.statusCode)) {
        return _decode(text);
      }
      throw SyncException(_errorMessage(res.statusCode, text), status: res.statusCode);
    } on SyncException {
      rethrow;
    } on TimeoutException {
      throw SyncException('连接同步服务超时，检查网络或服务地址');
    } on SocketException catch (e) {
      throw SyncException('连不上同步服务：${e.osError?.message ?? e.message}');
    } catch (e) {
      throw SyncException('同步请求失败：$e');
    }
  }

  static Object? _decode(String text) {
    if (text.trim().isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      // 服务地址填成了别人的网站时，返回的是 HTML —— 说人话比抛 FormatException 强。
      throw SyncException('服务端返回的不是 JSON，服务地址可能填错了');
    }
  }

  static String _errorMessage(int status, String text) {
    Object? raw;
    try {
      raw = text.trim().isEmpty ? null : jsonDecode(text);
    } catch (_) {
      raw = null;
    }
    if (raw is Map) {
      final String err = _s(raw['error']);
      if (err.isNotEmpty) return _humanize(err, status);
    }
    switch (status) {
      case 401:
        return '设备凭证已失效，需要重新配对';
      case 403:
        return '这个设备已被移出同步空间';
      case 404:
        return '服务地址不对，或者同步空间不存在';
      case 429:
        return '请求太频繁，稍后会自动重试';
      case 500:
      case 502:
      case 503:
        return '同步服务暂时不可用';
    }
    return '同步服务返回 HTTP $status';
  }

  static String _humanize(String code, int status) {
    switch (code) {
      case 'bad_bootstrap':
        return '部署密钥不对';
      case 'bad_code':
        return '配对码无效或已过期，在已配对的设备上重新生成一个';
      case 'revoked':
        return '这个设备已被移出同步空间';
      case 'space_full':
        return '这个同步空间的设备数已达上限';
      case 'too_large':
        return '站点太多，超出了单个文档的上限';
      case 'rate_limited':
        return '请求太频繁，稍后会自动重试';
      case 'cannot_revoke_self':
        return '这是当前这台设备，不能把自己移出（要停用请点「断开同步」）';
      case 'corrupt_doc':
        return '服务端的同步文档已损坏，已停止写入以免覆盖，稍后重试';
      case 'no_history':
        return '这一版历史已经不在了，重新打开历史版本列表看看';
      case 'unauthorized':
        // 走到这里几乎只有一个原因：请求路径没命中任何接口，Worker 把它当成
        // "没带设备凭证的访问"。所以别让用户去怀疑密钥 —— 直接指向地址。
        return '服务地址可能带了多余路径（如 /v1/health），或者这个 Worker 版本太旧、'
            '不认识 /v1/bootstrap。地址只填到域名再试一次';
    }
    return code;
  }

  static String? _ua() {
    // 只用 dart:io，拿不到应用版本；固定一个能看出是谁的 UA 就好。
    return 'Starport-Sync/1';
  }
}

String _trimSlash(String s) {
  String out = s.trim();
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// 路径里那些"具体接口名"。粘错地址时它们是最常见的尾巴。
const Set<String> _endpointTails = <String>{
  'health',
  'bootstrap',
  'pair',
  'state',
  'devices',
  'history',
  'version',
  'doc',
};

/// 把用户填的服务地址规整成"只剩根"的基址。
///
/// 真事：从浏览器地址栏抄下来的健康检查地址是
/// `https://xxx/v1/health`，拼上 `/v1/bootstrap` 就变成
/// `/v1/health/v1/bootstrap` —— Worker 认不出这个路径，代码里所有未知路径都会
/// 落到鉴权兜底那一行，于是回一个 `unauthorized`。用户看到的既不是"地址错"也
/// 不是"密钥错"，只能来问人。
///
/// 与其靠提示教育用户，不如自己吃掉错：**看到 `v1` / `api` 段就整段砍掉**，
/// 没有这种段时砍掉末尾那个已知接口名。都不匹配就原样保留 —— 真有人把 Worker
/// 挂在 `https://example.com/starport` 这种子路径上，砍了反而连不上。
///
/// 顺带把 `?query` 和 `#fragment` 扔掉（它们同样不该出现在基址里），
/// 并且协议缺省补 `https://`。
String normalizeEndpoint(String raw) {
  final String s = raw.trim();
  if (s.isEmpty) return s;

  // 没写协议时先补上再解析：`Uri.parse('sync.example.com/v1/health')` 的
  // `host` 是空的（整串被当成 path），不补协议就只能原样吐回去。
  final String withScheme =
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(s) ? s : 'https://$s';

  final Uri uri;
  try {
    uri = Uri.parse(withScheme);
  } on FormatException {
    return _trimSlash(s);
  }
  if (uri.host.isEmpty) return _trimSlash(s);

  final List<String> segs = uri.pathSegments.where((String e) => e.isNotEmpty).toList();

  // 找最靠前的 `v1` / `api` 段 —— 它和它后面的一切都是接口路径，不是基址。
  int cut = -1;
  for (int i = 0; i < segs.length; i++) {
    final String low = segs[i].toLowerCase();
    if (low == 'v1' || low == 'api') {
      cut = i;
      break;
    }
  }
  if (cut < 0 && segs.isNotEmpty && _endpointTails.contains(segs.last.toLowerCase())) {
    cut = segs.length - 1;
  }
  final List<String> keep = cut < 0 ? segs : segs.sublist(0, cut);

  final StringBuffer out = StringBuffer()
    ..write(uri.scheme.isEmpty ? 'https' : uri.scheme)
    ..write('://')
    ..write(uri.host);
  if (uri.hasPort) {
    out
      ..write(':')
      ..write(uri.port);
  }
  for (final String seg in keep) {
    out
      ..write('/')
      ..write(seg);
  }
  return out.toString();
}

String _s(Object? v) => v is String ? v.trim() : '';

int _i(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}
