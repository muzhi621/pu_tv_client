import 'package:pure_live/player/index.dart';
import 'package:rxdart/rxdart.dart';
import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/modules/live/playback/models/live_play_args.dart';
import 'package:pure_live/modules/live/playback/widgets/danmaku/danmaku_overlay.dart';
import 'package:pure_live/modules/live/playback/widgets/player_key_scope.dart';
import 'package:pure_live/modules/live/playback/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live/playback/states/live_play_state.dart';
import 'package:pure_live/modules/live/playback/widgets/video_player/audio_only_surface.dart';
import 'package:pure_live/modules/live/playback/widgets/video_player/video_controller_panel.dart';
import 'package:pure_live/modules/live/playback/widgets/placeholder/not_living_video_widget.dart';
import 'package:pure_live/modules/live/playback/widgets/video_player/playback_failure_overlay.dart';
import 'package:pure_live/modules/live/iptv/epg/epg_lookup.dart';
import 'package:pure_live/modules/live/iptv/epg/epg_model.dart';
import 'package:pure_live/modules/live/iptv/epg/epg_playback_service.dart';

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
  void initState() {
    super.initState();
    // 切台信息条要显示「正在播什么」，节目单在这里预热一次：先用本地缓存
    // 同步建索引，过期再后台刷新。放 initState 而不是 build：build 会被
    // 播放状态高频触发，重复调用虽然幂等，但没必要。
    EpgPlaybackService.instance.ensureLoaded();
  }

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
                  // 切台信息条：频道序号 + 名称 + 正在播/下一档（EPG）。
                  // 没有节目单时自动退化成「序号 + 名称」，不会空出一条。
                  child: _ChannelInfoBanner(
                    state: state,
                    rooms: controller.channelRooms,
                    index: controller.channelIndex,
                  ),
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
          // 切台时不带顶部房间卡，但信息条仍然要给出频道号与节目单：
          // 这正是用户按「上/下一台」后最想知道的两件事。
          child: state.room != null
              ? _ChannelInfoBanner(
                  state: state,
                  rooms: controller.channelRooms,
                  index: controller.channelIndex,
                )
              : _ChannelBannerToast(text: state.channelBanner!),
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

/// 切台信息条：频道序号、频道名、几项真实可得的参数，以及 EPG 的
/// 「正在播 / 简介 / 下一档」。
///
/// 参考酷9 的换台浮层，但**只画拿得到的数据**：IPTV 是单码率直链，
/// 没有时移、没有多声轨，播放器也没有对外抛分辨率/帧率，硬编一组
/// 「720x576 / 25FPS / 立体声」出来只会让用户以为那是真实状态。
/// 因此标签只保留三项：平台、分组、协议（IPv4/IPv6，由当前播放地址判断），
/// 有多线路时才追加「线路 n/m」。
///
/// EPG 数据来自 [EpgPlaybackService]（同步查、异步刷新）。匹配不到节目时
/// 整块节目区不渲染，条子退化成「序号 + 频道名」，与改造前一样短。
class _ChannelInfoBanner extends StatelessWidget {
  const _ChannelInfoBanner({required this.state, required this.rooms, required this.index});

  final LivePlayState state;
  final List<LiveRoom> rooms;

  /// 当前频道在 [rooms] 里的下标（0 基），用于显示「3 / 120」。
  final int index;

