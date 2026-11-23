import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 新增的遥控器提示必须中英同步：i18n 缺键时 easy_localization 会直接把
/// key 当文案显示到电视上（例如 "ui_failure_vod_hint"），比英文提示更难看。
void main() {
  Map<String, dynamic> load(String locale) =>
      jsonDecode(File('assets/translations/$locale.json').readAsStringSync()) as Map<String, dynamic>;

  test('失败浮层与站点面板的文案中英齐备', () {
    final zh = load('zh');
    final en = load('en');
    for (final key in <String>[
      'ui_failure_keys_hint',
      'ui_failure_vod_hint',
      'ui_failure_iptv_hint',
      'ui_switch_site',
      'ui_retry_playback',
    ]) {
      expect(zh[key], isA<String>(), reason: 'zh 缺 $key');
      expect(en[key], isA<String>(), reason: 'en 缺 $key');
    }
  });

  test('失败浮层提示不再暗示左右选择或刷新房间', () {
    final zh = load('zh');
    for (final key in <String>['ui_failure_keys_hint', 'ui_failure_vod_hint', 'ui_failure_iptv_hint']) {
      expect(zh[key], isNot(contains('←→')), reason: '$key 仍在提示左右选择');
      expect(zh[key], isNot(contains('刷新')), reason: '$key 仍在提示已移除的按钮');
    }
  });
}
