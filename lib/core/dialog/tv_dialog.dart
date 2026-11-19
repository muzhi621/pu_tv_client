import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:pure_live/core/theme/tv_theme_x.dart';
import 'package:pure_live/core/widgets/tv_button.dart';
import 'package:pure_live/core/theme/tv_text_scale.dart';
import 'package:pure_live/core/dialog/tv_dialog_focus_guard.dart';
import 'package:pure_live/core/theme/typography/app_font_scale.dart';
import 'package:flutter_screenutil_plus/flutter_screenutil_plus.dart';

class TvDialog extends StatefulWidget {
  final String? title;
  final Widget child;
  final String? confirmText;
  final String? cancelText;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;

  /// The node the keyboard should open on — a select dialog passes the row
  /// holding the value in force. Without it the focus guard settles on the
  /// first focusable, which for a lazy list can transiently be the close button.
  final FocusNode? initialFocusNode;

  /// Frame width; the default fits a plain form, wide lists (the room
  /// switcher) pass more.
  final double? width;

  const TvDialog({
    super.key,
    this.title,
    required this.child,
    this.confirmText,
    this.cancelText,
    this.onConfirm,
    this.onCancel,
    this.initialFocusNode,
    this.width,
  });

  @override
  State<TvDialog> createState() => _TvDialogState();
}

class _TvDialogState extends State<TvDialog> {
  /// The confirm button's node.
  ///
  /// Two jobs: it is the dialog's default opening focus (so a dialog that does
  /// not name a row still lands on the primary action instead of whatever
  /// happens to be focusable first), and it gives the focus guard a stable node
  /// to re-assert — `autofocus` alone only wins the very first frame and never
  /// recovers once something else takes the keyboard.
  final FocusNode _confirmFocus = FocusNode(debugLabel: 'tv-dialog/confirm');

  @override
  void dispose() {
    _confirmFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tvTheme = context.tvTheme;
    final borderRadius = BorderRadius.circular(24.sp);

    // The card must fit the screen.
    //
    // Every length in a dialog is drafted against a 1920x1080 panel, so on a
    // phone held in landscape the card is ~1/3 of the screen wide while its
    // *content* (fixed 260pt QR block, paddings, two text blocks, the button
    // row) still adds up to more than the ~300-400 logical pixels of height
    // that screen has. Dialog does not clip and does not shrink: the button row
    // was painted below the visible area, which is exactly "the exit prompt
    // shows up and cannot be confirmed". Bounding the card keeps the buttons on
    // screen; the body gets the leftover space, and a body that can still be too
    // tall (a long message plus a QR block) scrolls instead of pushing the
    // buttons away.
    final MediaQueryData media = MediaQuery.of(context);
    final double verticalInset = media.padding.vertical / 2 + 16.sp;
    // The soft keyboard counts: on a phone the dialog must stay inside the area
    // the keyboard leaves, not just inside the screen.
    final double maxHeight = (media.size.height - media.viewInsets.vertical - verticalInset * 2)
        .clamp(160.0, double.infinity);

    // The frame is a plain container, not a DpadFocusable.
    //
    // It used to be wrapped in a focusable whose default `excludeChildFocus`
    // put an `ExcludeFocus` over the whole dialog body, so the confirm and
    // cancel buttons could never take focus (the confirm button's
    // `autofocus: true` silently did nothing) and the frame itself became a
    // dead focus stop that swallowed OK. The frame never varied with focus
    // state anyway, so nothing is lost by rendering it directly.
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: 24.sp, vertical: verticalInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.width ?? 800.ts(context),
          maxHeight: maxHeight,
        ),
        child: Container(
          padding: EdgeInsets.all(32.ts(context)),
          decoration: BoxDecoration(
            color: tvTheme.cardColor,
            borderRadius: borderRadius,
            boxShadow: [
              // Crisp ring on light palettes; the blurred halo smears on white.
              BoxShadow(
                color: tvTheme.focusColor.withValues(alpha: .75),
                blurRadius: tvTheme.isLight ? 0 : 12.sp,
                spreadRadius: 1.sp,
              ),
            ],
            border: Border.all(color: tvTheme.focusColor, width: 1.sp),
          ),
          // Keeps the remote inside the modal: the page behind it must not react
          // to the d-pad while a dialog is open.
          child: DpadRegion(
            horizontalEdge: DpadEdgeBehavior.stop,
            verticalEdge: DpadEdgeBehavior.stop,
            // ...and keeps the keyboard here even when something behind the dialog
            // rebuilds and the d-pad layer restores focus to a node of that page.
            child: TvDialogFocusGuard(
              initialFocusNode: widget.initialFocusNode ?? _confirmFocus,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.title != null)
                    Padding(
                      padding: EdgeInsets.only(bottom: 24.ts(context)),
                      child: Text(
                        widget.title!,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: tvTheme.primaryTextColor,
                          fontWeight: FontWeight.bold,
                          fontSize: (32 * AppFontScale.user).sp,
                        ),
                      ),
                    ),
                  // Loose, so a short body keeps the card small; bounded by
                  // what the card has left, so a tall body can no longer push
                  // the buttons off the screen.
                  Flexible(child: widget.child),
                  if (widget.confirmText != null || widget.cancelText != null) ...[
                    SizedBox(height: 32.ts(context)),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (widget.cancelText != null)
                          Padding(
                            padding: EdgeInsets.only(right: 16.ts(context)),
                            child: TvButton(
                              title: widget.cancelText!,
                              size: TvButtonSize.mini,
                              isSecondary: true,
                              onTap: widget.onCancel ?? () => Navigator.of(context).pop(),
                            ),
                          ),
                        if (widget.confirmText != null)
                          TvButton(
                            title: widget.confirmText!,
                            size: TvButtonSize.mini,
                            autofocus: true,
                            focusNode: _confirmFocus,
                            onTap: widget.onConfirm,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
