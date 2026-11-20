/// 同步**节奏**（[SyncPacing] / [SyncProfile]）与**前后台**调度的单测。
///
/// 这一组测的是「省电方案」的三根承重柱，任何一根断了都会在真机上以
/// 「耗电」「同步像坏了」「改完切走就丢了」的形式暴露，但在 CI 里全是零成本：
///
/// 1. **退避阶梯**：一直没变化的时候，间隔必须逐级变长，而且要封顶。
/// 2. **追赶窗**：刚刚换过数据，间隔不许立刻跳回最慢档 —— 对面可能还在改。
/// 3. **后台静默**：不管哪个档位，`setForeground(false)` 之后一个请求都不许发；
///    但手上如果有没推上去的改动，必须趁切走的那一刻补推最后一轮。
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:starport_core/starport_core.dart';

ShellConfig _configuredConfig() => ShellConfig(
      syncEnabled: true,
      syncEndpoint: 'https://sync.example.com',
      syncSpaceId: 'space-1',
    );

SyncEngine _engineFor(ShellConfig config, Directory dir, {SyncLocalState? state}) =>
    SyncEngine(
      config: config,
      stateFile: SyncStateFile(File('${dir.path}/starport.sync.json')),
      credentials: MemorySyncCredentialStore(),
      state: state ?? SyncLocalState(),
    );

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ws-sync-pacing-');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  SyncService make({
    required SyncPacing pacing,
    required Future<SyncRunResult> Function() runner,
    SyncLocalState? state,
    Duration debounce = const Duration(milliseconds: 20),
    Duration resumeThrottle = Duration.zero,
  }) {
    final SyncService svc = SyncService(
      engine: _engineFor(_configuredConfig(), dir, state: state),
      pacing: pacing,
      debounce: debounce,
      resumeThrottle: resumeThrottle,
      runner: runner,
    );
    addTearDown(svc.dispose);
    return svc;
  }

  const SyncRunResult quiet = SyncRunResult(status: SyncStatus.ok);
  const SyncRunResult pushed =
      SyncRunResult(status: SyncStatus.ok, pushed: true);

  group('SyncProfile', () {
    test('存进去再读回来是同一个档位', () {
      for (final SyncProfile p in SyncProfile.values) {
        expect(SyncProfile.fromKey(p.key), p);
      }
    });

    test('配置里是垃圾值 / null / 数字都退回默认档，绝不把同步关掉', () {
      expect(SyncProfile.fromKey(null), SyncProfile.balanced);
      expect(SyncProfile.fromKey(''), SyncProfile.balanced);
      expect(SyncProfile.fromKey('turbo'), SyncProfile.balanced);
      expect(SyncProfile.fromKey(3), SyncProfile.balanced);
      expect(SyncProfile.fromKey('  saver  '), SyncProfile.saver);
    });
  });

  group('SyncPacing', () {
    test('阶梯越走越长，到顶就不再涨（封顶）', () {
      const SyncPacing p = SyncPacing.balanced;
      final List<Duration> first = <Duration>[
        for (int i = 0; i < p.backoff.length; i++) p.delayFor(i),
      ];
      // 单调不减
      for (int i = 1; i < first.length; i++) {
        expect(first[i] >= first[i - 1], isTrue,
            reason: '第 $i 档比上一档还快：${first[i]} < ${first[i - 1]}');
      }
      // 越界（模拟挂了一整天，unchanged 已经涨到几百）取最后一档
      expect(p.delayFor(999), p.backoff.last);
      expect(p.delayFor(-5), p.backoff.first);
    });

    test('三档的实际数值符合「活跃快、闲置慢」的承诺', () {
      expect(SyncPacing.balanced.delayFor(0), const Duration(seconds: 60));
      expect(SyncPacing.balanced.delayFor(999), const Duration(minutes: 10));
      expect(SyncPacing.saver.delayFor(0), const Duration(seconds: 60));
      expect(SyncPacing.saver.delayFor(999), const Duration(minutes: 30));
      expect(SyncPacing.realtime.delayFor(999), const Duration(seconds: 60));
    });

    test('仅手动档：永远返回零（调用方据此不排定时器）', () {
      expect(SyncPacing.manual.autoPoll, isFalse);
      expect(SyncPacing.manual.delayFor(0), Duration.zero);
      expect(SyncPacing.manual.delayFor(999), Duration.zero);
      expect(SyncPacing.manual.fastest, Duration.zero);
    });

    test('SyncPacing.of 把四个档位对上号', () {
      expect(SyncPacing.of(SyncProfile.manual), same(SyncPacing.manual));
      expect(SyncPacing.of(SyncProfile.saver), same(SyncPacing.saver));
      expect(SyncPacing.of(SyncProfile.realtime), same(SyncPacing.realtime));
      expect(SyncPacing.of(SyncProfile.balanced), same(SyncPacing.balanced));
    });
  });

  group('退避阶梯真的生效', () {
    test('一直没变化 → 间隔按阶梯变长', () async {
      int runs = 0;
      final SyncService svc = make(
        // 同长度但把量级压到毫秒：20, 20, 300
        pacing: const SyncPacing(
          backoff: <Duration>[
            Duration(milliseconds: 20),
            Duration(milliseconds: 20),
            Duration(milliseconds: 300),
          ],
          catchUpWindow: Duration.zero,
          autoPoll: true,
        ),
        runner: () async {
          runs++;
          return quiet;
        },
      );

      svc.start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // 跑完第 2 轮后 unchanged=2 → 下一档 300ms，所以这 150ms 里只有 2 轮
      expect(runs, 2, reason: '升档没生效，还是按最快档在刷');

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(runs, 3, reason: '最慢那一档到点后没跑');
    });

    test('有推送就清零，回到最快档', () async {
      int runs = 0;
      final SyncService svc = make(
        pacing: const SyncPacing(
          backoff: <Duration>[
            Duration(milliseconds: 20),
            Duration(milliseconds: 20),
            Duration(seconds: 30),
          ],
          catchUpWindow: Duration.zero,
          autoPoll: true,
        ),
        runner: () async {
          runs++;
          // 第一轮没动（unchanged=1），之后每轮都有推送 → 永远回到最快档
          return runs == 1 ? quiet : pushed;
        },
      );

      svc.start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(runs >= 3, isTrue,
          reason: '推送之后没回到快节奏，只跑了 $runs 轮');
      expect(svc.unchangedPolls, 0);
    });

    test('追赶窗里不升档（对面可能还在改）', () async {
      int runs = 0;
      final SyncService svc = make(
        pacing: const SyncPacing(
          backoff: <Duration>[
            Duration(milliseconds: 20),
            Duration(seconds: 30), // 一旦升档就是 30 秒，感知极明显
          ],
          catchUpWindow: Duration(seconds: 30),
          autoPoll: true,
        ),
        runner: () async {
          runs++;
          // 只有第一轮有推送，之后都没变化 —— 正常情况第 2 轮就该升到 30 秒
          return runs == 1 ? pushed : quiet;
        },
      );

      svc.start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(runs >= 4, isTrue,
          reason: '追赶窗没管住升档，刚推完就一头扎进慢档（只跑了 $runs 轮）');
    });
  });

  group('后台静默', () {
    test('切到后台：定时器全停，一个请求都不发', () async {
      int runs = 0;
      final SyncService svc = make(
        pacing: SyncPacing.realtime,
        runner: () async {
          runs++;
          return quiet;
        },
      );

      svc.start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final int before = runs;
      expect(before >= 1, isTrue);

      svc.setForeground(false);
      expect(svc.foreground, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(runs, before, reason: '后台还在轮询，这就是托盘里那一分钟一次的耗电');
    });

    test('回前台：立刻补一轮，并把退避计数清零', () async {
      int runs = 0;
      final SyncService svc = make(
        pacing: SyncPacing.realtime,
        resumeThrottle: Duration.zero,
        runner: () async {
          runs++;
          return quiet;
        },
      );

      svc.setForeground(false);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(runs, 0, reason: '不可见时不该有请求');

      svc.setForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(runs, 1, reason: '回到前台没有立刻补一轮');
      // 那一轮本身没变化，所以计数是 1 —— 关键是不能带着后台之前的旧计数。
      expect(svc.unchangedPolls <= 1, isTrue);
    });

    test('后台一次性推送：切走时手上有未推的改动，补推一轮然后闭嘴', () async {
      int runs = 0;
      final SyncLocalState dirty = SyncLocalState(
        base: SyncDoc(spaceId: 'space-1'),
        local: SyncDoc(
          spaceId: 'space-1',
          sites: <String, SyncSite>{
            'https://a.example': SyncSite(key: 'https://a.example', startUrl: 'https://a.example'),
          },
        ),
      );
      final SyncService svc = make(
        state: dirty,
        pacing: SyncPacing.realtime,
        runner: () async {
          runs++;
          return pushed;
        },
      );

      expect(svc.pending, isTrue, reason: '构造的脏状态没被识别出来');
      svc.setForeground(false);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(runs, 1, reason: '「改完就切走」的那次修改没被推上去');
      expect(svc.pending, isTrue, reason: 'runner 是替身，文档不该真的变干净');

      // 推完不许再排定时器
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(runs, 1, reason: '后台推完还在继续跑');
    });

    test('干净的切到后台：连那一轮都不发', () async {
      int runs = 0;
      final SyncService svc = make(
        pacing: SyncPacing.realtime,
        runner: () async {
          runs++;
          return quiet;
        },
      );

      svc.setForeground(false);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(runs, 0);
    });

    test('一开始就不可见（开机自启直接进托盘）：start 不排任何东西', () async {
      int runs = 0;
      final SyncService svc = make(
        pacing: SyncPacing.realtime,
        runner: () async {
          runs++;
          return quiet;
        },
      );

      svc.setForeground(false);
      svc.start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(runs, 0);
    });
  });

  group('仅手动档', () {
    test('跑完一轮之后不再自己排定时器', () async {
      int runs = 0;
      final SyncService svc = make(
        pacing: SyncPacing.manual,
        runner: () async {
          runs++;
          return quiet;
        },
      );

      svc.start(delay: Duration.zero);
      await svc.syncNow(manual: true);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(runs, 1, reason: '仅手动档还在自轮询');
    });

    test('本地改了东西照样防抖一轮（事件驱动不靠轮询）', () async {
      int runs = 0;
      final SyncService svc = make(
        pacing: SyncPacing.manual,
        runner: () async {
          runs++;
          return pushed;
        },
      );

      svc.markDirty();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(runs, 1);
    });
  });
}
