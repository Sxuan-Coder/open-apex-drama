import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/mock_data.dart';
import '../models/drama.dart';
import '../models/playback.dart';
import '../player/player_environment.dart';
import '../player/video_output.dart';
import '../providers/data_providers.dart';
import '../theme/app_colors.dart';
import '../widgets/watch_feed_page.dart';
import 'player_screen.dart';

/// 「看剧」Tab：全屏竖向推荐流，当前剧自动播放，下一部提前预加载。
///
/// 封面只作为加载/解析失败时的兜底；正常情况直接播放第一集。
/// 「看全集」直接进入播放页，不经过作品详情页。
class WatchFeedScreen extends ConsumerStatefulWidget {
  const WatchFeedScreen({
    super.key,
    this.active = true,
    this.environment = PlayerEnvironment.live,
  });

  /// 当前 Tab 是否在前台。IndexedStack 会同时构建所有 Tab，
  /// 只有 active 时才解析/播放，避免启动即消耗解析额度。
  final bool active;

  /// 播放器依赖：时钟与播放器工厂（与播放页共用），widget 测试注入假实现。
  final PlayerEnvironment environment;

  @override
  ConsumerState<WatchFeedScreen> createState() => _WatchFeedScreenState();
}

class _FeedMedia {
  _FeedMedia({
    required this.dramaId,
    required this.player,
    required this.controller,
    required this.bundle,
    required this.stream,
    required this.episodeCount,
  });

  final String dramaId;
  final Player player;

  /// 没有原生视频输出时为 null（见 [PlayerEnvironment.createPlayer]）。
  final VideoController? controller;
  final PlaybackBundle bundle;
  final StreamInfo stream;
  final int episodeCount;

  /// 首帧渲染完成前，页面继续盖封面，避免黑屏。
  bool ready = false;

  Future<void> dispose() async {
    try {
      await player.stop();
    } catch (_) {}
    try {
      await player.dispose();
    } catch (_) {}
  }
}

class _WatchFeedScreenState extends ConsumerState<WatchFeedScreen> {
  static const HomeFeedKey _feedKey = HomeFeedKey('推荐');

  final PageController _controller = PageController();
  List<Drama> _feed = mockDramas;
  String _cursor = '';
  bool _hasMore = false;
  bool _initialized = false;
  bool _loadingMore = false;
  _FeedMedia? _current;
  _FeedMedia? _next;
  int _index = 0;
  int _loadToken = 0;
  bool _loading = false;
  bool _muted = false;
  bool _scheduledCurrent = false;
  bool _autoplayAllowed = false;

  /// 解析失败的剧不再每帧重试，避免降级数据刷爆接口；用户点画面可手动重试。
  final Set<String> _failed = <String>{};

