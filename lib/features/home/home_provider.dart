import 'package:pure_live/exports/exports.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:pure_live/services/remote_config/remote_config.dart';
import 'package:pure_live/modules/video/video_section.dart';

import 'package:pure_live/services/menu_icons/menu_icon_controller.dart';

part 'home_provider.g.dart';

/// Top-level app modes, switched by the button at the top of the sidebar
/// (where the backup shortcut used to sit). Live keeps the classic room UI;
/// music and video are the bilibili UGC modes over the same VOD playback
/// engine — video shows the picture, music listens without it. Each mode owns
/// the whole navigation rail and content pane; their playback is exclusive
/// against live rooms.
enum AppMode { live, video, music }

/// The app-wide mode, persisted: the TV boots into whatever mode was last
/// used instead of always live.
@riverpod
class AppModeController extends _$AppModeController {
  @override
  AppMode build() {
    final saved = HivePrefUtil.getString('appMode');
    for (final mode in AppMode.values) {
      if (mode.name == saved) return mode;
    }
    return AppMode.live;
  }

  void setMode(AppMode mode) {
    state = mode;
    HivePrefUtil.setString('appMode', mode.name);
  }

  /// on, no submenu needed on a remote.
  void cycle() => setMode(switch (state) {
    AppMode.live => AppMode.video,
    AppMode.video => AppMode.music,
    AppMode.music => AppMode.live,
  });
}

/// Selected music-mode sidebar section (index into [MusicSection.values]).
@riverpod
class MusicSectionIndex extends _$MusicSectionIndex {
  @override
  int build() => 0;

  void change(int index) => state = index;
}

/// Selected video-mode sidebar section (index into [VideoSection.values]).
@riverpod
class VideoSectionIndex extends _$VideoSectionIndex {
  @override
  int build() {
    final service = SettingsService.to;
    if (!service.isInitialized) return 0;
    return service.videoState.startSection.clamp(0, VideoSection.values.length - 1);
  }

  void change(int index) => state = index;
}

/// Side-menu destinations.
///
/// The value is the identity that flows through
/// [SideMenuIndex]/[TvMenuType.fromIndex]; every [AppMenuItem] must carry the
/// value of its own entry. A mismatch used to make the settings entry select
/// `-2`, which matched nothing and silently fell back to [favorite], so the
/// settings button opened the followed-rooms page.
///
/// `profile` is gone: the slot the mobile app spent on account is the home
/// sidebar's backup header now, which pushes the backup page instead of swapping
/// the content pane, so it never participates in the menu index.
enum TvMenuType {
  favorite(0),
  hot(1),
  areas(2),
  favoriteAreas(3),
  moviePlayback(4),
  search(5),
  history(6),
  iptv(7),
  vodBrowse(8),
  settings(99);

  final int value;
  const TvMenuType(this.value);

  static TvMenuType fromIndex(int idx) {
    for (var type in TvMenuType.values) {
      if (type.value == idx) {
        return type;
      }
    }
    return TvMenuType.favorite;
  }
}

class AppMenuItem {
  /// Must be one of the [TvMenuType] values, not an ad-hoc constant.
  final int index;
  final String title;

  /// The two-character caption the collapsed sidebar paints under the icon.
  ///
  /// The full [title] is too long to fit the
  /// 110dp icon rail; the short form keeps every destination readable without
  /// expanding the sidebar. Empty falls back to [title].
  final String shortTitle;
  final IconData icon;

  AppMenuItem({required this.index, required this.title, required this.icon, String? shortTitle})
    : shortTitle = shortTitle ?? '';
}

/// 一级导航块（内置四大类）。云端只决定启动默认块（defaultGroupId）与二级显隐
/// （railMenuIds），块结构 / 本地化文案 / 图标固定在客户端，旧配置平滑升级。
class NavGroup {
  final String id;
  final String labelKey;
  final IconData icon;
  final List<String> children;
  const NavGroup({required this.id, required this.labelKey, required this.icon, required this.children});
}

/// 四个一级块，顺序即左侧一级栏顺序。children 用菜单 id 或字面量 'settings'。
const List<NavGroup> kNavGroups = <NavGroup>[
  NavGroup(id: 'iptv', labelKey: 'nav_group_iptv', icon: Icons.live_tv_outlined, children: <String>['iptv']),
  NavGroup(id: 'vod', labelKey: 'nav_group_vod', icon: Icons.movie_outlined, children: <String>['vodBrowse', 'moviePlayback']),
  NavGroup(
    id: 'live',
    labelKey: 'nav_group_live',
    icon: Icons.tv_rounded,
    children: <String>['favorite', 'hot', 'areas', 'favoriteAreas', 'search', 'history'],
  ),
  NavGroup(id: 'settings', labelKey: 'nav_group_settings', icon: Icons.settings_outlined, children: <String>['settings']),
];

