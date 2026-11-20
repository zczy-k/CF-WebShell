/// 同步的**调度层**：决定"什么时候跑一轮"。
///
/// 合并逻辑在 [SyncEngine]，这里只管节奏：
///
/// ```
/// 用户改了一个站点      → 8 秒防抖（连着改五次只跑一轮）
/// 启动                 → 3 秒后拉一次（等首帧画完，别拖慢开机）
/// 从后台回前台         → 30 秒节流（切来切去不该狂发请求）
/// 前台平时             → 按 SyncPacing 的退避阶梯问版本号
///                        默认 60,60,120,120,120,300×4,600 秒封顶
/// 切到后台             → **立刻停**；手上有没推的改动就补推最后一轮，然后闭嘴
/// ```
///
/// 为什么平时要轮询而不是长连接：Cloudflare Worker 免费额度按**请求数**算，
/// WebSocket 会一直占着连接、还要额外算时长，而轮询一次 `HEAD` 只有几十字节。
///
/// 为什么要退避阶梯：一台设备挂着 8 小时，60 秒一档 = 480 次请求；退到 10 分钟
/// 就只剩 50 次上下。免费额度 10 万次/天看着够用，但用户不止一台设备、
/// 还可能同时开着几个壳 —— 能省就省，反正"没变化"时快慢都一样没变化。
///
/// 为什么后台必须停：Windows 上「关掉窗口藏到托盘」的进程不会像手机上那样被
/// 系统冻结，定时器会一分不差地跳 —— 用户以为关了，其实每分钟还在发一次
/// HTTP、唤醒一次网卡。那才是这段时间里最实在的耗电来源。
///
/// **为什么放在 core 而不是 App 层**：这一整个类只有 `dart:async` 一个依赖，
/// 计时器 + 计数器是纯逻辑。放进 App 层就得靠 `flutter_test` 才能跑（起一个
/// 假的 `WidgetsBinding`、还要处理 `Timer` 和测试时钟的对账），而它恰恰是最
/// 容易写错的那部分（防抖漏掉、降频降不回来、dispose 后还在发请求）。
/// 放在这里，CI 上一次 `dart test` 就把这些边界全跑一遍。
library;

import 'dart:async';

import 'client.dart';
import 'pacing.dart';
import 'state.dart';

/// 同步调度器。**不含合并逻辑**，只负责触发和节流。
class SyncService {
  SyncService({
    required this.engine,
    this.onChanged,
    this.debounce = const Duration(seconds: 8),
    this.pollFast = const Duration(seconds: 60),
    this.pollSlow = const Duration(seconds: 180),
    this.resumeThrottle = const Duration(seconds: 30),
    this.slowAfterUnchanged,
    SyncPacing? pacing,
    Future<SyncRunResult> Function()? runner,
  })  : _run = runner ?? engine.runOnce,
        _pacing = pacing ?? SyncPacing.balanced;

  final SyncEngine engine;

  /// 真正干活的那一步。默认就是 [SyncEngine.runOnce]。
  ///
  /// 留这个口子**只**为了单测：调度逻辑的边界（防抖合并、降频、节流、dispose）
  /// 全都和网络无关，而真引擎要读凭证、发 HTTP、写临时文件才能产出一个结果。
  /// 换成替身以后，这些测试是确定性的、毫秒级的。
  final Future<SyncRunResult> Function() _run;

  /// 状态变了就喊一声 —— App 层在这里 `notifyListeners()`，界面跟着换图标。
  final void Function()? onChanged;

  /// 用户改完东西等多久再同步（防抖）。
  final Duration debounce;

  /// 平时轮询间隔。
  final Duration pollFast;

  /// 连续 [slowAfterUnchanged] 次没变化之后的轮询间隔。
  final Duration pollSlow;

  /// 回前台时距上次同步不足这个时长就跳过。
  final Duration resumeThrottle;

