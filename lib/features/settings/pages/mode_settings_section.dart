import 'package:flutter/widgets.dart';

/// 直播 / bilibili UGC 模式切换已下线。
///
/// 保留类名是因为设置路由表与 app_router.g.dart 仍引用它（生成产物本机无法
/// 重跑 build_runner）；设置菜单里已移除入口，任何进入都渲染空页。
class ModeSettingsSectionPage extends StatelessWidget {
  const ModeSettingsSectionPage({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
