import 'dart:async';
import 'dart:developer' show log;

import 'package:dpad/dpad.dart';
import 'package:pure_live/app/router/app/app_router.dart';
import 'package:pure_live/app/router/app/app_routes.dart';
import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/features/home/exit_confirm_dialog.dart';
import 'package:pure_live/features/home/home_provider.dart';
import 'package:pure_live/features/home/home_update_dialog.dart';
import 'package:pure_live/features/home/remote_notice_dialog.dart';
import 'package:pure_live/modules/live/iptv/services/iptv_resume_channel.dart';
import 'package:pure_live/modules/live/playback/models/live_play_args.dart';
import 'package:pure_live/platforms/sites.dart';
import 'package:pure_live/services/settings/settings.dart';

/// 启动页：只有 IPTV / 影音 / 设置三个大按钮。
///
/// 2026-11-16 定版：用户明确要求去掉侧边栏和“首页里嵌频道网格”的结构。
/// 这里只做分发：点 IPTV 直接进播放页，点影音进点播页，点设置进设置页；
/// 三个目标都是**独立的路由**，所以按返回一律回到这个启动页，不会中途
/// 掉进 IPTV 全部频道。
///
/// 频道目录仅作为兜底：本机一个可见 IPTV 频道都没有时，点 IPTV 才落到
/// `/iptv_channels`（也要先有频道才能播）。
class HomePage extends ConsumerStatefulWidget {
  final bool keepAlive;

  const HomePage({super.key, this.keepAlive = true});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final FocusNode _iptvFocus = FocusNode();
  final FocusNode _vodFocus = FocusNode();
  final FocusNode _settingsFocus = FocusNode();

  /// 同一时间只允许一个 IPTV 启动流程：解析库要查 sqlite，快速连点会叠两个播放页。
  bool _launchingIptv = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(RemoteNoticeDialog.maybeShow(context));
      unawaited(HomeUpdateDialog.maybeShow(context, ref));
    });
  }

  @override
  void dispose() {
    _iptvFocus.dispose();
    _vodFocus.dispose();
    _settingsFocus.dispose();
    super.dispose();
  }

  /// 观看历史里最近一条 IPTV 频道。
  ///
  /// 老版本（≤3.0.27）播放时只写观看历史，没有 [IptvResumeChannel] 记录，
  /// 升级后的第一次点 IPTV 要靠它接上。历史是倒序的，取第一条即可。
  LiveRoom? _lastIptvHistoryRoom() {
    for (final room in SettingsService.to.historyState.historyRooms) {
      if (room.normalizedPlatformId == Sites.iptvSite && room.normalizedRoomId.isNotEmpty) return room;
    }
    return null;
  }

  /// 解析 IPTV 的播放目标，按可靠度依次尝试：
  ///
  /// 1. [IptvResumeChannel] —— 上次真正起播成功的台；
  /// 2. 观看历史里最近一条 IPTV 频道 —— 覆盖升级后第一次启动；
  /// 3. 库里第一个可见频道 —— 覆盖新设备 / 清过历史的设备。
  ///
  /// 返回 null 表示库里一个可见频道都没有（云端源还没同步下来）。
  Future<LivePlayArgs?> _resolveIptvArgs() async {
    final db = DbService.to.db;

    final String? savedId = IptvResumeChannel.channelId;
    if (savedId != null) {
      final channel = await db.getChannelById(savedId);
      if (channel != null) return LivePlayArgs(platform: Sites.iptvSite, roomId: channel.id);
      // 频道被删了（换源 / 重新导入）：记录作废，继续往下找。
      IptvResumeChannel.clear();
    }

    final LiveRoom? fromHistory = _lastIptvHistoryRoom();
    if (fromHistory != null) {
      final channel = await db.getChannelById(fromHistory.normalizedRoomId);
      // 带上房间快照，播放页第一帧就有台名/台标；地址仍以回库解析的为准。
      if (channel != null) return LivePlayArgs.fromRoom(fromHistory);
    }

    final first = await db.getFirstVisibleChannel();
    if (first == null) return null;
    return LivePlayArgs(platform: Sites.iptvSite, roomId: first.id);
  }

  /// 点 IPTV：直接进播放页。频道目录只在没有任何可播频道时兜底。
  Future<void> _launchIptv() async {
    if (_launchingIptv) return;
    _launchingIptv = true;
    try {
      final LivePlayArgs? args = await _resolveIptvArgs();
      if (!mounted) return;
      if (args == null) {
        log('iptv launch: no visible channel in db', name: 'HomePage');
        context.push(AppRoutes.kIptvChannels);
        return;
      }
      // 只带 id / 房间快照：播放页会回库重新解析线路与地址。
      LivePlayRoute(args).push(context);
    } catch (e, s) {
      log('launch iptv failed: $e', name: 'HomePage', error: e, stackTrace: s);
      if (mounted) context.push(AppRoutes.kIptvChannels);
    } finally {
      _launchingIptv = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.tvTheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        showExitConfirmDialog(context, ref);
      },
      child: TvScaffold(
        // 遥控器开机焦点落在第一个按钮上。
        openingFocus: _iptvFocus,
        child: DpadRegion(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  i18n('app_name'),
                  style: AppTextStyles.t28.copyWith(
                    color: theme.primaryTextColor,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
                SizedBox(height: 44.ts(context)),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _buildTile(
                      label: i18n(kNavGroups[0].labelKey),
                      icon: kNavGroups[0].icon,
                      focusNode: _iptvFocus,
                      onTap: _launchIptv,
                    ),
                    SizedBox(width: 32.ts(context)),
                    _buildTile(
                      label: i18n(kNavGroups[1].labelKey),
                      icon: kNavGroups[1].icon,
                      focusNode: _vodFocus,
                      onTap: () => context.push(AppRoutes.kVodBrowse),
                    ),
                    SizedBox(width: 32.ts(context)),
                    _buildTile(
                      label: i18n(kNavGroups[2].labelKey),
                      icon: kNavGroups[2].icon,
                      focusNode: _settingsFocus,
                      onTap: () => const SettingsMenuRoute().push(context),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTile({
    required String label,
    required IconData icon,
    required FocusNode focusNode,
    required VoidCallback onTap,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: 240.ts(context),
        minHeight: 150.ts(context),
        maxWidth: 320.ts(context),
      ),
      child: TvButton(
        title: label,
        icon: Icon(icon),
        iconPosition: TvIconPosition.top,
        size: TvButtonSize.large,
        focusNode: focusNode,
        autofocus: focusNode == _iptvFocus,
        onTap: onTap,
      ),
    );
  }
}
