import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as media;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:apexduanju/data/local/watch_store.dart';
import 'package:apexduanju/data/mock_data.dart';
import 'package:apexduanju/data/repository/mock_repositories.dart';
import 'package:apexduanju/data/repository/repositories.dart';
import 'package:apexduanju/models/danmaku_cue.dart';
import 'package:apexduanju/models/drama.dart';
import 'package:apexduanju/models/playback.dart';
import 'package:apexduanju/models/series_detail.dart';
import 'package:apexduanju/providers/data_providers.dart';
import 'package:apexduanju/screens/category_screen.dart';
import 'package:apexduanju/screens/downloads_screen.dart';
import 'package:apexduanju/screens/drama_detail_screen.dart';
import 'package:apexduanju/screens/following_screen.dart';
import 'package:apexduanju/screens/home_screen.dart';
import 'package:apexduanju/screens/membership_screen.dart';
import 'package:apexduanju/screens/player_screen.dart';
import 'package:apexduanju/screens/profile_screen.dart';
import 'package:apexduanju/screens/rank_screen.dart';
import 'package:apexduanju/screens/recent_updates_screen.dart';
import 'package:apexduanju/screens/search_screen.dart';
import 'package:apexduanju/screens/settings_screen.dart';
import 'package:apexduanju/screens/watch_feed_screen.dart';
import 'package:apexduanju/theme/app_theme.dart';
import 'package:apexduanju/widgets/drama_card.dart';
import 'package:apexduanju/widgets/soft_chip.dart';

