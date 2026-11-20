import 'package:flutter/material.dart';

/// 一条公开列出的分集（来自 listEpisodes）。
@immutable
class EpisodeInfo {
  const EpisodeInfo({
    required this.id,
    required this.seriesId,
    required this.number,
    required this.title,
    required this.playable,
  });

  final String id;
  final String seriesId;
  final int number;
  final String title;
  final bool playable;
}

/// 播放模型中的一个流表示形式。
@immutable
class StreamInfo {
  const StreamInfo({
    required this.definition,
    required this.url,
    required this.backupUrl,
    this.codec = '',
    this.width = 0,
    this.height = 0,
    this.hls = false,
    this.dash = false,
    this.protected = false,
    this.encryption = '',
  });

  /// 分辨率标签，如 "720p"。
  final String definition;
  final String url;
  final String backupUrl;
  final String codec;

  /// bytevc2 是字节自研编码，mpv/ffmpeg 没有解码器，开了必然黑屏
  /// （音频/弹幕仍正常），见 issue #8。
  static bool isUndecodableCodec(String codec) => codec == 'bytevc2';

  /// 流本身是否无法被播放器解码（当前只有 bytevc2）。
  bool get undecodable => isUndecodableCodec(codec);
  final int width;
  final int height;
  final bool hls;
  final bool dash;

  /// 加密流标记；加密方案见 [encryption]（如 "cenc-aes-ctr"）。
  final bool protected;
  final String encryption;

  String get label {
    final StringBuffer sb = StringBuffer(definition.isEmpty ? '未知' : definition);
    if (hls) {
      sb.write(' · HLS');
    } else if (dash) {
      sb.write(' · DASH');
    }
    if (protected) {
      sb.write(' · 加密');
    }
    return sb.toString();
  }
}

/// 一次播放解析的结果：候选流 + 可用的内容密钥。
@immutable
class PlaybackBundle {
  const PlaybackBundle({
    required this.episodeId,
    required this.streams,
    this.contentKeyHex = '',
    this.expiresAt = 0,
    this.durationSeconds = 0,
  });

  final String episodeId;
  final List<StreamInfo> streams;

  /// 16 字节 AES 密钥的小写十六进制；未加密或解析失败时为空。
  final String contentKeyHex;

  /// 流 URL 失效时间（unix 秒）；0 表示未知。
  final int expiresAt;
  final int durationSeconds;

  bool get hasKey => contentKeyHex.isNotEmpty;

  /// 与 [preferred] 相同的选流规则，但排除无法解码的流；
  /// 不存在可解码流时返回 null（调用方需给出明确报错而不是黑屏）。
  StreamInfo? get decodablePreferred {
    final List<StreamInfo> pool = streams
        .where((StreamInfo s) => !s.undecodable && !s.protected && s.url.isNotEmpty)
        .toList();
    if (pool.isEmpty) {
      return null;
    }
    pool.sort((StreamInfo a, StreamInfo b) => b.height.compareTo(a.height));
    return pool.first;
  }

  /// 是否所有流都无法解码（此时应提示用户而不是静默黑屏）。
  bool get allUndecodable =>
      streams.isNotEmpty && streams.every((StreamInfo s) => s.undecodable);

  /// 默认选流：先未加密，再取分辨率最高。
  StreamInfo? get preferred {
    if (streams.isEmpty) {
      return null;
    }
    final List<StreamInfo> clear =
        streams.where((StreamInfo s) => !s.protected && s.url.isNotEmpty).toList();
    final List<StreamInfo> pool = clear.isNotEmpty ? clear : streams;
    pool.sort((StreamInfo a, StreamInfo b) => b.height.compareTo(a.height));
    return pool.first;
  }
}
