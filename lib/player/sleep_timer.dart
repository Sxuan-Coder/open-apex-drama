import 'dart:async';

import 'package:flutter/foundation.dart';

/// 定时关闭的模式。
enum SleepTimerMode {
  /// 倒计时结束后关闭。
  countdown,

  /// 当前这一集自然播完后关闭。
  episodeEnd,
}

/// 定时关闭进行中的状态；未开启时用 null 表示。
@immutable
class SleepTimerState {
  /// 倒计时：[total] 是设定时长（面板据此回显选中项），[remaining] 是剩余时间。
  const SleepTimerState.countdown(this.total, this.remaining)
    : mode = SleepTimerMode.countdown;

  /// 播完本集：不倒计时。
  const SleepTimerState.episodeEnd()
    : mode = SleepTimerMode.episodeEnd,
      total = Duration.zero,
      remaining = Duration.zero;

  final SleepTimerMode mode;
  final Duration total;

  /// 剩余时间，按秒向上取整：到点前最后一秒显示 00:01，不会提前出现 00:00。
  final Duration remaining;

  /// 是否为「播完本集」。
  bool get stopsAtEpisodeEnd => mode == SleepTimerMode.episodeEnd;

  /// 值相等：同一秒的重复 tick 不会让 [ValueNotifier] 多通知一次。
  @override
  bool operator ==(Object other) =>
      other is SleepTimerState &&
      other.mode == mode &&
      other.total == total &&
      other.remaining == remaining;

  @override
  int get hashCode => Object.hash(mode, total, remaining);

  @override
  String toString() => 'SleepTimerState($mode, $remaining/$total)';
}

/// 本集自然播完后的去向。
enum EpisodeEndAction {
  /// 停在片尾（自动播放关闭，且没有定时）。
  none,

  /// 自动连播下一集。
  advance,

  /// 定时关闭选了「播完本集」：停止播放并退出。
  closeForSleepTimer,
}

/// 本集播完时该做什么：定时的「播完本集」优先于自动连播。
EpisodeEndAction episodeEndAction({
  required bool autoPlay,
  required bool sleepTimerStopsAtEpisodeEnd,
}) {
  if (sleepTimerStopsAtEpisodeEnd) {
    return EpisodeEndAction.closeForSleepTimer;
  }
  return autoPlay ? EpisodeEndAction.advance : EpisodeEndAction.none;
}

/// 播放页的定时关闭：倒计时到点、或「播完本集」时由调用方停止播放并退出。
///
/// 倒计时按墙钟截止时刻计算，而不是逐次 tick 递减：应用退到后台、系统休眠时
/// Dart 定时器可能被推迟，恢复后的第一次 tick 仍按真实时间判定到点，漏掉的
/// tick 不会让播放多持续。
class SleepTimer {
  /// [now] 是墙钟（测试里替换成假时钟）；[onElapsed] 在倒计时到点时调用一次。
  SleepTimer({required this.now, required this.onElapsed});

  /// 倒计时刷新间隔。只决定剩余时间的刷新粒度，到点与否以墙钟为准。
  static const Duration tickInterval = Duration(seconds: 1);

  final DateTime Function() now;
  final VoidCallback onElapsed;
  final ValueNotifier<SleepTimerState?> _state =
      ValueNotifier<SleepTimerState?>(null);
  Timer? _ticker;
  DateTime? _deadline;
  Duration _total = Duration.zero;

  ValueListenable<SleepTimerState?> get state => _state;

  /// 是否处于「播完本集」：本集自然播完时播放页据此退出而不是切下一集。
  bool get stopsAtEpisodeEnd => _state.value?.stopsAtEpisodeEnd ?? false;

  /// 开始倒计时；非正时长视为立即到点。会覆盖进行中的任何定时。
  void startCountdown(Duration duration) {
    _disarm();
    if (duration <= Duration.zero) {
      _fire();
      return;
    }
    _total = duration;
    _deadline = now().add(duration);
    _state.value = SleepTimerState.countdown(duration, duration);
    _ticker = Timer.periodic(tickInterval, (_) => _tick());
  }

  /// 改为「本集播完即关闭」；会取消进行中的倒计时。
  void armUntilEpisodeEnd() {
    _disarm();
    _state.value = const SleepTimerState.episodeEnd();
  }

  void cancel() {
    _disarm();
    _state.value = null;
  }

  /// 停掉 tick 并清掉截止时刻；不动对外状态。
  void _disarm() {
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
  }

  void _tick() {
    final DateTime? deadline = _deadline;
    if (deadline == null) {
      return;
    }
    final Duration remaining = deadline.difference(now());
    if (remaining <= Duration.zero) {
      _fire();
      return;
    }
    // 用微秒算：按毫秒截断会把不足 1ms 的剩余算成 0，提前显示 00:00。
    final int wholeSeconds = (remaining.inMicroseconds / 1000000).ceil();
    _state.value = SleepTimerState.countdown(
      _total,
      Duration(seconds: wholeSeconds),
    );
  }

  /// 到点：回到未开启并通知调用方；截止时刻已清除，不会重复触发。
  void _fire() {
    _disarm();
    _state.value = null;
    onElapsed();
  }

  void dispose() {
    _disarm();
    _state.dispose();
  }
}
