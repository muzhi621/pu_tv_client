import 'dart:async';
import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/app/router/app/app_router.dart';
import 'package:pure_live/modules/live/playback/models/live_play_args.dart';
import 'package:pure_live/services/favorites/favorite_room_controller.dart';
import 'package:pure_live/modules/live/playback/states/live_play_state.dart';
import 'package:pure_live/modules/live/playback/controllers/live_play_controller.dart';

/// Key handling for the whole player — **without d-pad**.
///
/// Modelled on the reference player
/// (`E:/project/pure_live_TV/lib/modules/live_play/widgets/video_player/controller/
/// video_key_handler.dart`): one handler owns every key and decides what to do
/// from what is currently on screen, instead of leaving focus traversal to the
/// d-pad layer. Keys reach it through one [Focus], so nothing can steal focus or
/// leave the player with a dead remote.
///
/// * nothing open: OK shows the controls, Up/Down switch channel, Left
///   double-presses to follow, Right opens the playlist
/// * a side panel open: keys belong to that panel (they are focus based)
/// * controls visible: the control layer's own [Focus] handles them first —
///   events bubble from the primary focus outwards, so this handler stays out of
///   the way by ignoring them
class PlayerKeyScope extends ConsumerStatefulWidget {
  const PlayerKeyScope({super.key, required this.args, required this.child});

  final LivePlayArgs args;
  final Widget child;

  @override
  ConsumerState<PlayerKeyScope> createState() => _PlayerKeyScopeState();
}

class _PlayerKeyScopeState extends ConsumerState<PlayerKeyScope> {
  /// Double-press window for the left key, as in the reference (500 ms).
  static const Duration _doubleClickWindow = Duration(milliseconds: 500);

  final FocusNode _focusNode = FocusNode(debugLabel: 'live_play/keys');
  int _lastLeftTapAt = 0;
  Timer? _leftTapTimer;

  /// Channel switches are debounced: rapid presses accumulate their delta and
  /// one session teardown commits the total, so mashing Down walks several
  /// rooms instead of fighting the route replace mid-flight.
  Timer? _channelDebounce;
  int _pendingChannelDelta = 0;

  /// The window rapid presses have to accumulate within.
  static const Duration _channelDebounceWindow = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    // 兜底按键通道（见 [_onGlobalKey]）。
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _leftTapTimer?.cancel();
    _channelDebounce?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  /// 兜底按键通道：不依赖焦点链。
  ///
  /// 为什么需要它：播放页的焦点在部分机型/状态下会丢——媒体 surface 换成
  /// 原生视图、平台层抢走 primaryFocus 之后，[Focus] 树上的 handler 就
  /// 收不到遥控器按键，表现正是「画面在播、按什么都没反应」，菜单唤不出来。
  /// 硬件键盘 handler 在焦点派发之前拿到所有按键，只要本页还是当前路由，
  /// 遥控器就一定有响应。
  ///
  /// 但要放行两种情况：控制条/侧栏打开时它们靠焦点导航（抢在前面会把 OK
  /// 变成「再显示一次控制条」而不是「按下当前按钮」），阻塞浮层有自己的
  /// 焦点按钮。
  bool _onGlobalKey(KeyEvent event) {
    if (!mounted) return false;

    // 只接管当前路由：上一页还在栈里时不能抢它的按键。
    if (ModalRoute.of(context)?.isCurrent == false) return false;

    final state = ref.read(livePlayControllerProvider(widget.args));

    if (state.showSidePanel || state.showControls || state.hasBlockingOverlay) return false;

    return _onKeyEvent(_focusNode, event) == KeyEventResult.handled;
  }

