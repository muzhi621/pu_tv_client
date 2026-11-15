import 'package:flutter/widgets.dart';

/// bilibili UGC 视频的播放设置组已下线。
///
/// 保留类名是因为 video_settings_section.dart 仍引用它（设置菜单里已移除
/// 入口），任何进入都渲染空页。IPTV / TVBox 的播放器设置走通用播放器页。
class VideoPlaybackSettingsGroup extends StatelessWidget {
  const VideoPlaybackSettingsGroup({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
