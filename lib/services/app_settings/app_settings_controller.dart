import 'app_settings_model.dart';
import 'package:flutter/foundation.dart';
import 'package:pure_live/platforms/sites.dart';
import 'package:pure_live/core/consts/app_consts.dart';
import 'package:pure_live/core/models/live_room/live_room.dart';
import 'package:pure_live/core/utils/hive_pref_util.dart';
import 'package:pure_live/core/utils/list_reorder.dart';
import 'package:pure_live/services/settings/settings.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_settings_controller.g.dart';

@riverpod
class AppSettingsController extends _$AppSettingsController {
  static AppSettingsController get to => SettingsService.to.app;

  /// Platforms whose public API exposes a concurrent audience count, so
  /// concurrent mode has a real number to show out of the box.
  static const List<String> defaultRealOnlinePlatforms = [
    Sites.douyinSite,
    Sites.kuaishouSite,
    Sites.ccSite,
    Sites.twitchSite,
    Sites.soopSite,
    Sites.acfunSite,
    Sites.picartoSite,
    Sites.twitcastingSite,
  ];

  @override
  AppSettingsModel build() {
    return AppSettingsModel(
      autoRefreshTime: HivePrefUtil.getInt('autoRefreshTime') ?? 3,
      enableDenseFavorites: HivePrefUtil.getBool('enableDenseFavorites') ?? true,
      enableBackgroundPlay: HivePrefUtil.getBool('enableBackgroundPlay') ?? false,
      enableRotateScreen: HivePrefUtil.getBool('enableRotateScreen') ?? false,
      enableScreenKeepOn: HivePrefUtil.getBool('enableScreenKeepOn') ?? true,
      enableAutoCheckUpdate: HivePrefUtil.getBool('enableAutoCheckUpdate') ?? true,
      enableFullScreenDefault: HivePrefUtil.getBool('enableFullScreenDefault') ?? false,
      showSplashPage: HivePrefUtil.getBool('showSplashPage') ?? true,
      enableAsmrSleepMode: HivePrefUtil.getBool('enableAsmrSleepMode') ?? false,
      asmrSleepMinutes: HivePrefUtil.getInt('asmrSleepMinutes') ?? 60,
      useGitHubOriginForUpdates: HivePrefUtil.getBool('useGitHubOriginForUpdates') ?? false,
      refreshRateMode: HivePrefUtil.getString('refreshRateMode') ?? '',
      preferRealOnlineCounts: HivePrefUtil.getBool('preferRealOnlineCounts') ?? false,
      realOnlinePlatforms: normalizeRealOnlinePlatforms(
        HivePrefUtil.getStringList('realOnlinePlatforms') ?? defaultRealOnlinePlatforms,
      ),
      audienceMetricMigration: HivePrefUtil.getInt('audienceMetricMigration') ?? 0,
      enableMultiView: HivePrefUtil.getBool('enableMultiView') ?? true,
      enableNewWindowPlay: HivePrefUtil.getBool('enableNewWindowPlay') ?? true,
      savedMenuIds: HivePrefUtil.getStringList('savedMenuIds') ?? [],
      sidebarExpanded: HivePrefUtil.getBool('sidebarExpanded') ?? false,
    );
  }

  void update(AppSettingsModel newModel) {
    // Only concurrent-capable platforms may stay selected, so a stored or
    // imported entry can never present a heat value as a real audience.
    state = newModel.copyWith(realOnlinePlatforms: normalizeRealOnlinePlatforms(newModel.realOnlinePlatforms));
    _persist();
  }

  /// Visible menu ids in display order; an empty stored list means "all menus
  /// in the default order".
  static List<String> normalizeMenuIds(List<String> ids) {
    final known = HomeMenu.defaultOrder;
    final result = <String>[for (final id in ids) if (known.contains(id)) id];
    for (final id in known) {
      if (!result.contains(id)) result.add(id);
    }
    return result;
  }

  /// Repairs a stored or imported platform list: trimmed, lower-cased and
  /// limited to platforms that publish a concurrent audience count.
  static List<String> normalizeRealOnlinePlatforms(Iterable<String> platforms) {
    return platforms
        .map((platform) => platform.trim().toLowerCase())
        .where((platform) => LiveRoom.audienceCapabilityFor(platform).supportsConcurrentOnline)
        .toSet()
        .toList();
  }

  /// Selected platforms after dropping entries this build no longer supports.
  List<String>? _resolvedSource;
  List<String> _resolvedCache = const [];

  /// Normalized once per list identity: every room card calls this per build,
  /// and re-normalizing (trim/toSet/toList) each time was pure churn. The
  /// platform count is ~7, so contains() on the list is fine.
  List<String> get resolvedRealOnlinePlatforms {
    final source = state.realOnlinePlatforms;
    if (!identical(_resolvedSource, source)) {
      _resolvedSource = source;
      _resolvedCache = normalizeRealOnlinePlatforms(source);
    }
    return _resolvedCache;
  }

