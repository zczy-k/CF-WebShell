import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:starport_core/starport_core.dart';

import '../paths.dart';
import 'hard_exit.dart';
import 'webview_window_guard.dart';

/// 桌面端的窗口与托盘行为（Windows 规范版）。
///
/// * **最小化按钮 = 系统默认（进任务栏），不接管。**
///   window_manager 0.5.x 没有 preventMinimize：`onWindowMinimize` 是窗口
///   【已经最小化之后】的事后通知。在通知里再补 `hide()` 会造出
///   "最小化 + 隐藏"叠加态 —— 恢复链必须同时解两层，错一层桌面就剩一块
///   点不动的区域（本仓库曾出现过的故障形态）。系统默认最小化进任务栏，
///   任务栏由系统管理、永不失灵，也是用户的肌肉记忆。
/// * **关闭按钮 = 收进系统托盘**（[hideToTray] 开关，默认开；关掉后点关闭
///   = 真退出）。隐藏就是一次 `hide()`（`SW_HIDE`）：
///   - SW_HIDE 会**保留**最大化样式（Chrome 最小化再打开就是这个行为），
///     恢复时 `maximize()` 原样带回 —— 所以隐藏前【不做】预防性 unmaximize，
///     那会在屏幕上闪一次"从全屏缩回小窗"的还原动画，还附带一次焦点转移；
///   - 也不做 setAlwaysOnTop 折腾：TOPMOST 是窗口样式，hide() 不会放大它，
///     恢复链自有兜底。
/// * **恢复**：show → (最小化则 restore) → (曾是最大化则 maximize) → focus。
///   托盘单击是用户真实输入，自带前台授权（SetForegroundWindow 锁放行），
///   focus() 一次即可；"置顶→立刻取消"抖动只在授权失效（键盘/脚本触发）
///   没拿到前台时才作为兜底执行一次。
/// * **WebView2 残留窗清扫（Windows 专项，[WebViewWindowGuard]）**：
///   flutter_inappwebview 的内容窗是 `msedgewebview2.exe` 名下的独立顶层
///   LAYERED 弹窗（`Chrome_WidgetWin_1`），跟宿主窗口没有父子/属主关系 ——
///   宿主最小化或 hide 时它**不跟着走**，残留在原处；它对 `WM_NCHITTEST`
///   恒回 `HTNOWHERE`，覆盖区域的鼠标点击被**静默吞掉**（最大化后收托盘
///   = 整个桌面点不动即由此而来）。所以：所有让宿主不可见的路径补一次
///   `hideOrphaned()`，所有让宿主重新可见的路径补一次 `showSwept()`。
/// * **退出收尾（[_quit]）**：收割 WebView2 子进程树 → 关窗 → 硬切进程。
///   最后一步必须走 TerminateProcess，**不能把控制权交回 CRT**：从 wWinMain
///   返回会走 ExitProcess，它在持着装载器锁的状态下逐个调用插件 DLL 的
///   DllMain(DLL_PROCESS_DETACH)，而 inappwebview 的 detach 等的正是刚被
///   杀掉的那个消息泵线程 → 约 20s 后装载器死锁看门狗 fail-fast
///   0xC0000409，就是「快速异常检测失败」弹框。Runner 侧的同一处收尾也已
///   改成硬切（tools/patch_platform.py 的 patch_windows_runner_lifetime），
///   两条退出路径都不再经过 DLL detach。
/// * **历史教训（不许回潮）**：**绝对不要调 `windowManager.setSkipTaskbar()`**。
///   window_manager 的 Windows 插件在这个方法里用构造期缓存的 `ITaskbarList*`；
///   该指针没建起来时为 NULL，方法内没有判空，一调用就 `mov rax,[rcx]` 读
///   NULL->vtable 直接访问违例（window_manager_plugin.dll+0xb2af，
///   0xC0000005 进程级崩溃，Dart 侧 try/catch 拦不住）。hide() 之后任务栏
///   按钮本来就会消失，这一步没有任何收益。
///
/// 移动端没有"托盘"概念：[supported] 为 false，全部逻辑短路。
class TrayController with TrayListener, WindowListener {
  TrayController({
    required this.appName,
    required this.hideToTray,
    this.onBeforeQuit,
    this.onVisibilityChanged,
  });

  /// 展示在托盘提示与菜单里的名字。
  final String appName;

