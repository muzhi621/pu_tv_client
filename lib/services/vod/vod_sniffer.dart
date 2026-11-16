import 'dart:convert';

import 'package:pure_live/core/common/http_client.dart';
import 'package:pure_live/exports/package_export.dart';

/// 网页嗅探：把「网页/解析页地址」还原成真实流地址。
///
/// ## 为什么需要它
///
/// TVBox 的 `playerContent` 用 `parse` 字段说明返回的地址是什么性质：
/// `0` = 直链（可以直接播），`1` = 需要解析器（返回的是**网页**，真正的流
/// 地址要从网页里嗅探出来）。
///
/// 之前的处理只是弹一句「该地址需要解析器，已尝试直连」然后把网页地址丢给
/// 播放器——播放器拿到 HTML 必然失败，等于这类站点 100% 播不了。
///
/// ## 它做什么
///
/// 抓一次页面，在正文里找形如 `xxx.m3u8` / `.mp4` / `.flv` 的地址，按
/// 「m3u8 优先」挑一个交回去。找不到就返回空串，调用方退回原行为。
///
/// ## 边界（重要）
///
/// 这是**兜底**，不是通用解析器：
///
/// * 只在页面正文里出现完整流地址时才有效。页面靠 JS 运行时才拼出地址的
///   （纯前端渲染），这里拿不到——那种必须靠配置里的 `parses` 解析接口，
///   或者 WebView 嗅探。
/// * 解析接口返回的 JSON（`{"url": "...", "header": {...}}`）也能解出来，
///   这类接口其实不需要嗅探，直接读 JSON 就行。
///
/// 所以它只把「本来必然失败」变成「多数情况能播」，不会让任何原本能播的
/// 地址变差。
class VodSniffer {
  const VodSniffer._();

  /// 抓页面时最多读多少正文。嗅探只需要开头部分，超过这个量基本没有意义，
  /// 也能避免大页面拖垮内存。
  static const int _maxBytes = 2 * 1024 * 1024;

  /// 页面默认 UA。有些解析页对 UA 很敏感（给移动端 UA 才返回真地址）。
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 真流地址的正则。刻意宽松：URL 里允许带查询串（不少 m3u8 带 token）。
  static final RegExp _streamPattern = RegExp(
    r'''https?://[^\s"'<>\s\\)]+?\.(?:m3u8|mp4|flv|ismv?|mpegts|m3u)(?:\?[^\s"'<>\s\\)]*)?''',
    caseSensitive: false,
  );

  /// 协议相对地址（`//host/path.m3u8`）——不少页面这么写。
  static final RegExp _protocolRelativePattern = RegExp(
    r'''(?<!:)//[^\s"'<>\s\\)]+?\.(?:m3u8|mp4|flv|ismv?|mpegts|m3u)(?:\?[^\s"'<>\s\\)]*)?''',
    caseSensitive: false,
  );

  /// 嗅探结果：真实地址 + 播放时建议带的请求头。
  class Result {
    const Result(this.url, this.headers);

    final String url;
    final Map<String, String> headers;
  }

  /// 嗅探一个页面地址，返回真实流地址；失败返回 null。
  ///
  /// [headers] 是站点给的播放头（UA/Referer 等），会带上一起请求页面。
  static Future<Result?> sniff(String pageUrl, {Map<String, String> headers = const <String, String>{}}) async {
    final target = pageUrl.trim();
    if (target.isEmpty || !target.startsWith('http')) return null;

    try {
      final response = await HttpClient.instance.dio.get<List<int>>(
        target,
        options: Options(
          responseType: ResponseType.bytes,
          // 解析页经常返回 4xx/5xx 也带着正文，照收不误。
          validateStatus: (code) => code != null && code < 600,
          headers: _requestHeaders(headers),
        ),
      );

      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;

      // 只取前 _maxBytes，避免大页面占内存。
      final limited = bytes.length > _maxBytes ? bytes.sublist(0, _maxBytes) : bytes;
      var text = String.fromCharCodes(limited);

      // 正文可能是 UTF-8，也可能是 GBK（老解析站常见）。UTF-8 解出来有替换
      // 字符也不要紧——我们要找的流地址是 ASCII，不会被编码影响。
      final found = _extract(text);
      if (found == null) return null;

      // 播放真实流时通常要带上 Referer（指向原页面）与 UA。
      final playHeaders = _requestHeaders(headers);
      playHeaders.removeWhere((key, _) => key.toLowerCase() == 'referer');
      playHeaders['referer'] = target;
      return Result(found, playHeaders);
    } catch (_) {
      // 嗅探是兜底，失败就失败，不能因此影响正常播放。
      return null;
    }
  }

