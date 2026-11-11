import 'package:flutter/material.dart';
import 'package:pure_live/services/remote_config/remote_config.dart';

/// 云端下发的启动公告（需求文档 FR-06）。
///
/// P0 用 Flutter 原生对话框，保证「永远可关闭、绝不阻断主界面」；
/// P1 可替换为项目统一的 TvDialogUtils 样式。
class RemoteNoticeDialog {
  const RemoteNoticeDialog._();

  static bool _shownThisSession = false;

  static Future<void> maybeShow(BuildContext context) async {
    if (_shownThisSession) return;
    if (!RemoteConfigService.shouldShowNotice) return;

    final title = RemoteConfigService.noticeTitle;
    final body = RemoteConfigService.noticeBody;
    if (title.trim().isEmpty && body.trim().isEmpty) return;

    _shownThisSession = true;
    await RemoteConfigService.markNoticeShown();
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      // 解析异常时 noticeDismissible 默认 true，不会把用户锁在弹窗里。
      barrierDismissible: RemoteConfigService.noticeDismissible,
      builder: (dialogContext) => AlertDialog(
        title: Text(title.trim().isEmpty ? '公告' : title),
        content: SingleChildScrollView(child: Text(body)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