  /// **老的两档模式**：连续几轮"双方都没动"之后从 [pollFast] 换到 [pollSlow]。
  ///
  /// 留成 nullable 是有意的：传了（非 null）就走这套老逻辑，不传就走 [pacing]
  /// 的退避阶梯。单测里那些「压到毫秒级」的用例显式传它，所以行为一点没变。
  final int? slowAfterUnchanged;

  /// 退避阶梯与档位（见 [SyncPacing]）。null 时用 [SyncPacing.balanced]。
  SyncPacing _pacing;

  /// 应用是否在前台可见。
  ///
  /// **后台一律不轮询** —— 这是整套省电方案的承重墙：手机上系统本来就会冻结
  /// 进程（Android Doze / iOS 挂起），但 Windows 托盘里的进程会一分不差地跳
  /// 定时器，那才是真正在无意义耗电的场合。
  bool _foreground = true;

  /// 追赶窗截止时刻（ms）。刚发生过推送/拉取时，这段时间里不再升档。
  int _catchUpUntilMs = 0;

  Timer? _debounceTimer;
  Timer? _pollTimer;
  bool _started = false;
  bool _disposed = false;
  bool _running = false;

  /// 连续几轮"双方都没动"。
  int _unchanged = 0;

  int _lastResumeMs = 0;
  int _lastRunMs = 0;

  SyncRunResult _lastResult = SyncRunResult.disabled;

  bool get enabled => engine.config.syncConfigured;

  /// 在跑（自己的在跑，或者引擎正被别处用着）。
  bool get busy => _running || engine.busy;

  /// 上一次跑的结果。
  SyncRunResult get lastResult => _lastResult;

  SyncStatus get status => _lastResult.status;

  String get message => _lastResult.message;

  /// 本机有改动还没推上去（界面上显示"待同步"）。
  bool get pending {
    if (!enabled) return false;
    return engine.state.local.contentHash() != engine.state.base.contentHash();
  }

  /// 上一次真的跑完的时刻（0 = 还没跑过）。
  int get lastRunMs => _lastRunMs;

  /// 已经连续几轮"双方都没动"（给测试和排查用）。
  int get unchangedPolls => _unchanged;

  /// 现在是不是前台可见。托盘里藏着的窗口 = false。
  bool get foreground => _foreground;

  /// 启动。默认等 3 秒再跑：首帧还没画出来就去连网，换来的只是启动变慢。
  ///
  /// 没配置同步时**不**记 `_started` 标记 —— 用户完全可能在这次运行中途才去
  /// 配对，那时候再调 [start] 还得管用。
  void start({Duration delay = const Duration(seconds: 3)}) {
    if (_disposed || _started || !enabled) return;
    // 一开始就不可见（比如开机自启直接进托盘）：不排任何东西，
    // 等 [setForeground] 真把它叫醒再说。
    if (!_foreground) return;
    _started = true;
    _pollTimer?.cancel();
    _pollTimer = Timer(delay, () => unawaited(syncNow()));
  }

