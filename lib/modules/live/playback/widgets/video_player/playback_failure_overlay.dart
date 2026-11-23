import 'package:pure_live/exports/package_export.dart';

/// Playback failure overlay with a single action: retry.
///
/// The earlier three-button version (retry / refresh room / channel list) was
/// the wrong shape on a TV: the failure is a dead stream, so "refresh room" only
/// repeats the same failing request, and the list is reachable from the remote
/// (up/down switches channel, menu opens the list). Three focusable pills also
/// meant a remote user had to steer left/right before OK did anything.
///
/// Focus model: this overlay **owns a focus node and handles its own keys**,
/// exactly like the control bar does. The player page is key-handled by one
/// handler that would otherwise eat OK as "show the controls", leaving the
/// button unreachable. An `autofocus` inside the button cannot win here either:
/// Flutter honours one autofocus per scope and the page's handler node already
/// holds it.
class PlaybackFailureOverlay extends StatefulWidget {
  final String message;
  final String? hint;
  final VoidCallback onRetry;

  const PlaybackFailureOverlay({
    super.key,
    required this.message,
    required this.onRetry,
    this.hint,
  });

  @override
  State<PlaybackFailureOverlay> createState() => _PlaybackFailureOverlayState();
}

class _PlaybackFailureOverlayState extends State<PlaybackFailureOverlay> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'live_play/failure');

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

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (!mounted) return KeyEventResult.ignored;

    if (_isConfirm(event.logicalKey)) {
      widget.onRetry();
      return KeyEventResult.handled;
    }
    // ↑/↓ 留给页面换台；菜单键留给页面打开列表/站点面板。
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
              widget.hint ?? i18nOr('ui_failure_keys_hint', 'OK 重试'),
              style: AppTextStyles.t14.copyWith(fontWeight: FontWeight.w500, color: tvTheme.secondaryTextColor),
            ),
            SizedBox(height: 20.ts(context)),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onRetry,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.symmetric(horizontal: 26.ts(context), vertical: 12.ts(context)),
                decoration: BoxDecoration(
                  color: tvTheme.focusColor,
                  borderRadius: BorderRadius.circular(12.ts(context)),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.85)),
                  boxShadow: [
                    BoxShadow(
                      color: tvTheme.focusColor.withValues(alpha: 0.55),
                      blurRadius: 14.ts(context),
                      spreadRadius: 1.ts(context),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh, size: 20.ts(context), color: Colors.white),
                    SizedBox(width: 8.ts(context)),
                    Text(
                      i18n('ui_retry_playback'),
                      style: AppTextStyles.t16.copyWith(fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
