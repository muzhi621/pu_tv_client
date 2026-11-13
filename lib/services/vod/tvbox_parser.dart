/// TVBox 配置的解析层：把原始 JSON 拍平成终端能直接消费的结构。
///
/// 这里只做**解析**，不发网络请求、不碰 UI。三块最容易出错的地方集中在这：
///
///  1. `vod_play_from` / `vod_play_url` 的多分隔符（`$$$` 分线路、`#` 分集、
///     `$` 分「名 / 地址」）。真实站点两种顺序都存在，还有三段式与纯地址。
///  2. 单仓 / 多仓。单仓是 `{sites: [...]}`，多仓是 `{urls: [...]}`，多仓的
///     `urls` 元素既可能是字符串，也可能是 `{url, name}` —— 早期版本只收字符串，
///     导致真实配置里整批子仓被丢掉。
///  3. 采集接口的 URL 拼装。`api` 常常自带 `?ac=list` 或尾斜杠，直接拼会得到
///     `?ac=list&ac=detail`，站点返回空列表；必须先剥掉控制参数。
///
/// 算法先在 Python 原型里用 10 组样本验证过（含 m3u8 碎片、线路名缺失、
/// 数量不一致、url 在前、三段式等边界），这里逐条对齐。
library;

import 'dart:convert';

import 'vod_config.dart';

/// 一集（或一个播放项）。
class VodEpisode {
  const VodEpisode({required this.name, required this.url, this.extra = ''});

  final String name;
  final String url;

  /// `名$地址$flag` 的第三段，绝大多数站点不用，保留给少数特例。
  final String extra;

  Map<String, dynamic> toJson() => {'name': name, 'url': url, 'extra': extra};

  @override
  String toString() => '$name -> $url';
}

/// 一条播放线路（`vod_play_from` 里的一项）。
class VodPlayLine {
  const VodPlayLine({required this.flag, required this.episodes});

  final String flag;
  final List<VodEpisode> episodes;

  int get length => episodes.length;

  bool get isEmpty => episodes.isEmpty;
}

/// 多仓里的一项子配置。
class VodSubConfig {
  const VodSubConfig({required this.url, this.name = ''});

  final String url;
  final String name;
}

/// 一次配置解析的结果。
///
/// 单仓会填 [sites]，多仓会填 [subConfigs]；两者理论上互斥，但恶意/异常
/// 配置可能都给，所以两个都返回，由调用方决定递归策略。
class VodConfigParseResult {
  const VodConfigParseResult({
    this.sites = const <TvboxSite>[],
    this.subConfigs = const <VodSubConfig>[],
    this.spider = '',
    this.errors = const <String>[],
  });

  final List<TvboxSite> sites;
  final List<VodSubConfig> subConfigs;

  /// 顶层 `spider` 字段（已拆掉 `;md5;` 后缀）。
  final String spider;

  /// 被跳过的条目说明，给编辑器/诊断页展示用。
  final List<String> errors;

  bool get isEmpty => sites.isEmpty && subConfigs.isEmpty;
}

/// 解析后的一处站点。字段与云端下发的 `VodSite` 对齐，便于直接复用引擎。
class TvboxSite {
  const TvboxSite({
    required this.key,
    required this.name,
    required this.api,
    this.type = 1,
    this.ext = '',
    this.searchable = false,
    this.quickSearch = false,
    this.jar = '',
  });

  final String key;
  final String name;
  final String api;

  /// 0=XML、1=JSON、3=jar 反射、4=采集站。
  final int type;

  final String ext;
  final bool searchable;
  final bool quickSearch;

  /// 该站点所属源提供的 spider jar（仅 `csp_` 站点有意义）。
  final String jar;

  /// 是否需要 jar 里的代码。
  bool get needsSpider => api.startsWith('csp_');

  /// 反射用的类名：`csp_Ali` → `Ali`。
  String get spiderKey => needsSpider ? api.substring(4) : api;

  /// 是否能用纯 HTTP 引擎直接跑（不需要 jar）。
  bool get isHttp => !needsSpider && api.startsWith('http');
}

// ---------------------------------------------------------------------------
// 1. 播放地址解析
// ---------------------------------------------------------------------------

const String _episodeSplit = '#';
const String _lineSplit = r'$$$';

