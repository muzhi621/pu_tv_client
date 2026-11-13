import 'package:pure_live/exports/exports.dart';

/// 把一条已解析好的点播地址交给现有播放器。
///
/// 为什么不新写一个点播播放器：`LivePlayPage` 内部就是 media_kit 直接打开
/// 网络地址，IPTV 频道走的是同一条路。点播与直播的差别只在「地址从哪来」，
/// 播放器本身没有区别 —— 复用可以省掉一整套遥控器焦点、进度条、清晰度
/// 与错误重试的重复实现。
///
/// 这里把房间的 platform 设成 `Sites.iptvSite`，播放器据此走「地址即流」
/// 的直连分支，不去任何直播平台拉房间详情。
void openVodPlayback(
  BuildContext context, {
  required String title,
  required String url,
  String cover = '',
  Map<String, String> headers = const <String, String>{},
}) {
  if (url.trim().isEmpty) {
    ToastUtil.show(i18n('vod_play_url_empty'));
    return;
  }
  final room = LiveRoom(
    // roomId 只用于身份与历史去重。点播地址里常带一次性 token，直接用地址
    // 做 id 会让同一集每次都变成新记录，所以退化成「标题 + 地址」的短哈希。
    roomId: 'vod-${title.hashCode}-${url.hashCode}',
    title: title,
    nick: title,
    cover: cover,
    area: '',
    watching: '',
    avatar: '',
    introduction: title,
    status: true,
    liveStatus: LiveStatus.live,
    platform: Sites.iptvSite,
    link: url,
    data: url,
    httpHeaders: headers,
  );
  LivePlayRoute(room).push(context);
}
