import 'dlna_device.dart';

/// 解析 UPnP 设备描述 XML，取出展示名与 AVTransport / RenderingControl
/// 控制地址。
///
/// 不引入 XML 依赖：DLNA 描述文档结构固定，只需要几个字段；用正则按
/// `<service>` 分块提取，同时兼容带命名空间前缀（`<u:serviceType>`）。
/// 描述文档里的控制地址可能是相对路径，按 LOCATION 解析。
DlnaDevice? parseDeviceDescription(String xml, Uri location) {
  if (xml.isEmpty) {
    return null;
  }
  final String name = _firstTag(xml, 'friendlyName');
  final List<_ServiceBlock> services = _serviceBlocks(xml);
  final String? avTransport = _controlUrl(services, 'AVTransport:1');
  if (avTransport == null || avTransport.isEmpty) {
    return null;
  }
  final String? rendering = _controlUrl(services, 'RenderingControl:1');
  return DlnaDevice(
    name: name.isEmpty ? location.host : _unescape(name),
    location: location,
    avTransportUrl: location.resolve(avTransport),
    renderingControlUrl:
        rendering == null || rendering.isEmpty
            ? null
            : location.resolve(rendering),
    modelName: _unescape(_firstTag(xml, 'modelName')),
    manufacturer: _unescape(_firstTag(xml, 'manufacturer')),
  );
}

class _ServiceBlock {
  const _ServiceBlock({required this.type, required this.controlUrl});

  final String type;
  final String controlUrl;
}

List<_ServiceBlock> _serviceBlocks(String xml) {
  final RegExp block = RegExp(
    r'<(?:\w+:)?service\b[^>]*>(.*?)</(?:\w+:)?service>',
    caseSensitive: false,
    dotAll: true,
  );
  final List<_ServiceBlock> result = <_ServiceBlock>[];
  for (final RegExpMatch match in block.allMatches(xml)) {
    final String body = match.group(1) ?? '';
    result.add(
      _ServiceBlock(
        type: _firstTag(body, 'serviceType'),
        controlUrl: _firstTag(body, 'controlURL'),
      ),
    );
  }
  return result;
}

String? _controlUrl(List<_ServiceBlock> services, String suffix) {
  for (final _ServiceBlock service in services) {
    if (service.type.endsWith(suffix) && service.controlUrl.isNotEmpty) {
      return _unescape(service.controlUrl);
    }
  }
  return null;
}

/// 取第一个标签的文本内容（忽略命名空间前缀）。
String _firstTag(String xml, String tag) {
  final RegExp regExp = RegExp(
    '<(?:\\w+:)?$tag\\b[^>]*>(.*?)</(?:\\w+:)?$tag>',
    caseSensitive: false,
    dotAll: true,
  );
  final RegExpMatch? match = regExp.firstMatch(xml);
  return (match?.group(1) ?? '').trim();
}

String _unescape(String value) {
  if (!value.contains('&')) {
    return value;
  }
  return value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
}
