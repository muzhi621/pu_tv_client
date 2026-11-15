import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/services/remote_config/remote_config.dart';

Future<void> showExitConfirmDialog(BuildContext context, WidgetRef _) async {
  // 云端未接管（enabled == false）：完全沿用原有弹窗，UI / 文案 / 二维码一字不改。
  if (!RemoteConfigService.exitDialogEnabled) {
    await TvDialogUtils.show<bool>(context: context, builder: (_) => const _ExitConfirmDialog());
    return;
  }

  // 云端接管：never 或本 revision 已展示过 → 不弹窗，直接退出。
  // 用 if/else 而非「exit(0) 后跟 return」，避免不可达代码；确认退出会直接结束进程，
  // 自然也不会落到 else 显示弹窗。
  if (RemoteConfigService.exitDialogMode == 'never' ||
      !RemoteConfigService.shouldShowExitDialog) {
    exit(0);
  } else {
    // 必须在 await show 之前记录：点「确认退出」会 exit(0) 直接结束进程，
    // await 之后的代码不会执行，否则 once_per_revision 无法落盘。
    await RemoteConfigService.markExitDialogShown();
    await TvDialogUtils.show<bool>(
      context: context,
      builder: (_) => _CloudExitConfirmDialog(
        title: RemoteConfigService.exitDialogTitle,
        body: RemoteConfigService.exitDialogBody,
        dismissible: RemoteConfigService.exitDialogDismissible,
        showDonate: RemoteConfigService.exitDialogShowDonate,
        qrImageUrl: RemoteConfigService.exitDialogQrImageUrl,
        qrCaption: RemoteConfigService.exitDialogQrCaption,
        donateBody: RemoteConfigService.exitDialogDonateBody,
        confirmText: RemoteConfigService.exitDialogConfirmText,
        cancelText: RemoteConfigService.exitDialogCancelText,
      ),
    );
  }
}

/// 本地原有弹窗（enabled == false 时使用）：保持一字不改。
class _ExitConfirmDialog extends StatelessWidget {
  const _ExitConfirmDialog();

  @override
  Widget build(BuildContext context) {
    final tvTheme = context.tvTheme;

    return TvDialog(
      title: i18n('confirm_exit'),
      confirmText: i18n('exit_yes'),
      cancelText: i18n('exit_no'),
      onConfirm: () => exit(0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            i18nOr('exit_confirm_message', '感谢使用纯粹直播 TV，期待下次再见。'),
            textAlign: TextAlign.center,
            style: AppTextStyles.t22.copyWith(height: 1.5, color: tvTheme.primaryTextColor),
          ),
          SizedBox(height: 24.ts(context)),
          Center(
            child: Container(
              width: 260.ts(context),
              height: 260.ts(context),
              padding: EdgeInsets.all(12.ts(context)),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16.ts(context))),
              child: Image.asset('assets/images/wechat.png', fit: BoxFit.contain),
            ),
          ),
          SizedBox(height: 20.ts(context)),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.favorite_rounded, size: 24.ts(context), color: tvTheme.focusColor),
              SizedBox(width: 8.ts(context)),
              Text(
                i18n('support_donate'),
                style: AppTextStyles.t22.copyWith(fontWeight: FontWeight.w700, color: tvTheme.primaryTextColor),
              ),
            ],
          ),
          SizedBox(height: 12.ts(context)),
          Text(
            i18nOr('exit_donate_message', '项目全程开源免费，无任何付费门槛。若是本应用给您带来便利，欢迎微信扫码请开发者喝瓶牛奶，支持后续更新维护。'),
            textAlign: TextAlign.center,
            style: AppTextStyles.t20.copyWith(height: 1.5, color: tvTheme.secondaryTextColor),
          ),
        ],
      ),
    );
  }
}

