/// 云端下发的 TVBox 影音配置。
///
/// 服务端 `viewDocument` 已经把「设备引用了哪些源」展开成扁平的
/// `sources` + `sites` 列表（见 contract.js 的 `expandVodSites`），
/// 所以这里不需要再关心资源库和 id 引用，直接按字段读即可。
///
/// 站点分两类，后续两套完全不同的执行路径：
///   - `api` 以 `csp_` 开头 → 代码在源级 jar 里，走 Android 桥接反射调用
///   - 其余（http 开头的采集接口 / type 0 的 XML）→ 纯 HTTP，Dart 侧直连
class VodConfig {
  const VodConfig({
    this.managed = false,
    this.sources = const <VodSource>[],
    this.sites = const <VodSite>[],
    this.sourceIds = const <String>[],
    this.siteIds = const <String>[],
    this.defaultSiteId = '',
    this.lockLibrary = false,
    this.libraryRevision = 0,
  });

  factory VodConfig.fromSection(Map<String, dynamic> raw) {
    if (raw.isEmpty) return const VodConfig();
    return VodConfig(
      managed: raw['managed'] == true,
      sources: _list(raw['sources']).map(VodSource.fromJson).toList(growable: false),
      sites: _list(raw['sites']).map(VodSite.fromJson).toList(growable: false),
      sourceIds: _strings(raw['sourceIds']),
      siteIds: _strings(raw['siteIds']),
      // 云端「默认站点」：打开影音时先选谁。服务端已在展开时校验过它确实
      // 在下发列表里，这里仍按 id 找一次，找不到就回退第一个站点——老配置
      // 没有这个字段，行为与升级前完全一致。
      defaultSiteId: _str(raw['defaultSiteId']),
      lockLibrary: raw['lockLibrary'] == true,
      libraryRevision: raw['libraryRevision'] is int ? raw['libraryRevision'] as int : 0,
    );
  }

  static const VodConfig empty = VodConfig();

  final bool managed;
  final List<VodSource> sources;
  final List<VodSite> sites;

  /// 设备引用的源 id（管理用；终端播放时看 `sources` 就够）。
  final List<String> sourceIds;
  final List<String> siteIds;

  /// 云端指定的默认站点 id；空 = 没有指定。
  final String defaultSiteId;

  /// true 表示这台设备锁定了库快照，云端再改资源库不影响它。
  final bool lockLibrary;
  final int libraryRevision;

  bool get isEmpty => sources.isEmpty && sites.isEmpty;

  /// 打开影音时的首屏站点。
  ///
  /// 云端指定的 [defaultSiteId] 优先；没指定、或那个站点已经被库删掉/被白名单
  /// 排掉（服务端展开时会清空，但客户端仍要能兜住旧数据），回退第一个站点。
  /// 影音页的三处重建（首次、配置刷新、手动重拉）都走这里，避免默认站点只在
  /// 冷启动时生效。
  VodSite? get preferredSite {
    if (sites.isEmpty) return null;
    if (defaultSiteId.isNotEmpty) {
      for (final site in sites) {
        if (site.id == defaultSiteId) return site;
      }
    }
    return sites.first;
  }

  /// 需要 jar 的站点：api 以 csp_ 开头。
  List<VodSite> get spiderSites =>
      sites.where((site) => site.requiresSpiderJar).toList(growable: false);

  /// 纯 HTTP 站点：type 0（XML）/ 1（JSON）/ 4（采集站）。
  List<VodSite> get httpSites =>
      sites.where((site) => !site.requiresSpiderJar).toList(growable: false);

  /// 站点所属源的 jar 地址；站点自带 jar 时优先用站点的，源没配 jar 时返回 null。
  String? jarFor(VodSite site) {
    if (site.jar.isNotEmpty) return site.jar;
    for (final source in sources) {
      if (source.id == site.sourceId) {
        return source.jar.isEmpty ? null : source.jar;
      }
    }
    return null;
  }

  /// 预热用：所有 `csp_` 站点真正依赖的 jar（按 URL 去重）。
  ///
  /// 站点级 jar 覆盖源级 jar 的规则不在这里重写，一律走 [jarFor]，避免两处
  /// 判定漂移——多仓聚合里各族站点自带 jar，漏掉哪一条都会让预热白做。
  List<VodJarTarget> get jarTargets {
    final seen = <String>{};
    final out = <VodJarTarget>[];
    for (final site in sites) {
      if (!site.requiresSpiderJar) continue;
      final String url = jarFor(site) ?? '';
      if (url.isEmpty || !seen.add(url)) continue;
      out.add(VodJarTarget(url: url, md5: spiderMd5For(site) ?? ''));
    }
    return out;
  }

  /// 与 [jarFor] 同一条 jar 的 md5 校验和（配置里 `url;md5;<hash>` 的 hash）。
  String? spiderMd5For(VodSite site) {
    if (site.jar.isNotEmpty) return site.jarMd5.isEmpty ? null : site.jarMd5;
    for (final source in sources) {
      if (source.id == site.sourceId) {
        return source.spiderMd5.isEmpty ? null : source.spiderMd5;
      }
    }
    return null;
  }

  /// 按源分组，UI 上「切换源 → 看站点」用。
  Map<VodSource, List<VodSite>> get groupedSites {
    final grouped = <VodSource, List<VodSite>>{};
    for (final source in sources) {
      grouped[source] = sites
          .where((site) => site.sourceId == source.id)
          .toList(growable: false);
    }
    return grouped;
  }
}

/// 预热目标：一条 spider jar 地址 + 配置声明的 md5（可能为空）。
///
/// 单独建类而不是用 record，是因为它要跨 `vod_config` / `vod_jar_warmer` /
/// 平台通道三层传递，具名字段读起来比 `(url, md5)` 元组清楚。
class VodJarTarget {
  const VodJarTarget({required this.url, this.md5 = ''});

