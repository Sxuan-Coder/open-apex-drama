import 'package:apexduanju/services/dlna/dlna_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DLNA SOAP 模板', () {
    test('转义参数中的 XML 特殊字符', () {
      final String body = buildSoapEnvelope(
        DlnaControl.avTransportService,
        'Seek',
        <String, String>{
          'InstanceID': '0',
          'Target': '00:00:10&<>"\'',
        },
      );

      expect(body, contains('u:Seek'));
      expect(body, contains(DlnaControl.avTransportService));
      expect(body, contains('00:00:10&amp;&lt;&gt;&quot;&apos;'));
      expect(body, isNot(contains('Target>00:00:10&<')));
    });

    test('DIDL 元数据包含视频类型与地址', () {
      final String didl = buildDidlMetadata(
        title: '测试剧 第1集',
        uri: 'http://192.168.1.2:8080/cast/abc.mp4',
        mime: 'video/mp4',
      );

      expect(didl, contains('<dc:title>测试剧 第1集</dc:title>'));
      expect(didl, contains('protocolInfo="http-get:*:video/mp4:*"'));
      expect(didl, contains('http://192.168.1.2:8080/cast/abc.mp4'));
      expect(didl, contains('object.item.videoItem'));
    });
  });

  group('DLNA 时间', () {
    test('格式化为 HH:MM:SS', () {
      expect(formatDlnaTime(Duration.zero), '00:00:00');
      expect(formatDlnaTime(const Duration(seconds: 65)), '00:01:05');
      expect(
        formatDlnaTime(const Duration(hours: 2, minutes: 3, seconds: 4)),
        '02:03:04',
      );
    });

    test('解析 HH:MM:SS 与 MM:SS', () {
      expect(parseDlnaTime('02:03:04'), const Duration(hours: 2, minutes: 3, seconds: 4));
      expect(parseDlnaTime('01:05'), const Duration(minutes: 1, seconds: 5));
      expect(parseDlnaTime(''), isNull);
      expect(parseDlnaTime('NOT_IMPLEMENTED'), isNull);
      expect(parseDlnaTime('1:2:3:4'), isNull);
    });
  });
}
