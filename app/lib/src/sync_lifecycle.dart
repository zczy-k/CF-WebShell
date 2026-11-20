/// 把「前台 / 后台」这件事转给调度器（`SyncService.setForeground`）。
///
/// 单独一个类而不是让 `ShellState` 直接 `with WidgetsBindingObserver`：
/// `ShellState` 是纯数据 + 接线的对象，混进生命周期钩子会让它的单测要
/// 起一个 `WidgetsBinding`；分开以后测试里根本不注册这个观察者。
///
/// 调度逻辑本身在 core 的 `SyncService` 里（纯 Dart，可 `dart test`），
/// 这个文件是它在 Flutter 侧唯一需要的那点胶水。
///
/// **为什么 `inactive` 不算后台**：它只是"没有焦点"，窗口明明还在屏幕上。
/// 桌面用户最常见的姿势就是主屏开着壳、人在别的窗口干活 —— 把那种情况判成
/// 后台，等于同步在这台机器上彻底不动了，用户会报"同步坏了"。真正该停的是
/// `hidden`（收进托盘 / 缩到后台）和 `paused`（移动端切走）。
///
/// 桌面端特别注意：`window_manager.hide()` 把窗口收进托盘时**不一定**会
/// 触发 `hidden`（Flutter 的生命周期是引擎侧的推断，不是 Win32 的
/// `WM_SHOWWINDOW`）。所以桌面还得靠 `TrayController` 的窗口事件补一刀 ——
/// 两路都接到同一个 `setSyncForeground`，谁先到都算数。
library;

import 'package:flutter/widgets.dart';

class SyncLifecycle extends WidgetsBindingObserver {
  SyncLifecycle(this.setForeground);

  /// 传 `true` = 回到前台，`false` = 进后台。重复调用必须是幂等的
  /// （`SyncService.setForeground` 内部已经做了同值短路）。
  final void Function(bool visible) setForeground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        setForeground(true);
      case AppLifecycleState.inactive:
        // 仅仅失去焦点：窗口还在，照常同步（见文件头注释）。
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        setForeground(false);
    }
  }
}
