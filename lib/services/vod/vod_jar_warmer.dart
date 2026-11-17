import 'dart:async';

import 'package:flutter/foundation.dart';

import 'vod_config.dart';
import 'vod_spider_channel.dart';

/// 影音爬虫包预热器：把 `csp_` 站点要用的 spider jar 提前落到本地缓存。
///
/// ## 为什么需要它
///
/// jar 原来只在「用户点开某个站点」的那一刻同步下载（几 MB 到几十 MB）。
/// 电视上的体感就是：点进去转圈十几秒，弱网/被墙时直接报
/// `jar_download_failed`，而站点列表还挂着「需要爬虫 jar」的技术角标。
///
/// 改成「配置一到就后台下」之后，用户第一次进影音时文件已经在本地，
/// 切站点也是秒开——这才是「打开即用」。
///
/// ## 节流与重试
///
/// 云端每 3 分钟心跳一次，`_apply` 会反复调用本类；所以：
///   - 下成功的 URL 记进 [_warmed]，本进程不再重复下（磁盘缓存也会命中）；
///   - 失败的 URL 记次数，最多试 [_maxAttempts] 次，避免死源每次心跳都重试
///     一遍、白耗电视的网络；
///   - 同时只跑一条队列（[_running]），不并发抢带宽。
class VodJarWarmer {
  VodJarWarmer._();

  /// 同一个 jar 最多重试几次。3 次足够覆盖首次开机网络没就绪的情况。
  static const int _maxAttempts = 3;

  static final Set<String> _warmed = <String>{};
  static final Map<String, int> _attempts = <String, int>{};
  static Future<void>? _running;

  /// 队列跑着的时候又来的配置，等本轮结束后补跑。
  static VodConfig? _pending;

  /// 预热 [config] 里还没落地的 jar。可以随时调用，重入安全。
  ///
  /// 不抛异常：预热是锦上添花，失败就让真正点开站点时再走原来的同步下载路径。
  static Future<void> warm(VodConfig config) {
    final running = _running;
    if (running != null) {
      // 队列在跑：记下最新配置，等这一轮结束再补差额。url 模式的源是异步
      // 解析出 jar 地址的，很容易正好撞上正在跑的队列，丢掉就会漏预热。
      _pending = config;
      return running;
    }
    if (!VodSpiderChannel.isSupported) return Future<void>.value();

    final targets = config.jarTargets
        .where((target) => !_warmed.contains(target.url))
        .where((target) => (_attempts[target.url] ?? 0) < _maxAttempts)
        .toList(growable: false);
    if (targets.isEmpty) return Future<void>.value();

    final future = _run(targets);
    _running = future;
    // 队列结束就释放闸门；这里只关心原 future 的生命周期，不等它。
    unawaited(future.whenComplete(() {
      if (identical(_running, future)) _running = null;
      final next = _pending;
      _pending = null;
      // 补跑一轮；若差额里也没有可下的目标，_select 会让它立刻返回，不会递归。
      if (next != null) unawaited(warm(next));
    }));
    return future;
  }

  static Future<void> _run(List<VodJarTarget> targets) async {
    for (final target in targets) {
      try {
        final result = await VodSpiderChannel.warmupJar(
          url: target.url,
          jarMd5: target.md5,
        );
        if (result.ok) {
          _warmed.add(target.url);
          _attempts.remove(target.url);
          debugPrint(
            '[VodJarWarmer] ${result.cached ? '已缓存' : '预热完成'} '
            '${result.bytes ~/ 1024} KB ${target.url}',
          );
        } else {
          _attempts[target.url] = (_attempts[target.url] ?? 0) + 1;
          // 只记摘要：失败细节在真正点开站点时会带着 hint 完整报给用户。
          debugPrint('[VodJarWarmer] 预热失败 ${target.url}: ${result.failure?.summary}');
        }
      } catch (error) {
        _attempts[target.url] = (_attempts[target.url] ?? 0) + 1;
        debugPrint('[VodJarWarmer] 预热异常 ${target.url}: $error');
      }
    }
  }
}
