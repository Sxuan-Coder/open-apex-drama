import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 播放器实例及其视频输出；没有原生视频输出时 [controller] 为 null。
typedef PlayerBundle = ({Player player, VideoController? controller});

/// 播放页与「看剧」信息流共用的播放器依赖。
///
/// 生产环境用 [live]：真实的 media_kit 播放器和系统时钟。widget 测试没有
/// media_kit 的原生库，用 [platformPlayerFactory] 注入假的 `PlatformPlayer`，
/// 让开流 / 停播 / 播完这些真实链路能在测试里跑通。
@immutable
class PlayerEnvironment {
  const PlayerEnvironment({
    this.now = DateTime.now,
    this.platformPlayerFactory,
  });

  static const PlayerEnvironment live = PlayerEnvironment();

  /// 墙钟：定时关闭据此计算剩余时间。
  final DateTime Function() now;

  /// 替换 media_kit 的原生播放器实现；为 null 时创建真实播放器。
  final PlatformPlayer Function()? platformPlayerFactory;

  /// 创建播放器及其视频输出。
  ///
  /// 注入的实现没有原生视频输出，不建 [VideoController]（它依赖原生播放器的
  /// 初始化时序），画面位置显示封面。
  PlayerBundle createPlayer(VideoControllerConfiguration configuration) {
    final PlatformPlayer? platform = platformPlayerFactory?.call();
    if (platform != null) {
      return (player: Player(platformPlayer: platform), controller: null);
    }
    final Player player = Player();
    try {
      return (
        player: player,
        controller: VideoController(player, configuration: configuration),
      );
    } catch (_) {
      // 建不出视频输出时把刚建的播放器放掉：异常抛出后调用方拿不到它，
      // 不清理就泄漏一个原生播放器（与提取前两处调用方的兜底一致）。
      try {
        unawaited(player.dispose());
      } catch (_) {}
      rethrow;
    }
  }
}
