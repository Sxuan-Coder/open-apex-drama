import 'dart:async';
import 'dart:io';
import 'dart:math';

/// 手机上的本地转发服务：把投屏地址改写成 `http://<手机IP>:<端口>/cast/...`。
///
/// 为什么需要它：红果视频 CDN 只接受官方客户端 UA（见 `kCdnUserAgent`），
/// 而电视拉流时带的是电视自己的 UA，直连会被 CDN 拒绝。手机代为发起请求
/// 并注入官方 UA，电视只和手机通信。支持 Range，电视可以正常拖动进度。
///
/// 只监听局域网地址、只放行随机 token 路径；投屏结束即关闭。
class CastProxyServer {
  /// [addressResolver] 仅用于测试注入局域网地址（默认扫描本机网卡）。
  CastProxyServer({this.addressResolver});

  final Future<String?> Function()? addressResolver;

  HttpServer? _server;
  HttpClient? _client;
  Uri? _upstream;
  String? _token;

  /// 启动转发并返回可交给电视的本地地址。
  ///
  /// [userAgent] 是向上游拉流时使用的 UA；[extension] 只影响 URL 后缀，
  /// 部分电视靠后缀判断容器格式。
  Future<String> start({
    required Uri upstream,
    required String userAgent,
    String extension = 'mp4',
  }) async {
    await stop();
    final String? host = await (addressResolver?.call() ?? _lanAddress());
    if (host == null) {
      throw StateError('未连接到局域网，请先连接与电视相同的 Wi-Fi');
    }
    final String token = _randomToken();
    final HttpServer server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      0,
    );
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(minutes: 2)
      ..autoUncompress = false;

    _server = server;
    _client = client;
    _upstream = upstream;
    _token = token;
    server.listen((HttpRequest request) {
      unawaited(_handle(request, client, userAgent));
    });
    return 'http://$host:${server.port}/cast/$token.$extension';
  }

  Future<void> stop() async {
    _token = null;
    _upstream = null;
    final HttpServer? server = _server;
    final HttpClient? client = _client;
    _server = null;
    _client = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {
        // 已关闭 / 端口已释放，无需处理。
      }
    }
    client?.close(force: true);
  }

  Future<void> _handle(
    HttpRequest request,
    HttpClient client,
    String userAgent,
  ) async {
    final Uri? upstream = _upstream;
    final String? token = _token;
    final String method = request.method;
    if (upstream == null ||
        token == null ||
        !_isCastPath(request.uri.path, token) ||
        (method != 'GET' && method != 'HEAD')) {
      await _reply(request.response, HttpStatus.notFound);
      return;
    }

    HttpClientResponse? response;
    try {
      final HttpClientRequest proxyRequest = await client.openUrl(
        method,
        upstream,
      );
      proxyRequest.headers.set(HttpHeaders.userAgentHeader, userAgent);
      // 原样转发字节流，避免上游压缩后丢掉编码头导致电视无法解码。
      proxyRequest.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.isNotEmpty) {
        proxyRequest.headers.set(HttpHeaders.rangeHeader, range);
      }
      response = await proxyRequest.close();
      if (response.statusCode >= 400) {
        await response.drain<void>();
        await _reply(request.response, HttpStatus.badGateway);
        return;
      }
      final HttpResponse out = request.response;
      out.statusCode = response.statusCode;
      for (final String name in _forwardHeaders) {
        final String? value = response.headers.value(name);
        if (value != null) {
          out.headers.set(name, value);
        }
      }
      if (method == 'HEAD') {
        await response.drain<void>();
        await out.close();
        return;
      }
      await response.pipe(out);
    } catch (_) {
      // 电视中途断开 / 上游超时：尽力给一个错误码，不能影响下一次请求。
      try {
        await _reply(request.response, HttpStatus.badGateway);
      } catch (_) {
        // 响应已开始写出，忽略。
      }
    }
  }

  static const List<String> _forwardHeaders = <String>[
    HttpHeaders.contentTypeHeader,
    HttpHeaders.contentLengthHeader,
    HttpHeaders.contentRangeHeader,
    HttpHeaders.acceptRangesHeader,
    HttpHeaders.lastModifiedHeader,
    HttpHeaders.etagHeader,
    HttpHeaders.contentEncodingHeader,
  ];

  Future<void> _reply(HttpResponse response, int status) async {
    response.statusCode = status;
    await response.close();
  }

  /// 路径必须是 `/cast/<token>.<ext>`（token 之后允许带后缀）。
  bool _isCastPath(String path, String token) {
    if (!path.startsWith('/cast/')) {
      return false;
    }
    final String name = path.substring('/cast/'.length);
    final int dot = name.indexOf('.');
    final String value = dot < 0 ? name : name.substring(0, dot);
    return value == token;
  }

  String _randomToken() {
    final Random random = Random.secure();
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 16; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// 选一个电视可达的局域网 IPv4：优先无线网卡，其次任意私有地址。
  Future<String?> _lanAddress() async {
    final List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
    } catch (_) {
      return null;
    }
    String? fallback;
    for (final NetworkInterface interface in interfaces) {
      final bool wireless = _wirelessNames.any(
        (String name) => interface.name.toLowerCase().contains(name),
      );
      for (final InternetAddress address in interface.addresses) {
        if (!_isPrivateIPv4(address.address)) {
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

  static const List<String> _wirelessNames = <String>[
    'wlan',
    'wifi',
    'wi-fi',
    'en0',
  ];

  /// 只接受 RFC1918 私有地址；公网地址电视也访问不到。
  bool _isPrivateIPv4(String address) {
    final List<int> parts = address
        .split('.')
        .map((String part) => int.tryParse(part) ?? -1)
        .toList();
    if (parts.length != 4 || parts.any((int part) => part < 0 || part > 255)) {
      return false;
    }
    if (parts[0] == 10) {
      return true;
    }
    if (parts[0] == 192 && parts[1] == 168) {
      return true;
    }
    return parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31;
  }
}