  bool isRealOnlineEnabledFor(String? platform) =>
      resolvedRealOnlinePlatforms.contains(platform?.trim().toLowerCase());

  void setRealOnlineEnabledFor(String platform, bool enabled) {
    final normalized = platform.trim().toLowerCase();
    if (!LiveRoom.audienceCapabilityFor(normalized).supportsConcurrentOnline) return;
    final next = resolvedRealOnlinePlatforms;
    if (enabled) {
      if (!next.contains(normalized)) next.add(normalized);
    } else {
      next.remove(normalized);
    }
    update(state.copyWith(realOnlinePlatforms: next));
  }

  /// Moves [menuId] by [delta] positions inside the visible list.
  void moveMenu(String menuId, int delta) {
    final current = _visibleMenuIds();
    final index = current.indexOf(menuId);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= current.length) return;
    update(state.copyWith(savedMenuIds: reorderMenuIds(current, menuId, target)));
  }

  /// Puts [menuId] at [targetIndex] of the visible list, shifting the entries it
  /// passes.
  ///
  /// This is the ordering page's "pick an entry, then name its position" move: the
  /// entry the user chose lands exactly where they said, instead of being nudged
  /// there one step at a time.
  void moveMenuTo(String menuId, int targetIndex) {
    final current = _visibleMenuIds();
    final next = reorderMenuIds(current, menuId, targetIndex);
    if (listEquals(next, current)) return;
    update(state.copyWith(savedMenuIds: next));
  }

  /// The visible entries in display order, stored or defaulted.
  List<String> _visibleMenuIds() =>
      state.savedMenuIds.isEmpty ? List<String>.from(HomeMenu.defaultOrder) : normalizeMenuIds(state.savedMenuIds);

  /// [ids] with [menuId] placed at [targetIndex]; the entries it passes shift by
  /// one and nothing is dropped.
  ///
  /// Pure (it delegates to the shared [reorderIds]) so the reorder rule the ordering
  /// page promises is testable without the preference store.
  static List<String> reorderMenuIds(List<String> ids, String menuId, int targetIndex) =>
      reorderIds(ids, menuId, targetIndex);

  void toggleMenuVisibility(String menuId, bool visible) {
    final ids = List<String>.from(state.savedMenuIds);
    if (visible) {
      if (!ids.contains(menuId)) ids.add(menuId);
    } else {
      ids.remove(menuId);
    }
    update(state.copyWith(savedMenuIds: ids));
  }

  void _persist() {
    HivePrefUtil.setInt('autoRefreshTime', state.autoRefreshTime);
    HivePrefUtil.setBool('enableDenseFavorites', state.enableDenseFavorites);
    HivePrefUtil.setBool('enableBackgroundPlay', state.enableBackgroundPlay);
    HivePrefUtil.setBool('enableRotateScreen', state.enableRotateScreen);
    HivePrefUtil.setBool('enableScreenKeepOn', state.enableScreenKeepOn);
    HivePrefUtil.setBool('enableAutoCheckUpdate', state.enableAutoCheckUpdate);
    HivePrefUtil.setBool('enableFullScreenDefault', state.enableFullScreenDefault);
    HivePrefUtil.setBool('showSplashPage', state.showSplashPage);
    HivePrefUtil.setStringList('savedMenuIds', state.savedMenuIds);
    HivePrefUtil.setBool('sidebarExpanded', state.sidebarExpanded);
    HivePrefUtil.setBool('enableAsmrSleepMode', state.enableAsmrSleepMode);
    HivePrefUtil.setInt('asmrSleepMinutes', state.asmrSleepMinutes);
    HivePrefUtil.setBool('useGitHubOriginForUpdates', state.useGitHubOriginForUpdates);
    HivePrefUtil.setString('refreshRateMode', state.refreshRateMode);
    HivePrefUtil.setBool('preferRealOnlineCounts', state.preferRealOnlineCounts);
    HivePrefUtil.setStringList('realOnlinePlatforms', resolvedRealOnlinePlatforms);
    HivePrefUtil.setInt('audienceMetricMigration', state.audienceMetricMigration);
    HivePrefUtil.setBool('enableMultiView', state.enableMultiView);
    HivePrefUtil.setBool('enableNewWindowPlay', state.enableNewWindowPlay);
  }

  /// 一级块固定 id（与云端 navigation.groups 契约一致）。
  static const Set<String> _navGroupIds = <String>{'iptv', 'vod', 'live', 'settings'};

  /// 最近一次云端解析出的导航分组 / 默认块（applyRemoteNavigation 写入）。
  /// navigation.managed=false 时该路径不触发，home_provider 会直接读 _current 的
  /// 原始 groups，二者同源、结果一致；解析失败一律留空让调用方回退内置默认。
  static List<dynamic>? _lastNavGroups;
  static String? _lastDefaultGroupId;

  static List<dynamic>? get lastNavGroups => _lastNavGroups;
  static String? get lastDefaultGroupId => _lastDefaultGroupId;

  /// 校验一条导航分组：id 必须是四个固定块之一；children 只保留已知菜单 id 或
  /// 字面量 'settings'（去重、丢弃未知项）。整条非法返回 null。
  static Map<String, dynamic>? parseNavGroup(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || !_navGroupIds.contains(id)) return null;
    final childrenRaw = raw['children'];
    final children = <String>[];
    if (childrenRaw is List) {
      for (final c in childrenRaw) {
        if (c is! String) continue;
        final valid = HomeMenu.fromId(c) != null || c == 'settings';
        if (valid && !children.contains(c)) children.add(c);
      }
    }
    return <String, dynamic>{'id': id, 'children': children};
  }

  /// 校验并去重云端 navigation.groups；缺失 / 类型错误 / 全非法都返回空列表，
  /// 由调用方回退内置四大类默认分组。
  static List<dynamic> parseNavGroups(Object? raw) {
    if (raw is! List) return const <dynamic>[];
    final result = <dynamic>[];
    final seen = <String>{};
    for (final entry in raw) {
      final parsed = parseNavGroup(entry);
      if (parsed == null) continue;
      final id = parsed['id'] as String;
      if (!seen.add(id)) continue;
      result.add(parsed);
    }
    return result;
  }

  /// defaultGroupId 必须是 groups 里存在的固定块 id，否则返回 null（回退默认）。
  static String? normalizeDefaultGroupId(Object? raw, List<dynamic> groups) {
    final id = raw is String ? raw.trim().toLowerCase() : '';
    if (!_navGroupIds.contains(id)) return null;
    if (!groups.any((g) => g is Map && g['id'] == id)) return null;
    return id;
  }

  /// 云端下发的导航白名单（需求文档 FR-05）与一级分组 / 默认块。
  ///
  /// 白名单必须写入显式完整数组：normalizeMenuIds 会把缺失的 known id 全部补回，
  /// 而 _visibleMenuIds 把空列表解释为「全部默认序」，两者都与白名单语义冲突。
  /// groups / defaultGroupId 的解析独立于白名单：即使 railMenuIds 为空或不含
  /// iptv（线上旧配置），4 个一级块也始终由内置默认补齐，白名单只影响块内二级项。
  void applyRemoteNavigation({
    required List<String> railMenuIds,
    bool? sidebarExpanded,
    Object? groups,
    Object? defaultGroupId,
  }) {
    // 先解析分组 / 默认块，再处理白名单：旧配置无 groups 时得到空列表，调用方
    // 回退内置四大类，绝不会白屏或空菜单。
    final parsedGroups = parseNavGroups(groups);
    _lastNavGroups = parsedGroups.isEmpty ? null : parsedGroups;
    _lastDefaultGroupId = normalizeDefaultGroupId(defaultGroupId, parsedGroups);

    final ids = <String>[];
    for (final raw in railMenuIds) {
      final id = raw.trim();
      if (HomeMenu.fromId(id) != null && !ids.contains(id)) ids.add(id);
    }
    if (ids.isEmpty) return;
    update(state.copyWith(
      savedMenuIds: ids,
      sidebarExpanded: sidebarExpanded ?? state.sidebarExpanded,
    ));
  }

  /// 云端接管启动页与自动检查更新开关。走 update() 保证 state + Hive 一起写，
  /// 否则后续 _persist() 会用旧 state 回写覆盖云端配置。
  void applyRemoteStartupAndUpdate({bool? showSplashPage, bool? enableAutoCheckUpdate}) {
    update(state.copyWith(
      showSplashPage: showSplashPage ?? state.showSplashPage,
      enableAutoCheckUpdate: enableAutoCheckUpdate ?? state.enableAutoCheckUpdate,
    ));
  }

  /// 云端全部节退出接管时恢复本地用户设置。
  void restoreLocalSettings({
    required List<String> savedMenuIds,
    required bool sidebarExpanded,
    required bool showSplashPage,
    required bool enableAutoCheckUpdate,
  }) {
    update(state.copyWith(
      savedMenuIds: savedMenuIds,
      sidebarExpanded: sidebarExpanded,
      showSplashPage: showSplashPage,
      enableAutoCheckUpdate: enableAutoCheckUpdate,
    ));
  }

  Map<String, dynamic> toJson() => state.toJson();

  void importFromJson(Map<String, dynamic> json) {
    update(AppSettingsModel.fromJson(json));
  }
}
