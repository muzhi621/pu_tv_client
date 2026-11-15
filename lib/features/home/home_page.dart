import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/app/router/app/app_router.dart';
import 'package:pure_live/features/home/home_provider.dart';
import 'package:pure_live/modules/live/areas/areas_page.dart';
import 'package:pure_live/features/home/home_update_dialog.dart';
import 'package:pure_live/features/home/remote_notice_dialog.dart';
import 'package:pure_live/features/home/exit_confirm_dialog.dart';
import 'package:pure_live/features/settings/tv_settings_page.dart';
import 'package:pure_live/modules/live/movie_playback/movie_playback_page.dart';
import 'package:pure_live/modules/live/movie_playback/vod_browse_page.dart';
import 'package:pure_live/services/refresh_config/refresh_config_controller.dart';

/// 首页外壳：左侧一级栏（IPTV / 影音 / 设置）+ 右侧二级菜单与内容区。
///
/// 2026-11-15 起直播与 bilibili UGC 影音整体下线：这里不再有 live ↔ video
/// 模式切换，也不再渲染关注 / 热门 / 分区 / 搜索 / 历史等直播页面。
/// 内容区只保留 IPTV 频道页与 TVBox 点播页，二者共用 LivePlayRoute 播放器。
class HomePage extends ConsumerStatefulWidget {
  final bool keepAlive;

  const HomePage({super.key, this.keepAlive = true});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// One stable focus node per primary navigation group.
  final Map<String, FocusNode> _groupFocusNodes = {};

  FocusNode _groupNode(String id) => _groupFocusNodes.putIfAbsent(id, FocusNode.new);

  /// Currently selected primary group (iptv / vod). 'settings' never lives
  /// here: its primary item opens the settings route directly.
  late String _currentGroupId;

  /// Select a primary nav group and land on its first visible secondary item.
  /// The settings group keeps the existing "open the settings route" behaviour.
  void _selectNavGroup(String groupId) {
    if (groupId == 'settings') {
      const SettingsMenuRoute().push(context);
      return;
    }
    setState(() => _currentGroupId = groupId);
    final childIndexes = navChildIndexes(resolveNavGroups(), groupId);
    final items = ref
        .read(sideMenuListProvider)
        .where((item) => childIndexes.contains(item.index))
        .toList();
    if (items.isNotEmpty) {
      ref.read(sideMenuIndexProvider.notifier).changeIndex(items.first.index);
    } else if (childIndexes.isNotEmpty) {
      // 云端白名单漏了这一块也要能进去：直接落到块内的主页面。
      ref.read(sideMenuIndexProvider.notifier).changeIndex(childIndexes.first);
    }
  }

  /// 一级栏常驻块（IPTV / 影音 / 设置）。
  ///
  /// 2026-11-15 二改：不再在左侧追加当前块的二级菜单。影音块曾带
  /// 「影音 / 放映」两项，选中后左侧会重复出现一排图标，用户明确要求去掉。
  /// 现在一个一级块直接对应一个内容页：IPTV → 频道页，影音 → 点播浏览页。
  List<Widget> _buildRailItems(bool isExpanded, List<NavGroup> groups) {
    return <Widget>[
      for (final group in groups)
        Padding(
          padding: EdgeInsets.only(bottom: 12.ts(context)),
          child: _buildAdaptiveItem(
            ref: ref,
            item: AppMenuItem(
              index: -1 - groups.indexOf(group),
              title: i18n(group.labelKey),
              shortTitle: i18n(group.labelKey),
              icon: group.icon,
            ),
            isExpanded: isExpanded,
            isSelected: _currentGroupId == group.id,
            focusNode: _groupNode(group.id),
            onTap: () => _selectNavGroup(group.id),
          ),
        ),
    ];
  }

