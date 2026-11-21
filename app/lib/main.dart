// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 zczy-k

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:starport_core/starport_core.dart';

import 'src/app.dart';
import 'src/desktop/hard_exit.dart';
import 'src/desktop/single_instance.dart';
import 'src/desktop/tray_controller.dart';
import 'src/download_notifier.dart';
import 'src/startup_update_check.dart';
import 'src/state.dart';
import 'src/sync_lifecycle.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final Branding branding = await loadBranding();

  // Windows 单实例：同一个包（同一 app_id）只许跑一个。第二个实例
  // 唤醒旧窗口后立即退出 —— 多开会让各自的 WebView2 残留弹窗互相看不见
  // 对方进程系的清扫名单，正是"桌面点不动"Bug 的多开放大版（见
  // single_instance.dart / webview_window_guard.dart 的注释）。
  //
  // 重复启动曾在唤醒旧窗口后弹「快速异常检测失败」(0xC0000409)：那时走的是
  // exit(0) —— CRT 收尾会持装载器锁逐个调用插件 DLL 的 DllMain(DETACH)，
  // inappwebview 的 detach 等的正是刚被 ExitProcess 杀掉的线程，死锁看门狗
  // 约 20s 后 fail-fast。此分支尚未加载用户状态，直接用 Windows 硬切跳过
  // DLL 收尾（机理与退出路径同源，见 TrayController._quit）。
  if (!SingleInstanceGuard.instance.claim(
    windowTitle: branding.appName,
    appId: branding.appId,
  )) {
    hardExit(0);
    return;
  }

  final ShellState state = await ShellState.create(branding);

  // 先把引擎的原生 UA 取一份存进 state。
  //
  // 目的是让浏览页能派生一个"去掉 `; wv` 标记"的 UA（见 browser_page 的
  // _effectiveUa）：那个标记等于自报"我在 WebView 里"，Cloudflare 一类风控
  // 见到就上强制人机验证，站点会在手机上无限挑战、还提示设备时间不对。
  // 必须在 runApp 之前取到 —— WebView 的 settings 是建的时候就定死的，
  // 等 onWebViewCreated 再改就得整页 reload 一次。
  // 取不到就留空，浏览页回退到引擎自己的 UA，绝不因为这一层拖慢启动。
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      final String ua = await InAppWebViewController.getDefaultUserAgent();
      if (ua.isNotEmpty) state.engineUserAgent = ua;
    } catch (_) {}
  }

  // Android：下载进度通知 + 下载期间前台保活（其他平台 attach 内部 no-op）。
  DownloadNotifier.instance.attach(state);

  // 桌面端：关闭按钮收进系统托盘（最小化按钮走系统默认进任务栏，不接管；
  // 移动端没有托盘，supported 为 false 直接跳过）
  if (TrayController.supported) {
    final TrayController tray = TrayController(
      appName: branding.appName,
      hideToTray: () => state.config.closeToTray,
      // 真退出前同步落盘：配置与下载记录都是 400ms 防抖写，退出路径上的
      // 300ms 硬切可能抢在落盘前 —— 这里 flush 一次，最后的改动不丢。
      //
      // 同步放在落盘之前：这一轮要是从云端拉回了新内容，它会直接写进 config，
      // 紧接着的 saveNow 才能把合并结果一起存下来（反过来就是先存了个旧版本）。
      // 2 秒是死上限 —— _quit 里 5 秒就 hardExit，网络卡住的轮次绝不能把
      // "点关闭"拖成"程序没响应"。等不到就放弃：改动留在本地，下次启动补推。
      onBeforeQuit: () async {
        await state.flushSyncForQuit(const Duration(seconds: 2));
        state.saveNow();
        state.saveDownloadsNow();
      },
      // 同步的前后台开关。**桌面端这一路才是准的** ——
      // window_manager.hide()/最小化都不保证触发 Flutter 的
      // AppLifecycleState，只有 Win32 窗口事件是确定的（见 TrayController
      // 里 onVisibilityChanged 的注释）。
      onVisibilityChanged: state.setSyncForeground,
    );
    await tray.start();
  }

  // 启动静默更新检查（24h 节流；无 updateUrl / 无新版 / 网络失败全部静默）。
  // 不 await：启动路径不等网络，弹窗与否由它内部等第一帧决定。
  unawaited(runStartupUpdateCheck(state));

  // 同步：把"前台/后台"接到调度器，再让调度器自己排第一轮（3 秒后）。
  //
  // 这里接的两个回调是**同一件事**的两个来源：
  // * 移动端靠 AppLifecycleState（切走 / 回到前台）；
  // * 桌面端靠 TrayController 的窗口事件（收托盘 / 最小化 / 恢复）。
  // 重复值由 SyncService.setForeground 内部短路，不用担心两路打架。
  //
  // 后台一律不轮询 —— 这一条在 core 里硬编码死了，任何档位都绕不过去。
  // 唯一例外：切到后台那一刻手上还有没推上去的改动，补推最后一轮
  // （否则"改完就关窗口"的那次修改永远到不了云端）。
  final SyncService? sync = state.sync;
  if (sync != null) {
    WidgetsBinding.instance.addObserver(SyncLifecycle(state.setSyncForeground));
    sync.start();
  }

  runApp(StarportApp(state: state));
}

/// 白标配置来自 `assets/preset.json`（CI 按 workflow 输入重写它再打包）。
///
/// 读不到就用通用壳默认值：一个坏文件不该让 App 起不来。
/// 但失败原因记进 [presetLoadError]，空状态页会显示 —— 否则用户只能对着
/// 一个空白列表猜"是不是构建出错了"。
Future<Branding> loadBranding() async {
  try {
    final String text = await rootBundle.loadString('assets/preset.json');
    final Object? raw = jsonDecode(text);
    final Branding branding = Branding.fromJson(raw);
    // 写了预置站点却一项都没解析出来 —— 这不是"通用壳"，是配置写错了。
    // 不吭声的话用户看到的就是一个空列表，跟"根本没打包站点"分不清。
    final Object? rawSites = raw is Map ? raw['presetSites'] : null;
    if (rawSites is List && rawSites.isNotEmpty && branding.effectivePresetSites.isEmpty) {
      presetLoadError =
          'preset.json 的 presetSites 一项都没解析出来（每项都需要非空的 url）：'
          '${jsonEncode(rawSites)}';
    }
    return branding;
  } catch (e) {
    presetLoadError = e.toString();
    return Branding.generic;
  }
}
