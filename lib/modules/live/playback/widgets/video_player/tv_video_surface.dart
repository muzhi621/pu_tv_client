import 'package:pure_live/player/index.dart';
import 'package:rxdart/rxdart.dart';
import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/modules/live/playback/models/live_play_args.dart';
import 'package:pure_live/modules/live/playback/widgets/danmaku/danmaku_overlay.dart';
import 'package:pure_live/modules/live/playback/widgets/player_key_scope.dart';
import 'package:pure_live/modules/live/playback/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live/playback/widgets/video_player/audio_only_surface.dart';
import 'package:pure_live/modules/live/playback/widgets/video_player/video_controller_panel.dart';
import 'package:pure_live/modules/live/playback/widgets/placeholder/not_living_video_widget.dart';
import 'package:pure_live/modules/live/playback/widgets/video_player/playback_failure_overlay.dart';

/// Video surface: a Stack of the PlayerManager video layer, the flame_barrage
/// overlay, loading/error overlays and an auto-hiding D-pad control panel.
///
/// Remote key layout, ported from handleKeyNoPanel in the legacy app:
/// - Up / Down: open the channel list on the left (酷9's layout) with the
///   current channel highlighted; ↑↓ inside it walk the list and OK switches
/// - Left: double press to follow or unfollow
/// - Right: open the channel list as well
/// - OK: show the bottom control bar
///
/// Touch devices get the same entry points through [PlaybackTouchLayer]: a tap
/// on the picture is the OK key, a vertical swipe is Up/Down.
///
/// Every direction key is consumed here so focus cannot escape the player and
/// leave the remote apparently dead.

/// The audience read-out of the info bar.
///
/// Plain [LiveRoom.watching] rather than the settings-driven policy: this is a
/// glanceable badge next to the streamer's name, and a missing value must simply
/// not render instead of saying "unknown".
String _audienceText(LiveRoom room) {
  final String raw = room.watching.trim().isNotEmpty ? room.watching.trim() : room.onlineViewers.trim();
  if (raw.isEmpty) return '';
  final String readable = readableCount(raw);
  return readable.isEmpty ? '' : readable;
}