  @override
  void initState() {
    super.initState();
    // 一级栏启动默认块：云端 navigation.defaultGroupId，旧配置/非法值回退 iptv。
    _currentGroupId = resolveDefaultGroupId(resolveNavGroups());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(RemoteNoticeDialog.maybeShow(context));
      unawaited(HomeUpdateDialog.maybeShow(context, ref));
    });
  }

  @override
  void dispose() {
    for (final node in _groupFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(sideMenuIndexProvider);
    final menuList = ref.watch(sideMenuListProvider);
    final isExpanded = ref.watch(isMenuExpandedProvider);
    final groups = resolveNavGroups();
    final currentTvTheme = context.tvTheme;
    final bool effectiveKeepAlive =
        widget.keepAlive && ref.watch(refreshConfigControllerProvider.select((s) => s.homeKeepAlive));

    // 内容页始终取自当前一级块的 children；选中项被白名单隐藏或刚切换了一级块时，
    // 自动落到该块首个页面（IPTV 块固定落到 iptv，影音块固定落到 vodBrowse）。
    final childIndexes = navChildIndexes(groups, _currentGroupId);
    final visibleIndexes = menuList
        .map((item) => item.index)
        .where((index) => childIndexes.contains(index))
        .toSet();
    final int? landing = visibleIndexes.isNotEmpty
        ? visibleIndexes.first
        : (childIndexes.isNotEmpty ? childIndexes.first : null);
    if (!childIndexes.contains(currentIndex) && landing != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(sideMenuIndexProvider.notifier).changeIndex(landing);
      });
    }

    ref.listen(sideMenuIndexProvider, (_, next) {
      if (!visibleIndexes.contains(next)) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 二级项已不在左侧渲染，焦点统一落在当前一级块上，避免指向未挂载节点。
        final node = _groupNode(_currentGroupId);
        if (node.hasFocus) return;
        DpadRegion.ofNode(node)?.noteFocus(node);
        node.requestFocus();
      });
    });

    final sidebarWidth = isExpanded ? 228.ts(context) : 160.ts(context);

    // 只缓存三个可达页面；「放映」（moviePlayback）已从左侧入口移除，
    // 其余已下线的直播/UGC 类型同样回退 IPTV 页。
    const cacheableTypes = [
      TvMenuType.iptv,
      TvMenuType.vodBrowse,
      TvMenuType.settings,
    ];

    final currentMenuType = TvMenuType.fromIndex(currentIndex);
    final isCurrentCacheable = cacheableTypes.contains(currentMenuType);
    final stackIndex = cacheableTypes.indexOf(currentMenuType);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        showExitConfirmDialog(context, ref);
      },
      child: TvScaffold(
        openingFocus: _groupNode(_currentGroupId),
        child: Row(
          children: [
            DpadRegion(
              child: AnimatedContainer(
                key: const Key('home-sidebar'),
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                width: sidebarWidth,
                color: currentTvTheme.backgroundColor.withValues(alpha: 0.62),
                padding: EdgeInsets.symmetric(vertical: 24.ts(context)),
                child: LayoutBuilder(
                  builder: (context, constraints) => Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: TvDigitalClock(
                          format: isExpanded ? 'HH:mm:ss' : 'HH:mm',
                          style: AppTextStyles.t20.copyWith(
                            fontWeight: FontWeight.w600,
                            color: currentTvTheme.primaryTextColor,
                            height: 1,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                      if (isExpanded)
                        TvDigitalClock(
                          format: 'yyyy/MM/dd',
                          style: AppTextStyles.t14.copyWith(
                            fontWeight: FontWeight.w500,
                            color: currentTvTheme.secondaryTextColor,
                            height: 1,
                          ),
                        ),
                      SizedBox(height: 15.ts(context)),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(children: _buildRailItems(isExpanded, groups)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: DpadRegion(
                child: Padding(
                  padding: EdgeInsets.all(8.ts(context)),
                  child: effectiveKeepAlive
                      ? Stack(
                          children: [
                            Visibility(
                              visible: isCurrentCacheable,
                              maintainState: true,
                              child: IndexedStack(
                                index: stackIndex != -1 ? stackIndex : 0,
                                children: cacheableTypes.map((type) {
                                  final isCurrent = currentMenuType == type;
                                  return TvLazyWrapper(
                                    isCurrent: isCurrent,
                                    child: _buildPageContent(context, ref, type)
                                        .animate(target: isCurrent ? 1.0 : 0.0)
                                        .fadeIn(duration: 200.ms, curve: Curves.easeOutCubic)
                                        .scale(
                                          begin: const Offset(0.95, 0.95),
                                          end: const Offset(1.0, 1.0),
                                          duration: 250.ms,
                                          curve: Curves.easeOutCubic,
                                        ),
                                  );
                                }).toList(),
                              ),
                            ),
                            if (!isCurrentCacheable)
                              Container(
                                key: ValueKey(currentIndex),
                                child: _buildPageContent(context, ref, currentMenuType)
                                    .animate()
                                    .fadeIn(duration: 200.ms, curve: Curves.easeOutCubic),
                              ),
                          ],
                        )
                      : Container(
                          key: ValueKey(currentIndex),
                          child: _buildPageContent(context, ref, currentMenuType)
                              .animate()
                              .fadeIn(duration: 200.ms, curve: Curves.easeOutCubic),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdaptiveItem({
    required WidgetRef ref,
    required AppMenuItem item,
    required bool isExpanded,
    required bool isSelected,
    required VoidCallback onTap,
    FocusNode? focusNode,
  }) {
    if (isExpanded) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 16.ts(context)),
        child: TvButton(
          title: item.title,
          icon: Icon(item.icon),
          iconPosition: TvIconPosition.left,
          size: TvButtonSize.medium,
          isSecondary: !isSelected,
          selected: isSelected,
          useFadedFocus: true,
          focusNode: focusNode,
          onTap: onTap,
        ),
      ).animate().fadeIn(duration: 150.ms).slideX(begin: -0.05, end: 0, duration: 200.ms, curve: Curves.easeOutCubic);
    }

    return TvIconButton(
      icon: Icon(item.icon),
      label: item.shortTitle.isEmpty ? item.title : item.shortTitle,
      selected: isSelected,
      size: TvIconButtonSize.medium,
      useFadedFocus: true,
      isSecondary: !isSelected,
      expand: false,
      focusNode: focusNode,
      onTap: onTap,
    );
  }

  Widget _buildPageContent(BuildContext context, WidgetRef ref, TvMenuType type) {
    switch (type) {
      case TvMenuType.settings:
        return const SettingsCatalogView();
      case TvMenuType.moviePlayback:
        return const MoviePlaybackPage();
      case TvMenuType.vodBrowse:
        // 点播浏览：源与站点全部来自云端下发的 vod 节，本地没有任何内置源。
        return const VodBrowsePage();
      case TvMenuType.iptv:
        // IPTV 专用频道页：只保留 iptv 站点的频道目录（Sites.iptvSite == 'iptv'）。
        return const AreasPage(onlySiteId: 'iptv');
      // 直播 / UGC 菜单已下线。老缓存里若残留这些 TvMenuType 值，统一回退到
      // IPTV 频道页，绝不渲染空白内容区。
      default:
        return const AreasPage(onlySiteId: 'iptv');
    }
  }
}
