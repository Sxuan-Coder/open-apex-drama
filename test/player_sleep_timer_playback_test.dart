import 'package:apexduanju/data/local/watch_store.dart';
import 'package:apexduanju/data/mock_data.dart';
import 'package:apexduanju/data/repository/mock_repositories.dart';
import 'package:apexduanju/player/player_environment.dart';
import 'package:apexduanju/player/sleep_timer.dart';
import 'package:apexduanju/providers/data_providers.dart';
import 'package:apexduanju/providers/watch_providers.dart';
import 'package:apexduanju/screens/player_screen.dart';
import 'package:apexduanju/screens/watch_feed_screen.dart';
import 'package:apexduanju/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_clock.dart';
import 'support/fake_platform_player.dart';

/// 用假的原生播放器驱动真实的播放页与「看剧」信息流，验证定时关闭在真实
/// 播放链路上的行为：到点先停播再退页、进度不被归零、「播完本集」不连播、
/// 以及从信息流进入时定时退出后信息流不恢复播放。
void main() {
  late FakeClock clock;
  late List<FakePlatformPlayer> created;
  late ProviderContainer container;

  setUp(() {
    clock = FakeClock();
    created = <FakePlatformPlayer>[];
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 每次需要播放器时造一个假的，按创建顺序记下来。
  PlayerEnvironment environment() {
    return PlayerEnvironment(
      now: clock.now,
      platformPlayerFactory: () {
        final FakePlatformPlayer player = FakePlatformPlayer();
        created.add(player);
        return player;
      },
    );
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    required Size size,
    required Widget home,
  }) async {
    container = ProviderContainer(
      overrides: [
        catalogRepositoryProvider.overrideWithValue(MockCatalogRepository()),
        playbackRepositoryProvider.overrideWithValue(MockPlaybackRepository()),
        rankRepositoryProvider.overrideWithValue(MockRankRepository()),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light, home: home),
      ),
    );
  }

  /// mock 仓库带人为延迟，开流前还要等一帧再等 350ms：推进足够的时间。
  Future<void> settle(WidgetTester tester, [int rounds = 10]) async {
    for (int i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();
  }

  /// 经真实入口打开播放页并等第一集开流完成，返回 `openPlayer` 的结果。
  ///
  /// 固定 1280x720：最短边 ≥ 600 走桌面布局，播完后直接切集，没有竖屏的
  /// 上滑动画与相邻集预取，链路最短。暂停后控制层常显，入口才点得到。
  Future<Future<bool>> openFullPlayer(WidgetTester tester) async {
    await pumpApp(tester, size: const Size(1280, 720), home: const _HostPage());
    final BuildContext context = tester.element(find.text(_HostPage.label));
    final Future<bool> result = openPlayer(
      context,
      mockHero,
      environment: environment(),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    expect(created, hasLength(1), reason: '第一集应已开流');
    await created.single.pause();
    await tester.pump();
    return result;
  }

  Future<void> pick(WidgetTester tester, String option) async {
    await tester.tap(find.byTooltip('定时关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// 观看记录里这部剧的「进度 / 时长」。
  String recordedProgress() {
    final List<WatchSnapshot> history =
        container.read(historyProvider).value ?? const <WatchSnapshot>[];
    return history
        .where((WatchSnapshot entry) => entry.seriesId == mockHero.id)
        .map(
          (WatchSnapshot entry) =>
              '${entry.progressSeconds}/${entry.durationSeconds}',
        )
        .join(',');
  }

  /// 手机竖屏布局下控制层播放 2 秒后自动隐藏：点一下画面把它唤出来。
  Future<void> revealControls(WidgetTester tester) async {
    await tester.tapAt(tester.getCenter(find.byType(PlayerScreen)));
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('player', () {
    testWidgets(
      'episode-end mode closes the player at EOF instead of advancing',
      (WidgetTester tester) async {
        final Future<bool> result = await openFullPlayer(tester);
        final FakePlatformPlayer player = created.single;
        await pick(tester, '播完本集');
        player.calls.clear();

        player.emitEpisodeEnd();
        await tester.pump();

        // 播完当刻（同一轮事件循环内）就停播，这时路由才刚开始退场。
        expect(player.calls, contains('stop'));
        expect(player.disposed, isFalse);
        expect(find.byType(PlayerScreen), findsOneWidget);
        // 到点即解除定时：退场期间顶栏入口不再显示「播完本集」。
        expect(find.text('播完本集'), findsNothing);

        await tester.pumpAndSettle();
        expect(
          player.calls.where((String call) => call.startsWith('open:')),
          isEmpty,
          reason: '不能连播下一集',
        );
        expect(player.disposed, isTrue);
        expect(find.byType(PlayerScreen), findsNothing);
        expect(find.text(_HostPage.label), findsOneWidget);
        expect(await result, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'without the timer, EOF still auto-advances to the next episode',
      (WidgetTester tester) async {
        await openFullPlayer(tester);
        final FakePlatformPlayer player = created.single;
        player.calls.clear();

        player.emitEpisodeEnd();
        await settle(tester);

        expect(
          player.calls.where((String call) => call.startsWith('open:')),
          hasLength(1),
          reason: '应打开下一集',
        );
        expect(player.disposed, isFalse);
        expect(find.textContaining('第2集'), findsWidgets);
        expect(find.byType(PlayerScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'countdown expiry stops playback at once and keeps the last progress',
      (WidgetTester tester) async {
        final Future<bool> result = await openFullPlayer(tester);
        final FakePlatformPlayer player = created.single;
        await pick(tester, '15分钟');
        player.tickPosition(const Duration(seconds: 77));
        await tester.pump();
        player.calls.clear();

        clock.advance(const Duration(minutes: 15));
        await tester.pump(SleepTimer.tickInterval);

        // 到点当刻就发出停播，而不是等路由退场后的 dispose：应用在后台时
        // 退场动画不推进，dispose 可能要等到用户下次回前台。
        expect(player.calls, contains('stop'));
        expect(player.disposed, isFalse);
        expect(find.byType(PlayerScreen), findsOneWidget);
        // 进度是停播前的位置；随后的 stop() 会把播放器状态归零。
        await tester.pump();
        expect(recordedProgress(), '77/120');

        await tester.pumpAndSettle();
        expect(player.disposed, isTrue);
        expect(recordedProgress(), '77/120');
        expect(find.text(_HostPage.label), findsOneWidget);
        expect(await result, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'countdown expiry during an auto-advance boot does not open the next episode',
      (WidgetTester tester) async {
        final Future<bool> result = await openFullPlayer(tester);
        final FakePlatformPlayer player = created.single;
        await tester.tap(find.byTooltip('定时关闭'));
        await tester.pumpAndSettle();

        // 定时从点选那一刻开始计时，之后每 1000ms 一次 tick（相位已知），
        // 才能把「到点」精确安排在下一集开流前的退场窗口里。
        await tester.tap(find.text('15分钟'));
        await tester.pump();
        clock.advance(
          const Duration(minutes: 14, seconds: 59, milliseconds: 500),
        );

        // 这一集在离到点半秒时播完，自动连播开始启动下一集：分集 300ms +
        // 解析 400ms + 等一帧 + 350ms 之后才真正开流。
        await tester.pump(const Duration(milliseconds: 3040));
        player.calls.clear();
        player.emitEpisodeEnd();
        await tester.pump(const Duration(milliseconds: 750));
        clock.advance(const Duration(seconds: 1));

        // 到点的 tick 落在下一集开流前约 140ms：播放页正在退场（仍 mounted）。
        await tester.pump(const Duration(milliseconds: 500));
        await settle(tester);

        expect(
          player.calls.where((String call) => call.startsWith('open:')),
          isEmpty,
          reason: '到点之后不能再把下一集开流',
        );
        expect(player.disposed, isTrue);
        expect(await result, isTrue);
        expect(find.text(_HostPage.label), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'episode-end EOF during the Back exit animation keeps the page below',
      (WidgetTester tester) async {
        final Future<bool> result = await openFullPlayer(tester);
        final FakePlatformPlayer player = created.single;
        await pick(tester, '播完本集');

        await tester.tap(find.byTooltip('返回'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(PlayerScreen), findsOneWidget);

        player.emitEpisodeEnd();
        await tester.pumpAndSettle();

        expect(find.text(_HostPage.label), findsOneWidget);
        expect(player.disposed, isTrue);
        expect(await result, isFalse, reason: '用户是自己按返回离开的');
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('watch feed', () {
    Future<void> pumpFeed(WidgetTester tester) async {
      await pumpApp(
        tester,
        size: const Size(390, 844),
        home: WatchFeedScreen(environment: environment()),
      );
      await settle(tester, 14);
    }

    Future<void> openFullFromFeed(WidgetTester tester) async {
      await tester.tap(find.text('看全集'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await settle(tester, 12);
      expect(find.byType(PlayerScreen), findsOneWidget);
    }

    testWidgets('a sleep-timer close leaves the feed paused', (
      WidgetTester tester,
    ) async {
      await pumpFeed(tester);
      final FakePlatformPlayer feed = created.first;
      expect(feed.calls, contains('play'), reason: '信息流在自动播放');

      await openFullFromFeed(tester);
      await revealControls(tester);
      await pick(tester, '15分钟');
      feed.calls.clear();

      clock.advance(const Duration(minutes: 15));
      await tester.pump(SleepTimer.tickInterval);
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsNothing);
      expect(
        feed.calls,
        isNot(contains('play')),
        reason: '定时已经把全屏播放关掉，信息流不能再接着出声',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('leaving by Back resumes the feed as before', (
      WidgetTester tester,
    ) async {
      await pumpFeed(tester);
      final FakePlatformPlayer feed = created.first;

      await openFullFromFeed(tester);
      feed.calls.clear();
      await revealControls(tester);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsNothing);
      expect(feed.calls, contains('play'));
      expect(tester.takeException(), isNull);
    });
  });
}

class _HostPage extends StatelessWidget {
  const _HostPage();

  static const String label = '宿主页';

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text(label)));
  }
}