/// 把一集串解析成列表。
///
/// 兼容四种真实形态：
///   - `第1集$https://…`（最常见）
///   - `https://…$第1集`（顺序颠倒）
///   - `第1集$https://…$hd`（三段式，第三段丢弃）
///   - `https://…`（只有地址，序号兜底）
List<VodEpisode> parseEpisodes(String? raw) {
  final text = raw ?? '';
  if (text.trim().isEmpty) return const <VodEpisode>[];
  final out = <VodEpisode>[];
  for (final chunk in text.split(_episodeSplit)) {
    final trimmed = chunk.trim();
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split(r'$');
    if (parts.length >= 2) {
      var name = parts[0].trim();
      var url = parts[1].trim();
      if (url.isEmpty) continue;
      // 顺序颠倒：第一段才是地址。
      if (_looksLikeUrl(name) && !_looksLikeUrl(url)) {
        final swap = name;
        name = url;
        url = swap;
      }
      out.add(VodEpisode(
        name: _cleanName(name).isEmpty ? '${out.length + 1}' : _cleanName(name),
        url: url,
        extra: parts.length > 2 ? parts[2].trim() : '',
      ));
    } else if (_looksLikeUrl(parts[0])) {
      out.add(VodEpisode(name: '${out.length + 1}', url: parts[0].trim()));
    }
  }
  return out;
}

/// `vod_play_from` + `vod_play_url` → 线路列表。
///
/// 线路名与线路数对不上时按位置补 `线路N`，而不是整条丢弃 —— 真实配置里
/// 少写/多写 `$$$` 的情况很常见，丢弃会让整部片子无法播放。
List<VodPlayLine> parsePlayLines(String? fromField, String? urlField) {
  final flags = (fromField ?? '')
      .split(_lineSplit)
      .map((item) => item.trim())
      .toList(growable: false);
  final groups = (urlField ?? '').split(_lineSplit);
  final out = <VodPlayLine>[];

  if (groups.length == 1 && flags.length <= 1) {
    final episodes = parseEpisodes(groups.first);
    if (episodes.isNotEmpty) {
      out.add(VodPlayLine(
        flag: flags.isNotEmpty && flags.first.isNotEmpty ? flags.first : '线路1',
        episodes: episodes,
      ));
    }
    return out;
  }

  for (var i = 0; i < groups.length; i++) {
    final episodes = parseEpisodes(groups[i]);
    if (episodes.isEmpty) continue;
    final flag = i < flags.length && flags[i].isNotEmpty ? flags[i] : '线路${i + 1}';
    out.add(VodPlayLine(flag: flag, episodes: episodes));
  }
  return out;
}

bool _looksLikeUrl(String text) {
  final lower = text.toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('magnet:') ||
      lower.startsWith('ed2k://') ||
      lower.startsWith('thunder://');
}

String _cleanName(String name) => name.replaceAll('\u3000', ' ').trim();

// ---------------------------------------------------------------------------
// 2. 配置解析
// ---------------------------------------------------------------------------

/// 解析一份 TVBox 配置。
///
/// [rawText] 可以是带 `//` 整行注释的 JSON（真实配置几乎都带），这里会先
/// 剥掉再解析。[sourceJar] 是该源提供的 spider jar，会挂在 `csp_` 站点上。
VodConfigParseResult parseTvboxConfig(
  String rawText, {
  String sourceJar = '',
}) {
  final errors = <String>[];
  final text = stripJsonComments(rawText);
  Object? decoded;
  try {
    decoded = _decodeJson(text);
  } catch (error) {
    return VodConfigParseResult(errors: ['JSON 解析失败：$error']);
  }

  // 顶层也可能是数组（一组配置），逐个拍平。
  final nodes = <Map<String, dynamic>>[];
  if (decoded is List) {
    for (final item in decoded) {
      final map = _asMap(item);
      if (map.isNotEmpty) nodes.add(map);
    }
  } else {
    final map = _asMap(decoded);
    if (map.isEmpty) {
      return VodConfigParseResult(errors: const ['配置顶层不是对象或数组']);
    }
    nodes.add(map);
  }

  final sites = <TvboxSite>[];
  final subs = <VodSubConfig>[];
  var spider = sourceJar;

  for (final node in nodes) {
    if (spider.isEmpty) {
      spider = splitSpiderField(_str(node['spider'])).jar;
    }
    final rawSites = node['sites'];
    if (rawSites is List) {
      for (final item in rawSites) {
        final site = _parseSite(item, spider, errors);
        if (site != null) sites.add(site);
      }
    }
    final rawUrls = node['urls'];
    if (rawUrls is List) {
      for (final item in rawUrls) {
        if (item is String) {
          final url = item.trim();
          if (url.startsWith('http')) subs.add(VodSubConfig(url: url));
        } else {
          final map = _asMap(item);
          final url = _str(map['url']).trim();
          if (url.startsWith('http')) {
            subs.add(VodSubConfig(url: url, name: _str(map['name']).trim()));
          }
        }
      }
    }
  }

  return VodConfigParseResult(
    sites: sites,
    subConfigs: subs,
    spider: spider,
    errors: errors,
  );
}

