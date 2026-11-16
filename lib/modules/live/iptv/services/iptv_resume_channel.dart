import 'package:pure_live/core/utils/hive_pref_util.dart';

/// 「上次播放的 IPTV 频道」记忆。
///
/// IPTV 块不再以频道目录作为落地页：选中 IPTV 直接续播这台（和酷9 一致），
/// 频道目录只在没有记录、或记录已失效时兜底显示。
///
/// 只存 drifts 表 `Channel.id`（也就是 IPTV 房间的 `roomId`）。播放地址不缓存：
/// 重进时由 `IptvSite.getRoomDetail` 按 id 重新查库解析，云端同步改过地址、
/// 换过线路之后续播拿到的仍然是最新的那一条。
class IptvResumeChannel {
  IptvResumeChannel._();

  /// 与备份里其它 app_settings key 同一命名空间，避免和设置项撞名。
  static const String _key = 'iptv_resume_channel_id';

  /// 上次播放成功的频道 id；没有记录返回 null。
  static String? get channelId {
    final String? value = HivePrefUtil.getString(_key);
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  /// 记录频道 id。重复写入同一个 id 直接跳过（播放状态流会反复触发）。
  static void save(String channelId) {
    final String id = channelId.trim();
    if (id.isEmpty) return;
    if (HivePrefUtil.getString(_key) == id) return;
    HivePrefUtil.setString(_key, id);
  }

  /// 频道已被删除时清掉记录，下一次进 IPTV 落到频道目录。
  static void clear() => HivePrefUtil.remove(_key);
}
