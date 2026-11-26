import 'package:apexduanju/data/mock_data.dart';
import 'package:apexduanju/data/repository/mock_repositories.dart';
import 'package:apexduanju/player/player_environment.dart';
import 'package:apexduanju/player/sleep_timer.dart';
import 'package:apexduanju/providers/data_providers.dart';
import 'package:apexduanju/screens/player_screen.dart';
import 'package:apexduanju/theme/app_colors.dart';
import 'package:apexduanju/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_clock.dart';

/// 播放页的定时关闭：顶栏入口、选择面板、到点退出，以及 `openPlayer` 的返回值。
///
/// 这里不注入播放器（media_kit 的原生库在测试里不可用，播放页降级为纯 UI），
/// 只验证入口、面板与「到点 pop 掉播放页」；真实停播链路见
/// `player_sleep_timer_playback_test.dart`。
void main() {
  late FakeClock clock;

  setUp(() {
    clock = FakeClock();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 经真实入口把播放页压在宿主页之上，返回 `openPlayer` 的结果：
  /// 定时关闭退出为 true，手动返回为 false。
  Future<Future<bool>> pumpPlayer(
    WidgetTester tester, {
    required Size size,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(MockCatalogRepository()),
          playbackRepositoryProvider.overrideWithValue(
            MockPlaybackRepository(),
          ),
          rankRepositoryProvider.overrideWithValue(MockRankRepository()),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const _HostPage(),
          builder: textScale == 1
              ? null
              : (BuildContext context, Widget? child) {
                  return MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(textScale)),
                    child: child!,
                  );
                },
        ),
      ),
    );
    final BuildContext context = tester.element(find.text(_HostPage.label));
    final Future<bool> closedBySleepTimer = openPlayer(
      context,
      mockHero,
      environment: PlayerEnvironment(now: clock.now),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    return closedBySleepTimer;
  }

  /// 打开面板选一项。只推进 600ms：面板退场、提示进场，且不足一个 tick，
  /// 入口上仍是整分钟。
  Future<void> pick(WidgetTester tester, String option) async {
    await tester.tap(find.byTooltip('定时关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 墙钟走到到点之后，并触发一次 tick。
  Future<void> reachDeadline(WidgetTester tester, Duration remaining) async {
    clock.advance(remaining);
    await tester.pump(SleepTimer.tickInterval);
  }

  Color? cellColor(WidgetTester tester, String label) {
    return tester
        .widget<Material>(
          find
              .ancestor(of: find.text(label), matching: find.byType(Material))
              .first,
        )
        .color;
  }

  testWidgets('sleep timer entry opens the options sheet with "off" selected', (
    WidgetTester tester,
  ) async {
    await pumpPlayer(tester, size: const Size(390, 844));
    expect(find.byTooltip('定时关闭'), findsOneWidget);
    // 读屏软件需要入口有名字：未开启时它只是一个图标。
    final SemanticsHandle semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('定时关闭'), findsOneWidget);
    semantics.dispose();

    await tester.tap(find.byTooltip('定时关闭'));
    await tester.pumpAndSettle();

    for (final String label in const <String>[
      '不开启',
      '15分钟',
      '30分钟',
      '60分钟',
      '90分钟',
      '播完本集',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '面板应列出「$label」');
    }
    expect(cellColor(tester, '不开启'), AppTokens.immersiveAccent);
    expect(cellColor(tester, '30分钟'), isNot(AppTokens.immersiveAccent));
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a duration shows the countdown on the entry', (
    WidgetTester tester,
  ) async {
    await pumpPlayer(tester, size: const Size(390, 844));
    await pick(tester, '30分钟');

    expect(find.text('30分钟'), findsNothing, reason: '面板应已关闭');
    expect(find.text('30:00'), findsOneWidget);

    await reachDeadline(tester, const Duration(seconds: 90));
    expect(find.text('28:30'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('countdown expiry pops the player and tells the page below', (
    WidgetTester tester,
  ) async {
    final Future<bool> closedBySleepTimer = await pumpPlayer(
      tester,
      size: const Size(390, 844),
    );
    await pick(tester, '15分钟');
    final String? confirmation = snackBarText(tester);

    await reachDeadline(tester, const Duration(minutes: 15));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.text(_HostPage.label), findsOneWidget);
    // 调用方（如「看剧」信息流）据此知道是定时关闭，而不是用户自己返回。
    expect(await closedBySleepTimer, isTrue);
    // 选完先有一条确认提示；退回宿主页后换成了另一条。
    expect(confirmation, isNotNull);
    expect(snackBarText(tester), isNotNull);
    expect(snackBarText(tester), isNot(confirmation));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'countdown expiry also closes a sheet left open above the player',
    (WidgetTester tester) async {
      await pumpPlayer(tester, size: const Size(390, 844));
      await pick(tester, '15分钟');
      await tester.tap(find.byTooltip('定时关闭'));
      await tester.pumpAndSettle();
      expect(find.text('90分钟'), findsOneWidget);

      await reachDeadline(tester, const Duration(minutes: 15));
      await tester.pumpAndSettle();

      // 只 pop 一次的话关掉的是面板，播放器会接着播一整晚。
      expect(find.text('90分钟'), findsNothing);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.text(_HostPage.label), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'countdown expiry during the Back exit animation keeps the page below',
    (WidgetTester tester) async {
      final Future<bool> closedBySleepTimer = await pumpPlayer(
        tester,
        size: const Size(390, 844),
      );
      await pick(tester, '15分钟');

      // 到点前 10 秒用户按了返回：路由进入退场动画，播放页此时仍然 mounted。
      clock.advance(const Duration(minutes: 14, seconds: 50));
      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(PlayerScreen), findsOneWidget, reason: '播放页还在退场动画里');

      // 退场动画没走完就到点了：路由已在退场，不能再 pop。
      await reachDeadline(tester, const Duration(seconds: 10));
      await tester.pumpAndSettle();

      // 多 pop 一次会把播放页下面的页面一起弹掉，应用停在空白页。
      expect(find.text(_HostPage.label), findsOneWidget);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(await closedBySleepTimer, isFalse, reason: '用户是自己按返回离开的');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving by Back reports false to the caller', (
    WidgetTester tester,
  ) async {
    final Future<bool> closedBySleepTimer = await pumpPlayer(
      tester,
      size: const Size(390, 844),
    );
    await pick(tester, '30分钟');

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsNothing);
    expect(await closedBySleepTimer, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('episode-end mode shows on the entry and never fires on time', (
    WidgetTester tester,
  ) async {
    await pumpPlayer(tester, size: const Size(320, 640));
    await pick(tester, '播完本集');

    expect(find.text('播完本集'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '最窄竖屏下不应溢出');

    await reachDeadline(tester, const Duration(hours: 2));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reopening the sheet highlights the running choice and can cancel it',
    (WidgetTester tester) async {
      await pumpPlayer(tester, size: const Size(390, 844));
      await pick(tester, '30分钟');

      await tester.tap(find.byTooltip('定时关闭'));
      await tester.pumpAndSettle();
      expect(cellColor(tester, '30分钟'), AppTokens.immersiveAccent);
      expect(cellColor(tester, '不开启'), isNot(AppTokens.immersiveAccent));

      await tester.tap(find.text('不开启'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('30:00'), findsNothing);

      await reachDeadline(tester, const Duration(hours: 1));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop layout offers the sleep timer from the top bar too', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpPlayer(tester, size: const Size(1280, 720));
      expect(find.byTooltip('定时关闭'), findsOneWidget);

      await pick(tester, '30分钟');
      expect(find.text('30:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'armed entry and sheet survive the largest text scale on the narrowest phone',
    (WidgetTester tester) async {
      await pumpPlayer(tester, size: const Size(320, 640), textScale: 2);
      await pick(tester, '播完本集');
      expect(find.text('播完本集'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '入口胶囊不应把顶栏挤溢出');

      await tester.tap(find.byTooltip('定时关闭'));
      await tester.pumpAndSettle();
      expect(find.text('90分钟'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '面板的标题行与选项格不应溢出');
    },
  );
}

String? snackBarText(WidgetTester tester) {
  final Finder text = find.descendant(
    of: find.byType(SnackBar),
    matching: find.byType(Text),
  );
  if (text.evaluate().isEmpty) {
    return null;
  }
  return tester.widget<Text>(text.first).data;
}

class _HostPage extends StatelessWidget {
  const _HostPage();

  static const String label = '宿主页';

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text(label)));
  }
}
