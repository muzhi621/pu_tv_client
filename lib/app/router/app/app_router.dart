import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_live/features/index.dart';
import 'package:pure_live/services/remote_config/remote_config.dart';
import 'package:pure_live/modules/live/index.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pure_live/app/router/app/app_routes.dart';
import 'package:pure_live/app/bootstrap/app_navigator.dart';
import 'package:pure_live/core/widgets/tv_focus_restorer.dart';
import 'package:pure_live/core/models/live_room/live_room.dart';
import 'package:pure_live/services/startup/startup_controller.dart';
import 'package:pure_live/app/router/observers/wallpaper_route_observer.dart';
import 'package:pure_live/services/background_config/remote/background_catalog.dart';
import 'package:pure_live/features/settings/pages/app_update_page.dart';
import 'package:pure_live/features/settings/pages/app_download_page.dart';
import 'package:pure_live/features/settings/pages/nav_order_section.dart';
import 'package:pure_live/features/settings/pages/nav_icons_section.dart';
import 'package:pure_live/modules/live/iptv/pages/iptv_sync_section.dart';
import 'package:pure_live/features/settings/pages/navigation_section.dart';
import 'package:pure_live/features/settings/pages/update_history_page.dart';
import 'package:pure_live/features/settings/pages/device_sync_section.dart';
import 'package:pure_live/features/settings/pages/account_cookie_page.dart';
import 'package:pure_live/modules/live/iptv/pages/iptv_manage_section.dart';
import 'package:pure_live/modules/live/iptv/pages/iptv_import_section.dart';
import 'package:pure_live/modules/live/iptv/pages/iptv_headers_section.dart';
import 'package:pure_live/features/settings/pages/backup_manage_section.dart';
import 'package:pure_live/features/settings/pages/account_bilibili_page.dart';
import 'package:pure_live/features/settings/pages/danmaku_shield_section.dart';
import 'package:pure_live/features/settings/pages/tag_management_section.dart';
import 'package:pure_live/features/settings/pages/nav_visibility_section.dart';
import 'package:pure_live/modules/live/iptv/pages/iptv_resources_section.dart';
import 'package:pure_live/features/settings/pages/audience_metric_section.dart';
import 'package:pure_live/features/settings/pages/account_settings_section.dart';
import 'package:pure_live/features/settings/pages/font_family_manager_section.dart';
import 'package:pure_live/features/settings/pages/platform_display_order_section.dart';
import 'package:pure_live/features/settings/pages/platform_display_visibility_section.dart';

// The settings routes live in a `part` on purpose: go_router_builder emits one
// `$appRoutes` per *library*, so a separate `settings_routes.dart` library would
// generate a second, competing `$appRoutes` — and the local one silently shadows
// it, leaving every settings path unregistered.
part 'app_router.g.dart';
part '../settings/settings_routes.dart';

/// The home shell: side menu plus the tab the user picked.
@TypedGoRoute<HomeRoute>(path: AppRoutes.kInitial)
class HomeRoute extends GoRouteData with $HomeRoute {
  const HomeRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const HomePage();
}

/// `/settings` — the menu itself, not a section.
@TypedGoRoute<AreaRoomsRoute>(path: AppRoutes.kAreaRooms)
class AreaRoomsRoute extends GoRouteData with $AreaRoomsRoute {
  AreaRoomsRoute(this.$extra);

  final AreaRoomsArgs $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      AreaRoomsPage(site: $extra.site, subCategory: $extra.subCategory);
}

/// 直播搜索已下线；路由壳保留是因为 app_router.g.dart 仍引用这个类，
/// 本机无法重跑 build_runner。任何进入都渲染空页，不会再拉直播平台。
@TypedGoRoute<SearchResultRoute>(path: AppRoutes.kSearchResult)
class SearchResultRoute extends GoRouteData with $SearchResultRoute {
  SearchResultRoute(this.$extra);

  final SearchResultArgs $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox.shrink();
}

