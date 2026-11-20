import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:openhongguo/openhongguo.dart';

import '../../models/catalog.dart';
import '../../models/danmaku_cue.dart';
import '../../models/drama.dart';
import '../../models/playback.dart';
import '../../models/series_detail.dart';
import '../mappers.dart';
import '../remote/openhongguo_service.dart';
import 'repositories.dart';

/// 基于水果端 SDK 的实现。
class SdkCatalogRepository implements CatalogRepository {
  SdkCatalogRepository({OpenhongguoService? service})
      : _service = service ?? OpenhongguoService.instance;

  final OpenhongguoService _service;

  Future<T> _guard<T>(Future<T> Function(OpenhongguoClient client) run) async {
    try {
      final OpenhongguoClient client = await _service.client();
      return await run(client);
    } catch (error) {
      throw OpenhongguoService.translate(error);
    }
  }

  @override
  Future<DramaPage> discoverFeed(String channelLabel, {String cursor = ''}) {
    final String? channel = kDiscoverChannels[channelLabel];
    if (channel == null) {
      throw UnsupportedError('频道「$channelLabel」暂未接入 SDK');
    }
    return _guard<DramaPage>((OpenhongguoClient client) async {
      final PagedResult<SeriesSummary> page = await client.discover(
        DiscoverOptions(
          channel: channel,
          cursor: cursor.isEmpty ? null : cursor,
        ),
      );
      debugPrint(
        '[discover:$channelLabel${cursor.isEmpty ? '' : ':cursor'}] '
        '${page.items.length} 部: '
        '${page.items.take(5).map((SeriesSummary s) => s.title).join(' / ')}',
      );
      return DramaPage(
        items: <Drama>[
          for (final SeriesSummary item in page.items)
            dramaFromSummary(item, kind: channelLabel),
        ],
        cursor: page.cursor,
        hasMore: page.hasMore && page.cursor.isNotEmpty,
      );
    });
  }



  @override
  Future<SearchPage> searchPage(
    String query, {
    String cursor = '',
    int pageSize = 20,
  }) {
    return _guard<SearchPage>((OpenhongguoClient client) async {
      final PagedResult<SeriesSummary> page = await client.search(
        query,
        SearchOptions(
          cursor: cursor.isEmpty ? null : cursor,
          pageSize: pageSize,
        ),
      );
      final Map<String, String> covers = await _searchCovers(
        client,
        page.items,
      );
      return SearchPage(
        items: <Drama>[
          for (final SeriesSummary item in page.items)
            dramaFromSummary(item, coverUrl: covers[item.id]),
        ],
        cursor: page.cursor,
        hasMore: page.hasMore && page.cursor.isNotEmpty,
      );
    });
  }


  /// 搜索接口不返回封面（SDK 的 ParseSearch 只映射 id/标题/简介/集数），
  /// 直接渲染会整屏渐变色块。这里用一次 getSeriesBatch 批量补齐；
  /// 补不到或批量接口失败时保持无封面，不影响搜索结果本身。
  static Future<Map<String, String>> _searchCovers(
    OpenhongguoClient client,
    List<SeriesSummary> items,
  ) async {
    final List<String> ids = <String>[
      for (final SeriesSummary item in items)
        if (item.id.isNotEmpty && item.coverUrl.isEmpty) item.id,
    ];
    if (ids.isEmpty) {
      return const <String, String>{};
    }
    try {
      final List<SeriesDetail> details = await client.getSeriesBatch(ids);
      return <String, String>{
        for (final SeriesDetail detail in details)
          if (detail.series != null &&
              detail.series!.id.isNotEmpty &&
              detail.series!.coverUrl.isNotEmpty)
            detail.series!.id: detail.series!.coverUrl,
      };
    } catch (_) {
      return const <String, String>{};
    }
  }

