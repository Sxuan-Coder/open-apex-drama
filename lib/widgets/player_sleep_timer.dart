import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../player/sleep_timer.dart';
import '../theme/app_colors.dart';
import 'player_sheet_header.dart';

/// 定时面板里的可选项。
enum SleepTimerOption {
  off('不开启'),
  minutes15('15分钟', Duration(minutes: 15)),
  minutes30('30分钟', Duration(minutes: 30)),
  minutes60('60分钟', Duration(minutes: 60)),
  minutes90('90分钟', Duration(minutes: 90)),
  episodeEnd('播完本集');

  const SleepTimerOption(this.label, [this.duration = Duration.zero]);

  final String label;

  /// 倒计时选项的时长；[off] 与 [episodeEnd] 不倒计时，为零。
  final Duration duration;
}

/// 面板里应高亮的选项：未开启时高亮「不开启」。
SleepTimerOption sleepTimerOptionFor(SleepTimerState? state) {
  if (state == null) {
    return SleepTimerOption.off;
  }
  if (state.mode == SleepTimerMode.episodeEnd) {
    return SleepTimerOption.episodeEnd;
  }
  for (final SleepTimerOption option in SleepTimerOption.values) {
    if (option.duration > Duration.zero && option.duration == state.total) {
      return option;
    }
  }
  return SleepTimerOption.off;
}

/// 顶栏入口上的文字：未开启只有图标（null），其余显示倒计时或「播完本集」。
String? sleepTimerEntryLabel(SleepTimerState? state) {
  if (state == null) {
    return null;
  }
  if (state.mode == SleepTimerMode.episodeEnd) {
    return SleepTimerOption.episodeEnd.label;
  }
  return formatCountdown(state.remaining);
}

/// 倒计时文字 mm:ss（最长 90 分钟，不出小时位）。
String formatCountdown(Duration remaining) {
  final int seconds = remaining.inSeconds;
  final String minutes = (seconds ~/ 60).toString().padLeft(2, '0');
  final String rest = (seconds % 60).toString().padLeft(2, '0');
  return '$minutes:$rest';
}

/// 选中后的确认提示。
String sleepTimerFeedback(SleepTimerOption option) {
  if (option == SleepTimerOption.episodeEnd) {
    return '本集播完后自动关闭';
  }
  if (option == SleepTimerOption.off) {
    return '已取消定时关闭';
  }
  return '将在 ${option.duration.inMinutes} 分钟后自动关闭';
}

/// 定时关闭面板：与倍速面板同款的三列选项网格，点选后 pop 回 [SleepTimerOption]。
class SleepTimerSheet extends StatelessWidget {
  const SleepTimerSheet({super.key, required this.current});

  /// 打开面板时的定时状态，用来高亮当前选项。
  final SleepTimerState? current;

  @override
  Widget build(BuildContext context) {
    final SleepTimerOption selected = sleepTimerOptionFor(current);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: _maxTextScale,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const PlayerSheetHeader(title: '定时关闭', subtitle: '到点停止播放并退出'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 2.4,
                ),
                itemCount: SleepTimerOption.values.length,
                itemBuilder: (BuildContext context, int index) {
                  final SleepTimerOption option =
                      SleepTimerOption.values[index];
                  return _SleepOptionCell(
                    label: option.label,
                    selected: option == selected,
                    onTap: () => Navigator.of(context).pop(option),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SleepOptionCell extends StatelessWidget {
  const _SleepOptionCell({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppTokens.immersiveAccent
          : Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.1,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.78),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶栏「定时关闭」入口。
///
/// 未开启时是与相邻图标按钮同宽的图标；定时进行中变成强调色胶囊，显示
/// 倒计时（mm:ss）或「播完本集」。只重建自身，不带动整个播放页。
class SleepTimerEntry extends StatelessWidget {
  const SleepTimerEntry({super.key, required this.timer, required this.onTap});

  final ValueListenable<SleepTimerState?> timer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SleepTimerState?>(
      valueListenable: timer,
      builder: (BuildContext context, SleepTimerState? state, Widget? _) {
        final bool armed = state != null;
        final String? label = sleepTimerEntryLabel(state);
        return Tooltip(
          message: '定时关闭',
          child: Semantics(
            button: true,
            // 未开启时入口只有一个图标，读屏软件靠这个名字认出它。
            label: '定时关闭',
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: _maxTextScale,
              child: Material(
                color: armed ? AppTokens.immersiveAccent : Colors.transparent,
                borderRadius: BorderRadius.circular(_entryHeight / 2),
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(_entryHeight / 2),
                  child: SizedBox(
                    height: _entryHeight,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: armed ? 10 : _idlePadding,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            armed ? Icons.timer_rounded : Icons.timer_outlined,
                            size: 20,
                            color: Colors.white.withValues(alpha: 0.86),
                          ),
                          if (label != null) ...<Widget>[
                            const SizedBox(width: 4),
                            Text(
                              label,
                              style: const TextStyle(
                                fontSize: 12.5,
                                height: 1.1,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 入口与面板里的文字最多放大到 1.3 倍：它们挤在顶栏和三列网格里，
/// 系统最大字号（2 倍）下整行都会溢出。
const double _maxTextScale = 1.3;

/// 与播放页顶栏其它方形图标按钮同高，未开启时同宽（图标 20 + 两侧留白）。
const double _entryHeight = 36;
const double _idlePadding = 8;
