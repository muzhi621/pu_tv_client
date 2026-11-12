import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:pure_live/core/common/http_client.dart';
import 'package:pure_live/core/utils/hive_pref_util.dart';
import 'package:pure_live/modules/live/iptv/services/iptv_import_manager.dart';
import 'package:pure_live/services/settings/settings.dart';
import 'package:pure_live/services/vod/vod_config.dart';
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

  // ------------------------------------------------------------------
  // 轻量心跳（App 首帧之后启动）
  // ------------------------------------------------------------------

  static Timer? _heartbeatTimer;

  /// 启动 15 分钟定时同步 + 「回到前台立即同步」监听。
  ///
  /// 复用现有 [syncNow]：`GET /api/config?since=...`，云端无变更即 304，流量极小，
  /// 不新增任何 API 路径。幂等：以 [_heartbeatTimer] 为标记，重复调用不会重复建
  /// Timer、也不会重复注册 observer。
  ///
  /// 调用时机应在 WidgetsBinding 就绪之后（本项目挂在 runApp 首帧之后）；内部再
  /// 兜底一次 ensureInitialized，绝不影响「bootstrap 必须在 runApp 之前」的既有顺序。
  static void startHeartbeat() {
    if (_heartbeatTimer != null) return;
    WidgetsFlutterBinding.ensureInitialized();

    // syncNow 内部已全程 try/catch 静默降级；定时回调再包一层，杜绝未捕获异常。
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      try {
        unawaited(syncNow());
      } catch (error) {
        debugPrint('[RemoteConfig] 心跳同步异常（已忽略）: $error');
      }
    });

    // WidgetsBinding 会强引用已注册的 observer，无需另存；幂等由上面的 guard 保证。
    WidgetsBinding.instance.addObserver(_RemoteConfigLifecycleObserver());
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

    // 导航白名单与顺序。groups / defaultGroupId 独立于白名单传入：线上旧配置
    // 只有 7 项 railMenuIds、无 groups，也要走一遍解析以回退内置四大类分组，
    // 保证 4 个一级块始终可见。
    if (document.managed('navigation')) {
      final navigation = document.section('navigation');
      final ids = rcStringList(navigation['railMenuIds']);
      SettingsService.to.app.applyRemoteNavigation(
        railMenuIds: ids,
        sidebarExpanded: navigation.containsKey('sidebarExpanded')
            ? rcBool(navigation['sidebarExpanded'], false)
            : null,
        groups: navigation['groups'],
        defaultGroupId: navigation['defaultGroupId'],
      );
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
  // 一级导航分组（四大类；home_provider / home_page 读取）
  // ------------------------------------------------------------------

  /// 合法的四个一级块 id，与云端 navigation.groups 契约一致。
  static const Set<String> navGroupIds = <String>{'iptv', 'vod', 'live', 'settings'};

  /// 启动默认选中的一级块。云端 navigation.defaultGroupId 缺失 / 非法时回退
  /// iptv，保证线上旧配置（无该字段的 7 项白名单）也能平滑升级。
  static String get navigationDefaultGroupId {
    final raw = _section('navigation')['defaultGroupId'];
    final id = raw is String ? raw.trim().toLowerCase() : '';
    return navGroupIds.contains(id) ? id : 'iptv';
  }

  /// 云端 navigation.groups 原始数组；缺失 / 类型错误返回空数组，由 home_provider
  /// 解析并回退内置四大类分组。不设 managed 门槛：_current 在 syncNow 里无条件
  /// 赋值，导航节是否整节接管都不影响分组读取（线上旧配置无 groups 亦返回空）。
  static List<dynamic> get navigationGroupsRaw {
    final raw = _section('navigation')['groups'];
    return raw is List ? raw : const <dynamic>[];
  }

  // ------------------------------------------------------------------
  // TVBox 影音（影音板块读取）
  // ------------------------------------------------------------------

  /// 云端已把「设备引用哪些源」展开成扁平的 sources / sites，
  /// 这里直接读，终端不需要再关心资源库与 id 引用。
  /// 未接管（`managed` 缺失）时返回空配置，影音板块走原有局域网推送路径。
  static VodConfig get vod => VodConfig.fromSection(_section('vod'));

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
  // 退出确认弹窗（首页 PopScope 读取，对齐 notice* 的写法与兜底语义）
  // ------------------------------------------------------------------

  /// 仅看 exitDialog.enabled（缺省 false）：不设 startup.managed 门槛。
  /// _section/_sub 读的是 _current 完整文档，syncNow 会无条件赋值；_apply 里的
  /// managed 只控制是否把整节写进 AppSettingsModel，不会删掉 startup 节。云端
  /// seed 的 startup.managed 保持 false，避免一改就把协议页/公告/闪屏整节接管。
  /// enabled=false 时零影响，沿用本地原有弹窗。
  static bool get exitDialogEnabled =>
      rcBool(_sub('startup', 'exitDialog')['enabled'], false);

  /// always | once_per_revision | never。缺省兜底为 always，与本地「每次返回都
  /// 确认」的既有行为一致，也对应云端 seed 的默认值。
  static String get exitDialogMode => rcString(_sub('startup', 'exitDialog')['mode'], 'always');

  /// 解析异常也返回 true：宁可保留「取消」，也不能把用户锁进只能退出的弹窗。
  static bool get exitDialogDismissible =>
      rcBool(_sub('startup', 'exitDialog')['dismissible'], true);

  /// 解析异常也返回 true：保持原有捐赠二维码区域可见，零影响。
  static bool get exitDialogShowDonate =>
      rcBool(_sub('startup', 'exitDialog')['showDonate'], true);

  static String get exitDialogTitle =>
      rcLocalized(_sub('startup', 'exitDialog')['titleI18n'], _locale);

  static String get exitDialogBody =>
      rcLocalized(_sub('startup', 'exitDialog')['bodyI18n'], _locale);

  static bool get shouldShowExitDialog {
    if (!exitDialogEnabled || exitDialogMode == 'never') return false;
    if (exitDialogMode == 'always') return true;
    return RemoteConfigStore.exitDialogShownRevision != (_current?.revision ?? 0);
  }

  static Future<void> markExitDialogShown() async {
    await RemoteConfigStore.setExitDialogShownRevision(_current?.revision ?? 0);
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

/// App 生命周期监听：回到前台（resumed）时静默拉取一次配置，让云端及时感知
/// 设备在线并下发最新文档，无需等到下一个 15 分钟心跳。
class _RemoteConfigLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    try {
      unawaited(RemoteConfigService.syncNow());
    } catch (error) {
      debugPrint('[RemoteConfig] 前台恢复同步异常（已忽略）: $error');
    }
  }
}