  @override
  Future<List<String>> suggest(String prefix) {
    return _guard<List<String>>((OpenhongguoClient client) async {
      final List<Suggestion> items = await client.suggest(prefix);
      return <String>[
        for (final Suggestion s in items) s.text.isEmpty ? s.keyword : s.text,
      ];
    });
  }

  @override
  Future<SearchHome> searchHome() {
    return _guard<SearchHome>((OpenhongguoClient client) async {
      final HotSearch hot = await client.hotSearch();
      return SearchHome(
        guesses: <SearchCandidate>[
          for (final HotItem item in hot.guesses)
            SearchCandidate(
              text: item.title,
              seriesId: item.seriesId,
              coverUrl: item.coverUrl,
              episodeCount: item.episodeCount,
            ),
        ],
        hotBoard: <SearchCandidate>[
          if (hot.boards.isNotEmpty)
            for (final HotItem item in hot.boards.first.items)
              SearchCandidate(
                text: item.title,
                seriesId: item.seriesId,
                coverUrl: item.coverUrl,
                episodeCount: item.episodeCount,
                score: item.searchScore,
              ),
        ],
      );
    });
  }

  @override
  Future<List<Drama>> categorySeries(String categoryId) {
    return _guard<List<Drama>>((OpenhongguoClient client) async {
      final CategoryPage page = await client.categoryLanding(categoryId);
      return <Drama>[
        for (final SeriesSummary item in page.items) dramaFromSummary(item),
      ];
    });
  }

  @override
  Future<List<Drama>> filter({Map<String, List<String>>? selections}) {
    return _guard<List<Drama>>((OpenhongguoClient client) async {
      final ShortFilterPage page = await client.shortFilter(
        ShortFilterQuery(selections: selections),
      );
      return <Drama>[
        for (final SeriesSummary item in page.items) dramaFromSummary(item),
      ];
    });
  }

  @override
  Future<List<FilterGroupData>> filterPanel() {
    return _guard<List<FilterGroupData>>((OpenhongguoClient client) async {
      final List<FilterRow> rows = await client.shortFilterPanel();
      return <FilterGroupData>[
        for (final FilterRow row in rows)
          FilterGroupData(
            key: row.key,
            name: row.name,
            options: <(String, String)>[
              for (final FilterOption option in row.options)
                (option.name, option.value),
            ],
          ),
      ];
    });
  }

  @override
  Future<SeriesDetailData> seriesDetail(String seriesId) {
    return _guard<SeriesDetailData>((OpenhongguoClient client) async {
      // 三个请求并行；多季接口对单季剧会失败，容忍为空。
      final List<dynamic> results = await Future.wait(<Future<dynamic>>[
        client.getSeries(seriesId),
        client.seriesRecommend(seriesId),
        client
            .seasons(seriesId)
            .catchError((Object _) => Album()),
      ]);
      final Series series = results[0] as Series;
      final Recommend recommend = results[1] as Recommend;
      final Album album = results[2] as Album;
      return SeriesDetailData(
        drama: dramaFromSeries(series),
        seasons: <SeasonInfo>[
          for (final Season season in album.seasons)
            SeasonInfo(
              seriesId: season.seriesId,
              title: season.title,
              index: season.index,
              episodeCount: season.episodeCount,
            ),
        ],
        recommend: <Drama>[
          for (final SeriesSummary item in recommend.items)
            dramaFromSummary(item),
        ],
        isMultiSeason: series.isMultiSeason,
        relatedAlbumId: series.relatedAlbumId,
        payType: series.payType.value,
      );
    });
  }

  @override
  Future<List<Drama>> newReleases({String? date}) {
    return _guard<List<Drama>>((OpenhongguoClient client) async {
      final NewReleasePage page = await client.newReleases(
        NewReleaseQuery(date: date),
      );
      return <Drama>[
        for (final NewRelease item in page.items)
          Drama(
            id: item.seriesId,
            title: item.title,
            kind: '短剧',
            category:
                item.categories.isNotEmpty ? item.categories.first : '短剧',
            tags: item.categories,
            episodes: item.episodeCount,
            rating: 0,
            viewers: '',
            description: item.description,
            coverColors: paletteFor(item.seriesId + item.title),
            coverUrl: item.coverUrl,
            episodeTitles: const <String>[],
            badge: publishBadge(item.publishAt),
          ),
      ];
    });
  }
}