  @override
  void dispose() {
    _loadToken++;
    unawaited(_current?.dispose());
    unawaited(_next?.dispose());
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant WatchFeedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      final Drama? drama = _currentDrama();
      if (drama != null) {
        _failed.remove(drama.id);
        unawaited(_ensureCurrent(drama));
      }
    } else if (!widget.active && oldWidget.active) {
      _current?.player.pause();
      final _FeedMedia? preload = _next;
      _next = null;
      unawaited(preload?.dispose());
      if (mounted) {
        setState(() {});
      }
    }
  }

  Drama? _currentDrama() {
    if (_feed.isEmpty) {
      return null;
    }
    return _feed[_index.clamp(0, _feed.length - 1)];
  }

  void _scheduleEnsureCurrent() {
    if (!widget.active ||
        !_autoplayAllowed ||
        _feed.isEmpty ||
        _loading ||
        _scheduledCurrent) {
      return;
    }
    final Drama drama = _currentDrama()!;
    if (_current?.dramaId == drama.id || _failed.contains(drama.id)) {
      return;
    }
    _scheduledCurrent = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduledCurrent = false;
      if (!mounted || !widget.active) {
        return;
      }
      unawaited(_ensureCurrent(drama));
    });
  }

  Future<void> _ensureCurrent(Drama drama) async {
    if (!widget.active ||
        !_autoplayAllowed ||
        _failed.contains(drama.id)) {
      return;
    }
    if (_current?.dramaId == drama.id && _current!.ready) {
      _current!.player.setVolume(_muted ? 0 : 100);
      _current!.player.play();
      if (_next == null) {
        unawaited(_preloadNext());
      }
      return;
    }
    final int token = ++_loadToken;
    _loading = true;
    final _FeedMedia? oldCurrent = _current;
    final _FeedMedia? oldNext = _next;
    _current = null;
    _next = null;
    if (mounted) {
      setState(() {});
    }
    await oldCurrent?.dispose();
    await oldNext?.dispose();

    final _FeedMedia? media = await _prepareMedia(drama);
    if (!mounted || token != _loadToken || !widget.active) {
      await media?.dispose();
      return;
    }
    if (media == null) {
      _loading = false;
      _failed.add(drama.id);
      if (mounted) {
        setState(() {});
      }
      return;
    }
    // 先把 controller 挂到页面，让 Video 进树并建立 Surface；
    // 首帧完成前页面仍盖着封面。
    _current = media;
    _failed.remove(drama.id);
    if (mounted) {
      setState(() {});
    }
    final bool ok = await _openMedia(media, autoplay: true);
    if (!mounted || token != _loadToken || !widget.active) {
      _current = null;
      await media.dispose();
      return;
    }
    _loading = false;
    if (!ok) {
      _current = null;
      _failed.add(drama.id);
      await media.dispose();
      if (mounted) {
        setState(() {});
      }
      return;
    }
    media.ready = true;
    if (mounted) {
      setState(() {});
    }
    unawaited(_preloadNext());
  }

  Future<void> _preloadNext() async {
    if (!widget.active || !_autoplayAllowed || _loading) {
      return;
    }
    final int nextIndex = _index + 1;
    if (nextIndex < 0 || nextIndex >= _feed.length) {
      if (nextIndex >= _feed.length) {
        unawaited(_loadMore());
      }
      return;
    }
    final Drama next = _feed[nextIndex];
    if (_next?.dramaId == next.id ||
        _current?.dramaId == next.id ||
        _failed.contains(next.id)) {
      return;
    }
    final int token = _loadToken;
    final _FeedMedia? media = await _prepareMedia(next);
    if (!mounted || token != _loadToken || !widget.active) {
      await media?.dispose();
      return;
    }
    if (media == null) {
      _failed.add(next.id);
      return;
    }
    final _FeedMedia? old = _next;
    _next = media;
    if (mounted) {
      setState(() {});
    }
    final bool ok = await _openMedia(media, autoplay: false);
    if (!mounted || token != _loadToken || !widget.active) {
      _next = null;
      await media.dispose();
      return;
    }
    if (!ok) {
      _next = null;
      _failed.add(next.id);
      await media.dispose();
      if (mounted) {
        setState(() {});
      }
      return;
    }
    media.ready = true;
    await old?.dispose();
    if (mounted) {
      setState(() {});
    }
  }

  /// 自动翻页：游标来自上一页，追加去重后的新推荐。
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _cursor.isEmpty) {
      return;
    }
    _loadingMore = true;
    try {
      final HomeFeed next = await ref.read(
        homeFeedProvider(HomeFeedKey('推荐', _cursor)).future,
      );
      if (!mounted) {
        return;
      }
      final Set<String> known = _feed.map((Drama d) => d.id).toSet();
      final List<Drama> more = next.items
          .where((Drama d) => !known.contains(d.id))
          .toList(growable: false);
      if (more.isEmpty && next.cursor == _cursor) {
        _hasMore = false;
        return;
      }
      setState(() {
        _feed = <Drama>[..._feed, ...more];
        _cursor = next.cursor;
        _hasMore = next.hasMore;
      });
    } catch (_) {
      // 下一页失败不影响已加载内容，继续滑动可再次触发。
    } finally {
      _loadingMore = false;
    }
  }

  Future<_FeedMedia?> _prepareMedia(Drama drama) async {
    Player? player;
    try {
      final repo = ref.read(playbackRepositoryProvider);
      final List<EpisodeInfo> episodes = await repo.episodes(drama.id);
      if (episodes.isEmpty) {
        return null;
      }
      final EpisodeInfo first = episodes.firstWhere(
        (EpisodeInfo item) => item.playable,
        orElse: () => episodes.first,
      );
      final PlaybackBundle bundle = await repo.resolve(first.id);
      final StreamInfo? stream = bundle.preferred ??
          (bundle.streams.isEmpty ? null : bundle.streams.first);
      if (stream == null || stream.url.isEmpty) {
        return null;
      }
      final PlayerBundle created = widget.environment.createPlayer(
        videoOutputConfiguration(defaultVideoOutputMode()),
      );
      player = created.player;
      return _FeedMedia(
        dramaId: drama.id,
        player: created.player,
        controller: created.controller,
        bundle: bundle,
        stream: stream,
        episodeCount: episodes.length,
      );
    } catch (_) {
      try {
        await player?.dispose();
      } catch (_) {}
      return null;
    }
  }

  Future<bool> _openMedia(
    _FeedMedia media, {
    required bool autoplay,
  }) async {
    try {
      // 页面已先挂上 Video/Surface，再 open。
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (media.bundle.hasKey) {
        await (media.player.platform as dynamic).setProperty(
          'demuxer-lavf-o',
          'decryption_key=${media.bundle.contentKeyHex}',
        );
      }
      await (media.player.platform as dynamic).setProperty(
        'user-agent',
        kCdnUserAgent,
      );
      await media.player.setVolume(0);
      await media.player.open(Media(media.stream.url), play: false);
      bool rendered = true;
      await media.controller?.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 6),
        onTimeout: () {
          rendered = false;
        },
      );
      if (!rendered) {
        return false;
      }
      if (autoplay) {
        await media.player.setVolume(_muted ? 0 : 100);
        await media.player.play();
      } else {
        await media.player.pause();
        await media.player.setVolume(0);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
    if (!widget.active) {
      return;
    }
    // 接近列表尾部时自动取下一页推荐，形成无限刷。
    if (index >= _feed.length - 2) {
      unawaited(_loadMore());
    }
    final Drama drama = _feed[index];
    final _FeedMedia? promoted = _next;
    if (promoted != null &&
        promoted.dramaId == drama.id &&
        promoted.ready) {
      final _FeedMedia? old = _current;
      _current = promoted;
      _next = null;
      _loadToken++;
      if (mounted) {
        setState(() {});
      }
      unawaited(old?.dispose());
      promoted.player.setVolume(_muted ? 0 : 100);
      promoted.player.play();
      unawaited(_preloadNext());
      return;
    }
    // 预加载失败过的剧，用户切到这一页时再试一次。
    _failed.remove(drama.id);
    unawaited(_ensureCurrent(drama));
  }

  void _togglePlay() {
    final _FeedMedia? media = _current;
    if (media == null) {
      final Drama? drama = _currentDrama();
      if (drama != null && _autoplayAllowed) {
        // 手动点画面时允许对失败的剧再试一次。
        _failed.remove(drama.id);
        unawaited(_ensureCurrent(drama));
      }
      return;
    }
    if (media.player.state.playing) {
      unawaited(media.player.pause());
    } else {
      unawaited(media.player.play());
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openFull(Drama drama) async {
    // 真实 feed 的 Drama.episodes 常为 0；用已解析到的分集数补齐，
    // 否则 openPlayer 会把它当成未开播直接拦截。
    final int count = _current?.episodeCount ?? drama.episodes;
    final Drama target = count > 0 && count != drama.episodes
        ? _withEpisodeCount(drama, count)
        : drama;
    unawaited(_current?.player.pause());
    final bool closedBySleepTimer = await openPlayer(
      context,
      target,
      assumePlayable: true,
      environment: widget.environment,
    );
    // 定时关闭退出的不恢复信息流：否则「已停止播放」的提示下面还在出声。
    if (!closedBySleepTimer && mounted && widget.active) {
      unawaited(_current?.player.play());
    }
  }

  Drama _withEpisodeCount(Drama drama, int count) {
    return Drama(
      id: drama.id,
      title: drama.title,
      kind: drama.kind,
      category: drama.category,
      tags: drama.tags,
      episodes: count,
      rating: drama.rating,
      viewers: drama.viewers,
      description: drama.description,
      coverColors: drama.coverColors,
      coverUrl: drama.coverUrl,
      episodeTitles: drama.episodeTitles,
      badge: drama.badge,
    );
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    unawaited(_current?.player.setVolume(_muted ? 0 : 100));
  }

  void _shuffle() {
    _loadToken++;
    final _FeedMedia? oldCurrent = _current;
    final _FeedMedia? oldNext = _next;
    _current = null;
    _next = null;
    _failed.clear();
    _initialized = false;
    _feed = mockDramas;
    _cursor = '';
    _hasMore = false;
    _loadingMore = false;
    unawaited(oldCurrent?.dispose());
    unawaited(oldNext?.dispose());
    _index = 0;
    ref.invalidate(homeFeedProvider(_feedKey));
    if (_controller.hasClients) {
      _controller.jumpToPage(0);
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<HomeFeed>>(homeFeedProvider(_feedKey), (
      AsyncValue<HomeFeed>? previous,
      AsyncValue<HomeFeed> next,
    ) {
      final List<Drama>? before = previous?.value?.items;
      final List<Drama>? after = next.value?.items;
      if (before != after) {
        _loadToken++;
        final _FeedMedia? oldCurrent = _current;
        final _FeedMedia? oldNext = _next;
        _current = null;
        _next = null;
        _failed.clear();
        _initialized = false;
        _feed = mockDramas;
        _cursor = '';
        _hasMore = false;
        _loadingMore = false;
        unawaited(oldCurrent?.dispose());
        unawaited(oldNext?.dispose());
      }
    });

    final AsyncValue<HomeFeed> feedAsync = ref.watch(
      homeFeedProvider(_feedKey),
    );
    final HomeFeed? first = feedAsync.value;
    if (!_initialized && first != null) {
      _initialized = true;
      _feed = first.items.isEmpty ? mockDramas : first.items;
      _cursor = first.items.isEmpty ? '' : first.cursor;
      _hasMore = first.items.isEmpty ? false : first.hasMore;
    }
    // 降级 mock 数据的 id 对真实 SDK 无效，只展示封面，不自动解析。
    _autoplayAllowed = first != null && !first.isFallback;
    final int total = _feed.length;
    if (total == 0) {
      return const ColoredBox(
        color: AppTokens.playerBackground,
        child: Center(
          child: Text('暂无推荐', style: TextStyle(color: Colors.white70)),
        ),
      );
    }
    _scheduleEnsureCurrent();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: AppTokens.playerBackground,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: ColoredBox(
        color: AppTokens.playerBackground,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            PageView.builder(
              controller: _controller,
              scrollDirection: Axis.vertical,
              itemCount: total,
              onPageChanged: _onPageChanged,
              itemBuilder: (BuildContext context, int page) {
                final Drama drama = _feed[page];
                // 只有当前剧在这一页挂 Video；下一部在屏幕外预热，
                // 避免 PageView 未构建相邻页时首帧等待超时。
                final _FeedMedia? media = _current?.dramaId == drama.id
                    ? _current
                    : (_next?.dramaId == drama.id ? _next : null);
                return WatchFeedPage(
                  drama: drama,
                  episodeCount: media?.episodeCount ?? drama.episodes,
                  player: media?.player,
                  controller: media?.controller,
                  ready: media?.ready ?? false,
                  isLast: page == total - 1,
                  onTogglePlay: _togglePlay,
                  onOpenFull: () => _openFull(drama),
                );
              },
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 44,
                  child: Stack(
                    children: <Widget>[
                      const Center(
                        child: Text(
                          '推荐',
                          style: TextStyle(
                            fontSize: 18,
                            height: 1.2,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 4,
                        top: 0,
                        bottom: 0,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              tooltip: _muted ? '取消静音' : '静音',
                              onPressed: _toggleMute,
                              icon: Icon(
                                _muted
                                    ? Icons.volume_off_rounded
                                    : Icons.volume_up_rounded,
                                size: 21,
                                color: Colors.white,
                              ),
                            ),
                            IconButton(
                              tooltip: '换一批',
                              onPressed: _shuffle,
                              icon: const Icon(
                                Icons.refresh_rounded,
                                size: 22,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