  /// 每次都现问：用户可能随时在设置里开关"关闭时收进托盘"。
  final bool Function() hideToTray;

  /// 真退出前同步落盘一次。配置/下载记录都是 400ms 防抖写（saveSoon），
  /// 而 _quit 末尾有 300ms 硬切 —— 不先 flush 的话，退出前最后几秒的
  /// 改动（改设置、加站点、下载进度）可能还没写到盘进程就没了。
  final Future<void> Function()? onBeforeQuit;

  /// 窗口可见性变了（true = 回到屏幕上，false = 收托盘 / 最小化）。
  ///
  /// **为什么要在这里补一刀**：同步的轮询定时器在隐藏窗口里一分不差地跳，
  /// 每次跳都发一个 HTTP —— 用户以为关了，其实每分钟都在唤醒网卡。
  /// `window_manager.hide()` 走的是 `SW_HIDE`，Flutter 引擎的
  /// `AppLifecycleState` 推断**不一定**跟着变（它不是 Win32 的
  /// `WM_SHOWWINDOW` 回调），所以 `SyncLifecycle` 那一路在桌面上不可靠，
  /// 必须以本类的窗口事件为准。
  ///
  /// 三类事件都往这儿打：收托盘（[onWindowClose]）、最小化、托盘恢复。
  /// 重复值由 `SyncService.setForeground` 内部短路，这里不必去重。
  final void Function(bool visible)? onVisibilityChanged;

  bool _started = false;
  bool _quitting = false;

  /// 退出路径上窗口是否真的关掉了（决定收尾退出码：关掉 = 0，没关掉 = 1）。
  bool _windowClosed = false;

  /// rect 对账防抖：手拖窗口边缘/标题栏时 onWindowResize/onWindowMove
  /// 每帧都来，对账一次要打进程快照 + 全桌面窗口枚举，合并成 250ms
  /// 一次（拖完 250ms 后落定一记，无感）。
  Timer? _resyncDebounce;

  /// 关闭收托盘那一刻窗口是否最大化。恢复时按它还原。
  /// （SW_HIDE 保留最大化样式，但恢复链显式 maximize() 一次更稳，
  /// 也把"曾经最大化过但恢复时已被用户改小"的窗口区分开。）
  bool _wasMaximized = false;

  /// 只有桌面平台才启用（本仓库只出 Windows 包，但 mac/linux 逻辑同构）。
  static bool get supported =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  Future<void> start() async {
    if (!supported || _started) return;
    _started = true;

    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    // 把窗口标题钉在 branding 名上：单实例守卫按"类名+标题"找旧窗口，
    // 标题必须与 branding 一致（哪怕 runner 的 main.cpp 没被 CI patch）。
    await windowManager.setTitle(appName);
    windowManager.addListener(this);
    trayManager.addListener(this);

    // 托盘本体（解图标到数据目录 + setIcon/setToolTip/setContextMenu 三次
    // channel 调用）不参与首帧渲染，放到后台去做 —— 这几步排在 runApp 之前
    // 时，用户看到窗口内容的时间就往后推了这些步的总和。
    //
    // 上面三行必须留在这里，尤其 `setPreventClose(true)`：它没立起来的窗口
    // 期里用户点关闭 = 真退出，而不是收进托盘。
    unawaited(_setupTray());
  }