/// 榜单：短剧榜（contents/boards 提供 Tab，items 提供条目）。
class SdkRankRepository implements RankRepository {
  SdkRankRepository({OpenhongguoService? service})
      : _service = service ?? OpenhongguoService.instance;

  final OpenhongguoService _service;

  @override
  Future<RankPage> rankPage({String? contentId, String? boardId}) async {
    try {
      final OpenhongguoClient client = await _service.client();
      final ShortRanking ranking = await client.shortRank(
        ShortRankQuery(content: contentId, board: boardId),
      );
      return RankPage(
        tabs: <RankTab>[
          for (final RankContent content in ranking.contents)
            for (final RankBoard board in content.boards)
              RankTab(
                label: board.name,
                contentId: content.id,
                boardId: board.id,
                selected: content.selected || board.selected,
              ),
        ],
        entries: <RankEntry>[
          // 注意用 position（页面名次，从 1 开始）而非 rank（服务端编号，
          // 推广行前后重复、推荐榜个性化、预约榜可能全 0——v1.1.0 显示
          // 1,1,2,3… 与全 0 的根因）。position 异常时回退行序。
          for (final (int index, RankItem item) in ranking.items.indexed)
            RankEntry(
              rank: item.position > 0
                  ? item.position
                  : (item.rank > 0 ? item.rank : index + 1),
              score: item.score,
              actor: item.actor,
              drama: dramaFromSummary(
                SeriesSummary(
                  id: item.seriesId,
                  title: item.title,
                  coverUrl: item.coverUrl,
                ),
              ),
            ),
        ],
      );
    } catch (error) {
      throw OpenhongguoService.translate(error);
    }
  }
}

/// 播放解析：按分集缓存结果（匿名设备额度有限，绝不重复解析）。
class SdkPlaybackRepository implements PlaybackRepository {
  SdkPlaybackRepository({OpenhongguoService? service})
      : _service = service ?? OpenhongguoService.instance;

  final OpenhongguoService _service;
  final Map<String, PlaybackBundle> _cache = <String, PlaybackBundle>{};

  Future<T> _guard<T>(Future<T> Function(OpenhongguoClient client) run) async {
    try {
      final OpenhongguoClient client = await _service.client();
      return await run(client);
    } catch (error) {
      throw OpenhongguoService.translate(error);
    }
  }

  @override
  Future<List<EpisodeInfo>> episodes(String seriesId) async {
    try {
      return await _guard<List<EpisodeInfo>>((OpenhongguoClient client) async {
        // listEpisodes 是分页接口（默认一页 20 条），必须按 cursor 翻页
        // 拉全，否则百集剧只显示首页 20 集。上限防御：单剧最多 50 页。
        final List<EpisodeInfo> all = <EpisodeInfo>[];
        String? cursor;
        for (int page = 0; page < 50; page++) {
          final PagedResult<Episode> result = await client.listEpisodes(
            seriesId,
            EpisodeOptions(cursor: cursor, pageSize: 100),
          );
          all.addAll(<EpisodeInfo>[
            for (final Episode e in result.items) episodeInfoFrom(e),
          ]);
          if (!result.hasMore || result.cursor.isEmpty) {
            break;
          }
          cursor = result.cursor;
        }
        return all;
      });
    } catch (error) {
      _logResolve('episodes fail series=$seriesId error=$error');
      rethrow;
    }
  }

