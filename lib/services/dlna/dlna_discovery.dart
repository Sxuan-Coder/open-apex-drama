import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dlna_description.dart';
import 'dlna_device.dart';

/// 通过 SSDP 搜索同一局域网内的 DLNA 媒体渲染设备。
///
/// 只做 M-SEARCH（不做开机广播订阅）：搜索结果用于用户手动选择设备，
/// 不需要常驻监听。SSDP 的响应是发回本机临时端口的单播包，因此 Android
/// 上即使没有 MulticastLock 也能收到响应；发送组播包只需 INTERNET 权限。
class DlnaDiscovery {
  const DlnaDiscovery();

  static const String _searchTarget =
      'urn:schemas-upnp-org:device:MediaRenderer:1';
  static final InternetAddress _multicast =
      InternetAddress('239.255.255.250');
  static const int _ssdpPort = 1900;

  /// 搜索并返回可用设备列表（只保留声明了 AVTransport 的设备）。
  ///
  /// [timeout] 是收包窗口；[attempts] 次 M-SEARCH 覆盖丢包。设备描述
  /// 文档并发拉取，单个设备失败不影响其他设备。
  Future<List<DlnaDevice>> scan({
    Duration timeout = const Duration(seconds: 3),
    int attempts = 3,
  }) async {
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (error) {
      throw StateError('无法启动局域网搜索：$error');
    }
    socket.broadcastEnabled = true;

    final Set<String> locations = <String>{};
    final Completer<void> done = Completer<void>();

    void finish() {
      if (!done.isCompleted) {
        done.complete();
      }
    }

    socket.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final Datagram? datagram = socket.receive();
      if (datagram == null) {
        return;
      }
      final String text = utf8.decode(datagram.data, allowMalformed: true);
      final String? location = _header(text, 'location');
      if (location != null && location.isNotEmpty) {
        locations.add(location);
      }
    });

    final List<int> payload = utf8.encode(_searchRequest());
    Timer? repeat;
    int sent = 0;
    void send() {
      if (sent >= attempts) {
        repeat?.cancel();
        return;
      }
      sent++;
      try {
        socket.send(payload, _multicast, _ssdpPort);
      } catch (_) {
        // 单次发送失败（例如网络切换）不终止整个搜索。
      }
    }

    send();
    repeat = Timer.periodic(const Duration(milliseconds: 600), (_) => send());
    final Timer deadline = Timer(timeout, finish);

    try {
      await done.future;
    } finally {
      deadline.cancel();
      repeat.cancel();
      socket.close();
    }

    if (locations.isEmpty) {
      return const <DlnaDevice>[];
    }
    final List<DlnaDevice?> described = await Future.wait(
      locations.map(_describe),
    );
    final List<DlnaDevice> devices =
        described.whereType<DlnaDevice>().toList();
    devices.sort(
      (DlnaDevice a, DlnaDevice b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return devices;
  }

  Future<DlnaDevice?> _describe(String location) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final Uri? uri = Uri.tryParse(location);
      if (uri == null || !uri.hasScheme) {
        return null;
      }
      final HttpClientRequest request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 4));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'ApexDrama/1.0 UPnP/1.1',
      );
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        return null;
      }
      final String body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 4));
      return parseDeviceDescription(body, uri);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  String _searchRequest() {
    return 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $_searchTarget\r\n'
        'USER-AGENT: ApexDrama/1.0 UPnP/1.1\r\n'
        '\r\n';
  }

  /// 解析 SSDP 响应头（大小写不敏感）；同名头取第一个。
  static String? _header(String text, String name) {
    final RegExp regExp = RegExp(
      '^${RegExp.escape(name)}:\\s*(.+?)\\s*\$',
      caseSensitive: false,
      multiLine: true,
    );
    return regExp.firstMatch(text)?.group(1);
  }
}
