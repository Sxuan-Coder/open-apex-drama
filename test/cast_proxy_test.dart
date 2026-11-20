import 'dart:convert';
import 'dart:io';

import 'package:apexduanju/services/dlna/cast_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

const String _body = 'abcdefgh';

void main() {
  late HttpServer upstream;
  late CastProxyServer proxy;
  late String proxyUrl;
  String? seenUserAgent;
  String? seenRange;

  setUp(() async {
    seenUserAgent = null;
    seenRange = null;
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((HttpRequest request) async {
      seenUserAgent = request.headers.value(HttpHeaders.userAgentHeader);
      seenRange = request.headers.value(HttpHeaders.rangeHeader);
      final HttpResponse response = request.response;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (request.method == 'HEAD') {
        response.headers.contentType = ContentType('video', 'mp4');
        response.headers.contentLength = _body.length;
        await response.close();
        return;
      }
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      if (range == 'bytes=2-4') {
        response.statusCode = HttpStatus.partialContent;
        response.headers.contentType = ContentType('video', 'mp4');
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 2-4/${_body.length}',
        );
        response.write(_body.substring(2, 5));
      } else {
        response.headers.contentType = ContentType('video', 'mp4');
        response.write(_body);
      }
      await response.close();
    });

    proxy = CastProxyServer(addressResolver: () async => '127.0.0.1');
    proxyUrl = await proxy.start(
      upstream: Uri.parse(
        'http://127.0.0.1:${upstream.port}/video.mp4',
      ),
      userAgent: 'TestAgent/1.0',
      extension: 'mp4',
    );
  });

  tearDown(() async {
    await proxy.stop();
    await upstream.close(force: true);
  });

  test('转发 Range 请求并注入官方 UA', () async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(
        Uri.parse(proxyUrl),
      );
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=2-4');
      final HttpClientResponse response = await request.close();
      final String result = await response.transform(utf8.decoder).join();

      expect(response.statusCode, HttpStatus.partialContent);
      expect(result, 'cde');
      expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes 2-4/8');
      expect(seenUserAgent, 'TestAgent/1.0');
      expect(seenRange, 'bytes=2-4');
    } finally {
      client.close(force: true);
    }
  });

  test('HEAD 请求返回上游元数据', () async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.headUrl(
        Uri.parse(proxyUrl),
      );
      final HttpClientResponse response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentLength, _body.length);
      expect(seenUserAgent, 'TestAgent/1.0');
    } finally {
      client.close(force: true);
    }
  });

  test('token 不匹配时返回 404', () async {
    final Uri url = Uri.parse(proxyUrl).replace(
      path: '/cast/not-the-token.mp4',
    );
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(url);
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.notFound);
    } finally {
      client.close(force: true);
    }
  });
}
