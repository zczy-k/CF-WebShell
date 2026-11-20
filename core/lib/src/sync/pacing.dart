/// 同步节奏档位 —— 「多久问一次对方有没有变」。
///
/// 为什么要有这个东西：同步的下行（别的设备改了什么）没法靠本地事件触发，
/// 只能去问服务端。问得太勤 = 后台频繁唤醒射频，耗电、还会被 Android 记进
/// 高耗电名单；问得太稀 = 多设备同步像坏了。折中办法就是**退避阶梯**：
/// 越久没动静问得越少，一旦有变化立刻回到最快档。
///
/// 这套逻辑纯粹是参数表，和网络无关，所以放在 core 里 —— `dart test` 秒级跑完，
/// 不用起真机、不用联网。
///
/// 四个档位对应设置页那个下拉：
/// * [balanced] 默认。活跃 60 秒，闲置逐级退到 10 分钟。
/// * [saver] 省电。退到 30 分钟，适合"这台设备只是挂着"。
/// * [realtime] 实时。永远 60 秒，多设备写法，费一点。
/// * [manual] 仅手动。完全不自轮询 —— 只在你点同步、回到前台、或本地有改动时跑。
///
/// 一天挂 8 小时大概要发多少次请求（前台一直在，最坏情况也不退避）：
///
/// | 档位 | 8 小时请求数 | 占免费额度（10 万/天） |
/// |---|---|---|
/// | 活跃 60 秒 | 480 | 0.5% |
/// | 退到 10 分钟 | 约 60 | 0.06% |
/// | 退到 30 分钟 | 约 26 | 0.03% |
///
/// 后台是 0 —— 那才是真正省下来的部分（见 `SyncService.setForeground`）。
///
/// **后台一律不轮询，四档都一样。** 那是 [SyncPacing] 管不到的事，
/// 由 `SyncService.setForeground` 负责。
library;

/// 同步频率档位（持久化在 `starport.json` 的 `syncProfile` 字段里）。
enum SyncProfile {
  balanced,
  saver,
  realtime,
  manual;

  /// 存进配置用的字符串键。用 `name` 而不是 index —— 以后插入新档位
  /// 不会把老配置里的档位解释错（index 会整体错位）。
  String get key => name;

  /// 从配置里读回来。认不出来就用默认档，绝不因为一个字段把同步关掉。
  static SyncProfile fromKey(Object? raw) {
    final String s = raw is String ? raw.trim() : '';
    for (final SyncProfile p in SyncProfile.values) {
      if (p.name == s) return p;
    }
    return SyncProfile.balanced;
  }
}

/// 一个档位对应的具体节奏参数。
class SyncPacing {
  const SyncPacing({
    required this.backoff,
    required this.catchUpWindow,
    required this.autoPoll,
  });

  /// 连续"双方都没动"第 n 轮时，下一次等多久。越界取最后一档（封顶）。
  final List<Duration> backoff;

  /// 有推送 / 拉取成功之后，这段时间内不再升档。
  ///
  /// 多设备来回改的时候，如果刚推完就跳回 10 分钟，第二台设备的改动要等
  /// 很久才被看见。给一个"追赶窗"：变化刚发生过，说明对面可能还在动。
  final Duration catchUpWindow;

  /// 是否自动轮询。false = 仅手动档（只有本地改动 / 回前台 / 点同步才跑）。
  final bool autoPoll;

  /// 连续 [unchanged] 轮没变化之后该等多久。空表 / 关掉轮询时返回
  /// [Duration.zero]（调用方据此判断"不排定时器"）。
  Duration delayFor(int unchanged) {
    if (!autoPoll || backoff.isEmpty) return Duration.zero;
    final int i = unchanged < 0 ? 0 : (unchanged >= backoff.length ? backoff.length - 1 : unchanged);
    return backoff[i];
  }

  /// 最快一档（追赶窗里用它）。
  Duration get fastest => backoff.isEmpty ? Duration.zero : backoff.first;

  static const SyncPacing balanced = SyncPacing(
    // 60, 60, 120, 120, 120, 300, 300, 300, 300, 600…
    // 前两轮保持 60 秒（刚打开时手感最重要），之后每级放缓，
    // 10 分钟封顶 —— 再长用户就会觉得"同步是不是坏了"。
    backoff: <Duration>[
      Duration(seconds: 60),
      Duration(seconds: 60),
      Duration(seconds: 120),
      Duration(seconds: 120),
      Duration(seconds: 120),
      Duration(seconds: 300),
      Duration(seconds: 300),
      Duration(seconds: 300),
      Duration(seconds: 300),
      Duration(seconds: 600),
    ],
    catchUpWindow: Duration(minutes: 2),
    autoPoll: true,
  );

  static const SyncPacing saver = SyncPacing(
    backoff: <Duration>[
      Duration(seconds: 60),
      Duration(seconds: 120),
      Duration(seconds: 300),
      Duration(seconds: 600),
      Duration(seconds: 900),
      Duration(seconds: 1800),
    ],
    catchUpWindow: Duration(minutes: 2),
    autoPoll: true,
  );

  static const SyncPacing realtime = SyncPacing(
    backoff: <Duration>[Duration(seconds: 60)],
    catchUpWindow: Duration(minutes: 2),
    autoPoll: true,
  );

  /// 仅手动：不排任何自动轮询。
  ///
  /// **这是功能降级，不是优化。** 选了它，别的设备改了你这台不会知道，
  /// 除非你点「立即同步」、或把 App 切回前台、或本地自己改了东西。
  /// 所以它不是默认档 —— 数据分叉的修复成本远高于那点流量。
  static const SyncPacing manual = SyncPacing(
    backoff: <Duration>[],
    catchUpWindow: Duration.zero,
    autoPoll: false,
  );

  static SyncPacing of(SyncProfile p) {
    switch (p) {
      case SyncProfile.balanced:
        return balanced;
      case SyncProfile.saver:
        return saver;
      case SyncProfile.realtime:
        return realtime;
      case SyncProfile.manual:
        return manual;
    }
  }
}
