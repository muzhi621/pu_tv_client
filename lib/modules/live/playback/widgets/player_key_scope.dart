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

  /// 原生兜底通道的注册令牌（0 = 未注册 / 非 Android）。
  int _nativeKeyToken = 0;

  /// 原生通道当前是否处于接管状态，避免每次状态变化都发一次平台调用。
  bool _nativeCapture = false;

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
    // 原生兜底通道：视频 surface 抢焦点时按键进不到引擎，这一层在
    // dispatchKeyEvent 阶段就把方向键/确认键转发过来。只在纯视频态接管，
    // 首帧后再同步一次，避免与控制条/浮层的首帧焦点竞争。
    _nativeKeyToken = AndroidTvKeys.listen(_onNativeKeyDown);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncNativeCapture());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    AndroidTvKeys.stopListening(_nativeKeyToken);
    _nativeKeyToken = 0;
    _leftTapTimer?.cancel();
    _channelDebounce?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  /// 原生通道的接管范围。
  ///
  /// 只在**侧栏打开时**交回 Flutter：侧栏里的播放列表靠框架默认的方向键焦点
  /// 遍历滚动，一旦被原生接管就滚不动；而控制条、失败浮层都是自己实现
  /// `onKeyEvent` 的（按选中索引走），原生合成的按键会先派给它们自己的
  /// Focus 节点（见 [_dispatchNativeKey]），语义完全一致——所以播放器最需要
  /// 救的「唤出菜单 / 操作菜单」这两步，即使在 Flutter 收不到按键的机器上也成立。
  void _syncNativeCapture() {
    if (!mounted) return;
    final state = ref.read(livePlayControllerProvider(widget.args));
    final bool capture = !state.showSidePanel;
    if (capture == _nativeCapture) return;
    _nativeCapture = capture;
    unawaited(AndroidTvKeys.setEnabled(capture));
    // 回到视频态：控制条/浮层关闭时会把 primaryFocus 一起带走（失败浮层
    // 自己 requestFocus、卸载后焦点不回到本页），页面级 handler 就收不到按键。
    // 这里把焦点抢回来，保证遥控器在每一轮关闭浮层之后都还是活的。
    if (capture) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focusNode.hasFocus) _focusNode.requestFocus();
      });
    }
  }

  /// 原生转发的按键 → 复用既有按键逻辑，不另写一套语义。
  void _onNativeKeyDown(int androidKeyCode) {
    if (!mounted) return;
    final LogicalKeyboardKey? key = _logicalKeyOf(androidKeyCode);
    if (key == null) return;
    _dispatchNativeKey(key);
  }

  static LogicalKeyboardKey? _logicalKeyOf(int code) => switch (code) {
        AndroidTvKeys.keyCodeDpadUp => LogicalKeyboardKey.arrowUp,
        AndroidTvKeys.keyCodeDpadDown => LogicalKeyboardKey.arrowDown,
        AndroidTvKeys.keyCodeDpadLeft => LogicalKeyboardKey.arrowLeft,
        AndroidTvKeys.keyCodeDpadRight => LogicalKeyboardKey.arrowRight,
        AndroidTvKeys.keyCodeDpadCenter ||
        AndroidTvKeys.keyCodeEnter ||
        AndroidTvKeys.keyCodeNumpadEnter ||
        AndroidTvKeys.keyCodeMenu =>
          LogicalKeyboardKey.select,
        _ => null,
      };

  static PhysicalKeyboardKey _physicalKeyOf(LogicalKeyboardKey key) => switch (key) {
        LogicalKeyboardKey.arrowUp => PhysicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown => PhysicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft => PhysicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight => PhysicalKeyboardKey.arrowRight,
        _ => PhysicalKeyboardKey.enter,
      };

  /// 把原生按键合成一次 [KeyDownEvent] 派发下去。
  ///
  /// 先给当前 primary focus（控制条 / 失败浮层自己的 Focus），它不处理才落到
  /// 本页的 [_onKeyEvent]。这样原生通道与 Flutter 原生按键走的是同一条语义链。
  void _dispatchNativeKey(LogicalKeyboardKey key) {
    final KeyDownEvent event = KeyDownEvent(
      timeStamp: Duration.zero,
      physicalKey: _physicalKeyOf(key),
      logicalKey: key,
    );
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary != _focusNode) {
      if (primary.onKeyEvent?.call(primary, event) == KeyEventResult.handled) return;
    }
    _onKeyEvent(_focusNode, event);
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
    // 面板 / 控制条 / 浮层的开关决定原生通道是否接管。只在状态真的切换时才
    // 发一次平台调用（[_syncNativeCapture] 内部做了去重），本组件不因状态
    // 变化重建，画面层不受影响。
    ref.listen(livePlayControllerProvider(widget.args), (_, __) => _syncNativeCapture());

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