void main() {
  final List<Size> sizes = <Size>[
    const Size(320, 640),
    const Size(390, 844),
    const Size(800, 1000),
  ];

  Future<void> pumpScreen(
    WidgetTester tester,
    Widget screen, {
    required Size size,
    bool dark = false,
    double textScale = 1,
    PlaybackRepository? playbackRepository,
    CatalogRepository? catalogRepository,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        // 布局测试固定走 mock 数据源，避免测试环境触碰网络与原生 SDK。
        overrides: [
          catalogRepositoryProvider.overrideWithValue(
            catalogRepository ?? MockCatalogRepository(),
          ),
          playbackRepositoryProvider.overrideWithValue(
            playbackRepository ?? MockPlaybackRepository(),
          ),
          rankRepositoryProvider.overrideWithValue(MockRankRepository()),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          builder: textScale == 1
              ? null
              : (BuildContext context, Widget? child) {
                  final MediaQueryData data = MediaQuery.of(context);
                  return MediaQuery(
                    data: data.copyWith(
                      textScaler: TextScaler.linear(textScale),
                    ),
                    child: child!,
                  );
                },
          home: screen,
        ),
      ),
    );
    // mock 仓库带 350ms 人为延迟；pumpAndSettle 不会推进无帧调度的假时钟，
    // 需显式推进时间让异步数据落地。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Widget following(FollowingTab tab) {
    return Scaffold(
      body: FollowingScreen(
        selectedTab: tab,
        onTabChanged: (FollowingTab _) {},
      ),
    );
  }

  const Widget profile = Scaffold(
    body: ProfileScreen(onOpenFollowing: _absorbTab, onOpenCategory: _noop),
  );

  for (final Size size in sizes) {
    testWidgets('tab screens layout at $size', (WidgetTester tester) async {
      await pumpScreen(tester, const Scaffold(body: HomeScreen()), size: size);
      await pumpScreen(
        tester,
        const Scaffold(body: CategoryScreen()),
        size: size,
      );
      await pumpScreen(tester, const Scaffold(body: RankScreen()), size: size);
      await pumpScreen(
        tester,
        following(FollowingTab.continueWatching),
        size: size,
      );
      await pumpScreen(tester, following(FollowingTab.favorites), size: size);
      await pumpScreen(tester, following(FollowingTab.history), size: size);
      await pumpScreen(tester, profile, size: size);
    });

    testWidgets('secondary screens layout at $size', (
      WidgetTester tester,
    ) async {
      await pumpScreen(tester, DramaDetailScreen(drama: mockHero), size: size);
      await pumpScreen(tester, PlayerScreen(drama: mockHero), size: size);
      await pumpScreen(tester, const MembershipScreen(), size: size);
      await pumpScreen(tester, DownloadsScreen(onBrowse: _noop), size: size);
      await pumpScreen(tester, const RecentUpdatesScreen(), size: size);
      await pumpScreen(tester, const SettingsScreen(), size: size);
    });
  }

  testWidgets('recent updates switches day and lists dramas', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const RecentUpdatesScreen(),
      size: const Size(390, 844),
    );
    expect(find.text('今天'), findsOneWidget);
    expect(find.byType(DramaCard), findsWidgets);

    await tester.tap(find.text('明天'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(DramaCard), findsWidgets);
  });

  testWidgets('home recent-updates entry opens the calendar page', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(body: HomeScreen()),
      size: const Size(390, 844),
    );
    final Finder more = find.text('查看更多');
    await tester.dragUntilVisible(
      more,
      find.byType(CustomScrollView),
      const Offset(0, -220),
    );
    // 轮播在桌面版隐藏后首屏更短，目标可能贴着视口底边，
    // 先确保完全可见再点，否则命中会被遮挡。
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.byType(RecentUpdatesScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail switches to the info tab', (WidgetTester tester) async {
    await pumpScreen(
      tester,
      DramaDetailScreen(drama: mockHero),
      size: const Size(390, 844),
    );
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.text('分类'), findsOneWidget);
    expect(find.text('状态'), findsOneWidget);
    expect(find.text('全集已上线'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail folds episode grid to the first 20', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      DramaDetailScreen(drama: mockHero),
      size: const Size(390, 844),
      playbackRepository: _ThirtyEpisodePlaybackRepository(),
    );

    expect(find.text('20'), findsOneWidget);
    expect(find.text('21'), findsNothing);
    expect(find.textContaining('展开全部'), findsOneWidget);

    await tester.tap(find.textContaining('展开全部'));
    await tester.pumpAndSettle();
    expect(find.text('21'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings header back button hugs the left edge', (
    WidgetTester tester,
  ) async {
    const Size size = Size(390, 844);

    for (final bool dark in <bool>[false, true]) {
      await pumpScreen(tester, const SettingsScreen(), size: size, dark: dark);

      final Finder backButton = find.byTooltip('返回');
      expect(backButton, findsOneWidget);
      final double backDx = tester.getTopLeft(backButton).dx;
      expect(backDx, lessThan(20), reason: 'back icon must hug the left edge');

      final double titleCenterDx = tester.getCenter(find.text('设置')).dx;
      expect(
        (titleCenterDx - size.width / 2).abs(),
        lessThan(4),
        reason: 'title must stay horizontally centered',
      );
    }
  });

  testWidgets('dark mode renders every primary screen', (
    WidgetTester tester,
  ) async {
    const Size size = Size(390, 844);
    await pumpScreen(
      tester,
      const Scaffold(body: HomeScreen()),
      size: size,
      dark: true,
    );
    await pumpScreen(
      tester,
      const Scaffold(body: CategoryScreen()),
      size: size,
      dark: true,
    );
    await pumpScreen(
      tester,
      const Scaffold(body: RankScreen()),
      size: size,
      dark: true,
    );
    await pumpScreen(
      tester,
      following(FollowingTab.continueWatching),
      size: size,
      dark: true,
    );
    await pumpScreen(tester, profile, size: size, dark: true);
    await pumpScreen(
      tester,
      DramaDetailScreen(drama: mockHero),
      size: size,
      dark: true,
    );
    await pumpScreen(
      tester,
      PlayerScreen(drama: mockHero),
      size: size,
      dark: true,
    );
    await pumpScreen(tester, const SettingsScreen(), size: size, dark: true);
    await pumpScreen(tester, const MembershipScreen(), size: size, dark: true);
  });

  testWidgets('scrolled content has no overflow', (WidgetTester tester) async {
    const Size size = Size(390, 844);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> pump(Widget screen) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogRepositoryProvider.overrideWithValue(
              MockCatalogRepository(),
            ),
            playbackRepositoryProvider.overrideWithValue(
              MockPlaybackRepository(),
            ),
            rankRepositoryProvider.overrideWithValue(MockRankRepository()),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            home: screen,
          ),
        ),
      );
      // 推进假时钟让 mock 仓库的延迟数据落地。
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }

    await pump(const Scaffold(body: HomeScreen()));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await pump(const Scaffold(body: CategoryScreen()));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await pump(const Scaffold(body: RankScreen()));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await pump(following(FollowingTab.continueWatching));
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await pump(following(FollowingTab.favorites));
    await tester.drag(find.byType(GridView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await pump(following(FollowingTab.history));
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await pump(profile);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await pump(const SettingsScreen());
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await pump(const MembershipScreen());
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await pump(DramaDetailScreen(drama: mockHero));
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text scale 1.3 does not overflow', (
    WidgetTester tester,
  ) async {
    const Size size = Size(390, 844);

    await pumpScreen(
      tester,
      const Scaffold(body: HomeScreen()),
      size: size,
      textScale: 1.3,
    );
    await pumpScreen(
      tester,
      const Scaffold(body: CategoryScreen()),
      size: size,
      textScale: 1.3,
    );
    await pumpScreen(
      tester,
      const Scaffold(body: RankScreen()),
      size: size,
      textScale: 1.3,
    );
    await pumpScreen(
      tester,
      following(FollowingTab.continueWatching),
      size: size,
      textScale: 1.3,
    );
    await pumpScreen(tester, profile, size: size, textScale: 1.3);
    await pumpScreen(
      tester,
      DramaDetailScreen(drama: mockHero),
      size: size,
      textScale: 1.3,
    );
    await pumpScreen(
      tester,
      const SettingsScreen(),
      size: size,
      textScale: 1.3,
    );
    await pumpScreen(
      tester,
      const MembershipScreen(),
      size: size,
      textScale: 1.3,
    );
  });

  testWidgets(
    'detail renders recommendations and hides season row when single season',
    (WidgetTester tester) async {
      await pumpScreen(
        tester,
        DramaDetailScreen(drama: mockHero),
        size: const Size(390, 844),
      );

      // mock 环境聚合数据不带多季信息：季行不显示，页面主体照常渲染。
      expect(find.byKey(const Key('detail-season-row')), findsNothing);
      expect(find.text('选集'), findsOneWidget);
      expect(find.text('立即播放'), findsOneWidget);
      // 聚合数据就绪后，相关推荐区渲染 seriesDetail 返回的列表。
      expect(find.text('相关推荐'), findsOneWidget);
      expect(find.text(mockDramas[1].title), findsOneWidget);
      expect(find.text(mockDramas[2].title), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('detail uses server recommendation title instead of 相关推荐', (
    WidgetTester tester,
  ) async {
    final SeriesDetailData comic = SeriesDetailData(
      drama: mockHero,
      recommend: <Drama>[mockDramas[1], mockDramas[2]],
      recommendTitle: '更多漫剧',
    );

    await pumpScreen(
      tester,
      DramaDetailScreen(drama: mockHero),
      size: const Size(390, 844),
      catalogRepository: _RecommendCatalog(comic),
    );

    expect(find.text('更多漫剧'), findsOneWidget);
    expect(find.text('相关推荐'), findsNothing);
    expect(find.text(mockDramas[1].title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail hides recommendation section when list is empty', (
    WidgetTester tester,
  ) async {
    final SeriesDetailData empty = SeriesDetailData(
      drama: mockHero,
      recommendTitle: '',
    );

    await pumpScreen(
      tester,
      DramaDetailScreen(drama: mockHero),
      size: const Size(390, 844),
      catalogRepository: _RecommendCatalog(empty),
    );

    expect(find.text('相关推荐'), findsNothing);
    expect(find.text('查看更多'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multi-season detail shows season row and refetches episodes', (
    WidgetTester tester,
  ) async {
    const Size size = Size(390, 844);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final SeriesDetailData multiSeason = SeriesDetailData(
      drama: mockHero,
      seasons: const <SeasonInfo>[
        SeasonInfo(
          seriesId: 'flash-marriage',
          title: '第一季',
          index: 1,
          episodeCount: 3,
        ),
        SeasonInfo(
          seriesId: 'season-two',
          title: '第二季',
          index: 2,
          episodeCount: 6,
        ),
      ],
      isMultiSeason: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(
            _MultiSeasonCatalog(detail: multiSeason),
          ),
          playbackRepositoryProvider.overrideWithValue(
            _SeasonPlaybackRepository(),
          ),
          rankRepositoryProvider.overrideWithValue(MockRankRepository()),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          home: DramaDetailScreen(drama: mockHero),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // 多季聚合数据就绪后出现季行，默认选中第 1 季（3 集）。
    expect(find.byKey(const Key('detail-season-row')), findsOneWidget);
    expect(find.text('第一季'), findsOneWidget);
    expect(find.text('第二季'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('4'), findsNothing);

    // 切到第 2 季：分集按新 seriesId 重新拉取（6 集）。
    await tester.tap(find.text('第二季'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('4'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search screen layout at 320 / 390 / 800', (
    WidgetTester tester,
  ) async {
    for (final Size size in sizes) {
      await pumpScreen(tester, const SearchScreen(), size: size);
      expect(find.text('猜你想搜'), findsOneWidget);
      expect(find.text('热搜榜'), findsOneWidget);
      // mock 热搜榜来自 mockFeatured：前三名标题必须渲染出来
      // （同时出现在猜你想搜 chip 里，因此是 findsWidgets）。
      expect(find.text('闪婚老公是财阀'), findsWidgets);
      expect(find.text('重生之逆风翻盘'), findsWidgets);
      expect(find.text('穿越之王妃有点拽'), findsWidgets);
    }
  });

  testWidgets('search screen renders in dark mode', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const SearchScreen(),
      size: const Size(390, 844),
      dark: true,
    );
    expect(find.text('热搜榜'), findsOneWidget);
    expect(find.text('闪婚老公是财阀'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search screen survives 320 width and 1.3 text scale', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const SearchScreen(),
      size: const Size(320, 640),
      textScale: 1.3,
    );
    expect(find.text('热搜榜'), findsOneWidget);
    expect(find.text('闪婚老公是财阀'), findsWidgets);
  });

  testWidgets('search suggestions wait for the 350ms debounce', (
    WidgetTester tester,
  ) async {
    await pumpScreen(tester, const SearchScreen(), size: const Size(390, 844));
    await tester.enterText(find.byType(TextField), '闪婚');
    // debounce 未到不请求联想词。
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('闪婚 短剧'), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('闪婚 短剧'), findsOneWidget);
    expect(find.text('闪婚 完结'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('submitting a query shows the result grid', (
    WidgetTester tester,
  ) async {
    await pumpScreen(tester, const SearchScreen(), size: const Size(390, 844));
    await tester.enterText(find.byType(TextField), '财阀');
    await tester.tap(find.text('搜索'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // mock 搜索按标题包含匹配：只有「闪婚老公是财阀」命中。
    expect(find.byType(DramaCard), findsOneWidget);
    expect(find.text('闪婚老公是财阀'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final Size size in sizes) {
    testWidgets('category screen renders real filter panel at $size', (
      WidgetTester tester,
    ) async {
      await pumpScreen(
        tester,
        const Scaffold(body: CategoryScreen()),
        size: size,
      );
      // 筛选面板来自 filterPanelProvider：mock 返回「题材」一组 12 个选项。
      expect(find.text('题材'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(SoftChip), matching: find.text('都市')),
        findsOneWidget,
      );
      // 「全部」态：全量真实短剧网格（空 selections = 不筛选）。
      expect(find.byType(DramaCard), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('category screen appends the next filter page', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(body: CategoryScreen()),
      size: const Size(390, 844),
    );

    // mock 12 部按 6 条/页分页：首页应有「加载更多」与「已显示 6 部」。
    expect(find.text('已显示 6 部'), findsOneWidget);
    final Finder loadMore = find.text('加载更多');
    expect(loadMore, findsOneWidget);

    await tester.tap(loadMore);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 第二页追加后拿全 12 部，「加载更多」消失、计数复位为「共 N 部」。
    // SliverGrid 懒加载只构建可见卡片，这里以计数与按钮消失为准。
    expect(loadMore, findsNothing);
    expect(find.text('共 12 部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('category filter switch discards stale appended pages', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(body: CategoryScreen()),
      size: const Size(390, 844),
    );

    // 「全部」先加载第二页（共 12 部）。
    await tester.tap(find.text('加载更多'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('共 12 部'), findsOneWidget);

    // 切到「古装」筛选：追加页作废，只展示该题材首页（3 部）。
    await tester.tap(
      find.descendant(of: find.byType(SoftChip), matching: find.text('古装')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('古装 · 精选短剧'), findsOneWidget);
    expect(find.text('共 3 部'), findsOneWidget);
    expect(find.byType(DramaCard), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('player Windows fullscreen hides and restores native title bar', (
    WidgetTester tester,
  ) async {
    const MethodChannel channel = MethodChannel('window_manager');
    final List<MethodCall> calls = <MethodCall>[];
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpScreen(
        tester,
        PlayerScreen(drama: mockHero),
        // 用真实桌面的横屏窗口：竖屏尺寸下「宽屏布局」与「全屏态」恰好同时
        // 翻转，图标错用布局标志的 bug 测不出来（Windows 窗口永远是横的）。
        size: const Size(1280, 720),
      );

      // 未进全屏时按钮必须是「全屏」：图标要跟窗口全屏标志走，
      // 不能跟横屏布局走。
      expect(find.byTooltip('全屏'), findsWidgets);
      expect(find.byTooltip('退出全屏'), findsNothing);

      await tester.tap(find.byTooltip('全屏').first);
      await tester.pump();
      // 进全屏：先藏标题栏再设全屏。
      expect(
        calls.map((MethodCall call) => call.method),
        containsAllInOrder(<String>['setTitleBarStyle', 'setFullScreen']),
      );
      final Map<Object?, Object?> enterTitleArgs =
          calls
                  .firstWhere(
                    (MethodCall call) => call.method == 'setTitleBarStyle',
                  )
                  .arguments
              as Map<Object?, Object?>;
      expect(enterTitleArgs['titleBarStyle'], 'hidden');
      expect(enterTitleArgs['windowButtonVisibility'], isFalse);

      calls.clear();
      await tester.tap(find.byTooltip('退出全屏').first);
      await tester.pump();
      // 退全屏：先出全屏再恢复标题栏。
      expect(
        calls.map((MethodCall call) => call.method),
        containsAllInOrder(<String>['setFullScreen', 'setTitleBarStyle']),
      );
      final Map<Object?, Object?> leaveTitleArgs =
          calls
                  .lastWhere(
                    (MethodCall call) => call.method == 'setTitleBarStyle',
                  )
                  .arguments
              as Map<Object?, Object?>;
      expect(leaveTitleArgs['titleBarStyle'], 'normal');
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows mini player restores on Escape, button and disposal', (
    WidgetTester tester,
  ) async {
    const MethodChannel channel = MethodChannel('apexduanju/mini_player');
    final List<MethodCall> calls = <MethodCall>[];
    final backend = _MiniPlayerBackend();
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'exit') {
        await Future<void>.value();
        tester.view.physicalSize = const Size(800, 600);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await pumpScreen(
      tester,
      PlayerScreen(
        drama: mockHero,
        createPlayer: () => media.Player(platformPlayer: backend),
        createVideoController: (_, {required configuration}) => null,
      ),
      size: const Size(800, 600),
    );
    final State<StatefulWidget> player = tester.state(find.byType(PlayerScreen));
    expect(backend.opens, 1);
    expect(find.byTooltip('打开小窗'), findsNothing);

    backend.setVideoSize(1280, 720, rotate: 90);
    await tester.pumpAndSettle();

    Future<void> enter(Size size) async {
      await tester.tap(find.byTooltip('打开小窗'));
      await tester.pump();
      tester.view.physicalSize = size;
      await tester.pump();
      expect(find.byTooltip('选集'), findsNothing);
      expect(find.byTooltip('返回播放窗口'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    await enter(const Size(208, 156));
    expect(calls.single.arguments, isTrue);
    await tester.dragFrom(const Offset(14, 65), const Offset(40, 10));
    expect(calls.map((call) => call.method), <String>['enter', 'drag']);
    backend.setPlaying(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.byTooltip('返回播放窗口').hitTestable(), findsNothing);
    backend.failOpen = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byTooltip('后退 10 秒'), findsNothing);
    expect(find.byTooltip('返回播放窗口').hitTestable(), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('播放失败，请重试'), findsOneWidget);
    expect(find.byTooltip('后退 10 秒'), findsNothing);
    backend.setPlaying(false);
    backend.failOpen = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(backend.opens, 3);
    expect(find.byTooltip('后退 10 秒'), findsOneWidget);
    expect(calls.where((call) => call.method == 'setOrientation'), isEmpty);
    backend.setVideoSize(720, 1280, rotate: 270);
    await tester.pump();
    backend.setVideoSize(1920, 1080);
    await tester.pump();
    backend.setVideoSize(720, 1280);
    await tester.pump();
    expect(
      calls.where((call) => call.method == 'setOrientation')
          .map((call) => call.arguments),
      <bool>[false, true],
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byTooltip('打开小窗'), findsOneWidget);
    backend.setVideoSize(720, 1280, rotate: 270);
    await tester.pumpAndSettle();
    await enter(const Size(216, 384));
    expect(calls.last.arguments, isFalse);
    await tester.tap(find.byTooltip('返回播放窗口'));
    await tester.pump();
    expect(tester.state(find.byType(PlayerScreen)), same(player));
    backend.setVideoSize(720, 1280);
    await tester.pumpAndSettle();
    await enter(const Size(384, 216));
    expect(calls.last.arguments, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.map((call) => call.method), <String>[
      'enter', 'drag', 'setOrientation', 'setOrientation', 'exit',
      'enter', 'exit', 'enter', 'exit',
    ]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('mini player entry is Windows only', (
    WidgetTester tester,
  ) async {
    final backend = _MiniPlayerBackend();
    await pumpScreen(
      tester,
      PlayerScreen(
        drama: mockHero,
        createPlayer: () => media.Player(platformPlayer: backend),
        createVideoController: (_, {required configuration}) => null,
      ),
      size: const Size(390, 844),
    );
    // 尺寸已知也不该出现入口：通道只在 Windows 注册。
    backend.setVideoSize(1280, 720);
    await tester.pumpAndSettle();
    // 等下一集预解析的延时任务落地，否则测试结束时会报 pending timer。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.byTooltip('打开小窗'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('mini player entry failure keeps the entry available', (
    WidgetTester tester,
  ) async {
    const MethodChannel channel = MethodChannel('apexduanju/mini_player');
    final backend = _MiniPlayerBackend();
    int enterCalls = 0;
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'enter') {
        enterCalls++;
        throw PlatformException(code: 'window', message: 'enter failed');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await pumpScreen(
      tester,
      PlayerScreen(
        drama: mockHero,
        createPlayer: () => media.Player(platformPlayer: backend),
        createVideoController: (_, {required configuration}) => null,
      ),
      size: const Size(800, 600),
    );
    backend.setVideoSize(1280, 720);
    await tester.pumpAndSettle();
    expect(find.byTooltip('打开小窗'), findsOneWidget);

    await tester.tap(find.byTooltip('打开小窗'));
    await tester.pumpAndSettle();
    // 原生拒绝后回滚：仍是主窗口形态，入口还能再点一次。
    expect(find.byTooltip('打开小窗'), findsOneWidget);
    expect(find.byTooltip('返回播放窗口'), findsNothing);

    await tester.tap(find.byTooltip('打开小窗'));
    await tester.pumpAndSettle();
    expect(enterCalls, 2);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('mini player progress slider seeks', (
    WidgetTester tester,
  ) async {
    const MethodChannel channel = MethodChannel('apexduanju/mini_player');
    final backend = _MiniPlayerBackend();
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await pumpScreen(
      tester,
      PlayerScreen(
        drama: mockHero,
        createPlayer: () => media.Player(platformPlayer: backend),
        createVideoController: (_, {required configuration}) => null,
      ),
      size: const Size(800, 600),
    );
    backend.setVideoSize(1280, 720);
    backend.setDuration(const Duration(seconds: 100));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('打开小窗'));
    await tester.pump();
    tester.view.physicalSize = const Size(384, 216);
    await tester.pump();
    expect(find.byType(Slider), findsOneWidget);

    await tester.drag(find.byType(Slider), const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(backend.lastSeek, isNotNull);
    expect(backend.lastSeek!.inSeconds, greaterThan(30));
    expect(backend.lastSeek!.inSeconds, lessThanOrEqualTo(100));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('category filter chip tap refreshes the result grid', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(body: CategoryScreen()),
      size: const Size(390, 844),
    );

    // 「全部」态：全量剧集网格（mock filter 无筛选返回 12 部）。
    expect(find.byType(DramaCard), findsWidgets);
    expect(find.text('全部短剧'), findsOneWidget);

    // 点「古装」chip → watch filterResultProvider('genre=古装')。
    await tester.tap(
      find.descendant(of: find.byType(SoftChip), matching: find.text('古装')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('古装 · 精选短剧'), findsOneWidget);
    expect(find.text('共 3 部'), findsOneWidget);
    expect(find.byType(DramaCard), findsNWidgets(3));
    expect(find.text('穿越之王妃有点拽'), findsOneWidget);

    // 点回每组第一项「全部」（value=''）→ 回全量列表，标题复位。
    await tester.tap(
      find.descendant(of: find.byType(SoftChip), matching: find.text('全部')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('全部短剧'), findsOneWidget);
    expect(find.byType(DramaCard), findsWidgets);
  });

  testWidgets('category multi-select joins values into one selections key', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(body: CategoryScreen()),
      size: const Size(390, 844),
    );

    await tester.tap(
      find.descendant(of: find.byType(SoftChip), matching: find.text('古装')),
    );
    await tester.pump(const Duration(milliseconds: 120));
    // 「年代」在横滑列表靠后，先滚动到可见再点选。
    await tester.scrollUntilVisible(
      find.descendant(of: find.byType(SoftChip), matching: find.text('年代')),
      60,
      scrollable: find
          .descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(SoftChip), matching: find.text('年代')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 标题按选项顺序拼接；多选 key 为 genre=年代,古装（mock 命中 3+1 部）。
    expect(find.text('古装/年代 · 精选短剧'), findsOneWidget);
    expect(find.text('共 4 部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('category filter with no match shows empty state', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(body: CategoryScreen()),
      size: const Size(390, 844),
    );

    // mock 数据里没有 category=现言 的剧：结果为空 → EmptyState。
    await tester.tap(
      find.descendant(of: find.byType(SoftChip), matching: find.text('现言')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('该题材正在筹备中'), findsOneWidget);
    expect(find.byType(DramaCard), findsNothing);
    // 「看全部」清空筛选回全量列表。
    await tester.tap(find.text('看全部'));
    await tester.pumpAndSettle();
    expect(find.text('全部短剧'), findsOneWidget);
    expect(find.byType(DramaCard), findsWidgets);
  });

  testWidgets('rank screen renders provider data at 320 / 390 / 800', (
    WidgetTester tester,
  ) async {
    for (final Size size in sizes) {
      await pumpScreen(tester, const Scaffold(body: RankScreen()), size: size);
      // Tab 与条目均来自 rankPageProvider（MockRankRepository）。
      expect(find.text('热播榜'), findsOneWidget);
      expect(find.text('新剧榜'), findsOneWidget);
      expect(find.text('完结榜'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    }
  });

  testWidgets('rank screen survives 320 width and 1.3 text scale', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(body: RankScreen()),
      size: const Size(320, 640),
      textScale: 1.3,
    );
    expect(find.text('热播榜'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('watch feed renders the first drama and a play CTA', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(body: WatchFeedScreen(active: false)),
      size: const Size(390, 844),
    );

    expect(find.textContaining('看全集'), findsWidgets);
    expect(find.text('推荐'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rank screen switches boards via tabs', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(body: RankScreen()),
      size: const Size(390, 844),
    );
    expect(find.text('热播榜'), findsOneWidget);
    expect(find.text('新剧榜'), findsOneWidget);
    expect(find.text('完结榜'), findsOneWidget);

    // 点 Tab 换 rankPageProvider([contentId, boardId]) 的数据源。
    await tester.tap(find.text('新剧榜'));
    await tester.pumpAndSettle();
    expect(find.text('热播榜'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('完结榜'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player quality sheet opens from the playback settings sheet', (
    WidgetTester tester,
  ) async {
    // 移动端竖屏把清晰度收进「播放设置」；这里验证右栏入口能打开清晰度面板。
    await pumpScreen(
      tester,
      PlayerScreen(drama: mockHero),
      size: const Size(390, 844),
    );
    await tester.tap(find.byTooltip('播放设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清晰度'));
    await tester.pumpAndSettle();
    expect(find.text('清晰度'), findsOneWidget);
    // 纯 UI 环境下 bundle 未解析，面板呈现解析中空态而不是崩溃。
    expect(find.text('播放地址还在解析，请稍候…'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('清晰度'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player speed sheet updates the rail label', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      PlayerScreen(drama: mockHero),
      size: const Size(320, 640),
    );
    // 纯 UI 环境下 Player 未就绪，右侧操作栏与底部兜底控制行会同时渲染
    // 倍速入口（Windows 因走桌面布局只渲染一处）。两者打开同一面板，取第一个。
    await tester.tap(find.text('倍速').first);
    await tester.pumpAndSettle();
    expect(find.text('倍速播放'), findsOneWidget);
    expect(find.text('0.5x'), findsOneWidget);
    expect(find.text('2.0x'), findsOneWidget);

    // 选中 1.5x：面板关闭，倍速状态同步到按钮 label（移动端布局下两处同步）。
    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();
    expect(find.text('1.5x'), findsWidgets);
    expect(find.text('倍速'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('player sheet zone is the middle third', () {
    expect(isPlayerSheetZone(10, 300), isFalse);
    expect(isPlayerSheetZone(100, 300), isTrue);
    expect(isPlayerSheetZone(150, 300), isTrue);
    expect(isPlayerSheetZone(200, 300), isTrue);
    expect(isPlayerSheetZone(290, 300), isFalse);
  });

  test('paused indicator only shows on mobile with a ready player', () {
    expect(
      shouldShowPausedIndicator(
        mobile: true,
        hasPlayer: true,
        playing: false,
        loading: false,
        hasError: false,
      ),
      isTrue,
    );
    expect(
      shouldShowPausedIndicator(
        mobile: true,
        hasPlayer: true,
        playing: true,
        loading: false,
        hasError: false,
      ),
      isFalse,
    );
    expect(
      shouldShowPausedIndicator(
        mobile: false,
        hasPlayer: true,
        playing: false,
        loading: false,
        hasError: false,
      ),
      isFalse,
    );
    expect(
      shouldShowPausedIndicator(
        mobile: true,
        hasPlayer: false,
        playing: false,
        loading: false,
        hasError: false,
      ),
      isFalse,
    );
    expect(
      shouldShowPausedIndicator(
        mobile: true,
        hasPlayer: true,
        playing: false,
        loading: true,
        hasError: false,
      ),
      isFalse,
    );
    expect(
      shouldShowPausedIndicator(
        mobile: true,
        hasPlayer: true,
        playing: false,
        loading: false,
        hasError: true,
      ),
      isFalse,
    );
  });

  test('next preload episode respects the last episode', () {
    expect(nextPreloadEpisode(1, 3), 2);
    expect(nextPreloadEpisode(2, 3), 3);
    expect(nextPreloadEpisode(3, 3), 0);
    expect(nextPreloadEpisode(1, 0), 0);
  });

  test('vertical swipe commits only past threshold or fast flick', () {
    expect(
      swipeCommitDirection(dy: -300, velocity: 0, height: 800),
      1,
    );
    expect(
      swipeCommitDirection(dy: -100, velocity: -900, height: 800),
      1,
    );
    expect(
      swipeCommitDirection(dy: -100, velocity: 0, height: 800),
      0,
    );
    expect(
      swipeCommitDirection(dy: 300, velocity: 0, height: 800),
      -1,
    );
    expect(
      swipeCommitDirection(dy: 100, velocity: 0, height: 800),
      0,
    );
  });

  testWidgets('player vertical swipe advances to the next episode', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      PlayerScreen(drama: mockHero),
      size: const Size(390, 844),
    );
    expect(find.text('第1集'), findsOneWidget);

    await tester.drag(find.byType(PlayerScreen), const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();

    expect(find.text('第2集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player survives a second drag during the swipe animation', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      PlayerScreen(drama: mockHero),
      size: const Size(390, 844),
    );

    await tester.drag(find.byType(PlayerScreen), const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.drag(find.byType(PlayerScreen), const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('第2集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player mobile layout hides next episode and adds settings entry', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      PlayerScreen(drama: mockHero),
      size: const Size(390, 844),
    );

    expect(find.text('下一集'), findsNothing);
    expect(find.byTooltip('播放设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player mobile settings sheet lists playback options', (
    WidgetTester tester,
  ) async {
    await pumpScreen(
      tester,
      PlayerScreen(drama: mockHero),
      size: const Size(390, 844),
    );

    await tester.tap(find.byTooltip('播放设置'));
    await tester.pumpAndSettle();

    expect(find.text('清晰度'), findsOneWidget);
    expect(find.text('弹幕设置'), findsOneWidget);
    expect(find.text('自动播放'), findsOneWidget);
    expect(find.text('音量'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player desktop layout keeps the next episode panel', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpScreen(
        tester,
        PlayerScreen(drama: mockHero),
        size: const Size(800, 1000),
      );

      expect(find.text('下一集'), findsOneWidget);
      expect(find.byTooltip('播放设置'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('following tabs render data from the persisted watch store', (
    WidgetTester tester,
  ) async {
    // 追加的 override：watch providers 走真实 WatchStore，
    // 数据来自 SharedPreferences mock 初始值（不触碰插件）。
    await seedWatchStore(
      history: _storeDramaA,
      historyOlder: _storeDramaB,
      favorite: _storeFavorite,
    );

    // 继续观看：最新的甲在上，进度条按 progress/duration 渲染。
    await pumpScreen(
      tester,
      following(FollowingTab.continueWatching),
      size: const Size(390, 844),
    );
    expect(find.text('存储剧甲'), findsOneWidget);
    expect(find.text('存储剧乙'), findsOneWidget);
    expect(find.text('已观看至 3 集 / 共 80 集'), findsOneWidget);
    expect(find.text('已看 45%'), findsOneWidget);
    expect(find.text('已看 30%'), findsOneWidget);
    final double topA = tester.getTopLeft(find.text('存储剧甲')).dy;
    final double topB = tester.getTopLeft(find.text('存储剧乙')).dy;
    expect(topA, lessThan(topB), reason: 'continue list is time-desc');
    // 收藏横滑 rail 来自同一 store 的收藏列表。
    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('收藏剧丙'), findsOneWidget);

    // 历史：计数 + 时间倒序。
    await pumpScreen(
      tester,
      following(FollowingTab.history),
      size: const Size(390, 844),
    );
    expect(find.text('共 2 条观看记录'), findsOneWidget);
    expect(find.text('存储剧甲'), findsOneWidget);
    expect(find.text('存储剧乙'), findsOneWidget);
    expect(find.text('看到第 3 集 / 共 80 集'), findsOneWidget);
    final double historyTopA = tester.getTopLeft(find.text('存储剧甲')).dy;
    final double historyTopB = tester.getTopLeft(find.text('存储剧乙')).dy;
    expect(historyTopA, lessThan(historyTopB), reason: 'history is time-desc');

    // 收藏网格：快照重建的 DramaCard（rating 0 时 meta 只显示分类）。
    await pumpScreen(
      tester,
      following(FollowingTab.favorites),
      size: const Size(390, 844),
    );
    expect(find.byType(DramaCard), findsOneWidget);
    expect(find.text('收藏剧丙'), findsOneWidget);
    expect(find.text('全52集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history rows delete individually and clear all', (
    WidgetTester tester,
  ) async {
    await seedWatchStore(history: _storeDramaA, historyOlder: _storeDramaB);
    await pumpScreen(
      tester,
      following(FollowingTab.history),
      size: const Size(390, 844),
    );
    expect(find.text('共 2 条观看记录'), findsOneWidget);

    // 单条删除：删掉最新的甲，乙仍在。
    await tester.tap(find.byTooltip('删除记录').first);
    await tester.pumpAndSettle();
    expect(find.text('共 1 条观看记录'), findsOneWidget);
    expect(find.text('存储剧甲'), findsNothing);
    expect(find.text('存储剧乙'), findsOneWidget);

    // 清空：现有按钮接线 clearHistory，列表被空态替换。
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('还没有观看记录'), findsOneWidget);
    expect(find.text('共 1 条观看记录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail favorite toggle syncs with following favorites', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpScreen(
      tester,
      DramaDetailScreen(drama: mockHero),
      size: const Size(390, 844),
    );
    expect(find.byTooltip('收藏'), findsOneWidget);
    expect(find.byTooltip('取消收藏'), findsNothing);

    // toggle 写入 store 并落盘（mock prefs），图标随状态切换。
    await tester.tap(find.byTooltip('收藏'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    // 新的 ProviderScope 重新读 store：追剧收藏页出现该剧。
    await pumpScreen(
      tester,
      following(FollowingTab.favorites),
      size: const Size(390, 844),
    );
    expect(find.byType(DramaCard), findsOneWidget);
    expect(find.text(mockHero.title), findsOneWidget);

    // 再次进详情页：收藏态已持久化，取消收藏后追剧页回到空态。
    await pumpScreen(
      tester,
      DramaDetailScreen(drama: mockHero),
      size: const Size(390, 844),
    );
    expect(find.byTooltip('取消收藏'), findsOneWidget);
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('收藏'), findsOneWidget);

    await pumpScreen(
      tester,
      following(FollowingTab.favorites),
      size: const Size(390, 844),
    );
    expect(find.text('还没有收藏的短剧'), findsOneWidget);
    expect(find.byType(DramaCard), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// 详情页折叠测试用：固定返回 30 集，避免 mock 数据只有 3 集。
class _ThirtyEpisodePlaybackRepository implements PlaybackRepository {
  @override
  Future<List<EpisodeInfo>> episodes(String seriesId) async {
    return List<EpisodeInfo>.generate(
      30,
      (int i) => EpisodeInfo(
        id: '$seriesId-ep${i + 1}',
        seriesId: seriesId,
        number: i + 1,
        title: '第${i + 1}集',
        playable: true,
      ),
    );
  }

  @override
  Future<PlaybackBundle> resolve(String episodeId) {
    throw UnimplementedError();
  }

  @override
  void invalidate(String episodeId) {}

  @override
  Future<List<DanmakuCue>> danmaku(String seriesId, String episodeId) async {
    return const <DanmakuCue>[];
  }
}

/// 追加用例的 store 播种：按 WatchStore 的真实 JSON schema 写入
/// SharedPreferences mock 初始值，让 providers 直接读真实数据流。
Future<void> seedWatchStore({
  WatchSnapshot? history,
  WatchSnapshot? historyOlder,
  WatchSnapshot? favorite,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (history != null)
      WatchStore.historyKey: WatchStore.encodeEntries(<WatchSnapshot>[
        history,
        ?historyOlder,
      ]),
    if (favorite != null)
      WatchStore.favoritesKey: WatchStore.encodeEntries(<WatchSnapshot>[
        favorite,
      ]),
  });
}

/// 追加用例的固定快照：甲最新（at 2000）、乙更早（at 1000）、丙是收藏。
const WatchSnapshot _storeDramaA = WatchSnapshot(
  seriesId: 'store-drama-a',
  title: '存储剧甲',
  category: '都市',
  kind: '短剧',
  episodes: 80,
  coverColorsSeed: 'store-drama-a存储剧甲',
  lastEpisodeNumber: 3,
  lastEpisodeTitle: '初入都市',
  progressSeconds: 90,
  durationSeconds: 200,
  lastWatchAt: 2000,
);

const WatchSnapshot _storeDramaB = WatchSnapshot(
  seriesId: 'store-drama-b',
  title: '存储剧乙',
  category: '古装',
  kind: '短剧',
  episodes: 66,
  coverColorsSeed: 'store-drama-b存储剧乙',
  lastEpisodeNumber: 7,
  lastEpisodeTitle: '王爷别闹',
  progressSeconds: 60,
  durationSeconds: 200,
  lastWatchAt: 1000,
);

const WatchSnapshot _storeFavorite = WatchSnapshot(
  seriesId: 'store-favorite-c',
  title: '收藏剧丙',
  category: '爱情',
  kind: '短剧',
  episodes: 52,
  coverColorsSeed: 'store-favorite-c收藏剧丙',
  lastEpisodeNumber: 1,
  lastEpisodeTitle: '夏天的海',
  progressSeconds: 0,
  durationSeconds: 0,
  lastWatchAt: 500,
);

void _noop() {}

class _MiniPlayerBackend extends media.PlatformPlayer {
  _MiniPlayerBackend() : super(configuration: const media.PlayerConfiguration());

  int opens = 0;
  bool failOpen = false;
  Duration? lastSeek;

  void setDuration(Duration duration) {
    state = state.copyWith(duration: duration);
    durationController.add(duration);
  }

  @override
  Future<void> seek(Duration duration) async {
    lastSeek = duration;
  }

  void setVideoSize(int width, int height, {int rotate = 0}) {
    videoParamsController.add(
      media.VideoParams(dw: width, dh: height, rotate: rotate),
    );
  }

  void setPlaying(bool playing) {
    playingController.add(playing);
  }

  @override
  Future<void> open(media.Playable playable, {bool play = true}) async {
    opens++;
    videoParamsController.add(const media.VideoParams());
    if (failOpen) throw StateError('open failed');
  }

  Future<void> setProperty(String key, String value) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {}
}

void _absorbTab(FollowingTab _) {}

/// 固定返回多季聚合数据，验证详情页季 Tab 的交互数据流。
class _RecommendCatalog extends MockCatalogRepository {
  _RecommendCatalog(this.detail);

  final SeriesDetailData detail;

  @override
  Future<SeriesDetailData> seriesDetail(String seriesId) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return detail;
  }
}

class _MultiSeasonCatalog extends MockCatalogRepository {
  _MultiSeasonCatalog({required this.detail});

  final SeriesDetailData detail;

  @override
  Future<SeriesDetailData> seriesDetail(String seriesId) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return detail;
  }
}

/// 「season-two」返回 6 集，其余 seriesId 走 mock 实现，便于断言切季后重拉。
class _SeasonPlaybackRepository extends MockPlaybackRepository {
  @override
  Future<List<EpisodeInfo>> episodes(String seriesId) async {
    if (seriesId != 'season-two') {
      return super.episodes(seriesId);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return List<EpisodeInfo>.generate(6, (int i) {
      return EpisodeInfo(
        id: 'season-two-ep${i + 1}',
        seriesId: seriesId,
        number: i + 1,
        title: '第${i + 1}集',
        playable: true,
      );
    });
  }
}
