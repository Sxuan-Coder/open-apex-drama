import 'dart:async';

import 'package:flutter/material.dart';

import '../services/dlna/cast_controller.dart';
import '../services/dlna/dlna_device.dart';
import '../services/dlna/dlna_discovery.dart';
import '../theme/app_colors.dart';

/// 打开设备选择弹层，返回用户选中的电视；取消 / 关闭返回 null。
///
/// [scan] 仅用于测试注入；默认走真实的 SSDP 搜索。
Future<DlnaDevice?> showCastDevicePicker(
  BuildContext context, {
  Future<List<DlnaDevice>> Function()? scan,
}) {
  return showModalBottomSheet<DlnaDevice>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (BuildContext context) =>
        _CastDeviceSheet(scan: scan ?? const DlnaDiscovery().scan),
  );
}

/// 投屏中弹层：暂停 / 继续 / 停止。停止会回调 [onStop] 并关闭弹层。
Future<void> showCastStatusSheet(
  BuildContext context,
  CastController controller, {
  required Future<void> Function() onStop,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (BuildContext context) => _CastStatusSheet(
      controller: controller,
      onStop: onStop,
    ),
  );
}

class _CastDeviceSheet extends StatefulWidget {
  const _CastDeviceSheet({required this.scan});

  final Future<List<DlnaDevice>> Function() scan;

  @override
  State<_CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends State<_CastDeviceSheet> {
  bool _loading = true;
  List<DlnaDevice> _devices = const <DlnaDevice>[];
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final List<DlnaDevice> devices = await widget.scan();
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppTokens.immersiveSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const _SheetHandle(),
            _SheetHeader(
              title: '投屏',
              subtitle: _loading ? '正在搜索同一 Wi-Fi 下的电视…' : '请选择要投屏的设备',
              trailing: IconButton(
                tooltip: '重新搜索',
                onPressed: _loading ? null : _search,
                icon: Icon(
                  Icons.refresh_rounded,
                  size: 20,
                  color: Colors.white.withValues(alpha: _loading ? 0.3 : 0.72),
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              )
            else if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                child: Text(
                  _error,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: AppTokens.immersiveAccentBright,
                  ),
                ),
              )
            else if (_devices.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 4, 18, 20),
                child: Text(
                  '未找到可投屏设备。请确认手机与电视连接同一个 Wi-Fi，'
                  '且电视已开启投屏 / DLNA 功能后重新搜索。',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    color: AppTokens.immersiveTextTertiary,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: _devices.length,
                  itemBuilder: (BuildContext context, int index) {
                    final DlnaDevice device = _devices[index];
                    return _DeviceRow(
                      device: device,
                      onTap: () => Navigator.of(context).pop(device),
                    );
                  },
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 2, 18, 14),
              child: Text(
                '投屏期间请保持本应用在前台，手机与电视需在同一局域网。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: AppTokens.immersiveTextTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CastStatusSheet extends StatelessWidget {
  const _CastStatusSheet({required this.controller, required this.onStop});

  final CastController controller;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppTokens.immersiveSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, Widget? child) {
            final bool failed = controller.phase == CastPhase.error;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const _SheetHandle(),
                _SheetHeader(
                  title: failed ? '投屏中断' : '正在投屏',
                  subtitle: failed
                      ? controller.errorMessage
                      : controller.device?.name ?? '',
                ),
                if (!failed && controller.title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        controller.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: AppTokens.immersiveTextSecondary,
                        ),
                      ),
                    ),
                  ),
                if (!failed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                    child: Row(
                      children: <Widget>[
                        _RoundAction(
                          icon: controller.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          label: controller.playing ? '暂停' : '继续',
                          onTap: controller.playing
                              ? controller.pause
                              : controller.resume,
                        ),
                        const SizedBox(width: 14),
                        _RoundAction(
                          icon: Icons.stop_rounded,
                          label: '停止投屏',
                          onTap: () async {
                            Navigator.of(context).pop();
                            await onStop();
                          },
                        ),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                    child: Row(
                      children: <Widget>[
                        _RoundAction(
                          icon: Icons.stop_rounded,
                          label: '结束投屏',
                          onTap: () async {
                            Navigator.of(context).pop();
                            await onStop();
                          },
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.onTap});

  final DlnaDevice device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String subtitle = device.subtitle;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: <Widget>[
            const Icon(
              Icons.tv_rounded,
              size: 22,
              color: AppTokens.immersiveTextSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.3,
                      color: Colors.white,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.3,
                        color: AppTokens.immersiveTextTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: AppTokens.immersiveTextTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: OutlinedButton.icon(
        onPressed: () => unawaited(onTap()),
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: AppTokens.immersiveHairline),
          backgroundColor: AppTokens.immersiveSurfaceRaised,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 8, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                if (subtitle.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: AppTokens.immersiveTextTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Container(
        width: 34,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
