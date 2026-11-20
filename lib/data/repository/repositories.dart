/// 数据仓库契约。UI 只依赖这些接口与 App 域模型；
/// 实现有三个：SDK 直连 / mock 演示 /（未来）自建后端 HTTP。
///
/// 仓库层负责：错误统一翻译为 [ApiException]、播放结果缓存、敏感调用节流。
library;

import '../../models/catalog.dart';
import '../../models/danmaku_cue.dart';
import '../../models/drama.dart';
import '../../models/playback.dart';
import '../../models/series_detail.dart';

/// 发现 / 搜索。
abstract class CatalogRepository {
  /// 首页频道流的一页。[channelLabel] 为 UI 频道名（推荐/短剧/电影…），
  /// 无映射或映射失败的频道抛 [UnsupportedError] 由调用方降级。
  ///
  /// 首次取第一页传空 [cursor]；「换一换」把上一页的 [DramaPage.cursor]
  /// 原样传回即可拿到下一批内容，[DramaPage.hasMore] 为 false 表示已到底。
  Future<DramaPage> discoverFeed(String channelLabel, {String cursor = ''});

  /// 关键词搜索的一页。第一页传空 [cursor]；[SearchPage.cursor] 为下一页游标，
  /// [SearchPage.hasMore] 为 false 时表示已到底。
  Future<SearchPage> searchPage(
    String query, {
    String cursor = '',
    int pageSize = 20,
  });

  /// 搜索联想词。
  Future<List<String>> suggest(String prefix);

  /// 搜索首页：猜你想搜 + 热搜榜。
  Future<SearchHome> searchHome();

  /// 分类落地页：题材 + 剧集。
  Future<List<Drama>> categorySeries(String categoryId);

  /// 按筛选条件取剧集（shortFilter）。
  Future<List<Drama>> filter({Map<String, List<String>>? selections});

  /// 分类筛选面板（题材/状态/排序等维度）。
  Future<List<FilterGroupData>> filterPanel();

  /// 详情页聚合：完整剧集数据 + 多季 + 相关推荐。
  Future<SeriesDetailData> seriesDetail(String seriesId);

  /// 上新日历（[date] 为 YYYYMMDD，空取今日）。
  Future<List<Drama>> newReleases({String? date});
}

/// 榜单。
abstract class RankRepository {
  /// 榜单页：Tab（内容/榜单）与条目。无参调用返回默认榜单。
  Future<RankPage> rankPage({String? contentId, String? boardId});
}

/// 分集与播放。
abstract class PlaybackRepository {
  /// 某部短剧的公开分集列表。
  Future<List<EpisodeInfo>> episodes(String seriesId);

  /// 解析一集的播放模型（含内容密钥）。
  /// 匿名设备基本只能解析一次，结果按 episodeId 缓存复用。
  Future<PlaybackBundle> resolve(String episodeId);

  /// 丢弃某集的解析缓存。全档位 bytevc2 等无法解码时，重解析有机会
  /// 换到可解码流（服务端按解析时机切换编码，issue #8）。
  void invalidate(String episodeId) {}

  /// 一集的弹幕，按出现时间排序。分页在仓库层翻完；
  /// 拉取失败返回空列表（弹幕是锦上添花，不该影响播放）。
  Future<List<DanmakuCue>> danmaku(String seriesId, String episodeId);
}

/// 搜索结果的一页：条目 + 下一页游标。
class SearchPage {
  const SearchPage({
    required this.items,
    required this.cursor,
    required this.hasMore,
  });

  final List<Drama> items;
  final String cursor;
  final bool hasMore;
}