TvboxSite? _parseSite(Object? node, String jar, List<String> errors) {
  final map = _asMap(node);
  if (map.isEmpty) return null;
  final key = _str(map['key']).trim().isEmpty
      ? _str(map['id']).trim()
      : _str(map['key']).trim();
  final api = _normalizeApi(_str(map['api']));
  if (key.isEmpty || api.isEmpty) {
    // 缺 key 或 api 的条目在真实配置里不少，静默跳过会让用户以为导入不全，
    // 所以记一条但不中断。
    errors.add('跳过站点（缺 key 或 api）：${_str(map['name']).trim()}');
    return null;
  }
  final rawType = map['type'];
  return TvboxSite(
    key: key,
    name: _str(map['name']).trim().isEmpty ? key : _str(map['name']).trim(),
    api: api,
    type: _resolveType(api, rawType),
    ext: extToText(map['ext']),
    searchable: _truthy(map['searchable']),
    quickSearch: _truthy(map['quickSearch']),
    jar: api.startsWith('csp_') ? jar : '',
  );
}

/// 配置里没写 type 时按 api 推断：`csp_` 是 jar，其余按 JSON 采集接口处理。
int _resolveType(String api, Object? rawType) {
  final parsed = rawType is int ? rawType : int.tryParse(_str(rawType).trim());
  if (parsed != null) return parsed;
  return api.startsWith('csp_') ? 3 : 1;
}

/// TVBox 里 `./libs/x.json` 这种相对写法在 api 上也会出现，去掉前导 `./`。
String _normalizeApi(String api) {
  var value = api.trim();
  if (value.startsWith('./')) value = value.substring(2);
  return value;
}

/// `ext` 可能是字符串、对象或数组。对象/数组按紧凑 JSON 透传 —— spider
/// 初始化时自己会 parse，我们不去猜它的结构。
String extToText(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is Map || value is List) return _compactJson(value);
  return value.toString();
}

bool _truthy(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value.toString().trim().toLowerCase();
  return text == '1' || text == 'true' || text == 'yes';
}

// ---------------------------------------------------------------------------
// 3. URL 拼装
// ---------------------------------------------------------------------------

/// 采集接口的查询参数，出现这些说明 api 自带控制语句，拼装前必须清掉。
const Set<String> _controlKeys = {
  'ac', 'wd', 't', 'pg', 'ids', 'at', 'by', 'hours', 'hits', 'area', 'lang', 'year',
};

/// 拆 api：返回「不含 query 的基地址」与「保留参数」。
///
/// 真实 api 常见三种形态：
///   - `https://a.com/api.php/provide/vod/`
///   - `https://a.com/api.php/provide/vod/?ac=list`
///   - `https://a.com/api?token=abc`
/// 前两种拼 `ac=detail` 都要先剥掉旧的 `ac`，否则变成 `?ac=list&ac=detail`。
({String base, Map<String, String> params}) splitApi(String api) {
  final index = api.indexOf('?');
  if (index < 0) return (base: api, params: const <String, String>{});
  final base = api.substring(0, index);
  final query = api.substring(index + 1);
  final params = <String, String>{};
  for (final pair in query.split('&')) {
    if (pair.isEmpty) continue;
    final eq = pair.indexOf('=');
    final key = (eq < 0 ? pair : pair.substring(0, eq)).trim();
    final value = eq < 0 ? '' : pair.substring(eq + 1).trim();
    if (key.isEmpty) continue;
    if (_controlKeys.contains(key.toLowerCase())) continue;
    params[key] = value;
  }
  return (base: base, params: params);
}