  /// 解析重试退避：服务端播放接口会间歇性返回空结果或 5xx（实测成片出现，
  /// 几十秒后自愈），而 SDK 把空结果当成设备失效、每次都要换 2 台设备。
  /// App 侧先原地重试几次，能覆盖掉大部分抖动，避免直接给用户报错。
  static const List<Duration> _resolveBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 6),
  ];

  /// 这些错误码属于「服务端一时取不到」，值得重试；其余（内容下架、
  /// 需要登录等）重试也不会变好。
  static bool _retryableResolve(String code) {
    switch (code) {
      case 'ANONYMOUS_LIMITED':
      case 'DEVICE_REJECTED':
      case 'TRANSPORT':
      case 'RATE_LIMITED':
        return true;
      default:
        return false;
    }
  }

  @override
  Future<PlaybackBundle> resolve(String episodeId) async {
    final PlaybackBundle? cached = _cache[episodeId];
    if (cached != null) {
      return cached;
    }
    for (int attempt = 0; ; attempt++) {
      try {
        final PlaybackBundle bundle = await _guard<PlaybackBundle>(
          (OpenhongguoClient client) async {
            final PlaybackResult result =
                await client.resolvePlayback(episodeId);
            return bundleFrom(result);
          },
        );
        if (bundle.streams.isNotEmpty) {
          _cache[episodeId] = bundle;
        }
        // 记录各清晰度编码：bytevc2 等无法解码的编码会在播放器层
        // 黑屏，取址日志看不出问题，必须在这里留痕（issue #8）。
        final String codecs = bundle.streams
            .map((StreamInfo s) => '${s.definition}:${s.codec}')
            .join(',');
        _logResolve(
          'ok episode=$episodeId streams=${bundle.streams.length} codecs=$codecs'
          '${attempt > 0 ? ' retry=$attempt' : ''}',
        );
        return bundle;
      } on ApiException catch (error) {
        _logResolve(
          'fail episode=$episodeId attempt=$attempt error=$error',
        );
        if (!_retryableResolve(error.code) ||
            attempt >= _resolveBackoff.length) {
          rethrow;
        }
        await Future<void>.delayed(_resolveBackoff[attempt]);
      }
    }
  }

  @override
  void invalidate(String episodeId) {
    _cache.remove(episodeId);
  }

  @override
  Future<List<DanmakuCue>> danmaku(String seriesId, String episodeId) async {
    try {
      return await _guard<List<DanmakuCue>>((OpenhongguoClient client) async {
        final List<DanmakuCue> cues = <DanmakuCue>[];
        String cursor = '';
        // 服务端按播放时间分 30 秒一段下发，一集通常 2~6 页；
        // 上限 30 页防止异常情况下无限翻页。
        for (int page = 0; page < 30; page++) {
          final DanmakuPage result = await client.listDanmaku(
            seriesId,
            episodeId,
            DanmakuOptions(cursor: cursor.isEmpty ? null : cursor),
          );
          for (final Danmaku item in result.items) {
            final String text = item.text.trim();
            if (text.isNotEmpty) {
              cues.add(DanmakuCue(text: text, offsetMs: item.offsetMs));
            }
          }
          if (!result.hasMore || result.cursor.isEmpty) {
            break;
          }
          if (result.cursor == cursor) {
            break; // 游标没有推进，避免死循环
          }
          cursor = result.cursor;
        }
        cues.sort((DanmakuCue a, DanmakuCue b) => a.offsetMs - b.offsetMs);
        return cues;
      });
    } catch (error) {
      _logResolve('danmaku fail series=$seriesId episode=$episodeId error=$error');
      return const <DanmakuCue>[];
    }
  }

  /// 播放解析诊断日志。写入系统临时目录的 `apex-resolve.log`。
  ///
  /// 线上「匿名设备次数已用尽」这类报错只有错误码，看不出是哪一集、
  /// 失败在分集列表还是播放解析上，出问题时要靠这份日志定位。
  static void _logResolve(String line) {
    final String stamp = DateTime.now().toIso8601String();
    debugPrint('[resolve] $line');
    try {
      File('${Directory.systemTemp.path}/apex-resolve.log').writeAsStringSync(
        '$stamp $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 日志写失败不影响播放。
    }
  }
}
