import 'dart:math' as math;

import '../../models/catalog.dart';
import '../../models/danmaku_cue.dart';
import '../../models/drama.dart';
import '../../models/drama_category.dart';
import '../../models/playback.dart';
import '../../models/series_detail.dart';
import '../mock_data.dart';
import 'repositories.dart';

/// mock 演示数据实现：离线兜底与测试用。
class MockCatalogRepository implements CatalogRepository {
  /// 演示分页的每页条数：让 12 部演示数据正好分成两页，
  /// 首页与「换一换」都能观察到内容变化。
  static const int _discoverPageSize = 6;

  @override
  Future<DramaPage> discoverFeed(
    String channelLabel, {
    String cursor = '',
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final List<Drama> all = channelLabel == '推荐'
        ? mockDramas
        : mockDramas.where((Drama d) => d.kind == channelLabel).toList();
    // 游标就是下一页的起始下标；演示数据按固定页大小切分。
    final int start = int.tryParse(cursor) ?? 0;
    if (start >= all.length) {
      return const DramaPage(items: <Drama>[]);
    }
    final int end = math.min(start + _discoverPageSize, all.length);
    final bool hasMore = end < all.length;
    return DramaPage(
      items: all.sublist(start, end),
      cursor: hasMore ? '$end' : '',
      hasMore: hasMore,
    );
  }

  @override
  Future<SearchPage> searchPage(
    String query, {
    String cursor = '',
    int pageSize = 20,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // 演示模式一次性返回全部结果，游标留空表示没有更多页。
    final List<Drama> all =
        mockDramas.where((Drama d) => d.title.contains(query)).toList();
    return SearchPage(items: all, cursor: '', hasMore: false);
  }

  @override
  Future<List<String>> suggest(String prefix) async {
    return <String>['$prefix 短剧', '$prefix 完结', '$prefix 第一季'];
  }

  @override
  Future<SearchHome> searchHome() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return SearchHome(
      guesses: <SearchCandidate>[
        for (final Drama drama in mockDramas.take(6))
          SearchCandidate(text: drama.title),
      ],
      hotBoard: <SearchCandidate>[
        for (final Drama drama in mockFeatured)
          SearchCandidate(text: drama.title, score: '${drama.ratingLabel}分'),
      ],
    );
  }

  @override
  Future<List<Drama>> categorySeries(String categoryId) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return mockDramas
        .where((Drama d) => d.category == categoryId || d.kind == categoryId)
        .toList();
  }

  @override
  Future<List<Drama>> filter({Map<String, List<String>>? selections}) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final List<String> genres = selections?['genre'] ?? const <String>[];
    if (genres.isEmpty) {
      return mockDramas;
    }
    return mockDramas
        .where((Drama d) => genres.contains(d.category))
        .toList();
  }

  @override
  Future<List<FilterGroupData>> filterPanel() async {
    return <FilterGroupData>[
      FilterGroupData(
        key: 'genre',
        name: '题材',
        options: <(String, String)>[
          for (final DramaCategory category in mockCategories)
            (category.name, category.name),
        ],
      ),
    ];
  }

  @override
  Future<SeriesDetailData> seriesDetail(String seriesId) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final List<Drama> matches =
        mockDramas.where((Drama d) => d.id == seriesId).toList();
    final Drama drama = matches.isNotEmpty ? matches.first : mockDramas.first;
    return SeriesDetailData(
      drama: drama,
      recommend: mockDramas
          .where((Drama d) => d.id != drama.id)
          .take(6)
          .toList(growable: false),
    );
  }

  @override
  Future<List<Drama>> newReleases({String? date}) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return mockDramas.reversed.take(8).toList(growable: false);
  }
}

/// mock 榜单：按剧的评分/热度排几个榜。
class MockRankRepository implements RankRepository {
  @override
  Future<RankPage> rankPage({String? contentId, String? boardId}) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final List<Drama> sorted = <Drama>[...mockDramas]..sort(
        (Drama a, Drama b) => b.rating.compareTo(a.rating),
      );
    return RankPage(
      tabs: const <RankTab>[
        RankTab(label: '热播榜', selected: true),
        RankTab(label: '新剧榜'),
        RankTab(label: '完结榜'),
      ],
      entries: <RankEntry>[
        for (int i = 0; i < sorted.length; i++)
          RankEntry(
            rank: i + 1,
            score: '${sorted[i].ratingLabel}分',
            drama: sorted[i],
          ),
      ],
    );
  }
}

class MockPlaybackRepository implements PlaybackRepository {
  /// 公共测试流（Big Buck Bunny HLS），用于离线验证播放器链路。
  static const String _testHls =
      'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

  @override
  Future<List<EpisodeInfo>> episodes(String seriesId) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final List<Drama> matches =
        mockDramas.where((Drama d) => d.id == seriesId).toList(growable: false);
    if (matches.isEmpty) {
      return const <EpisodeInfo>[];
    }
    final Drama drama = matches.first;
    final int count = drama.episodeTitles.isEmpty ? 6 : drama.episodeTitles.length;
    return List<EpisodeInfo>.generate(count, (int i) {
      return EpisodeInfo(
        id: '${drama.id}-ep${i + 1}',
        seriesId: drama.id,
        number: i + 1,
        title: drama.episodeTitle(i + 1),
        playable: true,
      );
    });
  }

  @override
  @override
  Future<PlaybackBundle> resolve(String episodeId) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return PlaybackBundle(
      episodeId: episodeId,
      streams: const <StreamInfo>[
        StreamInfo(
          definition: '720p',
          url: _testHls,
          backupUrl: '',
          width: 1280,
          height: 720,
          hls: true,
        ),
      ],
      contentKeyHex: '',
      durationSeconds: 888,
    );
  }

  @override
  void invalidate(String episodeId) {}
  @override
  Future<List<DanmakuCue>> danmaku(String seriesId, String episodeId) async {
    return const <DanmakuCue>[];
  }

}