// ------------------------------------------------------------------ wallpaper

@TypedGoRoute<WallpaperPageRoute>(path: AppRoutes.kWallpaperPage)
class WallpaperPageRoute extends GoRouteData with $WallpaperPageRoute {
  const WallpaperPageRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const WallpaperPage();
}

@TypedGoRoute<WallpaperLibraryRoute>(path: AppRoutes.kWallpaperLibrary)
class WallpaperLibraryRoute extends GoRouteData with $WallpaperLibraryRoute {
  const WallpaperLibraryRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const WallpaperLibraryPage();
}

@TypedGoRoute<WallpaperApiRoute>(path: AppRoutes.kWallpaperApi)
class WallpaperApiRoute extends GoRouteData with $WallpaperApiRoute {
  const WallpaperApiRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const WallpaperApiPage();
}

@TypedGoRoute<WallpaperApiGroupRoute>(path: AppRoutes.kWallpaperApiGroup)
class WallpaperApiGroupRoute extends GoRouteData with $WallpaperApiGroupRoute {
  WallpaperApiGroupRoute(this.$extra);

  final WallpaperApiGroup $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) => WallpaperApiGroupPage(group: $extra);
}

@TypedGoRoute<WallpaperGalleryRoute>(path: AppRoutes.kWallpaperGallery)
class WallpaperGalleryRoute extends GoRouteData with $WallpaperGalleryRoute {
  WallpaperGalleryRoute(this.$extra);

  final BackgroundSource $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) => WallpaperGalleryPage(source: $extra);
}

@TypedGoRoute<WallpaperItemsRoute>(path: AppRoutes.kWallpaperItems)
class WallpaperItemsRoute extends GoRouteData with $WallpaperItemsRoute {
  WallpaperItemsRoute(this.$extra);

  final WallpaperItemsArgs $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      WallpaperItemsPage(sourceId: $extra.sourceId, categoryId: $extra.categoryId);
}

@TypedGoRoute<WallpaperPreviewRoute>(path: AppRoutes.kWallpaperPreview)
class WallpaperPreviewRoute extends GoRouteData with $WallpaperPreviewRoute {
  WallpaperPreviewRoute(this.$extra);

  final WallpaperPreviewArgs $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) => WallpaperPreviewPage(args: $extra);
}

// ------------------------------------------------------------------ playback

/// Playback accepts either a resolved room (the normal push) or ready-made
/// [LivePlayArgs] (channel switching inside the player).
@TypedGoRoute<LivePlayRoute>(path: AppRoutes.kLivePlay, name: AppRoutes.kLivePlayName)
class LivePlayRoute extends GoRouteData with $LivePlayRoute {
  LivePlayRoute(this.$extra);

  /// Non-nullable on purpose: every caller passes a room or ready-made args, and
  /// `state.extra as Object?` is the no-op cast the analyzer flags in the
  /// generated file.
  final Object $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    final Object extra = $extra;
    final LivePlayArgs args = extra is LiveRoom
        ? LivePlayArgs.fromRoom(extra)
        : (extra is LivePlayArgs ? extra : const LivePlayArgs(platform: '', roomId: ''));
    return LivePlayPage(args: args);
  }
}

// ---------------------------------------------------------------------------
// bilibili UGC 影音 / 音乐路由（已下线）
//
// 这些类只保留「路由壳」：app_router.g.dart 是已提交的生成产物，本机无法重跑
// build_runner，直接删类会让生成代码引用到不存在的 mixin。构造参数与字段名
// 必须与生成文件一致（$extra / keyword / mid / name），build 一律返回空页，
// 因此不会加载任何已删除的 UGC 页面或控制器。
// ---------------------------------------------------------------------------

@TypedGoRoute<MusicArchiveRoute>(path: AppRoutes.kMusicArchive)
class MusicArchiveRoute extends GoRouteData with $MusicArchiveRoute {
  MusicArchiveRoute(this.$extra);

  final Object $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox.shrink();
}

