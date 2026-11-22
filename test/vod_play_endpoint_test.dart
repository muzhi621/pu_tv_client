import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/services/vod/tvbox_http_engine.dart';
import 'package:pure_live/services/vod/vod_models.dart';

/// 回归：网关型站点的选集地址是「跳转端点」，不是流地址。
///
/// 自建爬虫网关（OmniBox / TVBox-Worker）的 `vod_play_url` 里写的是
/// `/play?spider=…&id=…&code=…`，服务端收到请求才去调爬虫再 302。
/// 判定必须严格：漏判会让端点被当成流交给播放器（302 带不出失败原因），
/// 误判会让每次播放都多一次往返。同时锁住英文技术错误的中文化。
void main() {
  group('跳转端点判定', () {
    test('网关端点命中', () {
      expect(
        TvboxHttpEngine.looksLikePlayEndpoint(
          'https://box.example.com/@tvbox/play?spider=movie-1&code=abc&id=abc123',
        ),
        isTrue,
      );
    });

    test('没有 code 但有 spider 也命中（未设访问码的部署）', () {
      expect(
        TvboxHttpEngine.looksLikePlayEndpoint(
          'https://box.example.com/@tvbox/play?spider=movie-1&id=abc123',
        ),
        isTrue,
      );
    });

    test('相对跳转、大小写路径也命中', () {
      expect(
        TvboxHttpEngine.looksLikePlayEndpoint('http://h.test/Play?id=1&spider=s'),
        isTrue,
      );
    });

    test('挂在数据端点上的写法也命中（/spider?ac=play&id=…）', () {
      expect(
        TvboxHttpEngine.looksLikePlayEndpoint(
          'https://box.example.com/@tvbox/spider?code=abc&spider=movie-1&base=https%3A%2F%2Fbox.example.com%2F&ac=play&id=ODU2MDk&flag=%E6%AD%A3%E7%89%87',
        ),
        isTrue,
      );
    });

    test('真实流地址不算端点', () {
      for (final url in <String>[
        'https://v.example.com/play/e9r15mxa/index.m3u8',
        'https://h.test/vodplay/123-1-1.html',
        'https://h.test/play?spider=s', // 缺 id
        'https://h.test/play?id=1', // 缺 spider/code
        'https://h.test/spider?ac=play&id=1', // 缺 spider/code
        'https://h.test/spider?ac=list&id=1&spider=s', // 不是 play 动作
        'ftp://h.test/play?id=1&spider=s',
        '',
        'not a url',
      ]) {
        expect(
          TvboxHttpEngine.looksLikePlayEndpoint(url),
          isFalse,
          reason: '不应命中：$url',
        );
      }
    });
  });

  group('服务端错误中文化', () {
    test('源已换过时给人话', () {
      expect(vodFriendlyMessage('spider not found'), '这个源已经换过了，请返回重新进入影音');
    });

    test('缺运行环境时指出具体模块', () {
      expect(vodFriendlyMessage('unsupported module: fs'), '这个源依赖 fs，服务端没提供');
      expect(vodFriendlyMessage('unsupported module: crypto-js'), '这个源依赖 crypto-js，服务端没提供');
      expect(vodFriendlyMessage('unsupported module:'), '服务端缺少这个源需要的运行环境');
    });

    test('服务端连不上源站点', () {
      expect(vodFriendlyMessage('fetch failed'), '服务端连不上源站点（网络不通或被拦）');
    });

    test('没有解析出播放地址', () {
      expect(vodFriendlyMessage('empty play url'), '这一集没有解析出播放地址，换一集或换源试试');
    });

    test('认不出来的错误保留原文', () {
      expect(vodFriendlyMessage('HTTP 502'), 'HTTP 502');
      expect(vodFriendlyMessage('详情为空，站点可能已失效'), '详情为空，站点可能已失效');
    });
  });
}
