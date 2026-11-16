/// XMLTV 解析器：把云端 epgUrl 拉到的 XML 解析成 [EpgGuide]。
///
/// 只依赖项目已有的 `xml` 包，纯函数、无 IO、无副作用，便于单测。
/// 兼容常见 XMLTV 变体：
/// - 时间 `20261116120000 +0800` / `20261116120000` / ISO8601；
/// - `<title lang="zh">` 多语言（优先中文，回退任意一条）；
/// - `<display-name lang="zh">` 同理；
/// - 自闭合与带属性写法。
library;

import 'package:xml/xml.dart';

import 'epg_model.dart';

class XmltvParseException implements Exception {
  const XmltvParseException(this.message);
  final String message;
  @override
  String toString() => 'XmltvParseException: $message';
}

/// XMLTV 时间戳 → DateTime。
///
/// XMLTV 规范：`YYYYMMDDHHmmss ±HHMM`（秒可省略）。带时区时用给定偏移解析成
/// UTC 再转本地；无时区按本地时间处理。解析失败返回 null，由调用方丢弃该节目。
DateTime? parseXmltvTime(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;

  // 已是 ISO8601（含 T）——直接交给 DateTime。
  if (value.contains('T')) return DateTime.tryParse(value);

  // 形如 20261116120000 +0800 / 202611161200 +0800
  final match = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(?:(\d{2}))?\s*([+-]\d{4})?$',
  ).firstMatch(value);
  if (match == null) return null;

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.tryParse(match.group(6) ?? '0') ?? 0;
  final zone = match.group(7);

  final local = DateTime(year, month, day, hour, minute, second);
  if (zone == null) return local;

  // +0800 → UTC 偏移 +8h；DateTime.utc(...) 再转本地。
  final sign = zone[0] == '-' ? -1 : 1;
  final zoneHour = int.parse(zone.substring(1, 3));
  final zoneMinute = int.parse(zone.substring(3, 5));
  final offset = Duration(minutes: sign * (zoneHour * 60 + zoneMinute));
  return local.subtract(offset).toLocal();
}

/// 从同名节点里挑出中文文案，回退第一条非空。
String _localizedText(Iterable<XmlElement> nodes, {String fallback = ''}) {
  String? first;
  for (final node in nodes) {
    final text = node.text.trim();
    if (text.isEmpty) continue;
    first ??= text;
    final lang = node.getAttribute('lang')?.toLowerCase() ?? '';
    if (lang.startsWith('zh') || lang == 'cmn' || lang == 'chi') return text;
  }
  return first ?? fallback;
}

Iterable<XmlElement> _childrenNamed(XmlElement parent, String name) =>
    parent.childElements().where((e) => e.name.local == name);

/// 解析 XMLTV 文档。格式非法时抛 [XmltvParseException]。
EpgGuide parseXmltv(String xmlText) {
  if (xmlText.trim().isEmpty) throw const XmltvParseException('EPG 内容为空');

  late XmlDocument document;
  try {
    document = XmlDocument.parse(xmlText);
  } catch (error) {
    throw XmltvParseException('XML 解析失败: $error');
  }

  final root = document.rootElement;
  if (root == null || root.name.local.toLowerCase() != 'tv') {
    throw const XmltvParseException('不是合法的 XMLTV 文档（缺少 <tv> 根节点）');
  }

  // ---- 频道 ----
  final channels = <EpgChannel>[];
  final channelIds = <String>{};
  for (final node in root.childElements().where((e) => e.name.local == 'channel')) {
    final id = node.getAttribute('id')?.trim() ?? '';
    if (id.isEmpty || !channelIds.add(id)) continue;
    final names = _childrenNamed(node, 'display-name');
    final displayName = _localizedText(names, fallback: id);
    final iconNodes = _childrenNamed(node, 'icon').toList();
    final iconNode = iconNodes.isEmpty ? null : iconNodes.first;
    channels.add(EpgChannel(
      id: id,
      displayName: displayName.isEmpty ? id : displayName,
      icon: iconNode?.getAttribute('src'),
    ));
  }

  // ---- 节目 ----
  final programmes = <EpgProgramme>[];
  for (final node in root.childElements().where((e) => e.name.local == 'programme')) {
    final channelId = node.getAttribute('channel')?.trim() ?? '';
    if (channelId.isEmpty) continue;
    final start = parseXmltvTime(node.getAttribute('start') ?? '');
    final end = parseXmltvTime(node.getAttribute('stop') ?? node.getAttribute('end') ?? '');
    if (start == null || end == null || !end.isAfter(start)) continue;

    final title = _localizedText(_childrenNamed(node, 'title'));
    if (title.isEmpty) continue;
    final subTitle = _localizedText(_childrenNamed(node, 'sub-title'));
    final description = _localizedText(_childrenNamed(node, 'desc'));
    final category = _localizedText(_childrenNamed(node, 'category'));

    programmes.add(EpgProgramme(
      channelId: channelId,
      title: title,
      start: start,
      end: end,
      subTitle: subTitle,
      description: description,
      category: category,
    ));
  }

  if (channels.isEmpty && programmes.isEmpty) {
    throw const XmltvParseException('XMLTV 中没有可用的频道或节目');
  }

  // 节目按频道 + 时间排序，UI 直接顺序展示即可。
  programmes.sort((a, b) {
    final byChannel = a.channelId.compareTo(b.channelId);
    return byChannel != 0 ? byChannel : a.start.compareTo(b.start);
  });

  return EpgGuide(channels: channels, programmes: programmes, fetchedAt: DateTime.now());
}
