/// 把"回到前台"这件事转给调度器（[SyncService.onResume]）。
///
/// 单独一个类而不是让 `ShellState` 直接 `with WidgetsBindingObserver`：
/// `ShellState` 是纯数据 + 接线的对象，混进生命周期钩子会让它的单测要
/// 起一个 `WidgetsBinding`；分开以后测试里根本不注册这个观察者。
///
/// 调度逻辑本身在 core 的 `SyncService` 里（纯 Dart，可 `dart test`），
/// 这个文件是它在 Flutter 侧唯一需要的那点胶水。
library;

import 'package:flutter/widgets.dart';

class SyncLifecycle extends WidgetsBindingObserver {
  SyncLifecycle(this.onResume);

  final void Function() onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}