  static bool _isConfirm(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    final state = ref.read(livePlayControllerProvider(widget.args));
    final controller = ref.read(livePlayControllerProvider(widget.args).notifier);
    final key = event.logicalKey;

    // A panel with its own index handling consumes its keys first; what reaches
    // here while a panel is open is Left/Escape, which closes it (room info has no
    // keys of its own).
    if (state.showSidePanel) {
      if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.escape) {
        controller.toggleSidePanel();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // Blocking overlays (playback failure / offline) carry their own focusable
    // buttons and handle left/right/OK on their own node. These must pass
    // through: the page would otherwise eat OK as "show controls" and left/right
    // as channel switch and follow, leaving the overlay buttons unreachable
    // (their autofocus loses to the node this scope already holds). Up/Down stay
    // here - hopping to the next room is the fastest way past a dead one.
    if (state.hasBlockingOverlay) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _switchChannel(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _switchChannel(1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // With the controls up, the control layer runs first. It leaves Up/Down
    // unhandled while no option list is open, so those arrive here: switch
    // rooms with the same debounced accumulate-and-commit path as everywhere
    // else. Left/Right/OK belong to the bar and are forwarded by returning
    // ignored (they were already consumed when an option list is open).
    if (state.showControls) {
      if (widget.args.vod) {
        // 点播没有「上下换台」，把这两键让给控制条自己（选项列表用它导航）。
        return KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _switchChannel(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _switchChannel(1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // 点播：遥控器左右就是快进 / 后退，上下唤出控制条。
    //
    // 直播那套「左键双击关注、右键开播放列表」在点播里全是噪音——用户
    // 想看的是时间轴。这里优先做时间轴，菜单靠 OK / 上下来唤。
    if (widget.args.vod) {
      if (_isConfirm(key)) {
        controller.showControls();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        unawaited(_seek(controller, -10));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        unawaited(_seek(controller, 10));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
        controller.showControls();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (_isConfirm(key)) {
      controller.showControls();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      _switchChannel(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _switchChannel(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _handleFollowDoublePress();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      controller.togglePanel(LivePlayPanel.playlist);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Queues a channel switch by [delta] (-1 previous, 1 next).
  ///
  /// Presses inside [_channelDebounceWindow] accumulate into one commit, so a
  /// rapid Down Down Down walks three rooms with a single session teardown
  /// instead of racing the route replace with a navigation per press.
  void _switchChannel(int delta) {
    _pendingChannelDelta += delta;
    _channelDebounce?.cancel();
    _channelDebounce = Timer(_channelDebounceWindow, _commitChannelSwitch);
  }

  /// Commits the accumulated channel delta: one route replace, one release.
  void _commitChannelSwitch() {
    final int delta = _pendingChannelDelta;
    _pendingChannelDelta = 0;
    if (delta == 0 || !mounted) return;

    final controller = ref.read(livePlayControllerProvider(widget.args).notifier);
    final rooms = controller.channelRooms;
    final target = controller.relativeChannel(delta);
    if (target == null) {
      ToastUtil.show(i18nOr('ui_no_switchable_channel', 'No channel available to switch to'));
      return;
    }
    // Channel switching uses a route replace, so the previous session is released.
    LivePlayRoute(LivePlayArgs.fromRoom(target, playlist: rooms, showChannelBanner: true)).replace(context);
  }

  /// 点播快进 / 后退并在画面上回显落点。
  ///
  /// 回显是必要的：快进时画面本来就在变，没有时间戳用户不知道跳了多远。
  /// 时长未知（源没给 metadata）时只显示落点，不显示总长。
  Future<void> _seek(LivePlayController controller, int seconds) async {
    final Duration? landed = await controller.seekBy(seconds);

    if (landed == null || !mounted) return;

    final Duration? duration = ref.read(livePlayControllerProvider(widget.args)).duration;
    final String arrow = seconds > 0 ? '⏩' : '⏪';
    final String tail = duration == null ? '' : ' / ${_fmtDuration(duration)}';

    ToastUtil.show('$arrow ${_fmtDuration(landed)}$tail');
  }

  static String _fmtDuration(Duration value) {
    final int hours = value.inHours;
    final String minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  /// Left double-press follows or unfollows the room.
  void _handleFollowDoublePress() {    final room = ref.read(livePlayControllerProvider(widget.args)).room;
    if (room == null) return;
    final fav = ref.read(favoriteRoomControllerProvider.notifier);
    final bool isFavorite = fav.isFavorite(room);

    final int now = DateTime.now().millisecondsSinceEpoch;
    final bool isDoubleClick = _lastLeftTapAt != 0 && now - _lastLeftTapAt < _doubleClickWindow.inMilliseconds;
    if (!isDoubleClick) {
      _lastLeftTapAt = now;
      ToastUtil.show(
        isFavorite
            ? i18nOr('ui_double_click_unfollow', 'Double click to unfollow')
            : i18nOr('ui_double_click_follow', 'Double click to follow'),
      );
      _leftTapTimer?.cancel();
      _leftTapTimer = Timer(const Duration(milliseconds: 600), () => _lastLeftTapAt = 0);
      return;
    }

    _lastLeftTapAt = 0;
    _leftTapTimer?.cancel();
    if (isFavorite) {
      fav.removeRoom(room);
      ToastUtil.show(i18nOr('ui_unfollowed', 'Unfollowed'));
    } else {
      fav.addRoom(room);
      ToastUtil.show(i18n('followed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back closes what is on screen before it leaves the player: an option
      // list, then the side panel, then the controls and the room card — and
      // only then the page. Leaving straight from a visible panel made the
      // remote feel unpredictable.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final state = ref.read(livePlayControllerProvider(widget.args));
        final controller = ref.read(livePlayControllerProvider(widget.args).notifier);
        if (state.showSidePanel) {
          controller.toggleSidePanel();
          return;
        }
        if (state.showControls || state.showRoomInfo) {
          controller.dismissOverlays();
          return;
        }
        if (mounted) Navigator.of(context).pop();
      },
      child: Focus(focusNode: _focusNode, autofocus: true, onKeyEvent: _onKeyEvent, child: widget.child),
    );
  }
}