  /// 托盘图标与菜单。晚几毫秒不影响任何行为，所以不在启动关键路径上等它。
  Future<void> _setupTray() async {
    // 退出已经开始就别再往托盘上装东西：`_quit` 里 destroy 过一次，晚到的
    // setIcon 会把图标又凭空挂回来（要等鼠标划过才消失）。整段吞异常同理 ——
    // 这段跑在后台，抛出去就是无人处理的异步错误。
    if (_quitting) return;
    try {
      // tray_manager 只吃磁盘路径：把 assets 里的图标解到数据目录再用。
      // 用 appDataDir() 而不是系统临时目录 —— 便携版下所有运行数据都在程序目录，
      // 连这个解出来的图标也一样，C 盘不留东西。
      final ByteData data = await rootBundle.load('assets/tray_icon.ico');
      final Directory dir = await appDataDir();
      final File icon = File(joinPath(dir.path, 'starport_tray.ico'));
      await icon.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await trayManager.setIcon(icon.path);
      await trayManager.setToolTip(appName);
      // tray_manager 0.5.x 的 API 叫 setContextMenu（不是 setMenu）
      await trayManager.setContextMenu(Menu(items: <MenuItem>[
        MenuItem(key: 'show', label: '打开 $appName'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]));
    } catch (_) {
      // 图标解不出来不挡启动：托盘里没图标，但窗口行为不受影响。
    }
  }

  // ------------------------------------------------------------- 窗口事件

  /// 关闭按钮：收托盘或真退出。
  ///
  /// 隐藏前只**记录**最大化状态，不动窗口 —— 隐藏动作本身只有一次
  /// `hide()`，不加任何前置窗口操作（见类注释）。hide() 之后立刻清掉
  /// WebView2 残留窗，否则它会留在桌面吞点击。
  @override
  void onWindowClose() async {
    if (_quitting) return; // 退出路径主动发送的 WM_CLOSE 不再收托盘。
    if (hideToTray()) {
      try {
        _wasMaximized = await windowManager.isMaximized();
      } catch (_) {
        _wasMaximized = false;
      }
      await windowManager.hide();
      // 窗口没了 = 同步进后台：掐掉轮询定时器，只留"手上还有没推的改动就走
      // 最后一轮"那一次补推（见 SyncService.setForeground）。
      onVisibilityChanged?.call(false);
      // WebView2 的内容窗是独立顶层弹窗，不会跟着宿主隐藏 —— 不清掉它
      // 就残留在桌面吞点击（见 WebViewWindowGuard 类注释）。
      WebViewWindowGuard.instance.hideOrphaned();
    } else {
      await _quit();
    }
  }

  /// 最小化按钮仍是**系统默认**（进任务栏），这里绝不碰宿主窗口一根毫毛；
  /// 只清 WebView2 残留窗 —— 最小化时它同样会留在原区域吞点击。
  /// （别把"事后通知里补 hide()"加回来：那才是"最小化+隐藏"叠加态的
  /// 设计根源，见类注释。）
  @override
  void onWindowMinimize() {
    WebViewWindowGuard.instance.hideOrphaned();
    // 最小化进任务栏 = 用户不看了。轮询在最小化状态下没有任何意义，
    // 停掉（改完东西切走的补推在 setForeground 里兜着）。
    onVisibilityChanged?.call(false);
  }

  /// 任务栏还原（从最小化回来）：把清掉的 WebView2 窗放回来。
  @override
  void onWindowRestore() {
    WebViewWindowGuard.instance.showSwept();
    onVisibilityChanged?.call(true);
  }

  /// 焦点兜底：万一 restore 事件因插件时序没到，窗口拿到焦点时也一定
  /// 已经可见 —— 这时补放一次（名单已清空时是空操作，零成本）。
  @override
  void onWindowFocus() {
    WebViewWindowGuard.instance.showSwept();
    onVisibilityChanged?.call(true);
  }

  // ------------------------------------------------------------- rect 对账

  /// 最大化→**还原**是重点故障位：宿主全程可见，hide/show 清扫不上场，
  /// 而插件的弹窗位置同步在这条路径上会失灵 —— WebView2 弹窗留在最大
  /// 化旧矩形上继续吞宿主外的点击（用户实测：还原后窗口旁一大块区域
  /// 点不动）。rect 一变就排一记对账：完全在宿主矩形外的弹窗挪回来。
  ///
  /// 手动拖动/缩放同样覆盖：弹窗错位残留不分触发来源，对账统一兜底。
  @override
  void onWindowResize() {
    _scheduleResync();
  }

  @override
  void onWindowMove() {
    _scheduleResync();
  }

  @override
  void onWindowMaximize() {
    _scheduleResync();
  }

  @override
  void onWindowUnmaximize() {
    _scheduleResync();
  }

  void _scheduleResync() {
    if (!supported) return;
    _resyncDebounce?.cancel();
    _resyncDebounce = Timer(const Duration(milliseconds: 250), () {
      WebViewWindowGuard.instance.resyncToHost();
    });
  }

  // ------------------------------------------------------------- 托盘事件

  @override
  void onTrayIconMouseDown() async {
    await _restore();
  }

  @override
  void onTrayIconRightMouseDown() async {
    // Windows 上菜单不会自己弹，要手动调一次。
    if (Platform.isWindows) await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show') {
      await _restore();
    } else if (menuItem.key == 'quit') {
      await _quit();
    }
  }

