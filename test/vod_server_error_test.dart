import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/services/vod/vod_models.dart';

/// 回归：OmniBox 订阅「无内容无报错」。
///
/// 网关的失败响应经常长这样：`{code:500, message, class:[正常分类], list:[]}`。
/// 早期判定先看 class，于是把一条真实错误当成「有数据但列表为空」，
/// 用户永远看不到服务端的报错。这里锁住「失败优先于 class」的顺序。
void main() {
  test('业务码 >= 400 时，带正常 class 也要判为失败', () {
    final json = <String, dynamic>{
      'code': 500,
      'message': '爬虫取数失败：spider home failed',
      'class': [
        {'type_id': '1', 'type_name': '电影'},
      ],
      'list': <dynamic>[],
    };
    expect(vodServerError(json), '爬虫取数失败：spider home failed');
  });

  test('HTTP 5xx 且没有可读正文时，回退成状态码描述', () {
    expect(vodServerError(<String, dynamic>{}, statusCode: 502), 'HTTP 502');
  });

  test('业务码 >= 400 但没有 message 时，回退成 code 描述', () {
    expect(vodServerError(<String, dynamic>{'code': 404}), 'code 404');
  });

  test('显式 error 字段（无状态码）也当失败', () {
    expect(vodServerError(<String, dynamic>{'error': 'invalid token'}), 'invalid token');
  });

  test('正常的空列表不算失败', () {
    expect(
      vodServerError(<String, dynamic>{'code': 1, 'msg': 'ok', 'list': <dynamic>[]}),
      isNull,
    );
  });

  test('有数据时即使带 200 业务码也不算失败', () {
    expect(
      vodServerError(<String, dynamic>{
        'code': 200,
        'list': [
          {'vod_id': '1', 'vod_name': '测试'},
        ],
      }),
      isNull,
    );
  });

  test('采集站常见的 {list: []} 空响应不算失败，交给调用方降级', () {
    expect(vodServerError(<String, dynamic>{'list': <dynamic>[]}), isNull);
    expect(vodServerError(<String, dynamic>{}), isNull);
  });
}