  /// 本机配置改了（加站 / 删站 / 改名 / 换偏好）→ 折进 local 并开始防抖。
  ///
  /// 这里同步调一次 [SyncEngine.markDirty]（纯内存计算，不联网），
  /// 好处是界面立刻能显示"有改动待同步"，不用等那 8 秒。
  void markDirty() {
    if (_disposed || !enabled) return;
    engine.markDirty();
    _notify();
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(syncNow()));
  }

  /// 从后台回到前台。节流 [resumeThrottle]。
  void onResume() => setForeground(true);

  /// 前台可见性切换。**整套省电方案的承重墙。**
  ///
  /// 为什么必须有它：手机上系统自己会冻结后台进程（Android Doze / iOS 挂起），
  /// 但 Windows 上「关掉窗口藏到托盘」的进程会一分不差地跳定时器 —— 用户以为
  /// 关了，实际每分钟还在发一次 HTTP、唤醒一次网卡。那才是真正的无意义耗电。
  ///
  /// 不可见时：
  /// 1. 掐掉轮询定时器，之后不再排；
  /// 2. 如果手上还有没推上去的改动，**趁现在推最后一轮**（否则"改完就切走"
  ///    的那次修改永远到不了云端）。推完 [syncNow] 里的 `_schedule()` 会因为
  ///    不可见而直接返回，所以不会再排下一个定时器。
  ///
  /// 可见时：重置退避计数与追赶窗，然后按 [resumeThrottle] 决定要不要立刻补
  /// 一轮。就算被节流跳过，也要保证定时器还在（可能刚从后台醒来、定时器是空的）。
  void setForeground(bool visible) {
    if (_disposed) return;
    final bool was = _foreground;
    _foreground = visible;

    if (!visible) {
      if (!was) return;
      _pollTimer?.cancel();
      _pollTimer = null;
      if (enabled && pending) unawaited(syncNow());
      return;
    }

    if (!was) {
      // 刚醒过来：别拿睡着时的陈旧计数继续压着节奏。
      _unchanged = 0;
      _catchUpUntilMs = 0;
    }
    if (!enabled) return;

    final int now = DateTime.now().millisecondsSinceEpoch;
    if (_lastResumeMs != 0 && now - _lastResumeMs < resumeThrottle.inMilliseconds) {
      // 节流命中也得把定时器救回来，不然切前台切成"永久静止"。
      if (_pollTimer == null) _schedule();
      return;
    }
    _lastResumeMs = now;
    unawaited(syncNow());
  }

  /// 立刻跑一轮（手动点"立即同步"也走这里）。
  ///
  /// [runner] 只给"确认删除"这条路用：它要跑的是 [SyncEngine.confirmBigDelete]
  /// 而不是普通的 [SyncEngine.runOnce]。走同一个入口是为了复用 `_running` 挡板、
  /// 降频计数和通知，不然那条路能绕开调度层、和轮询同时开两份。
  Future<SyncRunResult> syncNow({
    bool manual = false,
    Future<SyncRunResult> Function()? runner,
  }) async {
    if (_disposed) return SyncRunResult.disabled;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (!enabled) return SyncRunResult.disabled;
    // 已经有一轮在跑：直接把它的结果给出去，不排队（排队会在弱网下越积越多）。
    if (busy) {
      // 上一轮的结果还是"未开启"（从没跑过）时别把它交出去 —— 用户手动点了
      // "立即同步"，回一句"未开启"会让他以为同步根本没生效。
      return _lastResult.status == SyncStatus.disabled
          ? const SyncRunResult(status: SyncStatus.running, message: '正在同步，稍等')
          : _lastResult;
    }

    _running = true;
    _notify(); // busy 已经变 true，界面换成转圈

    SyncRunResult result;
    try {
      result = await (runner ?? _run)();
    } catch (e) {
      // runOnce 内部已经把网络错误翻成状态了，走到这里说明是意料之外的异常
      // （比如合并结果写回配置时炸了）。绝不能让它冒出去变成未捕获异常。
      result = SyncRunResult(status: SyncStatus.error, message: '同步失败：$e');
    } finally {
      _running = false;
    }
    _lastResult = result;
    if (_disposed) return result;

    _lastRunMs = DateTime.now().millisecondsSinceEpoch;
    if (result.awaitingConfirm) {
      // 等用户点头。这一轮该做的事已经做完了（护栏拦住了），再快也没用 ——
      // 直接放到最慢节奏，别让它在用户还在犹豫的时候每分钟拉一遍整份文档。
      _unchanged = slowAfterUnchanged ?? _pacing.backoff.length;
      _catchUpUntilMs = 0;
    } else if (result.ok && !result.pushed && !result.pulled) {
      _unchanged++;
    } else {
      // 有推送 / 有拉取 / 出错：都回到快节奏，出错要尽快重试，有变化说明对面活着
      _unchanged = 0;
      // 刚换过数据 = 对面可能还在动（比如另一台设备在连着改），
      // 这两个分钟里保持最快档，别一头扎进 10 分钟。
      if (result.ok) {
        _catchUpUntilMs = _lastRunMs + _pacing.catchUpWindow.inMilliseconds;
      }
    }
    if (manual) {
      _unchanged = 0;
      _catchUpUntilMs = _lastRunMs + _pacing.catchUpWindow.inMilliseconds;
    }

    _notify();
    _schedule();
    return result;
  }

  /// 用户点了"确认删除"：放行这一轮的大面积删除护栏。
  ///
  /// 放行**只对这一次调用有效**，引擎那一侧在 `runOnce` 的 finally 里就把标记
  /// 清掉了。所以用户要是再改主意，下一轮轮询照样会被拦下来。
  Future<SyncRunResult> confirmBigDelete() {
    return syncNow(manual: true, runner: engine.confirmBigDelete);
  }

  /// 云端历史版本清单（新的在前）。
  Future<List<SyncHistoryEntry>> history() => engine.history();

  /// 把第 [version] 版恢复成当前版本。恢复完记得再跑一轮把它拉下来。
  Future<SyncPutResult> restoreHistory(int version) => engine.restoreHistory(version);

  /// 手动同步后把节奏重置回快的。
  void resetSchedule() {
    _unchanged = 0;
    _catchUpUntilMs = 0;
    _schedule();
  }

  /// 换档位（设置页那个四选一）。
  ///
  /// 不重建 [SyncService]：引擎、凭证、重试挡板全在，换的只是"等多久"。
  /// 重建会把正在跑的那一轮和 `_running` 挡板一起扔掉，弱网下可能叠出两轮。
  void setPacing(SyncPacing pacing) {
    _pacing = pacing;
    _unchanged = 0;
    _catchUpUntilMs = 0;
    if (_disposed) return;
    _schedule();
    _notify();
  }

  /// 当前档位（给界面显示"下次大约 X 分钟后"之类）。
  SyncPacing get pacing => _pacing;

  /// 下一次自动化请求大概在多久之后。null = 不会自己跑（仅手动档 / 后台）。
  Duration? get nextPollIn {
    if (_disposed || !enabled || !_foreground) return null;
    final int? legacy = slowAfterUnchanged;
    if (legacy != null) return _unchanged >= legacy ? pollSlow : pollFast;
    if (!_pacing.autoPoll) return null;
    final bool catchingUp = _catchUpUntilMs > 0 &&
        DateTime.now().millisecondsSinceEpoch < _catchUpUntilMs;
    final Duration d = catchingUp ? _pacing.fastest : _pacing.delayFor(_unchanged);
    return d <= Duration.zero ? null : d;
  }

  void _schedule() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_disposed || !enabled) return;
    // 不可见 = 一律不排。这一条在所有档位之上，包括 realtime。
    if (!_foreground) return;

    // 老的两档模式（单测显式传 slowAfterUnchanged，行为一点不变）。
    final int? legacy = slowAfterUnchanged;
    if (legacy != null) {
      final Duration next = _unchanged >= legacy ? pollSlow : pollFast;
      if (next <= Duration.zero) return;
      _pollTimer = Timer(next, () => unawaited(syncNow()));
      return;
    }

    if (!_pacing.autoPoll) return; // 仅手动档

    final bool catchingUp = _catchUpUntilMs > 0 &&
        DateTime.now().millisecondsSinceEpoch < _catchUpUntilMs;
    final Duration next = catchingUp ? _pacing.fastest : _pacing.delayFor(_unchanged);
    if (next <= Duration.zero) return;
    _pollTimer = Timer(next, () => unawaited(syncNow()));
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _debounceTimer = null;
    _pollTimer = null;
    _catchUpUntilMs = 0;
  }

  void _notify() {
    if (_disposed) return;
    onChanged?.call();
  }
}
