/// TVBox 纯 HTTP 站点引擎：type 0（XML）/ 1（JSON）/ 4（采集站）。
///
/// 不依赖 jar，Dart 侧直连，覆盖那些不需要爬虫代码的站点。
///
/// 设计上的两个关键取舍：
///
///  1. **不按 `type` 死板分流，按响应内容判断**。真实配置里把 JSON 接口标成
///     type 0、把 XML 标成 type 1 的情况很常见；`type` 只在配置确实写了的时候
///     当作提示。响应 `trim` 后以 `{`/`[` 开头按 JSON 处理，以 `<` 开头按 XML。
///  2. **接口动作自动降级**。苹果CMS 有三代动作名：`ac=detail`（新版）/
///     `ac=videolist`（旧版）/ `ac=list`（最老）。只用一个会有大量站点返回空，
///     这里按顺序试，命中就停。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:charset_converter/charset_converter.dart';
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import 'tvbox_parser.dart';
import 'vod_models.dart';

// 使用方只 import 引擎就能拿到 VodItem / VodDetail 等模型，不必再记第二个路径。
export 'vod_models.dart' show
    VodCategory,
    VodDetail,
    VodHome,
    VodItem,
    VodPage,
    asVodNodes,
    normalizeVodPic,
    parseVodCategories,
    parseVodDetailNode,
    parseVodHomeJson,
    parseVodItems,
    parseVodPageJson,
    stripVodHtml,
    vodAsInt,
    vodServerError,
    vodText;

/// 引擎侧异常，带上「哪个站点、哪一步、什么原因」，方便影音页直接弹提示。
class VodEngineException implements Exception {
  VodEngineException(this.message, {this.site = '', this.step = '', this.cause});

  final String message;
  final String site;
  final String step;
  final Object? cause;

  @override
  String toString() {
    final parts = <String>[
      if (site.isNotEmpty) '站点 $site',
      if (step.isNotEmpty) '步骤 $step',
      message,
    ];
    return parts.join(' / ');
  }
}

