import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pure_live/core/common/http_client.dart';
import 'package:pure_live/core/utils/hive_pref_util.dart';
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
        _apply(cached);
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
      _apply(document);
    } catch (error) {
      debugPrint('[RemoteConfig] 同步失败，沿用本地配置: $error');
    }
  }

  static Future<RemoteConfigDocument?> _fetch(String endpoint, String token, int revision) async {
    final base = endpoint.replaceAll(RegExp(r'/+$'), '');
    try {
      final response = await HttpClient.instance.dio
          .get<dynamic>(
            '$base/api/config',
            queryParameters: <String, dynamic>{'since': revision},
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

  static void _apply(RemoteConfigDocument document) {
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
