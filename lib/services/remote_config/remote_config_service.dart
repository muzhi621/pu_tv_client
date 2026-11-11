import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pure_live/core/common/http_client.dart';
import 'package:pure_live/core/utils/hive_pref_util.dart';
import 'package:pure_live/modules/live/iptv/services/iptv_import_manager.dart';
import 'package:pure_live/services/settings/settings.dart';
import 'remote_config_model.dart';
import 'remote_config_store.dart';

/// 云端配置下发客户端（需求文档 FR-03）。
///
/// 三条铁律：
/// 1. 只在 `AppInitializer.initialize()` 的迁移之后、`runApp()` 之前注入，
///    否则首帧菜单/弹窗会读到旧值。
/// 2. apply 必须通过各 controller 的 update / 专用方法同时写内存 state 与
///    Hive；只写 Hive 会被 provider 的旧 state 回写覆盖。
/// 3. 任何网络/解析失败都静默降级本地缓存或内置 seed，绝不阻断看电视。
class RemoteConfigService {
  const RemoteConfigService._();

  static RemoteConfigDocument? _current;
  static bool _bootstrapped = false;

  static const Duration _networkTimeout = Duration(milliseconds: 1500);

  /// 云端下发的 IPTV 源在终端固定写成一个播放列表，便于重复导入时覆盖。
  static const String _cloudIptvProvider = 'cloud_iptv';
  static String? _cachedAppVersion;

  static RemoteConfigDocument? get current => _current;

  static String get _locale => PlatformDispatcher.instance.locale.languageCode;

  static Map<String, dynamic> _section(String name) =>
      _current?.section(name) ?? <String, dynamic>{};

  static Map<String, dynamic> _sub(String sectionName, String name) =>
      _current?.subsection(sectionName, name) ?? <String, dynamic>{};

  // ------------------------------------------------------------------
  // 冷启动注入
  // ------------------------------------------------------------------