/// 纯 HTTP 站点引擎。
///
/// 一个实例内部复用一个 [Dio]（连接池、Cookie 都能复用）。站点之间不共享
/// Cookie —— 不同采集站的会话互不相关，混用反而会让某些站鉴权失败。
class TvboxHttpEngine {
  TvboxHttpEngine({Dio? dio, Duration? timeout})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: timeout ?? const Duration(seconds: 12),
              receiveTimeout: timeout ?? const Duration(seconds: 20),
              sendTimeout: timeout ?? const Duration(seconds: 12),
              responseType: ResponseType.bytes,
              followRedirects: true,
              maxRedirects: 5,
              // 采集站普遍不校验状态码以外的内容，非 2xx 自己判更灵活。
              // 这里全部放行，由响应体判断成功与否 —— 4xx/5xx 的 body 里
              // 往往就是服务端给的失败原因，交给 Dio 抛掉就只剩「网络错误」。
              validateStatus: (code) => code != null,
            ));

  final Dio _dio;

  /// 各接口的标准动作，按「最可能命中」到「兜底」排列。
  ///
  /// 原来所有接口共用一条 `detail → videolist → list` 的链，home 也要先发两次
  /// 必然失败的请求：苹果CMS 拿分类的标准动作就是 `ac=list`，detail 只会回
  /// 一个空壳。慢源上每次空响应都要等满超时，白白放大成三倍等待。
  ///
  /// 降级仍然保留 —— 老站的动作支持确实参差不齐，但只在「服务端返回 2xx 且
  /// 没有数据」时才降级；网络层失败（超时/连不上）直接上抛，换动作也一样。
  static const List<String> _homeActions = ['list', 'videolist'];
  static const List<String> _listActions = ['videolist', 'detail', 'list'];
  static const List<String> _detailActions = ['detail', 'videolist', 'list'];
  static const List<String> _probeActions = ['list'];

  /// 一次降级链的总时间预算。单次请求已有 20s 接收超时，超过这个预算就
  /// 不再试下一个动作，避免「三次超时串起来」把首屏拖到一分钟。
  static const Duration _fallbackBudget = Duration(seconds: 25);

  /// 首页：拿分类与首页推荐。
  Future<VodHome> home(TvboxSite site) async {
    // 首页只需要分类 + 少量条目，用 `ac=list` 拿分类最省，还能避免部分站点
    // 在 detail 动作下强制要求 tid。
    final payload = await _requestWithFallback(
      site,
      (action) => <String, Object?>{'ac': action},
      step: 'home',
      actions: _homeActions,
    );
    return _parseHome(payload);
  }

  /// 分类列表。[tids] 为空表示「全部」。
  Future<VodPage> category(
    TvboxSite site, {
    String? tid,
    int page = 1,
    Map<String, String> filters = const <String, String>{},
  }) async {
    final payload = await _requestWithFallback(
      site,
      (action) => <String, Object?>{
        'ac': action,
        't': tid,
        'pg': page > 1 ? page : null,
        ...filters,
      },
      step: 'category',
      actions: _listActions,
    );
    return _parsePage(payload, fallbackPage: page);
  }

  /// 详情与选集。
  Future<VodDetail> detail(TvboxSite site, String vodId) async {
    final payload = await _requestWithFallback(
      site,
      (action) => <String, Object?>{'ac': action, 'ids': vodId},
      step: 'detail',
      actions: _detailActions,
    );
    final list = _extractList(payload);
    if (list.isEmpty) {
      throw VodEngineException('详情为空，站点可能已失效', site: site.name, step: 'detail');
    }
    return parseVodDetailNode(list.first);
  }

  /// 搜索。
  Future<VodPage> search(TvboxSite site, String keyword, {int page = 1}) async {
    final payload = await _requestWithFallback(
      site,
      (action) => <String, Object?>{
        'ac': action,
        'wd': keyword,
        'pg': page > 1 ? page : null,
      },
      step: 'search',
      actions: _listActions,
    );
    return _parsePage(payload, fallbackPage: page);
  }

  /// 探测站点是否可用：只发一次最轻的请求，不解析内容。
  ///
  /// 影音页「测速」按钮用它 —— 只关心能不能通，不想因为解析差异误判。
  Future<Duration> probe(TvboxSite site) async {
    final watch = Stopwatch()..start();
    await _requestWithFallback(
      site,
      (action) => <String, Object?>{'ac': action},
      step: 'probe',
      actions: _probeActions,
    );
    watch.stop();
    return watch.elapsed;
  }

  // ---------------------------------------------------------------- 请求

  /// 按 [actions] 顺序尝试，直到返回里有可用数据。
  ///
  /// 三种结局必须分开处理，它们正是「无内容无报错」与「首屏等一分钟」的根源：
  ///
  ///  * **服务端明确报错**（body 带 code/message/error）：立即把原文上抛。
  ///    换 action 不会改变服务端的失败，只会把同一条错误再等两遍。
  ///  * **网络层失败**（超时、连不上、TLS）：同样立即上抛。慢源的三倍耗时
  ///    就来自这里 —— 以前每次超时都被当成「这个 action 不行」，接着试下一个。
  ///  * **2xx 但没有数据**：才按下一个动作降级，这才是老站 action 不兼容的形态。
  Future<_Payload> _requestWithFallback(
    TvboxSite site,
    Map<String, Object?> Function(String action) build, {
    required String step,
    required List<String> actions,
  }) async {
    final watch = Stopwatch()..start();
    Object? lastError;
    _Payload? lastPayload;
    for (final action in actions) {
      if (watch.elapsed > _fallbackBudget) break;
      _Payload payload;
      try {
        payload = await _fetch(site, build(action), step: step);
      } on VodEngineException catch (error) {
        lastError = error;
        if (error.cause is DioException) rethrow;
        continue;
      }
      final serverError = payload.serverError;
      if (serverError != null) {
        throw VodEngineException(serverError, site: site.name, step: step);
      }
      if (!payload.isEmpty) return payload;
      lastPayload = payload;
    }
    if (lastPayload != null) return lastPayload;
    throw VodEngineException(
      '请求失败：${lastError ?? '站点无有效响应'}',
      site: site.name,
      step: step,
      cause: lastError,
    );
  }

  Future<_Payload> _fetch(
    TvboxSite site,
    Map<String, Object?> control, {
    required String step,
  }) async {
    final url = buildApiUrl(site.api, control);
    Response<List<int>> response;
    try {
      response = await _dio.get<List<int>>(
        url,
        options: Options(
          headers: {
            'User-Agent': _userAgent,
            'Accept': '*/*',
            if (site.ext.isNotEmpty && _looksLikeUrl(site.ext)) 'Referer': site.ext,
          },
        ),
      );
    } on DioException catch (error) {
      throw VodEngineException(
        _networkMessage(error),
        site: site.name,
        step: step,
        cause: error,
      );
    } catch (error) {
      throw VodEngineException('网络错误', site: site.name, step: step, cause: error);
    }
    final status = response.statusCode ?? 0;
    final bytes = Uint8List.fromList(response.data ?? const <int>[]);
    if (bytes.isEmpty) {
      return _Payload.empty(statusCode: status);
    }
    final text = await _decode(bytes, response.headers);
    return _Payload.parse(text, url: url, statusCode: status);
  }

  /// 网络层失败的人话。UI 只显示 `VodEngineException.message`，统一显示
  /// 「网络错误」会让超时和证书失败看起来一模一样。
  String _networkMessage(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时';
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '响应超时';
      case DioExceptionType.connectionError:
        return '无法连接站点';
      case DioExceptionType.badCertificate:
        return '证书校验失败';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode;
        return code == null ? '响应异常' : 'HTTP $code';
      case DioExceptionType.unknown:
        return '网络错误';
    }
  }

  /// 解码响应体。
  ///
  /// 采集站里 GBK/GB2312 仍占相当比例，直接按 UTF-8 解会得到一片 �。
  /// 顺序：header 的 charset → 内容里的 `charset=` → UTF-8 → GBK。
  Future<String> _decode(Uint8List bytes, Headers headers) async {
    final declared = _charsetFromHeader(headers.value('content-type'));
    if (declared != null && !_isUtf8Family(declared)) {
      final decoded = await _decodeWith(declared, bytes);
      if (decoded != null) return decoded;
    }
    // UTF-8 严格解码失败（出现非法字节序列）就说明不是 UTF-8。
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // 落到编码嗅探。
    }
    final sniffed = _charsetFromBody(bytes);
    if (sniffed != null) {
      final decoded = await _decodeWith(sniffed, bytes);
      if (decoded != null) return decoded;
    }
    final gbk = await _decodeWith('gbk', bytes);
    return gbk ?? utf8.decode(bytes, allowMalformed: true);
  }

  Future<String?> _decodeWith(String charset, Uint8List bytes) async {
    try {
      return await CharsetConverter.decode(charset.toLowerCase(), bytes);
    } catch (_) {
      return null;
    }
  }

  String? _charsetFromHeader(String? contentType) {
    if (contentType == null) return null;
    final match = RegExp(r'charset\s*=\s*"?([\w-]+)"?', caseSensitive: false).firstMatch(contentType);
    return match?.group(1);
  }

  String? _charsetFromBody(Uint8List bytes) {
    // 只看前 2KB，XML 声明或 meta 一定在头部。
    final head = String.fromCharCodes(bytes.take(2048));
    final match = RegExp(r'charset\s*=\s*["\x27]?([\w-]+)', caseSensitive: false).firstMatch(head);
    return match?.group(1);
  }

  bool _isUtf8Family(String charset) {
    final value = charset.toLowerCase();
    return value == 'utf-8' || value == 'utf8' || value == 'utf_8';
  }

  // ---------------------------------------------------------------- 解析

  VodHome _parseHome(_Payload payload) {
    if (payload.isJson) return parseVodHomeJson(payload.json);
    final root = payload.xml;
    if (root == null) return const VodHome();
    return VodHome(
      categories: _categoriesFromXml(root),
      // `_itemsFromXml` 给的是还原后的 vod_* 节点：详情分支要的就是原始节点
      // （选集还要拼 play_from/play_url），列表分支则统一走 parseVodItems。
      items: parseVodItems(_itemsFromXml(root.findAllElements('video'))),
    );
  }

  VodPage _parsePage(_Payload payload, {required int fallbackPage}) {
    if (payload.isJson) {
      return parseVodPageJson(payload.json, fallbackPage: fallbackPage);
    }
    final root = payload.xml;
    if (root == null) return VodPage(page: fallbackPage);
    final list = _first(root.findAllElements('list'));
    return VodPage(
      items: parseVodItems(_itemsFromXml(root.findAllElements('video'))),
      page: _asInt(list?.getAttribute('page')) ?? fallbackPage,
      pageCount: _asInt(list?.getAttribute('pagecount')) ?? 1,
      total: _asInt(list?.getAttribute('recordcount')) ?? 0,
    );
  }

  List<Map<String, dynamic>> _extractList(_Payload payload) {
    if (!payload.isJson) {
      final root = payload.xml;
      if (root == null) return const <Map<String, dynamic>>[];
      return _itemsFromXml(root.findAllElements('video'));
    }
    return asVodNodes(payload.json['list']);
  }

  List<VodCategory> _categoriesFromXml(XmlDocument root) {
    final out = <VodCategory>[];
    for (final node in root.findAllElements('ty')) {
      final id = node.getAttribute('id') ?? '';
      final name = node.innerText.trim();
      if (id.isEmpty || name.isEmpty) continue;
      out.add(VodCategory(id: id, name: name));
    }
    return out;
  }

  List<Map<String, dynamic>> _itemsFromXml(Iterable<XmlElement> nodes) {
    final out = <Map<String, dynamic>>[];
    for (final node in nodes) {
      final id = _first(node.findElements('id'))?.innerText.trim() ?? '';
      final name = _first(node.findElements('name'))?.innerText.trim() ?? '';
      if (id.isEmpty || name.isEmpty) continue;
      // XML 的选集在 <dl><dd flag="线路名">第1集$url#…</dd></dl>，
      // 这里拼成和 JSON 一致的串，下游复用同一套解析。
      final lineFlags = <String>[];
      final lineUrls = <String>[];
      for (final dd in node.findAllElements('dd')) {
        final flag = dd.getAttribute('flag')?.trim() ?? '';
        final value = dd.innerText.trim();
        if (value.isEmpty) continue;
        lineFlags.add(flag);
        lineUrls.add(value);
      }
      out.add(<String, dynamic>{
        'vod_id': id,
        'vod_name': name,
        'vod_pic': _childText(node, 'pic'),
        'vod_remarks': _childText(node, 'note'),
        'vod_year': _childText(node, 'year'),
        'vod_area': _childText(node, 'area'),
        'vod_class': _childText(node, 'type'),
        'vod_content': _childText(node, 'des'),
        'vod_actor': _childText(node, 'actor'),
        'vod_director': _childText(node, 'director'),
        'vod_play_from': lineFlags.join(r'$$$'),
        'vod_play_url': lineUrls.join(r'$$$'),
      });
    }
    return out;
  }

  String _childText(XmlElement node, String name) =>
      _first(node.findElements(name))?.innerText.trim() ?? '';

  /// `Iterable.firstOrNull` 在 package:collection 里，这里只为拿第一个元素，
  /// 不值得为此多引一个依赖。
  XmlElement? _first(Iterable<XmlElement> nodes) =>
      nodes.isEmpty ? null : nodes.first;

  // ---------------------------------------------------------------- 工具

  String get _userAgent => 'okhttp/4.12.0';

  bool _looksLikeUrl(String text) => text.startsWith('http://') || text.startsWith('https://');

  String _text(Object? value) => vodText(value);

  int? _asInt(Object? value) => vodAsInt(value);
}

