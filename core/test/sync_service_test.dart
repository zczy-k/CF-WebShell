/// 同步**调度层**（[SyncService]）的单测。
///
/// 这里测的全是"什么时候该发请求"，一条网络调用都不发 —— 用 `runner` 替身
/// 把真引擎换掉。这些边界恰恰是最容易写错、又最不容易在真机上发现的：
///
/// * 用户连着改五次，是不是只推了一轮（防抖漏掉 = 五次请求烧额度）
/// * 一直没变化，有没有真的放慢（降频降不回来 = 挂一天就吃掉几百次请求）
/// * 一旦有变化，是不是立刻回到快节奏（回不来 = 改了十分钟对面才看到）
/// * dispose 之后定时器还在不在跑（还在跑 = 退出时抛 use-after-dispose）
/// * run 抛异常，会不会冒出未捕获异常（冒出 = 整轮同步静默失效）
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:starport_core/starport_core.dart';

/// 一个已经配好同步的配置（`syncConfigured` 为真才会真干活）。
ShellConfig configuredConfig() => ShellConfig(
      syncEnabled: true,
      syncEndpoint: 'https://sync.example.com',
      syncSpaceId: 'space-1',
    );

/// 建一个指向临时目录的引擎 —— 它自己不会被调用（runner 被换掉了），
/// 但 `SyncService` 的构造签名要它。
SyncEngine engineFor(ShellConfig config, Directory dir) => SyncEngine(
      config: config,
      stateFile: SyncStateFile(File('${dir.path}/starport.sync.json')),
      credentials: MemorySyncCredentialStore(),
      state: SyncLocalState(),
    );

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ws-sync-svc-');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 造一个调度器，并把定时器的量级压到毫秒级。
  SyncService make({
    bool enabled = true,
    Duration debounce = const Duration(milliseconds: 30),
    Duration pollFast = const Duration(seconds: 10),
    Duration pollSlow = const Duration(seconds: 30),
    Duration resumeThrottle = const Duration(seconds: 30),
    int slowAfterUnchanged = 10,
    required Future<SyncRunResult> Function() runner,
  }) {
    final ShellConfig config = enabled
        ? configuredConfig()
        : ShellConfig();
    final SyncService svc = SyncService(
      engine: engineFor(config, dir),
      debounce: debounce,
      pollFast: pollFast,
      pollSlow: pollSlow,
      resumeThrottle: resumeThrottle,
      slowAfterUnchanged: slowAfterUnchanged,
      runner: runner,
    );
    addTearDown(svc.dispose);
    return svc;
  }

  SyncRunResult quiet() => const SyncRunResult(status: SyncStatus.ok);

  group('没配置同步', () {
    test('懒着不动：start 不排定时器，syncNow 直接回「未开启」', () async {
      int runs = 0;
      final SyncService svc = make(
        enabled: false,
        runner: () async {
          runs++;
          return quiet();
        },
      );

      expect(svc.enabled, isFalse);
      svc.start(delay: Duration.zero);
      final SyncRunResult r = await svc.syncNow();

      expect(r.status, SyncStatus.disabled);
      expect(runs, 0, reason: '没配置就不该发任何请求');
      expect(svc.pending, isFalse);
    });
  });

  group('防抖', () {
    test('连着改 5 次只跑一轮', () async {
      int runs = 0;
      final SyncService svc = make(
        debounce: const Duration(milliseconds: 40),
        runner: () async {
          runs++;
          return quiet();
        },
      );

      for (int i = 0; i < 5; i++) {
        svc.markDirty();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(runs, 0, reason: '防抖期内一次都不该发');

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(runs, 1, reason: '五次改动合成一轮');
    });

    test('markDirty 之后界面立刻能看到「待同步」，不用等 8 秒', () {
      final SyncService svc = make(runner: () async => quiet());

      expect(svc.pending, isFalse);
      svc.markDirty(); // 纯内存折进 local，不联网
      expect(svc.pending, isTrue);
    });
  });

  group('轮询节奏', () {
    test('连续没变化会放慢轮询', () async {
      int runs = 0;
      final SyncService svc = make(
        pollFast: const Duration(milliseconds: 20),
        pollSlow: const Duration(seconds: 5),
        slowAfterUnchanged: 3,
        runner: () async {
          runs++;
          return quiet(); // ok，且没 push / 没 pull
        },
      );

      svc.start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 160));

      expect(runs, 3, reason: '第 3 轮之后该切到慢节奏，不再 20ms 一次');
      expect(svc.unchangedPolls, 3);

      // 再等一段：慢节奏是 5 秒，这段时间里不该再跑。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(runs, 3);
    });

    test('有推送就回到快节奏', () async {
      int runs = 0;
      final SyncService svc = make(
        pollFast: const Duration(milliseconds: 20),
        pollSlow: const Duration(seconds: 5),
        slowAfterUnchanged: 2,
        runner: () async {
          runs++;
          return const SyncRunResult(status: SyncStatus.ok, pushed: true);
        },
      );

      svc.start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 160));

      expect(runs, greaterThanOrEqualTo(4), reason: '一直有变化就不该降频');
      expect(svc.unchangedPolls, 0);
    });

    test('出错也回到快节奏（要尽快重试）', () async {
      int runs = 0;
      final SyncService svc = make(
        pollFast: const Duration(milliseconds: 20),
        pollSlow: const Duration(seconds: 5),
        slowAfterUnchanged: 2,
        runner: () async {
          runs++;
          return const SyncRunResult(status: SyncStatus.offline, message: '连不上');
        },
      );

      svc.start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(runs, greaterThanOrEqualTo(4));
      expect(svc.unchangedPolls, 0);
    });

    test('手动同步把降频计数清零', () async {
      final SyncService svc = make(
        pollFast: const Duration(milliseconds: 20),
        pollSlow: const Duration(seconds: 5),
        slowAfterUnchanged: 2,
        runner: () async => quiet(),
      );

      svc.start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(svc.unchangedPolls, greaterThan(0));

      await svc.syncNow(manual: true);
      expect(svc.unchangedPolls, 0);
    });
  });

  group('回前台', () {
    test('30 秒内连点只跑一次', () async {
      int runs = 0;
      final SyncService svc = make(
        resumeThrottle: const Duration(seconds: 30),
        runner: () async {
          runs++;
          return quiet();
        },
      );

      svc.onResume();
      svc.onResume();
      svc.onResume();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(runs, 1);
    });

    test('过了节流窗口就会再跑', () async {
      int runs = 0;
      final SyncService svc = make(
        resumeThrottle: const Duration(milliseconds: 40),
        runner: () async {
          runs++;
          return quiet();
        },
      );

      svc.onResume();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(runs, 1);

      svc.onResume();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(runs, 2);
    });
  });

  group('健壮性', () {
    test('runner 抛异常 → 变成 error 状态，不冒出未捕获异常', () async {
      final SyncService svc = make(
        runner: () async => throw StateError('写配置时炸了'),
      );

      final SyncRunResult r = await svc.syncNow();
      expect(r.status, SyncStatus.error);
      expect(r.message, contains('同步失败'));
      expect(svc.status, SyncStatus.error);
    });

    test('dispose 之后定时器全停，再调也安全', () async {
      int runs = 0;
      final SyncService svc = SyncService(
        engine: engineFor(configuredConfig(), dir),
        debounce: const Duration(milliseconds: 20),
        pollFast: const Duration(milliseconds: 20),
        runner: () async {
          runs++;
          return quiet();
        },
      );

      svc.start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      final int before = runs;
      expect(before, greaterThan(0));

      svc.dispose();
      // 待着的防抖/轮询都要被掐掉，不然退出时会 use-after-dispose
      svc.markDirty();
      svc.onResume();
      final SyncRunResult r = await svc.syncNow();

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(runs, before, reason: 'dispose 之后一次都不该再跑');
      expect(r.status, SyncStatus.disabled);
    });

    test('上一轮还没跑完，再点不会有第二轮并上去', () async {
      int runs = 0;
      final Completer<void> gate = Completer<void>();
      final SyncService svc = make(
        runner: () async {
          runs++;
          await gate.future; // 卡住第一轮
          return quiet();
        },
      );

      final Future<SyncRunResult> first = svc.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(svc.busy, isTrue);

      final SyncRunResult second = await svc.syncNow(); // 不该排队
      expect(second.status, SyncStatus.running);
      expect(second.message, contains('正在同步'));
      expect(runs, 1);

      gate.complete();
      await first;
      expect(runs, 1);
    });
  });

  group('大面积删除待确认', () {
    SyncRunResult pending() => const SyncRunResult(
          status: SyncStatus.needsConfirm,
          message: '检测到一次大量删除（5 个站点），已暂停执行',
          pendingRemovals: 5,
        );

    test('拦下来的一轮把轮询放到最慢档（别在用户犹豫时狂拉整份文档）', () async {
      final SyncService svc = make(
        slowAfterUnchanged: 3,
        runner: () async => pending(),
      );

      final SyncRunResult r = await svc.syncNow();
      expect(r.awaitingConfirm, isTrue);
      expect(r.pendingRemovals, 5);
      expect(svc.unchangedPolls, 3, reason: '该做的事做完了，再快也是重复拉一遍');
    });

    test('确认删除走引擎那条路，不经过普通 runner', () async {
      int runnerCalls = 0;
      final SyncService svc = make(
        runner: () async {
          runnerCalls++;
          return quiet();
        },
      );

      final SyncRunResult r = await svc.confirmBigDelete();
      expect(
        runnerCalls,
        0,
        reason: '放行标记只在引擎的 confirmBigDelete 里立得起来，走普通 runner 等于没确认',
      );
      // engine 的凭证是空的 → 它自己那条路会如实报"还没配对"
      expect(r.status, SyncStatus.authFailed);
      expect(svc.busy, isFalse, reason: '确认完不能把 busy 挂在 true 上，界面会一直转圈');
    });

    test('确认一次之后，标记不留在引擎里（下一轮照样被拦）', () async {
      int runs = 0;
      final SyncService svc = make(
        runner: () async {
          runs++;
          return pending();
        },
      );

      await svc.confirmBigDelete();
      final SyncRunResult again = await svc.syncNow(manual: true);
      expect(again.awaitingConfirm, isTrue, reason: '确认只对一次有效，不能变成永久放行');
      expect(runs, 1, reason: '第二轮回到了普通 runner，说明放行标记没被带过去');
    });
  });
}
