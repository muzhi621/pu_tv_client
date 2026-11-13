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

  /// true 表示这台设备锁定了库快照，云端再改资源库不影响它。
  final bool lockLibrary;
  final int libraryRevision;

  bool get isEmpty => sources.isEmpty && sites.isEmpty;

  /// 需要 jar 的站点：api 以 csp_ 开头。
  List<VodSite> get spiderSites =>
      sites.where((site) => site.requiresSpiderJar).toList(growable: false);

  /// 纯 HTTP 站点：type 0（XML）/ 1（JSON）/ 4（采集站）。
  List<VodSite> get httpSites =>
      sites.where((site) => !site.requiresSpiderJar).toList(growable: false);

  /// 站点所属源的 jar 地址；源没配 jar 时返回 null。
  String? jarFor(VodSite site) {
    for (final source in sources) {
      if (source.id == site.sourceId) {
        return source.jar.isEmpty ? null : source.jar;
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

class VodSource {
  const VodSource({
    required this.id,
    required this.name,
    this.jar = '',
    this.url = '',
    this.spiderMd5 = '',
    this.spiderFlavor = 'fongmi',
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
      );

  final String id;
  final String name;

  /// spider.jar 地址，`csp_` 站点全靠它加载代码。
  final String jar;

  /// TVBox 配置 json 地址（管理用，终端不直接拉）。
  final String url;

  /// 配置里 `spider` 字段附带的 `;md5;<hash>` 校验和。
  /// 宿主下载 jar 后应比对，防止第三方源被替换（见 #61）。
  final String spiderMd5;

  /// spider 契约流派：`fongmi`（现有 catvod-api.jar）或 `tvboxos`。
  /// 两套 Spider 基类互不兼容，宿主加载前要据此分流。
  final String spiderFlavor;

  bool get hasJar => jar.isNotEmpty;

  bool get isFongmi => spiderFlavor != 'tvboxos';
}

class VodSite {
  const VodSite({
    required this.id,
    required this.sourceId,
    required this.name,
    required this.api,
    this.key = '',
    this.ext = '',
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

  /// TVBox 站点类型：0=XML、1=JSON、3=jar 反射、4=采集站。
  final int type;

  final bool searchable;
  final bool quickSearch;

  bool get requiresSpiderJar => api.startsWith('csp_');

  /// 反射调用时用的类名（`csp_Ali` → `Ali`）。
  String get spiderKey => requiresSpiderJar ? api.substring(4) : api;
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
