import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/app/router/app/app_routes.dart';
import 'package:pure_live/modules/live/movie_playback/vod_browse_page.dart';
import 'package:pure_live/modules/live/playback/models/live_play_args.dart';
import 'package:pure_live/modules/live/playback/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live/playback/states/live_play_state.dart';
import 'package:pure_live/modules/live/playback/widgets/panels/player_index_panel.dart';
import 'package:pure_live/services/remote_config/remote_config.dart';
import 'package:pure_live/services/vod/vod_config.dart';

/// 点播播放页的「切换站点」侧栏。
///
/// 点播没有「换台」：一条选集地址属于某个具体站点，换台需要一个可映射的
/// 频道表。用户真正需要的是「这个站播不了，换一个站找同一部片」，所以列表
/// 直接列云端下发的站点，选中后回影音首页并预选该站点，用户从它的推荐/
/// 搜索里继续找——比在播放器里伪造一个换台列表诚实。
///
/// 侧栏复用 [PlayerIndexPanel] 的索引焦点：↑↓ 走列表、OK 选中、← 或返回关闭。
/// 播放器页面在有侧栏时不再抢按键，两者不会争焦点。
class VodSitePanel extends ConsumerStatefulWidget {
  const VodSitePanel({super.key, required this.args});

  final LivePlayArgs args;

  @override
  ConsumerState<VodSitePanel> createState() => _VodSitePanelState();
}

class _VodSitePanelState extends ConsumerState<VodSitePanel> {
  int _index = 0;

  void _close() {
    ref.read(livePlayControllerProvider(widget.args).notifier).togglePanel(LivePlayPanel.vodSites);
  }

  @override
  Widget build(BuildContext context) {
    final sites = RemoteConfigService.vod.sites;
    final int selected = sites.isEmpty ? 0 : _index.clamp(0, sites.length - 1);

    return PlayerIndexPanel(
      title: i18n('ui_switch_site'),
      rows: <PlayerPanelRow>[
        for (final site in sites)
          PlayerPanelRow(
            label: site.name,
            subtitle: site.sourceId.isEmpty ? null : site.sourceId,
          ),
      ],
      selectedIndex: selected,
      onSelectionChanged: (i) => setState(() => _index = i),
      onSelect: (i) {
        if (i < 0 || i >= sites.length) return;
        VodBrowsePage.pendingSiteId = sites[i].id;
        context.go(AppRoutes.kVodBrowse);
      },
      onClose: _close,
      emptyHint: i18n('ui_none'),
      hint: i18nOr('ui_panel_keys', '↑↓ 选择 · OK 确认 · ← 关闭'),
    );
  }
}
