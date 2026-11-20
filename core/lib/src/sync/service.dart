/// 同步的**调度层**：决定"什么时候跑一轮"。
///
/// 合并逻辑在 [SyncEngine]，这里只管节奏：
///
/// ```
/// 用户改了一个站点      → 8 秒防抖（连着改五次只跑一轮）
/// 启动                 → 3 秒后拉一次（等首帧画完，别拖慢开机）
/// 从后台回前台         → 30 秒节流（切来切去不该狂发请求）
/// 平时                 → 60 秒问一次版本号；连续 10 次没变化就放慢到 180 秒
/// ```
///
/// 为什么平时要轮询而不是长连接：Cloudflare Worker 免费额度按**请求数**算，
/// WebSocket 会一直占着连接、还要额外算时长，而轮询一次 `HEAD` 只有几十字节。
/// 60 秒的延迟用户完全感知不到（需求里明确说了"可以有抖动延迟"）。
///
/// 为什么"没变化就放慢"：一台设备一天挂着 8 小时 = 480 次请求（60 秒）或
/// 160 次（180 秒）。免费额度 10 万次/天，看着够用，但用户不止一台设备、
/// 还可能同时开着几个壳 —— 能省就省，反正"没变化"时快慢都一样没变化。
///
/// **为什么放在 core 而不是 App 层**：这一整个类只有 `dart:async` 一个依赖，
/// 计时器 + 计数器是纯逻辑。放进 App 层就得靠 `flutter_test` 才能跑（起一个
/// 假的 `WidgetsBinding`、还要处理 `Timer` 和测试时钟的对账），而它恰恰是最
/// 容易写错的那部分（防抖漏掉、降频降不回来、dispose 后还在发请求）。
/// 放在这里，CI 上一次 `dart test` 就把这些边界全跑一遍。
library;

import 'dart:async';

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
    this.slowAfterUnchanged = 10,
    Future<SyncRunResult> Function()? runner,
  }) : _run = runner ?? engine.runOnce;

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

  /// 连续几轮"双方都没动"之后开始放慢轮询。
  final int slowAfterUnchanged;

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

  /// 启动。默认等 3 秒再跑：首帧还没画出来就去连网，换来的只是启动变慢。
  ///
  /// 没配置同步时**不**记 `_started` 标记 —— 用户完全可能在这次运行中途才去
  /// 配对，那时候再调 [start] 还得管用。
  void start({Duration delay = const Duration(seconds: 3)}) {
    if (_disposed || _started || !enabled) return;
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
  void onResume() {
    if (_disposed || !enabled) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (_lastResumeMs != 0 && now - _lastResumeMs < resumeThrottle.inMilliseconds) {
      return;
    }
    _lastResumeMs = now;
    unawaited(syncNow());
  }

  /// 立刻跑一轮（手动点"立即同步"也走这里）。
  Future<SyncRunResult> syncNow({bool manual = false}) async {
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
      result = await _run();
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
    if (result.ok && !result.pushed && !result.pulled) {
      _unchanged++;
    } else {
      // 有推送 / 有拉取 / 出错：都回到快节奏，出错要尽快重试，有变化说明对面活着
      _unchanged = 0;
    }
    if (manual) _unchanged = 0;

    _notify();
    _schedule();
    return result;
  }

  /// 手动同步后把节奏重置回快的。
  void resetSchedule() {
    _unchanged = 0;
    _schedule();
  }

  void _schedule() {
    _pollTimer?.cancel();
    if (_disposed || !enabled) return;
    final Duration next = _unchanged >= slowAfterUnchanged ? pollSlow : pollFast;
    _pollTimer = Timer(next, () => unawaited(syncNow()));
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _debounceTimer = null;
    _pollTimer = null;
  }

  void _notify() {
    if (_disposed) return;
    onChanged?.call();
  }
}