  final String url;
  final String md5;

  @override
  String toString() => 'VodJarTarget($url, md5: ${md5.isEmpty ? '-' : md5})';
}

class VodSource {
  const VodSource({
    required this.id,
    required this.name,
    this.jar = '',
    this.url = '',
    this.spiderMd5 = '',
    this.spiderFlavor = 'fongmi',
    this.mode = 'parsed',
  });

  factory VodSource.fromJson(Map<String, dynamic> json) => VodSource(
        id: _str(json['id']),
        name: _str(json['name']),
        jar: _str(json['jar']),
        url: _str(json['url']),
        spiderMd5: _str(json['spiderMd5']),
        spiderFlavor: _str(json['spiderFlavor']).isEmpty
            ? 'fongmi'
            : _str(json['spiderFlavor']),
        // 双轨下发模式：parsed = 用云端展开的 sites；url = 终端自己拉配置解析。
        // 老云端不带这个字段时默认 parsed，行为与升级前完全一致。
        mode: json['mode'] == 'url' ? 'url' : 'parsed',
      );

  final String id;
  final String name;

  /// spider.jar 地址，`csp_` 站点全靠它加载代码。
  final String jar;

  /// TVBox 配置 json 地址。`mode == 'url'` 时终端直接拉它自己解析；
  /// 其余情况仅作管理展示，站点走云端已展开的 [VodConfig.sites]。
  final String url;

  /// 下发模式：`parsed`（默认，云端解析）或 `url`（终端直连解析）。
  final String mode;

  bool get isUrlMode => mode == 'url' && url.isNotEmpty;

  /// 配置里 `spider` 字段附带的 `;md5;<hash>` 校验和。
  /// 宿主下载 jar 后应比对，防止第三方源被替换（见 #61）。
  final String spiderMd5;

  /// spider 契约流派：`fongmi`（现有 catvod-api.jar）或 `tvboxos`。
  /// 两套 Spider 基类互不兼容，宿主加载前要据此分流。
  final String spiderFlavor;

  bool get hasJar => jar.isNotEmpty;

  bool get isFongmi => spiderFlavor != 'tvboxos';

  /// url 模式下云端通常没有 jar，用终端解析配置时读到的 `spider` 字段补齐。
  VodSource copyWith({String? jar, String? spiderMd5}) => VodSource(
        id: id,
        name: name,
        jar: jar ?? this.jar,
        url: url,
        spiderMd5: spiderMd5 ?? this.spiderMd5,
        spiderFlavor: spiderFlavor,
        mode: mode,
      );
}

class VodSite {
  const VodSite({
    required this.id,
    required this.sourceId,
    required this.name,
    required this.api,
    this.key = '',
    this.ext = '',
    this.jar = '',
    this.jarMd5 = '',
    this.type = 0,
    this.searchable = false,
    this.quickSearch = false,
  });

  factory VodSite.fromJson(Map<String, dynamic> json) => VodSite(
        id: _str(json['id']),
        sourceId: _str(json['sourceId']),
        name: _str(json['name']),
        api: _str(json['api']),
        key: _str(json['key']),
        ext: _str(json['ext']),
        jar: _str(json['jar']),
        jarMd5: _str(json['jarMd5']),
        type: json['type'] is int ? json['type'] as int : 0,
        searchable: json['searchable'] == 1 || json['searchable'] == true,
        quickSearch: json['quickSearch'] == 1 || json['quickSearch'] == true,
      );

  final String id;
  final String sourceId;
  final String name;

  /// 站点在 TVBox 配置里的原始 key。`id` 是云端拼的 `源id:key`，
  /// 传给 spider 或写进收藏时必须用这个裸 key。
  final String key;

  /// `csp_Xxx` 走 jar；http 开头走直连采集接口。
  final String api;

  /// spider 初始化时原样透传的扩展参数。
  final String ext;

  /// 站点级 spider jar 地址。TVBox 里站点可自带 `jar` 覆盖顶层 spider，
  /// 多仓聚合里「族 jar」也冲压到这里——聚合配置只保留第一个源的 spider，
  /// 其它族的站点（如 Wex*Guard 系）离了自己的 jar 就找不到类。
  /// 为空表示用所属源的 jar（见 [VodConfig.jarFor]）。
  final String jar;

  /// [jar] 的 md5 校验和（`url;md5;<hash>` 的 hash）。
  final String jarMd5;

  /// TVBox 站点类型：0=XML、1=JSON、3=jar 反射、4=采集站。
  final int type;

  final bool searchable;
  final bool quickSearch;

  bool get requiresSpiderJar => api.startsWith('csp_');

  /// 反射调用时用的类名（`csp_Ali` → `Ali`）。
  String get spiderKey => requiresSpiderJar ? api.substring(4) : api;

  VodSite copyWith({String? jar, String? jarMd5}) => VodSite(
        id: id,
        sourceId: sourceId,
        name: name,
        api: api,
        key: key,
        ext: ext,
        jar: jar ?? this.jar,
        jarMd5: jarMd5 ?? this.jarMd5,
        type: type,
        searchable: searchable,
        quickSearch: quickSearch,
      );
}

Map<String, dynamic> _map(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, item) => MapEntry(key.toString(), item));
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _list(dynamic value) {
  if (value is! List) return const <Map<String, dynamic>>[];
  return value.whereType<Map>().map(_map).toList(growable: false);
}

List<String> _strings(dynamic value) {
  if (value is! List) return const <String>[];
  return value.whereType<String>().map((item) => item.trim()).where((item) => item.isNotEmpty).toList(growable: false);
}

String _str(dynamic value) => value is String ? value : (value == null ? '' : value.toString());
