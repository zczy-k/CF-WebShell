import 'dart:convert';

import 'package:webshell_core/webshell_core.dart';

import 'local_secure_store.dart';

/// 把同步凭证放进 `<数据目录>/secrets.bin`（和站点密码同一个抽屉）。
///
/// 为什么凭证不能进 `webshell.json`：那里面装的是"设备令牌"，拿到它就能读写
/// 整个同步空间的站点清单 —— 等于拿到账号。放在 secrets.bin 里，Windows 上是
/// DPAPI 加密（别的用户、别的机器都解不开），Android 上是应用私有目录 + 混淆。
///
/// 为什么 key 写成 `sync:creds` 而不是 `sync`：这个文件里还躺着
/// `basic:<站点id>` 这类键，加个冒号前缀一眼能看出分组，也避免将来撞名。
class SecureSyncCredentialStore implements SyncCredentialStore {
  SecureSyncCredentialStore(this._secure);

  final LocalSecureStore _secure;

  static const String key = 'sync:creds';

  @override
  Future<SyncCredentials?> read() async {
    try {
      final String? raw = await _secure.read(key: key);
      if (raw == null || raw.trim().isEmpty) return null;
      return SyncCredentials.tryFromJson(jsonDecode(raw));
    } catch (_) {
      // 文件坏了 / 换了 Windows 用户解不开 → 当成"没配对"，界面上提示重新配对。
      // 绝不能让它抛出去挡住启动。
      return null;
    }
  }

  @override
  Future<void> write(SyncCredentials? credentials) async {
    try {
      if (credentials == null) {
        await _secure.delete(key: key);
      } else {
        await _secure.write(key: key, value: jsonEncode(credentials.toJson()));
      }
    } catch (_) {
      // 写不进去（磁盘满 / 只读）不该让同步流程崩；下一次写还会再试。
    }
  }
}