/// 二级项 id → TvMenuType 值；未知 id 返回 null。
int? navIndexForId(String id) => switch (id) {
      'favorite' => TvMenuType.favorite.value,
      'hot' => TvMenuType.hot.value,
      'areas' => TvMenuType.areas.value,
      'favoriteAreas' => TvMenuType.favoriteAreas.value,
      'moviePlayback' => TvMenuType.moviePlayback.value,
      'vodBrowse' => TvMenuType.vodBrowse.value,
      'search' => TvMenuType.search.value,
      'history' => TvMenuType.history.value,
      'iptv' => TvMenuType.iptv.value,
      'settings' => TvMenuType.settings.value,
      _ => null,
    };

/// 云端 navigation.groups → NavGroup 列表；任何异常都回退内置四大类。
///
/// 一级块固定用内置本地化文案 / 图标（云端 label 是中文展示串、icon 是字符串
/// 名，直接用会破坏 i18n 并引入无效 IconData），云端只覆盖块结构（children）。
/// 数据来自静态字段 / _current，无响应式依赖，故用普通函数而非新增 @riverpod
/// provider，避免本机无法重新生成 home_provider.g.dart。
List<NavGroup> resolveNavGroups() {
  // 优先读 _current 的原始 groups（每次 syncNow 无条件刷新，永不过期）；
  // 仅当 _current 无该字段时回退 applyRemoteNavigation 解析出的缓存。
  final fromCurrent = RemoteConfigService.navigationGroupsRaw;
  final List<dynamic> raw = fromCurrent.isNotEmpty
      ? fromCurrent
      : (AppSettingsController.lastNavGroups ?? const <dynamic>[]);
  if (raw.isEmpty) return kNavGroups;
  final builtIn = <String, NavGroup>{for (final g in kNavGroups) g.id: g};
  final result = <NavGroup>[];
  final seen = <String>{};
  for (final entry in raw) {
    if (entry is! Map) continue;
    final id = entry['id'];
    if (id is! String || !builtIn.containsKey(id) || !seen.add(id)) continue;
    final childrenRaw = entry['children'];
    final children = <String>[];
    if (childrenRaw is List) {
      for (final c in childrenRaw) {
        if (c is String && navIndexForId(c) != null && !children.contains(c)) {
          children.add(c);
        }
      }
    }
    result.add(NavGroup(
      id: id,
      labelKey: builtIn[id]!.labelKey,
      icon: builtIn[id]!.icon,
      children: children,
    ));
  }
  // 必须恰好覆盖四个固定块，否则整份回退：左侧永远 4 项、IPTV 常驻可见。
  if (result.length != kNavGroups.length) return kNavGroups;
  return result;
}

/// 启动默认一级块：优先云端校验值；缺失 / 非法 / 不在分组内都回退首个分组
/// （内置首组即 iptv，结果上启动就落在 IPTV）。
String resolveDefaultGroupId(List<NavGroup> groups) {
  // 先看当前文档，再用 applyRemoteNavigation 解析出的缓存兜底，最后回退首组(iptv)。
  final candidates = <String>[
    RemoteConfigService.navigationDefaultGroupId,
    if (AppSettingsController.lastDefaultGroupId != null)
      AppSettingsController.lastDefaultGroupId!,
  ];
  for (final raw in candidates) {
    final id = raw.trim().toLowerCase();
    if (groups.any((g) => g.id == id)) return id;
  }
  return groups.isNotEmpty ? groups.first.id : 'iptv';
}

/// 一级块 id → 该块二级项的 TvMenuType 值集合（用于过滤 sideMenuList）。
Set<int> navChildIndexes(List<NavGroup> groups, String groupId) {
  final NavGroup group = groups.firstWhere(
    (g) => g.id == groupId,
    orElse: () => groups.isNotEmpty ? groups.first : kNavGroups.first,
  );
  final Set<int> result = <int>{};
  for (final String id in group.children) {
    final int? index = navIndexForId(id);
    if (index != null) result.add(index);
  }
  return result;
}

/// 启动默认二级项 = 默认一级块的首个子项；任何异常都回退到 iptv。
int defaultNavIndex(List<NavGroup> groups) {
  final String groupId = resolveDefaultGroupId(groups);
  final NavGroup group = groups.firstWhere(
    (g) => g.id == groupId,
    orElse: () => groups.isNotEmpty ? groups.first : kNavGroups.first,
  );
  if (group.children.isEmpty) return TvMenuType.iptv.value;
  return navIndexForId(group.children.first) ?? TvMenuType.iptv.value;
}