/// A small label pill for the room-info bar: the platform badge (accent filled)
/// and the audience read-out (plain).
class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.label, this.icon, this.accent, this.filled = false});

  final String label;
  final IconData? icon;
  final Color? accent;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final Color color = accent ?? Colors.white;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.ts(context), vertical: 4.ts(context)),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9.ts(context)),
        border: Border.all(color: filled ? color.withValues(alpha: 0.75) : Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18.ts(context), color: Colors.white70),
            SizedBox(width: 5.ts(context)),
          ],
          Text(
            label,
            style: AppTextStyles.t18.copyWith(
              fontWeight: FontWeight.w600,
              color: filled ? Colors.white : Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

class TvVideoSurface extends ConsumerStatefulWidget {
  final LivePlayArgs args;

  const TvVideoSurface({super.key, required this.args});

  @override
  ConsumerState<TvVideoSurface> createState() => _TvVideoSurfaceState();
}

class _TvVideoSurfaceState extends ConsumerState<TvVideoSurface> {
  /// The player manager, or null until [GlobalPlayerService] has finished
  /// initializing.
  ///
  /// `GlobalPlayerService.playerManager` is a `late final` field: reading it
  /// before initialization throws `LateInitializationError`, and a build that
  /// throws tears down whatever the previous build had mounted — which disposed
  /// media_kit's video output and made the next successful frame create a new
  /// one. That is the whole `VideoOutputManager.create` → `dispose` →
  /// `Resize 0x0` → `Surface.release()` NPE sequence in logcat. Never read the
  /// field without this check.
  LivePlayerFacade? get _playerManagerOrNull =>
      GlobalPlayerService.instance.initialized ? GlobalPlayerService.instance.livePlayer : null;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(livePlayControllerProvider(widget.args));
    final controller = ref.read(livePlayControllerProvider(widget.args).notifier);
    final tvTheme = context.tvTheme;

    // The room is seeded as soon as the session starts, so this is what the
    // info card draws from - before the site response, and after a failed one.
    final LiveRoom? room = state.room;

    // Room-detail loading is a business-level concern: it is not a player
    // state, so it is derived from LivePlayState's own fields. [room] is seeded
    // from the entry, so the flag - not a null room - is what says the site
    // response is still pending; the null check stays as the fallback for a
    // session that has not run its bootstrap yet.
    final bool loadingDetail = state.fetchingDetail || (state.room == null && state.detailError == null);

    // Show the spinner while the detail request or the player itself is
    // still working. Playback progress comes exclusively from media_core's
    // PlayerState; there is no local LivePlayStatus.
    final bool showLoading =
        !state.isOffline &&
        !state.hasStartedPlayback &&
        (loadingDetail || state.playerState.opening || state.playerState.buffering);

    // A single error flag for the overlay: business failures (detail / stream
    // URL / play() throwing) surface through errorMessage or detailError;
    // terminal playback failures from media_core surface through
    // playerState.hasError (the controller also mirrors them into errorMessage
    // via ErrorFormatter).
    final bool showError = state.showFailureOverlay;

    // The video widget stays mounted for the whole session, and the surface is
    // simply black until the player service is up.
    //
    // It used to be replaced by a black `Container` whenever `showError` was
    // true, and the manager getter threw while the service was still starting.
    // Either way the previously mounted `Video` was torn down, which disposed
    // media_kit's video output and made the next frame create a new one — the
    // `VideoOutputManager.create` → `dispose` → `Resize 0x0` → `Surface.release()`
    // NPE sequence in logcat (an output destroyed before it ever had a surface).
    // The failure overlay is drawn on top of the surface instead.
    final LivePlayerFacade? manager = _playerManagerOrNull;
    // The surface listens to `videoKey` on purpose: an engine switch bumps the
    // key, and this rebuild is what unmounts the `Video` widget of the retired
    // controller *before* PlayerManager destroys it. Without the listener the
    // old subtree survived until the next unrelated state change and kept
    // throwing "A ValueNotifier<int?> was used after being disposed".
    final Widget video = manager != null
        ? manager.getVideoWidget(state.fitIndex, fitList: kLivePlayFitList)
        : const ColoredBox(color: Colors.black);

    // Audio-only mode: the picture is replaced by the room panel, but the video
    // widget is only hidden, never unmounted — tearing it down disposes the
    // engine's video output and the restore would then have to rebuild the
    // whole texture. The listener mirrors what the settings page pushes into the
    // player, so the panel appears the moment the switch flips.
    //
    // A video track with no real picture (a placeholder track, or an
    // audio-live platform) gets the cover too; black is not a rendering.
    final Widget videoLayer = manager == null
        ? video
        : StreamBuilder<bool>(
            stream: Rx.combineLatest2<bool, bool, bool>(
              manager.onAudioOnlyChanged,
              manager.onDummyVideoChanged,
              (audioOnly, dummy) => audioOnly || dummy,
            ),
            initialData: manager.isAudioOnly || manager.isDummyVideo,
            builder: (context, snapshot) {
              final bool audioOnly = snapshot.data ?? false;
              return Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(offstage: audioOnly, child: video),
                  if (audioOnly) AudioOnlySurface(room: state.room),
                ],
              );
            },
          );

    final children = <Widget>[
      // The video area is NOT a d-pad node any more: the whole player is key
      // handled by [LivePlayPage], exactly like the reference player. Keys reach
      // it through the page-level [Focus], so nothing here competes for focus.
      Stack(
        fit: StackFit.expand,
        children: [
          videoLayer,
          DanmakuOverlay(args: widget.args),
          // 触摸捕获层：必须在视频**之上**。
          //
          // 视频是原生 Texture（media_kit 的 `mkv.Video`），它自己的
          // hitTestSelf 为 true，会把指针事件吃掉——外层的 GestureDetector
          // 因此永远收不到触摸，手机上点屏幕毫无反应。这层是普通 widget，
          // 指针事件一定先到它。
          //
          // 放在弹幕之后：弹幕自己带 IgnorePointer，两者不冲突；但捕获层要
          // 在弹幕之上，才能保证「画面上任何一点」都能接住。
          //
          // 控制条与失败浮层是后加入的兄弟节点（Positioned），层级更高，
          // 它们的按钮不会被这层挡住。
          if (!state.showControls && !showError && !state.isOffline)
            const Positioned.fill(child: _TouchCaptureLayer()),
          // The loading overlay covers both the initial start and every
          // later moment the surface provably has no picture: a source
          // opening, a line switch, an engine switch. The availability
          // stream comes from the player facade.
          //
          // Both signals must agree before a spinner is drawn: the state
          // has to still be waiting (detail loading / opening / buffering)
          // AND the surface must actually have no frame. media_core keeps
          // `opening` until its playback verification passes, which on a
          // slow source lands seconds after the first frame is already on
          // screen - keying the spinner on the state alone pinned the buffering label
          // over a picture that was playing.
          if (manager != null)
            StreamBuilder<bool>(
              stream: manager.onPictureAvailable,
              initialData: manager.hasPicture,
              builder: (context, pictureSnapshot) {
                final bool noPicture = !(pictureSnapshot.data ?? true);
                final bool waiting = loadingDetail || (showLoading && noPicture);

                if (showError || state.isOffline || !waiting) {
                  return const SizedBox.shrink();
                }

                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      tvInlineLoading(context, size: 36.ts(context)),
                      SizedBox(height: 12.ts(context)),
                      Text(
                        loadingDetail ? i18n('ui_loading_room_info') : i18n('ui_buffering'),
                        style: AppTextStyles.t16.copyWith(
                          fontWeight: FontWeight.w500,
                          color: tvTheme.secondaryTextColor,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          // Room info, the channel toast and the failure overlay are painted by
          // the outer stack, above this one: see [_RoomInfoBar].
        ],
      ),
    ];

    if (showError) {
      children.add(
        Positioned.fill(
          child: PlaybackFailureOverlay(
            message: state.errorMessage ?? i18n('multiview_play_failed'),
            onRetry: controller.retry,
            onRefreshRoom: controller.refreshRoom,
          ),
        ),
      );
    } else if (state.isOffline) {
      children.add(Positioned.fill(child: NotLivingVideoWidget(args: widget.args)));
    } else if (state.showControls) {
      // Flush to the bottom edge: the bar's own black band is the anchor, and
      // floating it above the edge left a strip of live picture under it.
      children.add(Positioned(left: 0, right: 0, bottom: 0, child: VideoControllerPanel(args: widget.args)));
    }

    // Room info and the channel toast paint last, above whichever overlay is up.
    //
    // The card is drawn whenever the room is known: while the site response is
    // pending (the data is already there, and an up/down switch would otherwise
    // be a black screen with a spinner), with the controls, on its own for a few
    // seconds after entry, and - most of all - under a failure overlay, which
    // cannot name the room it is about. The toast sits under the card while the
    // card is up instead of on top of it.
    if (room != null &&
        !state.isOffline &&
        (state.showRoomInfo || state.showControls || state.fetchingDetail || showError)) {
      children.add(
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _RoomInfoBar(room: room),
              if (state.showChannelBanner)
                Padding(
                  padding: EdgeInsets.only(top: 10.sp),
                  child: _ChannelBannerToast(text: state.channelBanner!),
                ),
            ],
          ),
        ),
      );
    } else if (state.showChannelBanner) {
      children.add(
        Positioned(
          left: 0,
          right: 0,
          top: 64.sp,
          child: _ChannelBannerToast(text: state.channelBanner!),
        ),
      );
    }

    // The quality / line read-out that used to sit on the right edge is gone:
    // both live on the control bar, which is where the user picks them, and a
    // permanent copy over the picture is one more thing competing with the
    // stream. A switch in progress is still reported — by the bar's own pill,
    // whose glyph turns into a ring while it applies.

    return Stack(fit: StackFit.expand, children: children);
  }
}

