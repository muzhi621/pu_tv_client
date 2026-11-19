import 'package:pure_live/exports/package_export.dart';

/// Playback failure overlay with three actions: retry, refresh room and the
/// channel list.
///
/// Focus model: this overlay **owns a focus node and handles its own keys**,
/// exactly like the control bar does. The player page is key-handled by one
/// handler that would otherwise eat OK as "show the controls" and ←/→ as
/// "switch channel / follow", leaving these buttons unreachable. An
/// `autofocus` inside the buttons cannot win here either: Flutter honours one
/// autofocus per scope and the page's handler node already holds it.
///
/// Steering is by selected index (0 = retry, 1 = refresh room, 2 = channel
/// list): ←/→ move, OK activates. Up/Down are left to the page, where they
/// open the channel list directly — on a dead stream the list is the way out,
/// and a blind up/down switch would just land on another dead channel.
class PlaybackFailureOverlay extends StatefulWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onRefreshRoom;
  final VoidCallback onOpenChannelList;

  const PlaybackFailureOverlay({
    super.key,
    required this.message,
    required this.onRetry,
    required this.onRefreshRoom,
    required this.onOpenChannelList,
  });

  @override
  State<PlaybackFailureOverlay> createState() => _PlaybackFailureOverlayState();
}

class _PlaybackFailureOverlayState extends State<PlaybackFailureOverlay> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'live_play/failure');
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Explicit request: the page's own handler node already holds this scope's
    // focus, so `autofocus` alone would be ignored and every key would be
    // routed to the page instead of here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focusNode.hasFocus) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  static bool _isConfirm(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;

  void _activate() {
    if (_index == 0) {
      widget.onRetry();
    } else if (_index == 1) {
      widget.onRefreshRoom();
    } else {
      widget.onOpenChannelList();
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (!mounted) return KeyEventResult.ignored;

    final key = event.logicalKey;

    if (_isConfirm(key)) {
      _activate();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      final int step = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
      setState(() => _index = (_index + step + 3) % 3);
      return KeyEventResult.handled;
    }
    // ↑/↓ 留给页面：失败态下它负责直接打开频道列表。
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final tvTheme = context.tvTheme;
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKeyEvent,
      child: Container(
        color: Colors.black.withValues(alpha: 0.72),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48.ts(context), color: tvTheme.secondaryTextColor),
            SizedBox(height: 12.ts(context)),
            SizedBox(
              // The message's line budget must survive the enlarged text: a
              // fixed 560.ts(context) held fewer words per line once every glyph grew,
              // and the third line then ellipsised mid-sentence.
              width: 560.ts(context),
              child: Text(
                widget.message,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.t18.copyWith(fontWeight: FontWeight.w500, color: tvTheme.primaryTextColor),
              ),
            ),
            SizedBox(height: 10.ts(context)),
            Text(
              i18nOr('ui_failure_keys_hint', '←→ 选择 · OK 确认 · ↑↓ 换台 · 菜单键开频道列表'),
              style: AppTextStyles.t14.copyWith(fontWeight: FontWeight.w500, color: tvTheme.secondaryTextColor),
            ),
            SizedBox(height: 20.ts(context)),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _pill(
                  tvTheme,
                  index: 0,
                  label: i18n('ui_retry_playback'),
                  icon: Icons.refresh,
                  onTap: widget.onRetry,
                ),
                SizedBox(width: 16.ts(context)),
                _pill(
                  tvTheme,
                  index: 1,
                  label: i18n('ui_refresh_room'),
                  icon: Icons.travel_explore,
                  onTap: widget.onRefreshRoom,
                ),
                SizedBox(width: 16.ts(context)),
                _pill(
                  tvTheme,
                  index: 2,
                  label: i18n('ui_channel_list'),
                  icon: Icons.playlist_play,
                  onTap: widget.onOpenChannelList,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// One action pill. [index] is the index-driven highlight; tapping moves the
  /// highlight too, so mouse and remote cannot disagree.
  Widget _pill(
    TvThemeData tvTheme, {
    required int index,
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final bool selected = _index == index;
    // 高亮必须跟着 [selected] 走：原来把背景色写死在调用处，←/→ 移动后
    // 三个按钮只有边框在变，蓝色仍留在第一项，看着像没选中。
    final Color background = selected
        ? tvTheme.focusColor
        : Colors.white.withValues(alpha: 0.12);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => _index = index);
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(horizontal: 22.ts(context), vertical: 12.ts(context)),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12.ts(context)),
          border: Border.all(color: selected ? Colors.white.withValues(alpha: 0.85) : Colors.transparent),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: tvTheme.focusColor.withValues(alpha: 0.55),
                    blurRadius: 14.ts(context),
                    spreadRadius: 1.ts(context),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20.ts(context), color: Colors.white),
            SizedBox(width: 8.ts(context)),
            Text(
              label,
              style: AppTextStyles.t16.copyWith(fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