/// Side menu entries in the order configured in settings, limited to the
/// visible ones. An empty configuration shows every entry in default order.
@riverpod
List<AppMenuItem> sideMenuList(Ref ref) {
  final saved = ref.watch(appSettingsControllerProvider).savedMenuIds;
  final overrides = ref.watch(menuIconOverridesProvider);
  // 云端托管时用显式白名单，绝不走 normalizeMenuIds（它会补回所有 known id）。
  final List<String> ids;
  if (RemoteConfigService.navigationManaged) {
    ids = <String>[for (final id in saved) if (HomeMenu.fromId(id) != null) id];
    // 线上旧配置的 7 项白名单不含 iptv，但 IPTV 入口必须常驻可见。
    if (!ids.contains('iptv')) ids.add('iptv');
  } else {
    ids = saved.isEmpty ? HomeMenu.defaultOrder : AppSettingsController.normalizeMenuIds(saved);
  }
  final visible = ids.isEmpty ? HomeMenu.defaultOrder : ids;
  return [for (final id in visible) ?_sideMenuItem(id, overrides)];
}

AppMenuItem? _sideMenuItem(String id, Map<String, IconData> overrides) {
  IconData withOverride(IconData fallback) => overrides[id] ?? fallback;

  return switch (HomeMenu.fromId(id)) {
    HomeMenu.favorite => AppMenuItem(
      index: TvMenuType.favorite.value,
      title: i18n('ui_following'),
      shortTitle: i18n('menu_short_following'),
      icon: withOverride(Icons.favorite_border),
    ),
    HomeMenu.hot => AppMenuItem(
      index: TvMenuType.hot.value,
      title: i18n('kilakila_hot'),
      shortTitle: i18n('menu_short_hot'),
      icon: withOverride(Icons.local_fire_department_outlined),
    ),
    // Categories and followed categories are different destinations, so they
    // must not share the same grid glyph.
    HomeMenu.areas => AppMenuItem(
      index: TvMenuType.areas.value,
      title: i18n('ui_category'),
      shortTitle: i18n('menu_short_category'),
      icon: withOverride(RemixIcons.function_line),
    ),
    HomeMenu.favoriteAreas => AppMenuItem(
      index: TvMenuType.favoriteAreas.value,
      title: i18n('favorite_areas'),
      shortTitle: i18n('menu_short_areas'),
      icon: withOverride(Icons.collections_bookmark_outlined),
    ),
    HomeMenu.vodBrowse => AppMenuItem(
      index: TvMenuType.vodBrowse.value,
      title: i18n('vod_browse'),
      shortTitle: i18n('menu_short_vod_browse'),
      icon: withOverride(Icons.video_library_outlined),
    ),
    HomeMenu.moviePlayback => AppMenuItem(
      index: TvMenuType.moviePlayback.value,
      title: i18n('ui_link_playback'),
      shortTitle: i18n('menu_short_link_playback'),
      icon: withOverride(Icons.movie_creation_outlined),
    ),
    HomeMenu.search => AppMenuItem(
      index: TvMenuType.search.value,
      title: i18n('search_live'),
      shortTitle: i18n('menu_short_search'),
      icon: withOverride(Icons.search_rounded),
    ),
    HomeMenu.history => AppMenuItem(
      index: TvMenuType.history.value,
      title: i18n('watch_history'),
      shortTitle: i18n('menu_short_history'),
      icon: withOverride(Icons.history),
    ),
    HomeMenu.iptv => AppMenuItem(
      index: TvMenuType.iptv.value,
      title: i18n('menu_iptv'),
      shortTitle: i18n('menu_short_iptv'),
      icon: withOverride(Icons.live_tv_outlined),
    ),
    null => null,
  };
}

@riverpod
AppMenuItem mySettingsMenuItem(Ref ref) {
  return AppMenuItem(
    index: TvMenuType.settings.value,
    title: i18n('settings'),
    shortTitle: i18n('menu_short_settings'),
    icon: ref.watch(menuIconOverridesProvider)['settings'] ?? Icons.settings_outlined,
  );
}

@riverpod
class SideMenuIndex extends _$SideMenuIndex {
  @override
  int build() => defaultNavIndex(resolveNavGroups());

  void changeIndex(int newIndex) {
    state = newIndex;
  }
}

/// The side rail's display mode (collapsed icons / expanded labels).
///
/// A preference now, not UI state: the toggle lives in navigation & display
/// boots the way the user last chose.
@riverpod
class IsMenuExpanded extends _$IsMenuExpanded {
  @override
  bool build() => ref.watch(appSettingsControllerProvider.select((s) => s.sidebarExpanded));

  void setExpanded(bool expanded) {
    ref
        .read(appSettingsControllerProvider.notifier)
        .update(ref.read(appSettingsControllerProvider).copyWith(sidebarExpanded: expanded));
  }
}