/// Floating room card: avatar, room title, and a metadata line (platform,
/// streamer, audience) with the wall clock behind a divider on the right.
///
/// Two separate cards side by side read as two unrelated read-outs instead of
/// one room banner, which is why the clock lives in here.
///
/// Non-interactive on purpose: it is information, and the picture below it must
/// stay reachable by the remote and the mouse.
class _RoomInfoBar extends StatelessWidget {
  const _RoomInfoBar({required this.room});

  final LiveRoom room;

  @override
  Widget build(BuildContext context) {
    final tvTheme = context.tvTheme;
    final String audience = _audienceText(room);

    return IgnorePointer(
      child: Container(
        // 两端留白加大：这张卡片向屏幕中间收，头像与时钟不再贴着边缘。
        padding: EdgeInsets.fromLTRB(40.ts(context), 14.ts(context), 40.ts(context), 20.ts(context)),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.72), Colors.black.withValues(alpha: 0.0)],
          ),
        ),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 20.ts(context), vertical: 14.ts(context)),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(18.ts(context)),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Row(
            children: [
              TvCommonAvatar(avatarUrl: room.avatar, fallbackName: room.nick, radius: 34.ts(context)),
              SizedBox(width: 16.ts(context)),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Falls back to the streamer and then to the room id: a room
                    // whose title never arrived still has to be nameable, or an
                    // error about it cannot be acted on.
                    Text(
                      room.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.t28.copyWith(fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    SizedBox(height: 9.ts(context)),
                    Row(
                      children: [
                        if (room.platform.isNotEmpty) ...[
                          _InfoPill(label: room.platform.toUpperCase(), accent: tvTheme.focusColor, filled: true),
                          SizedBox(width: 10.ts(context)),
                        ],
                        if (room.nick.isNotEmpty)
                          Flexible(
                            child: Text(
                              room.nick,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.t18.copyWith(fontWeight: FontWeight.w500, color: Colors.white70),
                            ),
                          ),
                        if (room.nick.isNotEmpty && audience.isNotEmpty) SizedBox(width: 10.ts(context)),
                        if (audience.isNotEmpty) _InfoPill(label: audience, icon: Icons.whatshot_rounded),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: 18.ts(context)),
              Container(
                width: 1.ts(context),
                height: 44.ts(context),
                color: Colors.white.withValues(alpha: 0.14),
              ),
              SizedBox(width: 18.ts(context)),
              // Wall clock: a live stream has no duration, so the time a viewer
              // glances up for is the time of day. The glyph rides the same
              // factor as the digits beside it.
              Icon(RemixIcons.time_line, size: 26.ts(context), color: Colors.white70),
              SizedBox(width: 9.ts(context)),
              TvDigitalClock(
                format: 'HH:mm',
                style: AppTextStyles.t28.copyWith(fontWeight: FontWeight.w600, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Channel name pill shown for a couple of seconds after an up/down switch.
class _ChannelBannerToast extends StatelessWidget {
  const _ChannelBannerToast({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tvTheme = context.tvTheme;

    return IgnorePointer(
      child: Center(
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 24.ts(context), vertical: 12.ts(context)),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12.ts(context)),
            border: Border.all(color: tvTheme.focusColor.withValues(alpha: 0.6)),
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.t24.copyWith(fontWeight: FontWeight.w600, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// 视频之上的透明触摸捕获层。
///
/// 它不画任何东西，只把指针事件接住并转成播放页的手势语义（单击 / 滑动）。
/// 必须存在的原因：原生 Texture 会吃掉指针事件，没有这层，手机上点屏幕
/// 完全没反应。
///
/// 事件处理来自 [PlayerGestureScope]（播放页提供），所以与遥控器共用同一套
/// 语义，不会出现「触摸能做而按键不能」的分叉。
class _TouchCaptureLayer extends StatelessWidget {
  const _TouchCaptureLayer();

  @override
  Widget build(BuildContext context) {
    final PlayerGestureScope? gestures = PlayerGestureScope.maybeOf(context);
    // 没有 scope（组件被单独使用时）就不接管，交给下层自己处理。
    if (gestures == null) return const SizedBox.shrink();

    return GestureDetector(
      // opaque：即使子节点没有内容，也要占满并接收事件。
      behavior: HitTestBehavior.opaque,
      onTap: gestures.onTap,
      onDoubleTap: gestures.onDoubleTap,
      onPanStart: gestures.onPanStart,
      onPanUpdate: gestures.onPanUpdate,
      onPanEnd: gestures.onPanEnd,
      onPanCancel: gestures.onPanCancel,
      child: const SizedBox.expand(),
    );
  }
}
