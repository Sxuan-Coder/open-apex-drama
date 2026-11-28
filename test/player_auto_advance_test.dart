import 'package:apexduanju/data/mock_data.dart';
import 'package:apexduanju/data/repository/mock_repositories.dart';
import 'package:apexduanju/data/repository/repositories.dart';
import 'package:apexduanju/models/playback.dart';
import 'package:apexduanju/player/player_environment.dart';
import 'package:apexduanju/providers/data_providers.dart';
import 'package:apexduanju/screens/player_screen.dart';
import 'package:apexduanju/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_clock.dart';
import 'support/fake_platform_player.dart';

/// 自动连播的「无感」回归：
///
/// - 片尾播放器只发 playing(false)、之后才发 completed(true)，不能把这次
///   暂停当成用户暂停去唤出控制层，否则每次切集都会弹标题栏 + 进度条；
/// - 过渡期间不出现加载圈；
/// - 用户自己按暂停时控制层仍要常显；
/// - 桌面端开播后就预解析下一集（P1），切集不再现场取址。
void main() {
  late List<FakePlatformPlayer> created;
  late FakeClock clock;

  setUp(() {
    created = <FakePlatformPlayer>[];
    clock = FakeClock();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  PlayerEnvironment environment() => PlayerEnvironment(
    now: clock.now,
    platformPlayerFactory: () {
      final FakePlatformPlayer player = FakePlatformPlayer();
      created.add(player);
      return player;
    },
  );

  /// mock 仓库带人为延迟，开流前还要等一帧再等 350ms：推进足够的时间。
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();
  }

  /// 桌面窗口尺寸：不走手机竖屏的上滑动画，链路最短。
  Future<void> pumpPlayer(
    WidgetTester tester, {
    PlaybackRepository? playback,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(MockCatalogRepository()),
          playbackRepositoryProvider.overrideWithValue(
            playback ?? MockPlaybackRepository(),
          ),
          rankRepositoryProvider.overrideWithValue(MockRankRepository()),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: PlayerScreen(drama: mockHero, environment: environment()),
        ),
      ),
    );
    await settle(tester);
  }

  /// 控制层实际透明度：控制层隐藏时控件仍在树上，只是 opacity=0。
  double controlsOpacity(WidgetTester tester) {
    return tester
        .widget<AnimatedOpacity>(find.byKey(const Key('player-controls')))
        .opacity;
  }

  testWidgets('片尾自动连播不唤出控制层，也不闪加载圈', (WidgetTester tester) async {
    await pumpPlayer(tester);
    final FakePlatformPlayer player = created.single;

    // 播放 4 秒让桌面控制层自动收起。
    await player.play();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(controlsOpacity(tester), 0);

    // 片尾前会尝试截最后一帧遮挡黑屏；假播放器不支持截图时必须静默跳过。
    player.tickPosition(const Duration(minutes: 1, seconds: 59));
    await tester.pump();
    expect(tester.takeException(), isNull);

    player.emitEpisodeEnd();
    await tester.pump();
    expect(controlsOpacity(tester), 0, reason: '片尾暂停不是用户暂停');
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 整个过渡期都不该弹出来（含等待解析与固定 350ms 的窗口）。
    await tester.pump(const Duration(milliseconds: 600));
    expect(controlsOpacity(tester), 0);

    // 下一集真正开流后也保持收起。
    await settle(tester);
    expect(
      player.calls.where((String call) => call.startsWith('open:')),
      hasLength(2),
      reason: '应已自动连播到下一集',
    );
    expect(controlsOpacity(tester), 0);
  });

  testWidgets('用户自己暂停仍然常显控制层', (WidgetTester tester) async {
    await pumpPlayer(tester);
    final FakePlatformPlayer player = created.single;

    await player.play();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(controlsOpacity(tester), 0);

    await player.pause();
    await tester.pump();
    expect(controlsOpacity(tester), greaterThan(0.5));
  });

  testWidgets('桌面端开播后预解析下一集', (WidgetTester tester) async {
    final _RecordingPlaybackRepository repo = _RecordingPlaybackRepository();
    await pumpPlayer(tester, playback: repo);

    expect(
      repo.resolved,
      contains('${mockHero.id}-ep2'),
      reason: 'Windows 也应提前解析下一集，切集不再现场取址',
    );
  });
}

/// 记录被解析的分集 id，用来验证预取确实发生在桌面端。
class _RecordingPlaybackRepository extends MockPlaybackRepository {
  final List<String> resolved = <String>[];

  @override
  Future<PlaybackBundle> resolve(String episodeId) {
    resolved.add(episodeId);
    return super.resolve(episodeId);
  }
}
