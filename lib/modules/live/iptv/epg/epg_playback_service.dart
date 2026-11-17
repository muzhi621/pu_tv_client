/// 播放页用到的 EPG 单例：一次加载、全页共享、切台零等待。
///
/// 切台信息条和左侧频道列表都要显示「正在播什么」，如果各自去读缓存/联网，
/// 会出现同一个节目在两处显示不一样、或者每次切台都卡一下去解析 XMLTV。
/// 所以这里统一持有：
///   - 先用 Hive 里上次的缓存同步建索引（离线也有节目单）；
///   - 缓存缺失或太旧时后台拉一次，成功后通知界面重建。
///
/// 不放进 Riverpod：它没有任何按参数区分的状态（全 App 一份），而且播放页
/// 的 banner 是同步渲染路径，取数据越直白越好。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'epg_lookup.dart';
import 'epg_model.dart';
import 'epg_repository.dart';

class EpgPlaybackService {
  EpgPlaybackService._();

  static final EpgPlaybackService instance = EpgPlaybackService._();

  /// 数据变化计数：界面用 [ValueListenableBuilder] 监听它决定是否重建。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  EpgLookup? _lookup;
  bool _loading = false;
  DateTime? _loadedAt;

  /// 缓存超过这个时长就在后台刷新；直播间信息条对时效不敏感，6 小时足够
  /// 覆盖一个晚上，也不至于每次打开播放页都去拉几 MB 的 XMLTV。
  static const Duration _maxAge = Duration(hours: 6);

  bool get hasData => _lookup != null;

  /// 播放页 initState 调一次即可，重复调用无副作用。
  void ensureLoaded() {
    if (_lookup == null) {
      final cached = EpgRepository().readCached();
      if (cached != null && !cached.isEmpty) {
        _apply(cached);
      }
    }
    if (_lookup == null || _isStale()) {
      unawaited(refresh());
    }
  }

  bool _isStale() {
    final at = _loadedAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > _maxAge;
  }

  /// 强制刷新（供「节目单」页或调试用）。
  Future<void> refresh() async {
    if (_loading) return;
    final repository = EpgRepository();
    // 云端没下发 epgUrl 时不必尝试：省掉一次必然失败的请求与日志噪音。
    if (!repository.hasSource) return;
    _loading = true;
    try {
      final guide = await repository.fetch();
      _apply(guide);
    } catch (error) {
      // 有旧数据就继续用；没有就保持「无节目信息」，让 UI 回退到纯频道名。
      debugPrint('EPG playback refresh failed: $error');
    } finally {
      _loading = false;
    }
  }

  void _apply(EpgGuide guide) {
    _lookup = EpgLookup(guide);
    _loadedAt = guide.fetchedAt.isAfter(DateTime.now()) ? DateTime.now() : guide.fetchedAt;
    revision.value++;
  }

  /// 频道当前节目；没有节目单或匹配不到时返回 null。
  EpgProgramme? currentOf(String channelName) {
    final lookup = _lookup;
    if (lookup == null || channelName.isEmpty) return null;
    return lookup.currentAt(channelName, DateTime.now());
  }

  /// 下一档节目。
  EpgProgramme? nextOf(String channelName) {
    final lookup = _lookup;
    if (lookup == null || channelName.isEmpty) return null;
    return lookup.nextAfter(channelName, DateTime.now());
  }
}
