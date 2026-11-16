/// TVBox 配置「终端直连」解析层与加载器（双轨下发的 url 模式）。
///
/// 云端既可以把配置展开成 `sites` 下发（parsed 模式，默认、兼容老客户端），
/// 也可以只下发配置 URL（url 模式）。本文件负责后者：终端自己拉取配置、
/// 解析成 [VodSite]，成功则替换该源的站点；**任何失败都保留云端已展开的
/// sites 作为兜底**，绝不因为第三方源失效让影音板块变空。
///
/// 解析逻辑与云端编辑器 `parseTvboxJson` / `collectTvboxConfigs` 对齐：
/// BOM、整行 `//` 注释、尾部逗号、base64 封装、单仓 / 顶层数组 / 多仓 urls、
/// `./` 相对资源、spider 的 `url;md5;hash` 拆分。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pure_live/core/utils/hive_pref_util.dart';

import 'vod_config.dart';

const int _maxSitesPerSource = 200;

/// 多仓最多跟随的子配置数。多仓订阅常有 10+ 个族（每族一个 spider jar），
/// 截到 5 会让后半部分族的站点全部落到错误的 jar 上，找不到类。
const int _maxSubConfigs = 12;

/// 一次解析的产物。
class TvboxConfigResult {
  const TvboxConfigResult({
    this.sites = const <VodSite>[],
    this.jar = '',
    this.spiderMd5 = '',
    this.subUrls = const <String>[],
  });

  final List<VodSite> sites;
  final String jar;
  final String spiderMd5;
  final List<String> subUrls;

  bool get hasSites => sites.isNotEmpty;

  /// 站点级 jar 与源级 jar 相同时清空（不重复下发，省流量；语义不变——
  /// [VodConfig.jarFor] 对空 jar 会回退到源 jar）。
  ///
  /// 只在「这是最终结果」时调用：多仓子配置合并的中途产物不能提前清，
  /// 各族站点的 jar 正是要靠它区分的。
  TvboxConfigResult dedupeJarAgainstSource() {
    if (jar.isEmpty) return this;
    final cleaned = sites
        .map((site) =>
            site.jar == jar ? site.copyWith(jar: '', jarMd5: '') : site)
        .toList(growable: false);
    return TvboxConfigResult(
      sites: cleaned,
      jar: jar,
      spiderMd5: spiderMd5,
      subUrls: subUrls,
    );
  }
}

class SpiderRef {
  const SpiderRef(this.jar, this.md5);

  final String jar;
  final String md5;
}

/// 纯解析层：不发网络请求、不碰平台通道，便于纯 Dart 单测。
class TvboxConfigParser {
  const TvboxConfigParser._();

  /// `./x` / `/x` 按 [baseUrl] 解析成绝对地址；`csp_`、ext 文本、绝对 URL 原样返回。
  static String resolveRef(String value, String baseUrl) {
    final v = value.trim();
    if (v.isEmpty || v.startsWith('http://') || v.startsWith('https://')) return v;
    if (!v.startsWith('./') && !v.startsWith('/')) return v;
    if (baseUrl.isEmpty) return v;
    try {
      return Uri.parse(baseUrl)
          .resolve(v.startsWith('./') ? v.substring(2) : v)
          .toString();
    } catch (_) {
      return v;
    }
  }

  /// `"./fty.jar;md5;<hash>"` → SpiderRef(jar, md5)。
  static SpiderRef parseSpider(Object? raw, String baseUrl) {
    final parts = raw
        .toString()
        .trim()
        .split(';')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    String jar = '';
    String md5 = '';
    if (parts.isNotEmpty) {
      final resolved = resolveRef(parts[0], baseUrl);
      if (resolved.startsWith('http://') || resolved.startsWith('https://')) {
        jar = resolved;
      }
    }
    for (final part in parts.skip(1)) {
      if (part.toLowerCase() == 'md5') continue;
      if (RegExp(r'^[0-9a-fA-F]{16,64}$').hasMatch(part)) {
        md5 = part;
        break;
      }
    }
    return SpiderRef(jar, md5);
  }