  /// 组装请求头。
  ///
  /// 单独写成一个方法而不是在 map 字面量里用 `for` + `if`：字面量里同一个
  /// 常量键出现两次是编译错误（'user-agent' 既给默认值又可能被站点覆盖）。
  static Map<String, String> _requestHeaders(Map<String, String> headers) {
    final result = <String, String>{'user-agent': _defaultUserAgent};
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'user-agent') {
        result['user-agent'] = entry.value;
      }
    }
    return result;
  }

  /// 从正文里挑一个流地址。
  static String? _extract(String raw) {
    // JSON 里的转义：播放器页面常把地址写成 "https:\/\/host\/a.m3u8"，
    // 不还原的话正则匹配不到。
    final text = raw.replaceAll(r'\/', '/').replaceAll(r'\u002F', '/').replaceAll(r'\u002f', '/');

    // 先试 JSON：解析接口返回 {"url": "..."} 的情况最省事，也最准。
    final fromJson = _extractFromJson(text);
    if (fromJson != null) return fromJson;

    final candidates = <String>[];
    for (final match in _streamPattern.allMatches(text)) {
      candidates.add(match.group(0)!);
    }
    for (final match in _protocolRelativePattern.allMatches(text)) {
      candidates.add('https:${match.group(0)}');
    }
    if (candidates.isEmpty) return null;

    // m3u8 优先：直播/点播的通用格式，兼容性最好；其次 mp4、flv。
    const order = <String>['.m3u8', '.mp4', '.flv', '.ism', '.ts', '.m3u'];
    for (final ext in order) {
      for (final candidate in candidates) {
        final path = Uri.tryParse(candidate)?.path.toLowerCase() ?? '';
        if (path.endsWith(ext)) return candidate;
      }
    }
    return candidates.first;
  }

  /// JSON 形态的解析结果：`{"url": "...", "header": {...}}`。
  static String? _extractFromJson(String text) {
    // 只在看起来像 JSON 时才尝试解析，避免对大 HTML 做无谓的 jsonDecode。
    final trimmed = text.trimLeft();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      return _findUrlInJson(decoded, 0);
    } catch (_) {
      return null;
    }
  }

  /// 递归找 JSON 里的第一个流地址。
  static String? _findUrlInJson(Object? node, int depth) {
    if (depth > 4) return null;
    if (node is Map) {
      // 常见字段名：url / playUrl / m3u8 / src / file。
      for (final key in const <String>['url', 'playUrl', 'm3u8', 'src', 'file']) {
        final value = node[key];
        if (value is String) {
          final candidate = value.trim();
          if (candidate.startsWith('http') && _looksLikeStream(candidate)) return candidate;
        }
      }
      for (final value in node.values) {
        final found = _findUrlInJson(value, depth + 1);
        if (found != null) return found;
      }
      return null;
    }
    if (node is List) {
      for (final item in node) {
        final found = _findUrlInJson(item, depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  static bool _looksLikeStream(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.m3u8') ||
        path.endsWith('.mp4') ||
        path.endsWith('.flv') ||
        path.endsWith('.ism') ||
        path.endsWith('.ismv') ||
        path.endsWith('.mpegts');
  }
}
