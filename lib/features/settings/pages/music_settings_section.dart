import 'package:flutter/widgets.dart';

/// 音乐模式设置已下线（bilibili UGC 影音/音乐整体移除）。
///
/// 保留类名是因为 settings_routes.dart 的 SettingsSectionScaffold 仍引用它；
/// 设置菜单里已移除入口，任何进入都渲染空页。
class MusicSettingsSectionPage extends StatelessWidget {
  const MusicSettingsSectionPage({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
