// ignore_for_file: avoid_print
import 'dart:io';

/// 读取命令行参数 `--name value`。
String? argValue(List<String> args, String name) {
  final int index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
}

/// 解析 SSDP / HTTP 头（大小写不敏感）。
String? dlnaHeader(String text, String name) {
  final RegExpMatch? match = RegExp(
    '^${RegExp.escape(name)}:\\s*(.+?)\\s*\$',
    caseSensitive: false,
    multiLine: true,
  ).firstMatch(text);
  return match?.group(1);
}

/// 取 SOAP / XML 第一个同名标签的文本内容（兼容命名空间前缀）。
String dlnaTag(String xml, String tag) {
  final RegExpMatch? match = RegExp(
    '<(?:\\w+:)?$tag[^>]*>(.*?)</(?:\\w+:)?$tag>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(xml);
  return unescapeXml(match?.group(1)?.trim() ?? '');
}

String escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String unescapeXml(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String formatDlnaTime(Duration value) {
  final int total = value.inSeconds.clamp(0, 359999);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(total ~/ 3600)}:${two((total % 3600) ~/ 60)}:'
      '${two(total % 60)}';
}

Duration? parseDlnaTime(String value) {
  final List<String> chunks = value.trim().split(':');
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

/// 真的向手机侧转发地址取 1KB，验证可达性与 Range。
Future<void> probeStream(String url) async {
  if (url.isEmpty) {
    return;
  }
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6);
  try {
    final HttpClientRequest request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final HttpClientResponse response = await request.close();
    final int bytes = await response.fold<int>(
      0,
      (int total, List<int> chunk) => total + chunk.length,
    );
    final String range = response.headers.value('content-range') ?? '-';
    print(
      '[拉流验证] ${response.statusCode} '
      '${response.headers.contentType} ${bytes}B range=$range',
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      print('[拉流验证] 状态异常，请检查手机端转发 / CDN');
    }
  } catch (error) {
    print('[拉流验证] 失败：$error');
  } finally {
    client.close(force: true);
  }
}

/// 选一个电视 / 手机可达的局域网 IPv4，优先无线网卡。
Future<String?> lanAddress() async {
  final List<NetworkInterface> interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  String? fallback;
  for (final NetworkInterface interface in interfaces) {
    final bool wireless = <String>['wlan', 'wifi', 'wi-fi', 'en0'].any(
      (String item) => interface.name.toLowerCase().contains(item),
    );
    for (final InternetAddress address in interface.addresses) {
      if (!_isPrivate(address.address)) {
        continue;
      }
      if (wireless) {
        return address.address;
      }
      fallback ??= address.address;
    }
  }
  return fallback;
}

bool _isPrivate(String address) {
  final List<int> parts = address
      .split('.')
      .map((String part) => int.tryParse(part) ?? -1)
      .toList();
  if (parts.length != 4 || parts.any((int part) => part < 0)) {
    return false;
  }
  return parts[0] == 10 ||
      (parts[0] == 192 && parts[1] == 168) ||
      (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31);
}
