import 'package:apexduanju/player/sleep_timer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_clock.dart';

/// 定时关闭的计时逻辑与本集播完后的去向判定。
///
/// [SleepTimer] 的时间来自注入的 `now`，这里用 [FakeClock] 手动推进；
/// 周期 tick 是真实的 `Timer`，借 flutter_test 的假时钟驱动——testWidgets
/// 环境里 `tester.pump(时长)` 会推进 FakeAsync 并触发这段时间内到期的定时器。
void main() {
  late FakeClock clock;
  late int fired;

  setUp(() {
    clock = FakeClock();
    fired = 0;
  });

  SleepTimer create() => SleepTimer(now: clock.now, onElapsed: () => fired++);

  /// 墙钟与假时钟同步推进，并触发这段时间内到期的 tick。
  Future<void> elapse(WidgetTester tester, Duration by) async {
    clock.advance(by);
    await tester.pump(by);
  }

  /// 墙钟只走 [by]，期间恰好触发一次 tick：用来制造 tick 与墙钟不同步
  /// （应用在后台时定时器会被推迟）。
  Future<void> tickAfter(WidgetTester tester, Duration by) async {
    clock.advance(by);
    await tester.pump(SleepTimer.tickInterval);
  }

  testWidgets(
    'countdown remaining follows the wall clock, not the tick count',
    (WidgetTester tester) async {
      final SleepTimer timer = create();
      timer.startCountdown(const Duration(minutes: 15));
      expect(timer.state.value?.remaining, const Duration(minutes: 15));

      // 墙钟走了 100 秒，但只触发了 90 次 tick：剩余时间仍必须按真实时间算。
      clock.advance(const Duration(seconds: 100));
      await tester.pump(const Duration(seconds: 90));

      expect(
        timer.state.value?.remaining,
        const Duration(minutes: 13, seconds: 20),
      );
      expect(timer.state.value?.total, const Duration(minutes: 15));
      timer.dispose();
    },
  );

  testWidgets(
    'countdown fires exactly once when a tick finds the deadline passed',
    (WidgetTester tester) async {
      final SleepTimer timer = create();
      timer.startCountdown(const Duration(minutes: 15));
      await elapse(tester, const Duration(minutes: 14, seconds: 59));
      expect(fired, 0);

      // 到点那一刻没有 tick：下一次 tick 一到就必须按墙钟判定到点。
      await tickAfter(tester, const Duration(seconds: 4));
      expect(fired, 1);
      expect(timer.state.value, isNull);

      // 之后 tick 再多也不会重复回调。
      await elapse(tester, const Duration(minutes: 5));
      expect(fired, 1);
      timer.dispose();
    },
  );

  testWidgets('cancel disarms the countdown', (WidgetTester tester) async {
    final SleepTimer timer = create();
    timer.startCountdown(const Duration(minutes: 15));
    timer.cancel();
    expect(timer.state.value, isNull);

    await elapse(tester, const Duration(minutes: 16));
    expect(fired, 0);
    timer.dispose();
  });

  testWidgets('restarting a countdown replaces the previous deadline', (
    WidgetTester tester,
  ) async {
    final SleepTimer timer = create();
    timer.startCountdown(const Duration(minutes: 15));
    await elapse(tester, const Duration(minutes: 10));

    timer.startCountdown(const Duration(minutes: 30));
    expect(timer.state.value?.remaining, const Duration(minutes: 30));

    // 原来的 15 分钟到点不能触发，新的 30 分钟到点才触发。
    await elapse(tester, const Duration(minutes: 5, seconds: 1));
    expect(fired, 0);
    await elapse(tester, const Duration(minutes: 24, seconds: 58));
    expect(fired, 0);
    await elapse(tester, const Duration(seconds: 1));
    expect(fired, 1);
    timer.dispose();
  });

  testWidgets('remaining time rounds up so the label never shows 00:00 early', (
    WidgetTester tester,
  ) async {
    final SleepTimer timer = create();
    timer.startCountdown(const Duration(minutes: 15));

    // 刚过 0.5 秒：剩 14:59.5，入口应继续显示 15:00 而不是跳成 14:59。
    await tickAfter(tester, const Duration(milliseconds: 500));
    expect(timer.state.value?.remaining, const Duration(minutes: 15));

    // 只剩 0.5 秒：显示 00:01，而不是提前显示 00:00。
    await tickAfter(tester, const Duration(minutes: 14, seconds: 59));
    expect(timer.state.value?.remaining, const Duration(seconds: 1));
    expect(fired, 0);

    await tickAfter(tester, const Duration(milliseconds: 500));
    expect(fired, 1);
    timer.dispose();
  });

  testWidgets('a sliver under one second still counts as 00:01', (
    WidgetTester tester,
  ) async {
    final SleepTimer timer = create();
    timer.startCountdown(const Duration(minutes: 15));

    // tick 落在截止前最后 1ms 之内：按毫秒截断会算成 0，提前显示 00:00。
    await tickAfter(
      tester,
      const Duration(
        minutes: 14,
        seconds: 59,
        milliseconds: 999,
        microseconds: 500,
      ),
    );
    expect(timer.state.value?.remaining, const Duration(seconds: 1));
    expect(fired, 0);
    timer.dispose();
  });

  testWidgets('the same displayed second does not notify listeners again', (
    WidgetTester tester,
  ) async {
    final SleepTimer timer = create();
    int notifications = 0;
    timer.state.addListener(() => notifications++);

    timer.startCountdown(const Duration(minutes: 15));
    expect(notifications, 1);

    // 两次 tick 后仍停在 15:00：入口不该为同一个秒数重建两次。
    await tickAfter(tester, const Duration(milliseconds: 400));
    await tickAfter(tester, const Duration(milliseconds: 400));
    expect(timer.state.value?.remaining, const Duration(minutes: 15));
    expect(notifications, 1);

    // 第三次 tick 跨过整秒边界才通知。
    await tickAfter(tester, const Duration(milliseconds: 400));
    expect(
      timer.state.value?.remaining,
      const Duration(minutes: 14, seconds: 59),
    );
    expect(notifications, 2);
    timer.dispose();
  });

  testWidgets(
    'episode-end mode never fires on time and flags the episode end',
    (WidgetTester tester) async {
      final SleepTimer timer = create();
      timer.armUntilEpisodeEnd();

      expect(timer.stopsAtEpisodeEnd, isTrue);
      expect(timer.state.value?.mode, SleepTimerMode.episodeEnd);

      await elapse(tester, const Duration(hours: 3));
      expect(fired, 0);
      expect(timer.stopsAtEpisodeEnd, isTrue);

      timer.cancel();
      expect(timer.stopsAtEpisodeEnd, isFalse);
      expect(timer.state.value, isNull);
      timer.dispose();
    },
  );

  testWidgets('switching between modes keeps only the latest one armed', (
    WidgetTester tester,
  ) async {
    final SleepTimer timer = create();
    timer.startCountdown(const Duration(minutes: 15));
    await elapse(tester, const Duration(minutes: 1));

    // 改成「播完本集」后，原来的倒计时不该再把播放关掉。
    timer.armUntilEpisodeEnd();
    await elapse(tester, const Duration(minutes: 20));
    expect(fired, 0);
    expect(timer.stopsAtEpisodeEnd, isTrue);

    // 再改回倒计时，「播完本集」随之失效。
    timer.startCountdown(const Duration(minutes: 30));
    expect(timer.stopsAtEpisodeEnd, isFalse);
    await elapse(tester, const Duration(minutes: 29, seconds: 59));
    expect(fired, 0);
    await elapse(tester, const Duration(seconds: 1));
    expect(fired, 1);
    timer.dispose();
  });

  testWidgets('dispose stops the ticker and the elapsed callback', (
    WidgetTester tester,
  ) async {
    final SleepTimer timer = create();
    timer.startCountdown(const Duration(minutes: 15));
    timer.dispose();

    await elapse(tester, const Duration(minutes: 16));
    expect(fired, 0);
  });

  testWidgets('a non-positive duration fires immediately', (
    WidgetTester tester,
  ) async {
    final SleepTimer timer = create();
    timer.startCountdown(Duration.zero);
    expect(fired, 1);
    expect(timer.state.value, isNull);

    await elapse(tester, const Duration(minutes: 30));
    expect(fired, 1);
    timer.dispose();
  });

  test('episode end action prefers the sleep timer over auto play', () {
    expect(
      episodeEndAction(autoPlay: true, sleepTimerStopsAtEpisodeEnd: true),
      EpisodeEndAction.closeForSleepTimer,
    );
    expect(
      episodeEndAction(autoPlay: false, sleepTimerStopsAtEpisodeEnd: true),
      EpisodeEndAction.closeForSleepTimer,
    );
    expect(
      episodeEndAction(autoPlay: true, sleepTimerStopsAtEpisodeEnd: false),
      EpisodeEndAction.advance,
    );
    expect(
      episodeEndAction(autoPlay: false, sleepTimerStopsAtEpisodeEnd: false),
      EpisodeEndAction.none,
    );
  });
}