@TypedGoRoute<MusicPlayerRoute>(path: AppRoutes.kMusicPlayer)
class MusicPlayerRoute extends GoRouteData with $MusicPlayerRoute {
  const MusicPlayerRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox.shrink();
}

@TypedGoRoute<VideoDetailRoute>(path: AppRoutes.kVideoDetail)
class VideoDetailRoute extends GoRouteData with $VideoDetailRoute {
  VideoDetailRoute(this.$extra);

  final Object $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox.shrink();
}

@TypedGoRoute<VideoPlayerRoute>(path: AppRoutes.kVideoPlayer)
class VideoPlayerRoute extends GoRouteData with $VideoPlayerRoute {
  const VideoPlayerRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox.shrink();
}

@TypedGoRoute<VideoSeasonRoute>(path: AppRoutes.kVideoSeason)
class VideoSeasonRoute extends GoRouteData with $VideoSeasonRoute {
  VideoSeasonRoute(this.$extra);

  final Object $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox.shrink();
}

@TypedGoRoute<VideoTagSearchRoute>(path: AppRoutes.kVideoTagSearch)
class VideoTagSearchRoute extends GoRouteData with $VideoTagSearchRoute {
  VideoTagSearchRoute(this.keyword);

  final String keyword;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox.shrink();
}

@TypedGoRoute<UgcCommentsRoute>(path: AppRoutes.kUgcComments)
class UgcCommentsRoute extends GoRouteData with $UgcCommentsRoute {
  UgcCommentsRoute(this.$extra);

  final Object $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox.shrink();
}

@TypedGoRoute<UgcUserSpaceRoute>(path: AppRoutes.kUgcUserSpace)
class UgcUserSpaceRoute extends GoRouteData with $UgcUserSpaceRoute {
  UgcUserSpaceRoute(this.mid, this.name);

  final int mid;
  final String name;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox.shrink();
}

@TypedGoRoute<MusicFavDetailRoute>(path: AppRoutes.kMusicFavDetail)
class MusicFavDetailRoute extends GoRouteData with $MusicFavDetailRoute {
  MusicFavDetailRoute(this.$extra);

  final Object $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) => const SizedBox.shrink();
}

/// The arguments [UgcCommentsRoute] carries through `$extra`.
class UgcCommentsArgs {
  const UgcCommentsArgs({required this.oid, required this.title, this.type = 1});

  final int oid;
  final String title;
  final int type;
}

final routerProvider = Provider<GoRouter>((ref) {
  final isFirstInApp = ref.watch(startupControllerProvider);

  return GoRouter(
    navigatorKey: appNavigatorKey,
    // Lets every page know when it is covered and uncovered again, so focus can
    // return to the item the user acted on after a pop.
    observers: [tvRouteObserver, wallpaperRouteObserver],
    initialLocation: AppRoutes.kInitial,
    redirect: (context, state) {
      final location = state.uri.path;

      // requiredVersion 提升时重新征求同意；不翻 isFirstInApp，避免
      // 备份/同步把已同意的 TV 弹回协议页。
      final agreementRequired = RemoteConfigService.agreementRequired;
      if ((isFirstInApp || agreementRequired) && location != AppRoutes.kAgreementPage) {
        return AppRoutes.kAgreementPage;
      }

      if (!isFirstInApp && !agreementRequired && location == AppRoutes.kAgreementPage) {
        return AppRoutes.kInitial;
      }

      return null;
    },
    // 启动页的三个入口各自是一个独立路由：播放页 / 点播页 / 设置页按返回
    // 都直接回到 /home，而不是回到嵌在首页里的某个内容 tab。
    routes: [
      ...$appRoutes,
      GoRoute(
        path: AppRoutes.kVodBrowse,
        builder: (context, state) => const VodBrowsePage(),
      ),
      GoRoute(
        path: AppRoutes.kIptvChannels,
        builder: (context, state) => const AreasPage(onlySiteId: 'iptv'),
      ),
    ],
  );
});