/// 在 [api] 上拼一组参数，自动处理已有的 `?`、尾斜杠与控制参数。
///
/// [control] 里值为 null 或空串的键会被跳过 —— 调用方不必判断「这个参数
/// 在这一步用不到」。
String buildApiUrl(String api, Map<String, Object?> control) {
  final split = splitApi(api);
  final params = <String, String>{...split.params};
  for (final entry in control.entries) {
    final value = entry.value;
    if (value == null) continue;
    final text = value.toString();
    if (text.isEmpty) continue;
    params[entry.key] = text;
  }
  if (params.isEmpty) return split.base;
  final query = params.entries
      .map((e) => '${_encode(e.key)}=${_encode(e.value)}')
      .join('&');
  return '${split.base}?$query';
}

/// 用 `%20` 而不是 `+` 表示空格，与 TVBox 侧一致（部分采集站只认前者）。
String _encode(String value) => Uri.encodeComponent(value);

/// 拆 `spider` 字段：`./fty.jar;md5;<hash>` → (jar, md5)。
///
/// 只认 `http(s)` 或 `./` 开头的路径，`csp_Xxx` 这类纯类名原样返回。
({String jar, String md5}) splitSpiderField(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return (jar: '', md5: '');
  final parts = text.split(';').map((item) => item.trim()).where((item) => item.isNotEmpty).toList();
  if (parts.isEmpty) return (jar: '', md5: '');
  var jar = parts.first;
  if (jar.startsWith('./')) jar = jar.substring(2);
  var md5 = '';
  for (var i = 1; i < parts.length; i++) {
    final part = parts[i];
    if (part.toLowerCase() == 'md5') continue;
    if (RegExp(r'^[0-9a-fA-F]{16,64}$').hasMatch(part)) {
      md5 = part;
      break;
    }
  }
  return (jar: jar, md5: md5);
}

/// 剥掉整行 `//` 注释。真实 TVBox 配置几乎都带注释，直接 `jsonDecode` 会失败。
///
/// 只处理「整行」注释：行内 `//` 可能出现在 URL 里（`https://`），
/// 全局替换会把地址截断，这是常见的踩坑点。
String stripJsonComments(String text) {
  if (!text.contains('//')) return text;
  final buffer = StringBuffer();
  for (final line in text.split('\n')) {
    if (line.trimLeft().startsWith('//')) continue;
    buffer.writeln(line);
  }
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

String _str(Object? value) => value is String ? value : (value == null ? '' : value.toString());

/// 紧凑 JSON，不引入额外依赖（对象/数组字段透传用）。
String _compactJson(Object? value) {
  final buffer = StringBuffer();
  void write(Object? node) {
    if (node == null) {
      buffer.write('null');
    } else if (node is String) {
      buffer.write(_jsonString(node));
    } else if (node is num || node is bool) {
      buffer.write(node.toString());
    } else if (node is List) {
      buffer.write('[');
      for (var i = 0; i < node.length; i++) {
        if (i > 0) buffer.write(',');
        write(node[i]);
      }
      buffer.write(']');
    } else if (node is Map) {
      buffer.write('{');
      var first = true;
      node.forEach((key, item) {
        if (!first) buffer.write(',');
        first = false;
        buffer.write(_jsonString(key.toString()));
        buffer.write(':');
        write(item);
      });
      buffer.write('}');
    } else {
      buffer.write(_jsonString(node.toString()));
    }
  }

  write(value);
  return buffer.toString();
}

String _jsonString(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  return '"$escaped"';
}

/// 极简 JSON 读取器：把 `jsonDecode` 的异常收敛成解析结果里的 errors，
/// 避免调用方到处 try/catch。
Object? _decodeJson(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  return jsonDecode(trimmed);
}

// ---------------------------------------------------------------------------
// 与云端模型的桥接
// ---------------------------------------------------------------------------

/// 把云端下发的 [VodSite] 转成本模块的 [TvboxSite]，交给引擎消费。
///
/// 两边字段几乎一致，唯一要处理的是 `type`：云端允许它缺省为 0，
/// 而 0 本身又是「XML」的合法取值，所以要靠 `api` 前缀消歧。
extension VodSiteBridge on VodSite {
  TvboxSite toTvboxSite() => TvboxSite(
        key: key.isEmpty ? id : key,
        name: name,
        api: api,
        type: type > 0 ? type : (requiresSpiderJar ? 3 : 1),
        ext: ext,
        searchable: searchable,
        quickSearch: quickSearch,
      );
}
