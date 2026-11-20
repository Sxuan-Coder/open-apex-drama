import 'package:apexduanju/services/dlna/dlna_description.dart';
import 'package:flutter_test/flutter_test.dart';

const String _description = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>客厅电视 &amp; 投影</friendlyName>
    <manufacturer>Example</manufacturer>
    <modelName>TV-100</modelName>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/ctl/render</controlURL>
      </service>
      <service>
        <u:serviceType xmlns:u="urn:schemas-upnp-org:device-1-0">urn:schemas-upnp-org:service:AVTransport:1</u:serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>control/avt</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';

void main() {
  test('解析 friendlyName、AVTransport 与 RenderingControl 地址', () {
    final device = parseDeviceDescription(
      _description,
      Uri.parse('http://192.168.1.8:9000/desc.xml'),
    );

    expect(device, isNotNull);
    expect(device!.name, '客厅电视 & 投影');
    expect(device.modelName, 'TV-100');
    expect(device.manufacturer, 'Example');
    expect(
      device.avTransportUrl.toString(),
      'http://192.168.1.8:9000/control/avt',
    );
    expect(
      device.renderingControlUrl.toString(),
      'http://192.168.1.8:9000/ctl/render',
    );
  });

  test('没有 AVTransport 服务时返回 null', () {
    const String xml = '''<root><device><friendlyName>只读设备</friendlyName>
      <serviceList><service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/cm</controlURL>
      </service></serviceList></device></root>''';

    expect(
      parseDeviceDescription(xml, Uri.parse('http://10.0.0.2/desc.xml')),
      isNull,
    );
  });

  test('空文档返回 null', () {
    expect(parseDeviceDescription('', Uri.parse('http://10.0.0.2/')), isNull);
  });
}
