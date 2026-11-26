import 'package:media_kit/media_kit.dart';

/// media_kit 原生播放器的假实现：让真实的播放页 / 信息流能在 widget 测试里
/// 走完开流、停播、播完的链路（测试环境没有 media_kit 的原生库）。
///
/// 事件顺序照 media_kit 1.2.6 的 NativePlayer：
/// - [stop] 先把 state 归零，再依次发 playing(false)、completed(false)、
///   position(0)、duration(0)；
/// - 一集播完是先 playing(false)，后 completed(true)。
class FakePlatformPlayer extends PlatformPlayer {
  FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  /// 一集的时长：两分钟的短剧。
  static const Duration episodeDuration = Duration(minutes: 2);

  /// 按发生顺序记录的调用与事件，如 `open:`、`stop`、`episodeEnd`、`dispose`。
  final List<String> calls = <String>[];
  bool disposed = false;

  /// 推进播放位置（position 流）。
  void tickPosition(Duration position) {
    state = state.copyWith(position: position);
    if (!positionController.isClosed) {
      positionController.add(position);
    }
  }

  /// 这一集播完。
  void emitEpisodeEnd() {
    calls.add('episodeEnd');
    state = state.copyWith(playing: false, completed: true);
    if (!playingController.isClosed) {
      playingController.add(false);
    }
    if (!completedController.isClosed) {
      completedController.add(true);
    }
  }

  void _emitPlaying(bool playing) {
    if (!playingController.isClosed) {
      playingController.add(playing);
    }
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    calls.add('open:${(playable as Media).uri}');
    state = state.copyWith(
      playing: play,
      completed: false,
      position: Duration.zero,
      duration: episodeDuration,
    );
    _emitPlaying(play);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    state = PlayerState().copyWith(volume: state.volume, rate: state.rate);
    _emitPlaying(false);
    if (!completedController.isClosed) {
      completedController.add(false);
    }
    if (!positionController.isClosed) {
      positionController.add(Duration.zero);
    }
    if (!durationController.isClosed) {
      durationController.add(Duration.zero);
    }
  }

  @override
  Future<void> play() async {
    calls.add('play');
    state = state.copyWith(playing: true);
    _emitPlaying(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    state = state.copyWith(playing: false);
    _emitPlaying(false);
  }

  @override
  Future<void> playOrPause() async {
    if (state.playing) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration duration) async {
    calls.add('seek:$duration');
    state = state.copyWith(position: duration);
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add('volume:$volume');
    state = state.copyWith(volume: volume);
  }

  @override
  Future<void> setRate(double rate) async {
    calls.add('rate:$rate');
    state = state.copyWith(rate: rate);
  }

  /// 播放页通过 `(platform as dynamic).setProperty` 设置解密密钥与 UA。
  Future<void> setProperty(String name, String value) async {
    calls.add('setProperty:$name');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    disposed = true;
    return super.dispose();
  }
}
