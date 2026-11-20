import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// DLNA 控制失败：网络错误、非 2xx、SOAP Fault 都归一到这里。
class DlnaException implements Exception {
  const DlnaException(this.message, {this.statusCode = 0});

  final String message;
  final int statusCode;

  @override
  String toString() => 'DlnaException($statusCode): $message';
}

/// UPnP AVTransport / RenderingControl 的 SOAP 客户端。
///
/// 只覆盖投屏需要的动作：设置地址、播放、暂停、停止、跳转、查询状态。
/// SOAP 模板按 UPnP 规范拼装；参数值统一做 XML 转义。
class DlnaControl {
  DlnaControl({
    required this.avTransportUrl,
    this.renderingControlUrl,
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const String avTransportService =
      'urn:schemas-upnp-org:service:AVTransport:1';
  static const String renderingControlService =
      'urn:schemas-upnp-org:service:RenderingControl:1';

  final Uri avTransportUrl;
  final Uri? renderingControlUrl;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 6);

  /// 设定投屏地址并让电视开始缓冲。部分电视收到 URI 后不会自动播放，
  /// 仍需要再调用 [play]。
  Future<void> setAvTransportUri({
    required String uri,
    required String title,
    String mime = 'video/mp4',
  }) {
    return _invoke(avTransportUrl, avTransportService, 'SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': uri,
      'CurrentURIMetaData': buildDidlMetadata(
        title: title,
        uri: uri,
        mime: mime,
      ),
    });
  }

  Future<void> play() =>
      _invoke(avTransportUrl, avTransportService, 'Play', {
        'InstanceID': '0',
        'Speed': '1',
      });

  Future<void> pause() =>
      _invoke(avTransportUrl, avTransportService, 'Pause', {
        'InstanceID': '0',
      });

  Future<void> stop() =>
      _invoke(avTransportUrl, avTransportService, 'Stop', {
        'InstanceID': '0',
      });

  Future<void> seek(Duration position) => _invoke(
    avTransportUrl,
    avTransportService,
    'Seek',
    <String, String>{
      'InstanceID': '0',
      'Unit': 'REL_TIME',
      'Target': formatDlnaTime(position),
    },
  );

  /// 返回 PLAYING / PAUSED_PLAYBACK / STOPPED / TRANSITIONING 等。
  Future<String> getTransportState() async {
    final String body = await _invoke(
      avTransportUrl,
      avTransportService,
      'GetTransportInfo',
      <String, String>{'InstanceID': '0'},
    );
    return _tag(body, 'CurrentTransportState');
  }

  /// 返回电视侧的当前播放位置；解析失败返回 null。
  Future<Duration?> getPosition() async {
    final String body = await _invoke(
      avTransportUrl,
      avTransportService,
      'GetPositionInfo',
      <String, String>{'InstanceID': '0'},
    );
    return parseDlnaTime(_tag(body, 'RelTime'));
  }

  Future<void> setVolume(int percent) {
    final Uri? target = renderingControlUrl;
    if (target == null) {
      return Future<void>.value();
    }
    return _invoke(target, renderingControlService, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': percent.clamp(0, 100).toString(),
    });
  }

  Future<String> _invoke(
    Uri url,
    String service,
    String action,
    Map<String, String> args,
  ) async {
    final String body = buildSoapEnvelope(service, action, args);
    try {
      final http.Response response = await _client
          .post(
            url,
            headers: <String, String>{
              'Content-Type': 'text/xml; charset="utf-8"',
              'SOAPACTION': '"$service#$action"',
            },
            body: utf8.encode(body),
          )
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DlnaException(
          _faultMessage(_decodeBody(response)) ?? '电视拒绝了操作（$action）',
          statusCode: response.statusCode,
        );
      }
      return _decodeBody(response);
    } on DlnaException {
      rethrow;
    } on TimeoutException {
      throw const DlnaException('电视响应超时');
    } catch (error) {
      throw DlnaException('无法连接电视：$error');
    }
  }

  String _decodeBody(http.Response response) {
    // 极少数设备按 GBK 返回；中文只用于错误提示，解码失败不致命。
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  String? _faultMessage(String body) {
    if (body.isEmpty) {
      return null;
    }
    final RegExpMatch? match = RegExp(
      '<(?:\\w+:)?errorDescription[^>]*>(.*?)</(?:\\w+:)?errorDescription>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(body);
    return match?.group(1)?.trim();
  }

  void close() => _client.close();
}

/// 组装 SOAP 请求体。参数顺序与传入顺序一致。
String buildSoapEnvelope(
  String service,
  String action,
  Map<String, String> args,
) {
  final StringBuffer buffer = StringBuffer()
    ..write('<?xml version="1.0" encoding="utf-8"?>')
    ..write(
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:',
    )
    ..write(action)
    ..write(' xmlns:u="')
    ..write(service)
    ..write('">');
  args.forEach((String key, String value) {
    buffer
      ..write('<')
      ..write(key)
      ..write('>')
      ..write(xmlEscape(value))
      ..write('</')
      ..write(key)
      ..write('>');
  });
  buffer.write('</u:$action></s:Body></s:Envelope>');
  return buffer.toString();
}

/// DIDL-Lite 元数据：告诉电视这个地址是视频。
String buildDidlMetadata({
  required String title,
  required String uri,
  String mime = 'video/mp4',
}) {
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="1">'
      '<dc:title>${xmlEscape(title)}</dc:title>'
      '<upnp:class>object.item.videoItem</upnp:class>'
      '<res protocolInfo="http-get:*:$mime:*">${xmlEscape(uri)}</res>'
      '</item></DIDL-Lite>';
}

String xmlEscape(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

/// DLNA 使用 `HH:MM:SS`（时位不受 24 小时限制）。
String formatDlnaTime(Duration value) {
  final int total = value.inSeconds.clamp(0, 359999);
  final int hours = total ~/ 3600;
  final int minutes = (total % 3600) ~/ 60;
  final int seconds = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(hours)}:${two(minutes)}:${two(seconds)}';
}

/// 解析 `HH:MM:SS` / `H:MM:SS` / `MM:SS`；非法输入返回 null。
Duration? parseDlnaTime(String value) {
  final String text = value.trim();
  if (text.isEmpty) {
    return null;
  }
  final List<String> chunks = text.split(':');
  if (chunks.length < 2 || chunks.length > 3) {
    return null;
  }
  int seconds = 0;
  for (final String chunk in chunks) {
    final int? part = int.tryParse(chunk);
    if (part == null || part < 0) {
      return null;
    }
    seconds = seconds * 60 + part;
  }
  return Duration(seconds: seconds);
}

String _tag(String xml, String tag) {
  final RegExpMatch? match = RegExp(
    '<(?:\\w+:)?$tag[^>]*>(.*?)</(?:\\w+:)?$tag>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(xml);
  return match?.group(1)?.trim() ?? '';
}
