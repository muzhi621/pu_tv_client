/// 站点引擎门面：把「HTTP 直连」与「jar 爬虫」两条完全不同的执行路径
/// 收敛成同一组方法，UI 只依赖这个门面。
///
/// 分流规则只看 `api` 前缀：
///   - `csp_Xxx`  → 走 Android 桥接，DexClassLoader 加载源 jar，反射调用
///   - 其余        → 走 [TvboxHttpEngine]，纯 Dart 直连
///
/// 两条路径的返回值统一成 [VodHome] / [VodPage] / [VodDetail]，因为 spider
/// 返回的 JSON 结构与苹果CMS 的 `vod_*` 字段本来就一致（见 `vod_models.dart`）。
library;

import 'dart:convert';

import 'tvbox_http_engine.dart';
import 'tvbox_parser.dart' show VodPlayLine, VodSiteBridge, parsePlayLines;
import 'vod_config.dart';
import 'vod_models.dart';
import 'vod_spider_channel.dart';

/// 播放解析结果。
///
/// [parse] 为 0 表示 [url] 就是最终直链，可直接交给播放器；
/// 为 1 表示需要嗅探/解析器（部分站点把真实地址藏在网页里），当前版本
/// 不内置解析器，会把 [url] 一并抛出，由 UI 决定提示还是尝试直连。
class VodPlayResolved {
  const VodPlayResolved({
    required this.url,
    this.header = const <String, String>{},
    this.parse = 0,
    this.playUrl = '',
  });

  final String url;
  final Map<String, String> header;

  /// 0 = 直链；1 = 需要解析器。
  final int parse;

  /// 少数 spider 用这个字段返回解析器专用的跳转地址。
  final String playUrl;

  bool get isDirect => parse == 0 && url.isNotEmpty;
}

/// 站点能力探测结果，影音页的「测速」与「这个站能不能搜」都读它。
class VodSiteProbe {
  const VodSiteProbe({
    required this.ok,
    this.elapsed = Duration.zero,
    this.categoryCount = 0,
    this.itemCount = 0,
    this.message = '',
  });

  final bool ok;
  final Duration elapsed;
  final int categoryCount;
  final int itemCount;
  final String message;
}

class VodSiteEngine {
  VodSiteEngine({VodConfig? config, TvboxHttpEngine? http})
      : _config = config,
        _http = http ?? TvboxHttpEngine();

  final VodConfig? _config;
  final TvboxHttpEngine _http;

  /// 已经完成 init 的 spider 站点。键用 [_keyOf] 的结果 —— spider 侧按
  /// siteKey 索引实例，键重复会导致两个站点共用一个实例。
  final Set<String> _prepared = <String>{};

  /// 首页：分类 + 推荐。
  Future<VodHome> home(VodSite site) async {
    if (!site.requiresSpiderJar) {
      return _http.home(site.toTvboxSite());
    }
    await _ensurePrepared(site);
    final call = await VodSpiderChannel.homeContent(siteKey: _keyOf(site), filter: true);
    final json = _requireJson(call, site, 'homeContent');
    return parseVodHomeJson(json);
  }

  /// 分类列表。[tid] 为空表示「全部」。
  Future<VodPage> category(
    VodSite site, {
    String? tid,
    int page = 1,
    Map<String, String> filters = const <String, String>{},
  }) async {
    if (!site.requiresSpiderJar) {
      return _http.category(site.toTvboxSite(), tid: tid, page: page);
    }
    await _ensurePrepared(site);
    final call = await VodSpiderChannel.categoryContent(
      siteKey: _keyOf(site),
      tid: tid ?? '',
      pg: '$page',
      filter: true,
      extend: filters,
    );
    final json = _requireJson(call, site, 'categoryContent');
    return parseVodPageJson(json, fallbackPage: page);
  }

  /// 详情与选集。
  Future<VodDetail> detail(VodSite site, String vodId) async {
    if (!site.requiresSpiderJar) {
      return _http.detail(site.toTvboxSite(), vodId);
    }
    await _ensurePrepared(site);
    final call = await VodSpiderChannel.detailContent(
      siteKey: _keyOf(site),
      ids: <String>[vodId],
    );
    final json = _requireJson(call, site, 'detailContent');
    final list = asVodNodes(json['list']);
    if (list.isEmpty) {
      throw VodEngineException('详情为空，站点可能已失效', site: site.name, step: 'detail');
    }
    return parseVodDetailNode(list.first);
  }

  /// 搜索。`quick` 为 true 时 spider 一般只返回少量结果，用于输入联想。
  Future<VodPage> search(
    VodSite site,
    String keyword, {
    int page = 1,
    bool quick = false,
  }) async {
    if (!site.requiresSpiderJar) {
      return _http.search(site.toTvboxSite(), keyword, page: page);
    }
    await _ensurePrepared(site);
    final call = await VodSpiderChannel.searchContent(
      siteKey: _keyOf(site),
      key: keyword,
      quick: quick,
      pg: '$page',
    );
    final json = _requireJson(call, site, 'searchContent');
    return parseVodPageJson(json, fallbackPage: page);
  }