  /// 从托盘恢复窗口。
  ///
  /// 顺序：显示 → 若最小化则还原 → 若收托盘前是最大化则还原最大化
  /// → 补放 WebView2 残留窗 → 抢前台。托盘单击带前台授权，focus() 一次就够；
  /// 只有没拿到前台时才抖一次"置顶→取消"兜底（置顶会强制把窗口置前，马上取消
  /// 又不会让它一直压着别人）。
  Future<void> _restore() async {
    await windowManager.show();
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
    } catch (_) {}
    if (_wasMaximized) {
      _wasMaximized = false;
      try {
        await windowManager.maximize();
      } catch (_) {}
    }
    // 宿主已可见：把收托盘/最小化时清掉的 WebView2 窗放回来。
    WebViewWindowGuard.instance.showSwept();
    onVisibilityChanged?.call(true);
    await windowManager.focus();
    // 兜底：前台授权失效（键盘/脚本触发）导致 focus 没生效时才抖。
    try {
      if (!await windowManager.isFocused()) {
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setAlwaysOnTop(false);
        await windowManager.focus();
      }
    } catch (_) {}
  }

  Future<void> _quit() async {
    // 事件回调可能并发重入；先锁住退出路径，避免重复 destroy/重复定时器。
    if (_quitting) return;
    _quitting = true;

    _resyncDebounce?.cancel();
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    // 超时强退不是正常关窗；用非零退出码，避免回归测试误判成功。
    Timer(const Duration(seconds: 5), () => hardExit(1));

    // 先落盘再拆窗口：配置与下载记录在退出路径上同步 flush。
    try {
      await onBeforeQuit?.call();
    } catch (_) {
      // 落盘失败不挡退出（磁盘满/只读介质时用户至少还能走）。
    }

    // 退出前再清一次：进程树销毁前那几秒，别让残留窗继续吃桌面点击。
    // （清扫内部已改 ShowWindowAsync：跨进程投递不等回执，WebView2 正忙也
    // 不会把退出卡在这里。）
    try {
      WebViewWindowGuard.instance.hideOrphaned();
    } catch (_) {}
    try {
      await trayManager.destroy();
    } catch (_) {
      // 退出路径上任何托盘问题都不该挡住退出本身。
    }
    // WebView2 子进程树必须在**关窗之前**收掉：windowManager.close() 走
    // WM_CLOSE → Runner 的 OnDestroy 里 controller.reset() 会把引擎连同
    // Dart VM 一起拆掉，那之后的代码根本回不到 Dart。放在这里才保证执行得到。
    // （Chromium 本来就按"随时会被杀"设计，cookie 落盘自有 crash-safe 兜底；
    // 漏收的代价是 msedgewebview2.exe 孤儿，见 killDescendants 的注释。）
    try {
      WebViewWindowGuard.instance.killDescendants();
    } catch (_) {}
    try {
      if (Platform.isWindows) {
        // Windows 插件的 destroy() 直接投递 WM_QUIT。走正常 WM_CLOSE，
        // 让 Runner 在消息循环退出、COM 反初始化之前销毁 Flutter/WebView。
        await windowManager.setPreventClose(false);
        await windowManager.close();
        _windowClosed = true;
      } else {
        await windowManager.destroy();
        _windowClosed = true;
      }
    } catch (_) {
      // 插件调用失败时，仍由已启动的退出计时器兜底。
    }

    // 走到这里，进程只剩一种收尾方式：TerminateProcess，**绝不把控制权交回
    // CRT**。从 wWinMain 返回会走 ExitProcess —— 杀掉其它线程、持着装载器锁
    // 逐个调用插件 DLL 的 DllMain(DLL_PROCESS_DETACH)，而 inappwebview 的
    // detach 等的正是刚被杀掉的那个消息泵线程 → 装载器死锁看门狗约 20s 后
    // fail-fast 0xC0000409，就是用户看到的「快速异常检测失败」弹框。
    //
    // 正常情况下上面那行 await 不会返回（引擎已随 OnDestroy 拆掉），进程由
    // Runner 末尾的同款硬切结束（tools/patch_platform.py 的
    // patch_windows_runner_lifetime）；这一行只在插件先回执、Dart 还活着的
    // 时序下才走到，两条路都不再经过 DLL detach。落盘已在 onBeforeQuit 完成。
    // 关窗没成功就不是正常退出：非零码，别让回归测试把强退当成优雅关闭。
    hardExit(_windowClosed ? 0 : 1);
  }
}