/// 一次响应的统一形态：可能是 JSON 也可能是 XML，解析一次后复用。
class _Payload {
  const _Payload._({
    this.json = const {},
    this.xml,
    this.raw = '',
    this.url = '',
    this.statusCode = 0,
    this.serverError,
  });

  const _Payload.empty({int statusCode = 0}) : this._(statusCode: statusCode);

  factory _Payload.parse(String text, {required String url, int statusCode = 0}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return _Payload.empty(statusCode: statusCode);
    // 内容优先：type 标错在真实配置里很常见。
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          final map = decoded.map((key, value) => MapEntry(key.toString(), value));
          return _Payload._(
            json: map,
            raw: trimmed,
            url: url,
            statusCode: statusCode,
            serverError: vodServerError(map, statusCode: statusCode),
          );
        }
        if (decoded is List) {
          return _Payload._(
            json: {'list': decoded},
            raw: trimmed,
            url: url,
            statusCode: statusCode,
          );
        }
      } on FormatException {
        // 不是合法 JSON，落到 XML 尝试。
      }
    }
    if (trimmed.startsWith('<')) {
      try {
        return _Payload._(
          xml: XmlDocument.parse(trimmed),
          raw: trimmed,
          url: url,
          statusCode: statusCode,
        );
      } on XmlException {
        // 可能是错误页 HTML，当作空响应。
      }
    }
    // 既不是 JSON 也不是 XML，只有 4xx/5xx 才值得报错：有些站 200 返回
    // 一段「无数据」的 HTML，那属于正常空响应，该走降级。
    return _Payload._(
      raw: trimmed,
      url: url,
      statusCode: statusCode,
      serverError: statusCode >= 400 ? _plainError(trimmed, statusCode) : null,
    );
  }

  /// 非 JSON 的错误页：去掉标签与多余空白，截断到一行能显示的长度。
  static String _plainError(String text, int status) {
    final plain = text
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (plain.isEmpty) return 'HTTP $status';
    return plain.length <= 120 ? plain : '${plain.substring(0, 120)}…';
  }

  final Map<String, dynamic> json;
  final XmlDocument? xml;
  final String raw;
  final String url;
  final int statusCode;

  /// 服务端明确给出的失败原因。非 null 表示这次请求已经失败，调用方应直接
  /// 上抛而不是换个 action 再试。
  final String? serverError;

  bool get isJson => json.isNotEmpty;

  /// 有没有可用数据。空 JSON / 错误页都算空，触发下一个 action 重试。
  bool get isEmpty {
    if (serverError != null) return true;
    if (isJson) {
      final list = json['list'];
      final hasList = list is List && list.isNotEmpty;
      final hasClass = json['class'] is List && (json['class'] as List).isNotEmpty;
      return !hasList && !hasClass;
    }
    if (xml != null) {
      return xml!.findAllElements('video').isEmpty && xml!.findAllElements('ty').isEmpty;
    }
    return true;
  }
}
