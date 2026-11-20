import 'dart:convert';

import 'package:starport_core/starport_core.dart';

import 'local_secure_store.dart';

/// 把同步凭证放进 `<数据目录>/secrets.bin`（和站点密码同一个抽屉）。
///
/// 为什么凭证不能进 `starport.json`：那里面装的是"设备令牌"，拿到它就能读写
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
  Future<bool> write(SyncCredentials? credentials) async {
    try {
      if (credentials == null) {
        await _secure.delete(key: key);
      } else {
        await _secure.write(key: key, value: jsonEncode(credentials.toJson()));
      }
      // 回读一次确认真的落盘了。这个文件很小，多读一遍的代价可以忽略，
      // 换来的是"写失败不会被当成成功" —— 不然配置说已开启、界面永远报
      // 「这台设备还没有配对」，用户根本不知道该查哪里。
      if (credentials == null) return true;
      final String? back = await _secure.read(key: key);
      return back != null && back.isNotEmpty;
    } catch (_) {
      // 写不进去（磁盘满 / 只读 / 加密失败）要把 false 交回去，让调用方回滚开关。
      return false;
    }
  }
}
