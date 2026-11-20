import 'package:flutter_test/flutter_test.dart';
import 'package:apexduanju/models/playback.dart';

StreamInfo _stream(
  String definition,
  int height, {
  String codec = 'avc',
  bool protected = false,
}) =>
    StreamInfo(
      definition: definition,
      url: 'https://example.com/$definition',
      backupUrl: '',
      codec: codec,
      width: height * 16 ~/ 9,
      height: height,
      protected: protected,
    );

void main() {
  group('PlaybackBundle bytevc2 选流（issue #8）', () {
    test('全清晰度 bytevc2 时 allUndecodable 为真', () {
      final PlaybackBundle bundle = PlaybackBundle(
        episodeId: 'e1',
        streams: <StreamInfo>[
          _stream('360p', 360, codec: 'bytevc2'),
          _stream('1080p', 1080, codec: 'bytevc2'),
        ],
      );
      expect(bundle.allUndecodable, isTrue);
      expect(bundle.decodablePreferred, isNull);
    });

    test('部分 bytevc2 时 decodablePreferred 只挑可解码的最高分辨率', () {
      final PlaybackBundle bundle = PlaybackBundle(
        episodeId: 'e1',
        streams: <StreamInfo>[
          _stream('360p', 360, codec: 'bytevc2'),
          _stream('720p', 720),
          _stream('1080p', 1080, codec: 'bytevc2'),
        ],
      );
      expect(bundle.allUndecodable, isFalse);
      final StreamInfo? picked = bundle.decodablePreferred;
      expect(picked, isNotNull);
      expect(picked!.definition, '720p');
    });

    test('preferred 仍可能选中 bytevc2（兜底由播放器层提示）', () {
      final PlaybackBundle bundle = PlaybackBundle(
        episodeId: 'e1',
        streams: <StreamInfo>[
          _stream('720p', 720),
          _stream('1080p', 1080, codec: 'bytevc2'),
        ],
      );
      // preferred 按分辨率最高选，仍会拿到 bytevc2 的 1080p；
      // 播放器 _pickStream 优先用 decodablePreferred 规避。
      expect(bundle.preferred!.definition, '1080p');
      expect(bundle.decodablePreferred!.definition, '720p');
    });

    test('空流列表 allUndecodable 为假（避免空 bundle 误报）', () {
      final PlaybackBundle bundle = PlaybackBundle(episodeId: 'e1', streams: const <StreamInfo>[]);
      expect(bundle.allUndecodable, isFalse);
    });

    test('isUndecodableCodec 只认 bytevc2', () {
      expect(StreamInfo.isUndecodableCodec('bytevc2'), isTrue);
      expect(StreamInfo.isUndecodableCodec('h264'), isFalse);
      expect(StreamInfo.isUndecodableCodec(''), isFalse);
    });
  });
}
