/// TVBox 影视数据的通用模型与 JSON 解析。
///
/// HTTP 引擎（type 0/1/4）和 spider 引擎（`csp_` jar）拿到的结构高度一致 ——
/// 都是苹果CMS 那套 `vod_*` 字段，只有外层信封不同。所以解析集中在这里：
///
///   - HTTP：整体是 `{code, page, pagecount, list, class}`
///   - spider `homeContent`：`{class, list, filters}`
///   - spider `categoryContent`：`{page, pagecount, limit, total, list}`
///   - spider `detailContent` / `searchContent`：`{list}`
///
/// 集中后两条引擎只有一个差异点：谁去发请求。
library;

import 'tvbox_parser.dart';

/// 分类（TVBox 里的 `class` / `<ty>`）。
class VodCategory {
  const VodCategory({required this.id, required this.name});

  final String id;
  final String name;

  @override
  String toString() => '$name($id)';
}

/// 列表项。
class VodItem {
  const VodItem({
    required this.id,
    required this.name,
    this.pic = '',
    this.remarks = '',
    this.year = '',
    this.area = '',
    this.typeName = '',
  });

  final String id;
  final String name;
  final String pic;

  /// 更新状态：`HD`、`已完结`、`第12集` 等。
  final String remarks;
  final String year;
  final String area;
  final String typeName;

  bool get hasPic => pic.isNotEmpty;
}

/// 首页：分类 + 推荐。
class VodHome {
  const VodHome({
    this.categories = const <VodCategory>[],
    this.items = const <VodItem>[],
  });

  final List<VodCategory> categories;
  final List<VodItem> items;

  bool get isEmpty => categories.isEmpty && items.isEmpty;
}

/// 分类 / 搜索的一页结果。
class VodPage {
  const VodPage({
    this.items = const <VodItem>[],
    this.page = 1,
    this.pageCount = 1,
    this.total = 0,
  });

  final List<VodItem> items;
  final int page;
  final int pageCount;
  final int total;

  bool get hasMore => page < pageCount;
}

/// 详情。
class VodDetail {
  const VodDetail({
    required this.id,
    required this.name,
    this.pic = '',
    this.content = '',
    this.year = '',
    this.area = '',
    this.remarks = '',
    this.actor = '',
    this.director = '',
    this.lines = const <VodPlayLine>[],
  });

  final String id;
  final String name;
  final String pic;
  final String content;
  final String year;
  final String area;
  final String remarks;
  final String actor;
  final String director;

  /// 多线路选集。
  final List<VodPlayLine> lines;

  bool get playable => lines.any((line) => line.episodes.isNotEmpty);

  /// 默认选第一条有内容的线路。
  VodPlayLine? get defaultLine {
    for (final line in lines) {
      if (line.episodes.isNotEmpty) return line;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// 字段工具
// ---------------------------------------------------------------------------

/// 取值转字符串并 trim。`vod_id` 在不同站点可能是数字或字符串，统一成字符串。
String vodText(Object? value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  return value.toString().trim();
}

int? vodAsInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// 站点常把图片写成 `//img.x.com/a.jpg`，不补协议 `Image.network` 会直接失败。
String normalizeVodPic(String pic) {
  final value = pic.trim();
  if (value.isEmpty) return '';
  if (value.startsWith('//')) return 'https:$value';
  return value;
}

/// 简介常带 HTML 片段，直接显示会露出 `<br>` 与 `&nbsp;`。
String stripVodHtml(String text) {
  if (!text.contains('<') && !text.contains('&')) return text.trim();
  return text
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();
}

/// 把 `list` 字段拍平成节点列表。兼容元素是 Map 或已经是 Map 的情况。
List<Map<String, dynamic>> asVodNodes(Object? raw) {
  if (raw is! List) return const <Map<String, dynamic>>[];
  final out = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is Map<String, dynamic>) {
      out.add(item);
    } else if (item is Map) {
      out.add(item.map((key, value) => MapEntry(key.toString(), value)));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// 解析入口
// ---------------------------------------------------------------------------

/// `class` 字段 → 分类列表。spider 里也叫 `class`，字段名 `type_id`/`type_name`。
List<VodCategory> parseVodCategories(Object? raw) {
  if (raw is! List) return const <VodCategory>[];
  final out = <VodCategory>[];
  final seen = <String>{};
  for (final item in raw) {
    if (item is! Map) continue;
    final id = vodText(item['type_id']).isEmpty
        ? vodText(item['id'])
        : vodText(item['type_id']);
    final name = vodText(item['type_name']).isEmpty
        ? vodText(item['name'])
        : vodText(item['type_name']);
    if (id.isEmpty || name.isEmpty) continue;
    if (!seen.add(id)) continue;
    out.add(VodCategory(id: id, name: name));
  }
  return out;
}

/// `list` 字段 → 条目列表。缺 `vod_id` 或 `vod_name` 的直接丢弃 —— 这种条目
/// 点进去必然白屏。
List<VodItem> parseVodItems(Object? raw) {
  final nodes = asVodNodes(raw);
  if (nodes.isEmpty) return const <VodItem>[];
  final out = <VodItem>[];
  for (final node in nodes) {
    final id = vodText(node['vod_id']).isEmpty
        ? vodText(node['id'])
        : vodText(node['vod_id']);
    final name = vodText(node['vod_name']).isEmpty
        ? vodText(node['name'])
        : vodText(node['vod_name']);
    if (id.isEmpty || name.isEmpty) continue;
    final className = vodText(node['vod_class']).isNotEmpty
        ? vodText(node['vod_class'])
        : vodText(node['type_name']);
    out.add(VodItem(
      id: id,
      name: name,
      pic: normalizeVodPic(vodText(node['vod_pic'])),
      remarks: vodText(node['vod_remarks']),
      year: vodText(node['vod_year']),
      area: vodText(node['vod_area']),
      typeName: className,
    ));
  }
  return out;
}

/// 单个详情节点 → [VodDetail]。
VodDetail parseVodDetailNode(Map<String, dynamic> node) {
  return VodDetail(
    id: vodText(node['vod_id']).isEmpty ? vodText(node['id']) : vodText(node['vod_id']),
    name: vodText(node['vod_name']).isEmpty ? vodText(node['name']) : vodText(node['vod_name']),
    pic: normalizeVodPic(vodText(node['vod_pic'])),
    content: stripVodHtml(vodText(node['vod_content']).isEmpty
        ? vodText(node['vod_blurb'])
        : vodText(node['vod_content'])),
    year: vodText(node['vod_year']),
    area: vodText(node['vod_area']),
    remarks: vodText(node['vod_remarks']),
    actor: vodText(node['vod_actor']),
    director: vodText(node['vod_director']),
    lines: parsePlayLines(
      vodText(node['vod_play_from']),
      vodText(node['vod_play_url']),
    ),
  );
}

/// 分页信封 → [VodPage]。
VodPage parseVodPageJson(Map<String, dynamic> map, {int fallbackPage = 1}) {
  return VodPage(
    items: parseVodItems(map['list']),
    page: vodAsInt(map['page']) ?? fallbackPage,
    pageCount: vodAsInt(map['pagecount']) ?? vodAsInt(map['page_count']) ?? 1,
    total: vodAsInt(map['total']) ?? 0,
  );
}

/// 首页信封 → [VodHome]。
VodHome parseVodHomeJson(Map<String, dynamic> map) {
  return VodHome(
    categories: parseVodCategories(map['class']),
    items: parseVodItems(map['list']),
  );
}