/// 云端接管后的退出确认弹窗：标题 / 正文 / 二维码 / 捐赠文案 / 按钮文案全部取云端
/// （为空时回退本地 i18n 与内置二维码图片），按 dismissible / showDonate 控制
/// 取消按钮与捐赠区域是否显示。视觉风格、TV 焦点行为与本地
/// [_ExitConfirmDialog] 保持一致。
class _CloudExitConfirmDialog extends StatelessWidget {
  const _CloudExitConfirmDialog({
    required this.title,
    required this.body,
    required this.dismissible,
    required this.showDonate,
    this.qrImageUrl = '',
    this.qrCaption = '',
    this.donateBody = '',
    this.confirmText = '',
    this.cancelText = '',
  });

  final String title;
  final String body;
  final bool dismissible;
  final bool showDonate;

  /// 云端二维码地址；空串回退 `assets/images/wechat.png`。
  final String qrImageUrl;
  final String qrCaption;
  final String donateBody;
  final String confirmText;
  final String cancelText;

  @override
  Widget build(BuildContext context) {
    final tvTheme = context.tvTheme;
    final resolvedTitle = title.isNotEmpty ? title : i18n('confirm_exit');
    final resolvedBody = body.isNotEmpty
        ? body
        : i18nOr('exit_confirm_message', '感谢使用纯粹直播 TV，期待下次再见。');
    final resolvedConfirm = confirmText.isNotEmpty ? confirmText : i18n('exit_yes');
    final resolvedCancel = cancelText.isNotEmpty ? cancelText : i18n('exit_no');
    final resolvedCaption = qrCaption.isNotEmpty ? qrCaption : i18n('support_donate');
    final resolvedDonateBody = donateBody.isNotEmpty
        ? donateBody
        : i18nOr('exit_donate_message', '项目全程开源免费，无任何付费门槛。若是本应用给您带来便利，欢迎微信扫码请开发者喝瓶牛奶，支持后续更新维护。');

    return TvDialog(
      title: resolvedTitle,
      confirmText: resolvedConfirm,
      // cancelText 为 null 时 TvDialog 不渲染「取消」按钮，confirm 按钮仍 autofocus。
      cancelText: dismissible ? resolvedCancel : null,
      onConfirm: () => exit(0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            resolvedBody,
            textAlign: TextAlign.center,
            style: AppTextStyles.t22.copyWith(height: 1.5, color: tvTheme.primaryTextColor),
          ),
          if (showDonate) ...<Widget>[
            SizedBox(height: 24.ts(context)),
            Center(
              child: Container(
                width: 260.ts(context),
                height: 260.ts(context),
                padding: EdgeInsets.all(12.ts(context)),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16.ts(context))),
                child: _buildQrImage(),
              ),
            ),
            SizedBox(height: 20.ts(context)),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.favorite_rounded, size: 24.ts(context), color: tvTheme.focusColor),
                SizedBox(width: 8.ts(context)),
                Text(
                  resolvedCaption,
                  style: AppTextStyles.t22.copyWith(fontWeight: FontWeight.w700, color: tvTheme.primaryTextColor),
                ),
              ],
            ),
            SizedBox(height: 12.ts(context)),
            Text(
              resolvedDonateBody,
              textAlign: TextAlign.center,
              style: AppTextStyles.t20.copyWith(height: 1.5, color: tvTheme.secondaryTextColor),
            ),
          ],
        ],
      ),
    );
  }

  /// 云端配了 http(s) 地址就加载网络图（带缓存），失败或未配置时回退内置资源，
  /// 保证没网也不会出现破图。
  Widget _buildQrImage() {
    const fallback = AssetImage('assets/images/wechat.png');
    final url = qrImageUrl.trim();
    if (url.isEmpty) return Image.asset('assets/images/wechat.png', fit: BoxFit.contain);
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.contain,
      placeholder: (_, __) => Image.asset('assets/images/wechat.png', fit: BoxFit.contain),
      errorWidget: (_, __, ___) => const Image(image: fallback, fit: BoxFit.contain),
    );
  }
}