  @override
  Widget build(BuildContext context) {
    final LiveRoom? room = state.room;
    if (room == null) return const SizedBox.shrink();
    final tvTheme = context.tvTheme;
    final EpgPlaybackService epg = EpgPlaybackService.instance;

    final String title = room.title.trim().isNotEmpty ? room.title.trim() : i18n('untitled_room');
    final int total = rooms.length;
    final String number = total == 0 ? '' : '${index.clamp(0, total - 1) + 1} / $total';

    final List<String> urls = state.playUrls;
    final int line = urls.isEmpty ? 0 : state.lineIndex.clamp(0, urls.length - 1);
    final String protocol = _protocolOf(urls.isEmpty ? '' : urls[line]);

    return IgnorePointer(
      child: Center(
        child: ValueListenableBuilder<int>(
          // 背景拉到节目单后重建一次，否则浮层会一直显示「无节目信息」。
          valueListenable: epg.revision,
          builder: (context, _, _) {
            final EpgProgramme? current = epg.currentOf(title);
            final EpgProgramme? next = epg.nextOf(title);
            return ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 880.ts(context)),
              child: Container(
                margin: EdgeInsets.symmetric(horizontal: 32.ts(context)),
                padding: EdgeInsets.fromLTRB(22.ts(context), 14.ts(context), 22.ts(context), 14.ts(context)),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.74),
                  borderRadius: BorderRadius.circular(14.ts(context)),
                  border: Border.all(color: tvTheme.focusColor.withValues(alpha: 0.45)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (number.isNotEmpty) ...[
                          Text(
                            number,
                            style: AppTextStyles.t22.copyWith(
                              color: tvTheme.focusColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(width: 14.ts(context)),
                        ],
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.t24.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        SizedBox(width: 12.ts(context)),
                        if (room.platform.trim().isNotEmpty)
                          _InfoPill(label: room.platform.toUpperCase(), accent: tvTheme.focusColor, filled: true),
                        if (room.nick.trim().isNotEmpty) ...[
                          SizedBox(width: 8.ts(context)),
                          _InfoPill(label: room.nick.trim()),
                        ],
                        if (protocol.isNotEmpty) ...[
                          SizedBox(width: 8.ts(context)),
                          _InfoPill(label: protocol),
                        ],
                        if (urls.length > 1) ...[
                          SizedBox(width: 8.ts(context)),
                          _InfoPill(label: '线路 ${line + 1}/${urls.length}'),
                        ],
                      ],
                    ),
                    if (current != null) ...[
                      SizedBox(height: 10.ts(context)),
                      Divider(height: 1, color: Colors.white.withValues(alpha: 0.16)),
                      SizedBox(height: 10.ts(context)),
                      _EpgLine(
                        prefix: i18nOr('epg_now_playing', '正在播放'),
                        range: formatEpgRange(current.start, current.end),
                        title: _programmeTitle(current),
                        prefixColor: tvTheme.focusColor,
                      ),
                      if (current.description.trim().isNotEmpty)
                        Padding(
                          padding: EdgeInsets.only(top: 6.ts(context), left: 84.ts(context)),
                          child: Text(
                            current.description.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.t16.copyWith(
                              color: Colors.white70,
                              height: 1.35,
                            ),
                          ),
                        ),
                      if (next != null)
                        Padding(
                          padding: EdgeInsets.only(top: 6.ts(context)),
                          child: _EpgLine(
                            prefix: i18nOr('epg_next', '下一节目'),
                            range: formatEpgRange(next.start, next.end),
                            title: _programmeTitle(next),
                            prefixColor: Colors.white54,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 节目名优先用主标题；XMLTV 常把细节放 subTitle（「第 12 集」这类）。
  String _programmeTitle(EpgProgramme programme) {
    final String sub = programme.subTitle.trim();
    if (sub.isEmpty || programme.title.contains(sub)) return programme.title;
    return '${programme.title} · $sub';
  }

  /// 由播放地址判断协议族：IPv6 主机在 Uri 里带冒号（方括号已被解析掉）。
  ///
  /// 只做「看一眼」，不做 DNS 解析：那是网络请求，不该出现在绘图层。
  String _protocolOf(String url) {
    if (url.isEmpty) return '';
    final String host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return '';
    return host.contains(':') ? 'IPv6' : 'IPv4';
  }
}

/// 「标签 + 时间段 + 标题」一行：正在播放与下一节目共用同一套对齐。
class _EpgLine extends StatelessWidget {
  const _EpgLine({
    required this.prefix,
    required this.range,
    required this.title,
    required this.prefixColor,
  });

  final String prefix;
  final String range;
  final String title;
  final Color prefixColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          // 固定宽度让两行的「时间段」对齐，扫读时不用重新找起点。
          width: 84.ts(context),
          child: Text(
            prefix,
            style: AppTextStyles.t16.copyWith(color: prefixColor, fontWeight: FontWeight.w600),
          ),
        ),
        Text(
          range,
          style: AppTextStyles.t16.copyWith(color: Colors.white70, fontWeight: FontWeight.w500),
        ),
        SizedBox(width: 12.ts(context)),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.t18.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
      ],
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