  static Future<void> bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    try {
      // 先用本地缓存生效，保证断网/首次无网也能拿到上次配置。
      final cached = RemoteConfigStore.readDocument();
      if (cached != null) {
        _current = cached;
        await _apply(cached);
      }
      await syncNow();
    } catch (error) {
      debugPrint('[RemoteConfig] bootstrap 已降级到本地配置: $error');
    }
  }

  /// 拉取一次云端配置。304 / 超时 / 解析失败均静默返回，不抛异常。
  static Future<void> syncNow() async {
    final endpoint = RemoteConfigStore.endpoint;
    if (endpoint.isEmpty) return; // 未配置 = 纯本地运行
    try {
      final document = await _fetch(endpoint, RemoteConfigStore.token, RemoteConfigStore.revision);
      if (document == null) return;
      if (document.revision < RemoteConfigStore.revision) return; // 防倒退
      await RemoteConfigStore.saveDocument(document);
      _current = document;
      await _apply(document);
    } catch (error) {
      debugPrint('[RemoteConfig] 同步失败，沿用本地配置: $error');
    }
  }

  static Future<RemoteConfigDocument?> _fetch(String endpoint, String token, int revision) async {
    final base = endpoint.replaceAll(RegExp(r'/+$'), '');
    try {
      final version = await _appVersion();
      final query = <String, dynamic>{
        // 首次启动不带 since：新设备文档 revision 从 1 起，带 since=0 会命中 304。
        if (revision > 0) 'since': revision,
        'deviceId': RemoteConfigStore.deviceId,
        if (version.isNotEmpty) 'appVersion': version,
      };
      final response = await HttpClient.instance.dio
          .get<dynamic>(
            '$base/api/config',
            queryParameters: query,
            options: Options(
              responseType: ResponseType.json,
              // 304 是预期的「未变更」，不能让 Dio 当成异常。
              validateStatus: (code) => code == 200 || code == 304,
              headers: <String, String>{
                'Accept': 'application/json',
                'Cache-Control': 'no-cache',
                if (token.isNotEmpty) 'Authorization': 'Bearer $token',
              },
            ),
          )
          .timeout(_networkTimeout);
      if (response.statusCode == 304) return null;
      final data = response.data;
      final Map<String, dynamic> json;
      if (data is String) {
        json = Map<String, dynamic>.from(jsonDecode(data) as Map);
      } else if (data is Map) {
        json = Map<String, dynamic>.from(data);
      } else {
        throw const FormatException('配置响应不是 JSON 对象');
      }
      return RemoteConfigDocument.fromJson(json);
    } catch (error) {
      debugPrint('[RemoteConfig] 请求失败（静默降级）: $error');
      return null;
    }
  }

  // ------------------------------------------------------------------
  // 按节 apply：只改 managed:true 的节
  // ------------------------------------------------------------------

  static Future<void> _apply(RemoteConfigDocument document) async {
    if (!HivePrefUtil.isInitialized) return;

    final anyManaged = document.sections.values.any(
      (value) => value is Map && value['managed'] == true,
    );
    if (anyManaged) {
      _backupLocalOnce();
    } else {
      final snapshot = RemoteConfigStore.consumeLocalSnapshot();
      if (snapshot != null) _restoreLocal(snapshot);
    }

    // 站点白名单：关闭斗鱼后冷启动不再有斗鱼页签。
    if (document.managed('sites')) {
      final ids = rcStringList(document.section('sites')['enabledSiteIds']);
      // 空列表绝不写入：global_room_push.dart 的 .first 会抛错。
      if (ids.isNotEmpty) SettingsService.to.fav.applyRemoteSiteWhitelist(ids);
    }

    // 导航白名单与顺序。
    if (document.managed('navigation')) {
      final navigation = document.section('navigation');
      final ids = rcStringList(navigation['railMenuIds']);
      if (ids.isNotEmpty) {
        SettingsService.to.app.applyRemoteNavigation(
          railMenuIds: ids,
          sidebarExpanded: navigation.containsKey('sidebarExpanded')
              ? rcBool(navigation['sidebarExpanded'], false)
              : null,
        );
      }
    }

    // 启动页与更新开关写进 AppSettingsModel（state + Hive 一起写）。
    final startupManaged = document.managed('startup');
    final updateManaged = document.managed('update');
    if (startupManaged || updateManaged) {
      final startup = document.section('startup');
      final update = document.section('update');
      SettingsService.to.app.applyRemoteStartupAndUpdate(
        showSplashPage: startupManaged && startup.containsKey('showSplashPage')
            ? rcBool(startup['showSplashPage'], true)
            : null,
        enableAutoCheckUpdate: updateManaged && update.containsKey('autoCheck')
            ? rcBool(update['autoCheck'], true)
            : null,
      );
    }

    // IPTV 频道列表写 Drift，必须在 runApp 之前完成。任何异常都不能阻断启动。
    try {
      await _applyIptv(document);
    } catch (error) {
      debugPrint('[RemoteConfig] IPTV 下发失败（沿用本地列表）: $error');
    }
  }


  /// 读取包内版本号，仅用于云端设备列表展示；失败不影响启动。
  static Future<String> _appVersion() async {
    if (_cachedAppVersion != null) return _cachedAppVersion!;
    try {
      final raw = await rootBundle.loadString('assets/version.json');
      final decoded = jsonDecode(raw);
      _cachedAppVersion = decoded is Map ? (decoded['version'] ?? '').toString() : '';
    } catch (_) {
      _cachedAppVersion = '';
    }
    return _cachedAppVersion!;
  }

  /// 把云端 iptv 节写成本地播放列表。
  ///
  /// 复用 IptvImportManager 而不是裸写 Drift：这样能自动获得 M3U/TXT 解析、
  /// 稳定频道 ID（收藏/隐藏不丢）、事务写入与失效频道清理。冷启动注入保证首帧
  /// 的 IptvSite.getCategores() 读到的就是新数据，无需 invalidate provider。
  static Future<void> _applyIptv(RemoteConfigDocument document) async {
    final iptv = document.section('iptv');
    if (iptv['managed'] != true) return;
    final rawChannels = iptv['channels'];
    if (rawChannels is! List || rawChannels.isEmpty) return;

    // 冷启动会先用缓存文档 apply 一次、再 apply 新文档，用标记保证导入幂等。
    final stamp = '${RemoteConfigStore.deviceId}:${document.revision}:${rawChannels.length}';
    if (RemoteConfigStore.iptvStamp == stamp) return;

    final grouped = <String, List<Map<String, String>>>{};
    for (final item in rawChannels) {
      if (item is! Map) continue;
      final name = (item['name'] ?? '').toString().trim();
      final url = (item['url'] ?? '').toString().trim();
      if (name.isEmpty || url.isEmpty) continue;
      final group = (item['group'] ?? '').toString().trim();
      final key = group.isEmpty ? '未分组' : group;
      grouped.putIfAbsent(key, () => <Map<String, String>>[])
          .add(<String, String>{'name': name, 'url': url});
    }
    if (grouped.isEmpty) return;

    // TXT genre 格式：分组行 + 名称,地址 行，与项目内置 TxtParser 完全兼容。
    final buffer = StringBuffer();
    grouped.forEach((group, channels) {
      buffer.writeln('$group,#genre#');
      for (final channel in channels) {
        buffer.writeln('${channel['name']},${channel['url']}');
      }
    });

    final ok = await IptvImportManager().importFromWebString(
      buffer.toString(),
      '$_cloudIptvProvider.txt',
      forceUpdate: true,
      showTips: false,
    );
    if (ok) await RemoteConfigStore.setIptvStamp(stamp);
  }

  static void _backupLocalOnce() {
    final app = SettingsService.to.appState;
    final fav = SettingsService.to.favState;
    RemoteConfigStore.saveLocalSnapshotOnce(<String, dynamic>{
      'savedMenuIds': app.savedMenuIds,
      'sidebarExpanded': app.sidebarExpanded,
      'showSplashPage': app.showSplashPage,
      'enableAutoCheckUpdate': app.enableAutoCheckUpdate,
      'hotAreasList': fav.hotAreasList,
      'siteCatalogMigration': fav.siteCatalogMigration,
    });
  }

  static void _restoreLocal(Map<String, dynamic> snapshot) {
    SettingsService.to.app.restoreLocalSettings(
      savedMenuIds: rcStringList(snapshot['savedMenuIds']),
      sidebarExpanded: rcBool(snapshot['sidebarExpanded'], false),
      showSplashPage: rcBool(snapshot['showSplashPage'], true),
      enableAutoCheckUpdate: rcBool(snapshot['enableAutoCheckUpdate'], true),
    );
    SettingsService.to.fav.restoreLocalSiteCatalog(
      rcStringList(snapshot['hotAreasList']),
      rcInt(snapshot['siteCatalogMigration'], 0),
    );
  }

  // ------------------------------------------------------------------
  // 导航栏（home_provider 读取）
  // ------------------------------------------------------------------

  /// 云端接管时，sideMenuList 必须使用显式数组，不能走 normalizeMenuIds
  /// （它会把缺失的 known id 全部补回，白名单会失效）。
  static bool get navigationManaged => _current?.managed('navigation') ?? false;

  // ------------------------------------------------------------------
  // 协议（路由守卫与协议页读取）
  // ------------------------------------------------------------------

  static bool get agreementRequired {
    final startup = _section('startup');
    if (startup['managed'] != true) return false;
    final agreement = _sub('startup', 'agreement');
    if (!rcBool(agreement['enabled'], true)) return false;
    final required = rcInt(agreement['requiredVersion'], 1);
    return RemoteConfigStore.agreementAcceptedVersion < required;
  }

  static String get agreementTitle =>
      rcLocalized(_sub('startup', 'agreement')['titleI18n'], _locale);

  static String get agreementBody =>
      rcLocalized(_sub('startup', 'agreement')['bodyI18n'], _locale);

  static Future<void> markAgreementAccepted() async {
    final required = rcInt(_sub('startup', 'agreement')['requiredVersion'], 1);
    await RemoteConfigStore.setAgreementAcceptedVersion(required);
  }

  // ------------------------------------------------------------------
  // 公告（首页首帧后读取）
  // ------------------------------------------------------------------

  static bool get noticeEnabled {
    if (_section('startup')['managed'] != true) return false;
    return rcBool(_sub('startup', 'notice')['enabled'], false);
  }

  static String get noticeMode => rcString(_sub('startup', 'notice')['mode'], 'once_per_revision');

  /// 解析异常也返回 true：宁可让公告可关闭，也不能把用户卡在主界面外。
  static bool get noticeDismissible => rcBool(_sub('startup', 'notice')['dismissible'], true);

  static String get noticeTitle => rcLocalized(_sub('startup', 'notice')['titleI18n'], _locale);

  static String get noticeBody => rcLocalized(_sub('startup', 'notice')['bodyI18n'], _locale);

  static bool get shouldShowNotice {
    if (!noticeEnabled || noticeMode == 'never') return false;
    if (noticeMode == 'always') return true;
    return RemoteConfigStore.noticeShownRevision != (_current?.revision ?? 0);
  }

  static Future<void> markNoticeShown() async {
    await RemoteConfigStore.setNoticeShownRevision(_current?.revision ?? 0);
  }

  // ------------------------------------------------------------------
  // 更新策略（VersionUtil / HomeUpdateDialog 读取）
  // ------------------------------------------------------------------

  static bool get updateManaged => _section('update')['managed'] == true;

  static bool get updateAutoCheck =>
      updateManaged ? rcBool(_section('update')['autoCheck'], true) : true;

  static String get updatePrompt =>
      updateManaged ? rcString(_section('update')['prompt'], 'dialog') : 'dialog';

  static int get updateCheckIntervalHours =>
      updateManaged ? rcInt(_section('update')['checkIntervalHours'], 24) : 24;

  /// 完整的 version.json URL 列表；为空时沿用内置 GitHub 镜像。
  static List<String> get updateMirrorUrls =>
      updateManaged ? rcStringList(_section('update')['mirrorUrls']) : <String>[];

  static bool get updateAllowUserOverride =>
      updateManaged ? rcBool(_section('update')['allowUserOverride'], true) : true;

  static bool get updateAllowPrerelease =>
      updateManaged ? rcBool(_section('update')['allowPrerelease'], false) : false;

  static String get updateMinSupportedVersion =>
      updateManaged ? rcString(_section('update')['minSupportedVersion'], '') : '';

  static String get updateChangelog =>
      rcLocalized(_section('update')['changelogI18n'], _locale);

  static bool shouldCheckUpdateNow() {
    final hours = updateCheckIntervalHours;
    if (hours <= 0) return true;
    final last = RemoteConfigStore.lastUpdateCheckAt;
    if (last <= 0) return true;
    return DateTime.now().millisecondsSinceEpoch - last >= hours * 3600 * 1000;
  }

  static Future<void> markUpdateChecked() async {
    await RemoteConfigStore.setLastUpdateCheckAt(DateTime.now().millisecondsSinceEpoch);
  }
}
