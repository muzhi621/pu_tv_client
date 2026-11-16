import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/modules/live/playback/player_panel_layout.dart';
import 'package:pure_live/modules/live/playback/models/live_play_args.dart';
import 'package:pure_live/modules/live/playback/states/live_play_state.dart';
import 'package:pure_live/modules/live/playback/widgets/player_key_scope.dart';
import 'package:pure_live/modules/live/playback/widgets/panels/playlist_panel.dart';
import 'package:pure_live/modules/live/playback/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live/playback/widgets/panels/danmaku_settings_panel.dart';
import 'package:pure_live/modules/live/playback/widgets/video_player/tv_video_surface.dart';

/// Fullscreen live playback page.
///
/// The video always fills the screen (a TV room is fullscreen, period): the
/// channel list, danmaku settings and danmaku filter panels (see
/// [LivePlayPanel]) float over it as an overlay card on one edge — the left one
/// by default, where an IPTV viewer looks for the channel list — instead of
/// squeezing the video into a column.
class LivePlayPage extends ConsumerWidget {
  final LivePlayArgs args;

  const LivePlayPage({super.key, required this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(livePlayControllerProvider(args));
    final controller = ref.read(livePlayControllerProvider(args).notifier);
    final tvTheme = context.tvTheme;
    // 400 design px is a TV-side panel: on a phone held upright it is wider than
    // the screen. The panel inside reads the very same value, so the frame and
    // its content cannot disagree.
    final double panelWidth = PlayerPanelLayout.widthOf(context);

    return PlayerKeyScope(
      args: args,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 视频区**不是** d-pad 节点：整个播放器的按键由本页的
            // PlayerKeyScope 统一处理（见 tv_video_surface 的说明）。
            // 这里曾经包过一层 DpadRegion，它会自建焦点区域并记忆焦点，
            // 把 primaryFocus 从页面级 Focus 抢走后，方向键被当焦点遍历吞掉，
            // 表现正是「画面在播、遥控器唤不出菜单」——两套焦点体系不能共存。
            TvVideoSurface(args: args),
            // The panel overlays the video instead of sitting beside it: playback
            // keeps the whole screen and the danmaku keep their geometry.
            if (state.showSidePanel)
              Positioned(
                top: 24.sp,
                bottom: 24.sp,
                left: PlayerPanelLayout.isLeft ? PlayerPanelLayout.offset.ts(context) : null,
                right: PlayerPanelLayout.isLeft ? null : PlayerPanelLayout.offset.ts(context),
                width: panelWidth,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20.ts(context)),
                  child: Container(
                    decoration: BoxDecoration(
                      color: tvTheme.backgroundColor.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(20.ts(context)),
                      border: Border.all(color: tvTheme.focusColor.withValues(alpha: 0.35)),
                    ),
                    // 面板内部（PlayerIndexPanel）自己持有一个 Focus 并手写
                    // 上下/确认键，不需要 d-pad 焦点区。这里原本又包了一层
                    // DpadRegion：它会自建焦点区域、记忆焦点，和面板内的
                    // Focus 抢同一个 primaryFocus，方向键在面板里的行为因此
                    // 时好时坏。与视频区同理，一套焦点体系就够。
                    child: _SidePanel(
                      state: state,
                      controller: controller,
                      args: args,
                      onTogglePanel: controller.toggleSidePanel,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Side panel container. The content is chosen by [LivePlayState.panel].
///
/// A [Key] forces the subtree to rebuild when the panel changes, so the new
/// panel's `autofocus` row can take focus.
class _SidePanel extends ConsumerWidget {
  final LivePlayState state;
  final LivePlayController controller;
  final LivePlayArgs args;
  final VoidCallback onTogglePanel;

  const _SidePanel({required this.state, required this.controller, required this.args, required this.onTogglePanel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tvTheme = context.tvTheme;

    // Collapse button in the panel corner: it keeps a remote path back to the
    // video area.
    // The panel carries its own visible back row now, so the old d-pad collapse
    // button is just a hint.
    final collapse = Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.ts(context), vertical: 10.ts(context)),
      child: Text(
        i18nOr('ui_panel_keys', '↑↓ select · OK confirm · ← back'),
        style: AppTextStyles.t14.copyWith(fontWeight: FontWeight.w500, color: tvTheme.secondaryTextColor),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildContent(context)),
        collapse,
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (state.panel) {
      // No panel open (or the layout state did not record one yet).
      case null:
        return const SizedBox.shrink();
      case LivePlayPanel.playlist:
        return PlaylistPanel(key: const ValueKey('live-play-panel-playlist'), args: args);
      case LivePlayPanel.danmakuSettings:
        return DanmakuSettingsPanel(key: const ValueKey('live-play-panel-danmaku'), onClose: onTogglePanel);
      case LivePlayPanel.shield:
        // #68 减法：弹幕过滤（屏蔽词）系统已降级，返回空面板
        return const SizedBox.shrink();
    }
  }
}
