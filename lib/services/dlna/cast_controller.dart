import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cast_proxy.dart';
import 'dlna_control.dart';
import 'dlna_device.dart';

/// 投屏会话状态。
enum CastPhase {
  /// 未投屏。
  idle,

  /// 已选设备，正在启动本地转发并让电视开播。
  connecting,

  /// 电视正在播放 / 暂停。
  casting,

  /// 启动或控制失败。
  error,
}

/// 一次投屏会话：本地转发 + DLNA 控制 + 电视状态轮询。
///
/// UI 只监听这个对象；页面销毁时必须调用 [dispose]，它会停止电视播放
/// 并关闭本地转发端口。
class CastController extends ChangeNotifier {
  CastController({CastProxyServer? proxy, this.pollInterval = const Duration(seconds: 5)})
    : _proxy = proxy ?? CastProxyServer();

  final CastProxyServer _proxy;
  final Duration pollInterval;

  DlnaDevice? _device;
  CastPhase _phase = CastPhase.idle;
  String _title = '';
  String _errorMessage = '';
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  DlnaControl? _control;
  Timer? _pollTimer;
  bool _disposed = false;

  DlnaDevice? get device => _device;
  CastPhase get phase => _phase;
  String get title => _title;
  String get errorMessage => _errorMessage;
  bool get playing => _playing;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get isCasting =>
      _phase == CastPhase.connecting || _phase == CastPhase.casting;
  bool get disposed => _disposed;

  /// 连接设备并开始播放 [upstream]。
  ///
  /// 本地转发会注入 [userAgent]；[mime] 用于 DIDL 元数据，[extension]
  /// 用于本地地址后缀。失败时不抛异常，状态落到 [CastPhase.error]。
  Future<void> start({
    required DlnaDevice device,
    required Uri upstream,
    required String title,
    required String userAgent,
    required Duration startAt,
    Duration duration = Duration.zero,
    String mime = 'video/mp4',
    String extension = 'mp4',
  }) async {
    await _reset();
    _device = device;
    _title = title;
    _phase = CastPhase.connecting;
    _errorMessage = '';
    _position = startAt;
    _duration = duration;
    _notify();
    try {
      final String localUrl = await _proxy.start(
        upstream: upstream,
        userAgent: userAgent,
        extension: extension,
      );
      final DlnaControl control = DlnaControl(
        avTransportUrl: device.avTransportUrl,
        renderingControlUrl: device.renderingControlUrl,
      );
      _control = control;
      if (_disposed) {
        await _reset();
        return;
      }
      await control.setAvTransportUri(uri: localUrl, title: title, mime: mime);
      if (startAt > Duration.zero) {
        await control.seek(startAt);
      }
      await control.play();
      if (_disposed) {
        return;
      }
      _phase = CastPhase.casting;
      _playing = true;
      _startPolling();
      _notify();
    } catch (error) {
      await _reset();
      _phase = CastPhase.error;
      _errorMessage = _humanMessage(error);
      _notify();
    }
  }

  Future<void> pause() async {
    final DlnaControl? control = _control;
    if (control == null || _phase != CastPhase.casting) {
      return;
    }
    try {
      await control.pause();
      _playing = false;
      _notify();
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> resume() async {
    final DlnaControl? control = _control;
    if (control == null || _phase != CastPhase.casting) {
      return;
    }
    try {
      await control.play();
      _playing = true;
      _notify();
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> seek(Duration target) async {
    final DlnaControl? control = _control;
    if (control == null || _phase != CastPhase.casting) {
      return;
    }
    try {
      await control.seek(target);
      _position = target;
      _notify();
    } catch (error) {
      _fail(error);
    }
  }

  /// 停止投屏并返回电视侧最后的位置（用于把本地播放接续回去）。
  Future<Duration?> stop() async {
    final DlnaControl? control = _control;
    Duration last = _position;
    if (control != null && _phase == CastPhase.casting) {
      try {
        last = await control.getPosition() ?? last;
      } catch (_) {
        // 电视已离线：沿用最后一次轮询到的位置。
      }
      try {
        await control.stop();
      } catch (_) {
        // 停止失败不影响本地清理。
      }
    }
    await _reset();
    _phase = CastPhase.idle;
    _notify();
    return last;
  }

  void _startPolling() {
    if (_disposed) {
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) {
      unawaited(_poll());
    });
  }

  Future<void> _poll() async {
    final DlnaControl? control = _control;
    if (control == null || _phase != CastPhase.casting) {
      return;
    }
    try {
      final String state = await control.getTransportState();
      final Duration? position = await control.getPosition();
      if (_phase != CastPhase.casting) {
        return;
      }
      _playing = state == 'PLAYING';
      if (position != null) {
        _position = position;
      }
      _notify();
    } catch (_) {
      // 轮询失败是瞬时的（电视切源、网络抖动），不改变会话状态。
    }
  }

  void _fail(Object error) {
    _phase = CastPhase.error;
    _errorMessage = _humanMessage(error);
    _notify();
  }

  String _humanMessage(Object error) {
    if (error is StateError) {
      return error.message;
    }
    if (error is DlnaException) {
      return error.message;
    }
    return '投屏失败，请检查手机与电视是否在同一 Wi-Fi';
  }

  Future<void> _reset() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final DlnaControl? control = _control;
    _control = null;
    control?.close();
    await _proxy.stop();
    _playing = false;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    final DlnaControl? control = _control;
    _control = null;
    if (control != null) {
      // 关闭页面即停止电视播放，避免手机退出后电视还在放。
      // 必须等停止请求发完再关闭 HTTP 客户端，否则命令会被中断。
      unawaited(
        control
            .stop()
            .catchError((Object _) {})
            .whenComplete(control.close),
      );
    }
    unawaited(_proxy.stop());
    super.dispose();
  }
}