  /// 剥 BOM / 整行注释 / 尾部逗号；失败时尝试 base64 封装。
  static Object? decode(String rawText) {
    final raw = rawText.replaceFirst('\uFEFF', '').trim();
    if (raw.isEmpty) return null;
    final direct = _attempt(raw);
    if (direct != null) return direct;
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    if (compact.length >= 40 && RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(compact)) {
      try {
        final bytes = base64Decode(compact);
        final text = utf8.decode(bytes, allowMalformed: true);
        return _attempt(text.replaceFirst('\uFEFF', ''));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Object? _attempt(String value) {
    final cleaned = value
        .split(RegExp(r'\r?\n'))
        .where((line) => !RegExp(r'^\s*//').hasMatch(line))
        .join('\n')
        .replaceAllMapped(RegExp(r',\s*([}\]])'), (match) => match.group(1)!);
    try {
      return jsonDecode(cleaned);
    } catch (_) {
      return null;
    }
  }

  /// 把任意形态的配置拍平成 [TvboxConfigResult]。
  static TvboxConfigResult parse(
    String text, {
    required String sourceId,
    required String baseUrl,
  }) {
    final root = decode(text);
    if (root == null) return const TvboxConfigResult();

    final configs = <Map<String, dynamic>>[];
    void walk(Object? node) {
      if (node is List) {
        // 顶层站点数组（没有外层对象包裹）直接当成一个只有 sites 的配置。
        if (node.any((item) => item is Map && item['api'] is String)) {
          configs.add(<String, dynamic>{'sites': node});
          return;
        }
        for (final item in node) {
          walk(item);
        }
        return;
      }
      if (node is! Map) return;
      configs.add(Map<String, dynamic>.from(node));
    }

    walk(root);
    final sites = <VodSite>[];
    final seen = <String>{};
    final subUrls = <String>[];
    String jar = '';
    String md5 = '';

    for (final config in configs) {
      final spider = parseSpider(config['spider'], baseUrl);
      if (jar.isEmpty && spider.jar.isNotEmpty) jar = spider.jar;
      if (md5.isEmpty && spider.md5.isNotEmpty) md5 = spider.md5;

      // 族 jar：这套配置自己的 spider。多仓聚合只会把第一个源的 spider 记成
      // 源级 jar，其它族的站点（如 Wex*Guard 系）离了自己的 jar 会在
      // prepare 阶段报「找不到类」，所以 csp_ 站点要记住本族 spider。
      final family = spider;
      final rawSites = config['sites'];
      if (rawSites is List) {
        for (final item in rawSites) {
          if (item is! Map) continue;
          if (sites.length >= _maxSitesPerSource) continue;
          final entry = Map<String, dynamic>.from(item);
          final key = _text(entry['key']);
          final api = resolveRef(_text(entry['api']), baseUrl);
          if (key.isEmpty || api.isEmpty) continue;
          if (!api.startsWith('http://') &&
              !api.startsWith('https://') &&
              !api.startsWith('csp_')) continue;
          final id = _siteId(sourceId, key);
          if (!seen.add(id)) continue;
          // 站点自带 jar（TVBox 的站点级 jar 字段，`url;md5;hash` 写法）优先；
          // 没有才继承本族 spider。http/采集站点不需要 jar，不冲压省流量。
          final own = parseSpider(entry['jar'], baseUrl);
          final bool needsJar = api.startsWith('csp_');
          final String siteJar = own.jar.isNotEmpty
              ? own.jar
              : (needsJar ? family.jar : '');
          final String siteMd5 = own.jar.isNotEmpty
              ? own.md5
              : (needsJar ? family.md5 : '');
          sites.add(VodSite(
            id: id,
            sourceId: sourceId,
            name: _text(entry['name']).isEmpty ? key : _text(entry['name']),
            api: api,
            key: key,
            ext: resolveRef(_text(entry['ext']), baseUrl),
            jar: siteJar,
            jarMd5: siteMd5,
            type: _int(entry['type']),
            searchable: _bool(entry['searchable']),
            quickSearch: _bool(entry['quickSearch']),
          ));
        }
      }

      // 多仓 urls 既可能是字符串，也可能是 {url, name}；相对路径按当前配置解析。
      final rawUrls = config['urls'];
      if (rawUrls is List) {
        for (final item in rawUrls) {
          final raw = item is String
              ? item
              : (item is Map ? _text(item['url']) : '');
          final resolved = resolveRef(raw, baseUrl);
          if (!resolved.startsWith('http://') &&
              !resolved.startsWith('https://')) continue;
          if (subUrls.contains(resolved)) continue;
          if (subUrls.length >= _maxSubConfigs) break;
          subUrls.add(resolved);
        }
      }
    }

    return TvboxConfigResult(
      sites: sites,
      jar: jar,
      spiderMd5: md5,
      subUrls: subUrls,
    );
  }
}

/// 带缓存的网络加载层。缓存同时存内存与 Hive（只存原始文本，重新解析即可），
/// 这样首次冷启动、离线时也能立刻拿到上次成功的站点表。
class TvboxConfigLoader {
  TvboxConfigLoader({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
              responseType: ResponseType.plain,
            ));

  static const String _cachePrefix = 'vod_url_cfg_';
  static final Map<String, TvboxConfigResult> _memory =
      <String, TvboxConfigResult>{};

  final Dio _dio;

  static String _cacheKey(String url) => _cachePrefix + url.hashCode.toString();

  /// 同步读缓存；供启动时立即生效，不发网络请求。
  static TvboxConfigResult? cached(String url, String sourceId) {
    final memory = _memory[url];
    if (memory != null) return memory;
    try {
      final text = HivePrefUtil.getString(_cacheKey(url));
      if (text == null || text.isEmpty) return null;
      final result =
          TvboxConfigParser.parse(text, sourceId: sourceId, baseUrl: url)
              .dedupeJarAgainstSource();
      if (!result.hasSites) return null;
      _memory[url] = result;
      return result;
    } catch (_) {
      return null;
    }
  }

  /// 拉主配置 + 最多 12 个子仓；失败返回 null，由调用方回退到云端 sites。
  Future<TvboxConfigResult?> fetch(String url, String sourceId) async {
    try {
      final response = await _dio.get<String>(url);
      final text = response.data ?? '';
      if (text.trim().isEmpty) return null;
      final main =
          TvboxConfigParser.parse(text, sourceId: sourceId, baseUrl: url);
      if (!main.hasSites && main.subUrls.isEmpty) return null;

      final merged = List<VodSite>.from(main.sites);
      final seen = merged.map((site) => site.id).toSet();
      String jar = main.jar;
      String md5 = main.spiderMd5;
      for (final sub in main.subUrls) {
        try {
          final subResponse = await _dio.get<String>(sub);
          final part = TvboxConfigParser.parse(subResponse.data ?? '',
              sourceId: sourceId, baseUrl: sub);
          if (jar.isEmpty && part.jar.isNotEmpty) jar = part.jar;
          if (md5.isEmpty && part.spiderMd5.isNotEmpty) md5 = part.spiderMd5;
          for (final site in part.sites) {
            if (merged.length >= _maxSitesPerSource) break;
            if (seen.add(site.id)) merged.add(site);
          }
        } catch (_) {
          // 单个子仓失效不影响主仓与其它子仓。
        }
      }
      if (merged.isEmpty) return null;
      final result = TvboxConfigResult(
        sites: merged,
        jar: jar,
        spiderMd5: md5,
      ).dedupeJarAgainstSource();
      _memory[url] = result;
      try {
        await HivePrefUtil.setString(_cacheKey(url), text);
      } catch (_) {
        // 缓存写失败不影响本次解析结果。
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  /// 用解析结果替换 [config] 中对应源的站点；没有结果的源保留云端 sites。
  static VodConfig apply(
      VodConfig config, Map<String, TvboxConfigResult> results) {
    if (results.isEmpty) return config;
    final known = config.sources.map((source) => source.id).toSet();
    final sites = <VodSite>[];
    final sources = <VodSource>[];
    for (final source in config.sources) {
      final result = results[source.id];
      if (result != null && result.hasSites) {
        sites.addAll(result.sites);
        // 只下发 URL 的源云端没有 jar，而 TVBox 配置里的 spider 字段刚解析出来：
        // 写回源，否则配置中的 csp_ 站点会因为没有爬虫包而播不了。
        sources.add(result.jar.isEmpty
            ? source
            : source.copyWith(
                jar: result.jar, spiderMd5: result.spiderMd5));
      } else {
        sites.addAll(
            config.sites.where((site) => site.sourceId == source.id));
        sources.add(source);
      }
    }
    // 理论上不会出现不属于任何源的站点，保留它们避免数据意外丢失。
    sites.addAll(
        config.sites.where((site) => !known.contains(site.sourceId)));
    return VodConfig(
      managed: config.managed,
      sources: sources,
      sites: sites,
      sourceIds: config.sourceIds,
      siteIds: config.siteIds,
      lockLibrary: config.lockLibrary,
      libraryRevision: config.libraryRevision,
    );
  }
}

String _text(Object? value) =>
    value == null ? '' : value.toString().trim();

int _int(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

bool _bool(Object? value) => value == true || value == 1 || value == '1';

String _siteId(String sourceId, String key) {
  final raw = '$sourceId:$key';
  if (RegExp(r'^[A-Za-z0-9_:-]{1,96}$').hasMatch(raw)) return raw;
  final clean = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return '$sourceId:${clean.length > 64 ? clean.substring(0, 64) : clean}';
}