  /// 解析播放地址。
  ///
  /// HTTP 站点没有这一步 —— 详情里的选集地址本身就是最终地址，所以直接
  /// 返回直链。只有 spider 需要额外调 `playerContent`。
  Future<VodPlayResolved> resolvePlay(
    VodSite site, {
    required String flag,
    required String id,
  }) async {
    if (!site.requiresSpiderJar) {
      return VodPlayResolved(url: id);
    }
    await _ensurePrepared(site);
    final call = await VodSpiderChannel.playerContent(
      siteKey: _keyOf(site),
      flag: flag,
      id: id,
    );
    final json = _requireJson(call, site, 'playerContent');
    return VodPlayResolved(
      url: vodText(json['url']),
      header: _parseHeader(json['header']),
      parse: vodAsInt(json['parse']) ?? 0,
      playUrl: vodText(json['playUrl']),
    );
  }

  /// 探测站点可用性。只发最轻的请求，只看「能不能拿到分类」。
  Future<VodSiteProbe> probe(VodSite site) async {
    final watch = Stopwatch()..start();
    try {
      final home = await this.home(site);
      watch.stop();
      return VodSiteProbe(
        ok: !home.isEmpty,
        elapsed: watch.elapsed,
        categoryCount: home.categories.length,
        itemCount: home.items.length,
        message: home.isEmpty ? '站点返回空内容' : '',
      );
    } catch (error) {
      watch.stop();
      return VodSiteProbe(
        ok: false,
        elapsed: watch.elapsed,
        message: _messageOf(error),
      );
    }
  }

  /// 释放 spider 实例。切源或退出影音板块时调用，避免 jar 里的静态状态残留。
  Future<void> release({String? siteKey}) async {
    if (siteKey == null) {
      _prepared.clear();
    } else {
      _prepared.remove(siteKey);
    }
    await VodSpiderChannel.releaseSite(siteKey: siteKey);
  }

  // ---------------------------------------------------------------- 内部

  /// spider 侧用裸 key 索引实例；旧配置可能没有 key，回退到 id（`源id:key`）。
  String _keyOf(VodSite site) => site.key.isEmpty ? site.id : site.key;

  /// 确保 spider 站点已建实例。`jar` 从云端下发的源信息里取 —— 站点本身
  /// 不存 jar，因为它属于源，多个站点共用一个 jar。
  Future<void> _ensurePrepared(VodSite site) async {
    final key = _keyOf(site);
    if (_prepared.contains(key)) return;
    final jar = _config?.jarFor(site) ?? '';
    if (jar.isEmpty) {
      throw VodEngineException(
        '该站点需要爬虫 jar，但所属源没有配置 jar 地址',
        site: site.name,
        step: 'prepare',
      );
    }
    final prep = await VodSpiderChannel.prepareSite(
      siteKey: key,
      jarUrl: jar,
      api: site.api,
      ext: site.ext,
    );
    if (prep.failure != null) {
      throw VodEngineException(
        prep.failure!.message,
        site: site.name,
        step: 'prepare',
      );
    }
    _prepared.add(key);
  }

  Map<String, dynamic> _requireJson(VodSpiderCall call, VodSite site, String step) {
    if (!call.ok) {
      throw VodEngineException(
        call.failure?.message ?? '调用失败',
        site: site.name,
        step: step,
      );
    }
    final json = call.jsonObject;
    if (json == null) {
      throw VodEngineException(
        '返回内容不是 JSON 对象（部分站点返回数组，暂不支持）',
        site: site.name,
        step: step,
      );
    }
    return json;
  }

  /// spider 的 `header` 可能直接是 JSON 字符串，也可能是对象。
  Map<String, String> _parseHeader(Object? raw) {
    if (raw == null) return const <String, String>{};
    Object? decoded = raw;
    if (raw is String) {
      final text = raw.trim();
      if (text.isEmpty) return const <String, String>{};
      // 部分 spider 返回的是 `{"User-Agent":"..."}` 字符串，也可能是
      // `User-Agent: xxx` 这种逐行写法，两种都接。
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        final out = <String, String>{};
        for (final line in text.split('\n')) {
          final index = line.indexOf(':');
          if (index <= 0) continue;
          out[line.substring(0, index).trim()] = line.substring(index + 1).trim();
        }
        return out;
      }
    }
    if (decoded is! Map) return const <String, String>{};
    final out = <String, String>{};
    decoded.forEach((key, value) {
      final k = key.toString().trim();
      final v = vodText(value);
      if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
    });
    return out;
  }

  String _messageOf(Object error) {
    if (error is VodEngineException) return error.message;
    return error.toString();
  }
}
