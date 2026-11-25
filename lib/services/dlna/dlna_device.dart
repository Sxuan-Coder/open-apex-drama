import 'package:flutter/foundation.dart';

/// 局域网内一台支持 DLNA 的媒体渲染设备（通常是智能电视 / 盒子）。
@immutable
class DlnaDevice {
  const DlnaDevice({
    required this.name,
    required this.location,
    required this.avTransportUrl,
    this.renderingControlUrl,
    this.modelName = '',
    this.manufacturer = '',
  });

  /// 设备展示名（UPnP 描述里的 friendlyName）。
  final String name;

  /// 设备描述文档地址（SSDP 响应里的 LOCATION）。
  final Uri location;

  /// AVTransport 控制地址：播放 / 暂停 / 停止 / 跳转都发给它。
  final Uri avTransportUrl;

  /// RenderingControl 控制地址；设备未声明时为 null。
  final Uri? renderingControlUrl;

  final String modelName;
  final String manufacturer;

  /// 列表副标题：优先型号，其次厂商，都为空时不显示。
  String get subtitle {
    if (modelName.isNotEmpty) {
      return manufacturer.isEmpty
          ? modelName
          : '$manufacturer · $modelName';
    }
    return manufacturer;
  }

  @override
  bool operator ==(Object other) =>
      other is DlnaDevice && other.location == location;

  @override
  int get hashCode => location.hashCode;
}
