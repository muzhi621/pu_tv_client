/// EPG（XMLTV）解析单测。
///
/// 覆盖云端下发 epgUrl 后的解析链路：时间格式、多语言标题、节目归属日。
/// 纯 Dart 逻辑，不依赖 widget 环境。
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/modules/live/iptv/epg/epg_model.dart';
import 'package:pure_live/modules/live/iptv/epg/xmltv_parser.dart';

void main() {
  group('XMLTV 时间解析', () {
    test('带时区偏移', () {
      final t = parseXmltvTime('20261116120000 +0800');
      expect(t, isNotNull);
      expect(t!.toUtc().hour, 4); // 12:00 +0800 = 04:00 UTC
    });

    test('无秒、无时区', () {
      final t = parseXmltvTime('202611161230');
      expect(t, isNotNull);
      expect(t!.hour, 12);
      expect(t.minute, 30);
    });

    test('ISO8601', () {
      expect(parseXmltvTime('2026-11-16T12:00:00'), isNotNull);
    });

    test('非法输入返回 null', () {
      expect(parseXmltvTime(''), isNull);
      expect(parseXmltvTime('not-a-time'), isNull);
    });
  });

  group('XMLTV 文档解析', () {
    const xml = '''
<tv>
  <channel id="cctv1">
    <display-name lang="en">CCTV-1</display-name>
    <display-name lang="zh">央视一套</display-name>
    <icon src="https://example.com/cctv1.png"/>
  </channel>
  <programme start="20261116120000 +0800" stop="20261116130000 +0800" channel="cctv1">
    <title lang="en">News</title>
    <title lang="zh">新闻联播</title>
    <desc lang="zh">今日要闻</desc>
    <category>新闻</category>
  </programme>
  <programme start="20261116130000 +0800" stop="20261116140000 +0800" channel="cctv1">
    <title>电视剧</title>
  </programme>
</tv>
''';

    test('解析频道（中文名优先）', () {
      final guide = parseXmltv(xml);
      expect(guide.channels.length, 1);
      expect(guide.channels.first.id, 'cctv1');
      expect(guide.channels.first.displayName, '央视一套');
      expect(guide.channels.first.icon, 'https://example.com/cctv1.png');
    });

    test('解析节目（中文标题优先、按时间排序）', () {
      final guide = parseXmltv(xml);
      expect(guide.programmes.length, 2);
      expect(guide.programmes.first.title, '新闻联播');
      expect(guide.programmes.first.description, '今日要闻');
      expect(guide.programmes.first.category, '新闻');
      expect(guide.programmes.first.start.isBefore(guide.programmes.last.start), isTrue);
    });

    test('按频道 + 所属日过滤节目', () {
      final guide = parseXmltv(xml);
      final day = DateTime(2026, 11, 16);
      final list = guide.programmesOf('cctv1', day);
      expect(list.length, 2);
      expect(guide.programmesOf('unknown', day), isEmpty);
    });

    test('非法文档抛异常', () {
      expect(() => parseXmltv(''), throwsA(isA<XmltvParseException>()));
      expect(() => parseXmltv('<html></html>'), throwsA(isA<XmltvParseException>()));
    });
  });

  group('EpgGuide JSON 往返', () {
    test('序列化后能还原', () {
      final guide = parseXmltv('''
<tv>
  <channel id="c1"><display-name>通道1</display-name></channel>
  <programme start="20261116120000 +0800" stop="20261116130000 +0800" channel="c1"><title>节目</title></programme>
</tv>
''');
      final restored = EpgGuide.fromJson(guide.toJson());
      expect(restored.channels.length, 1);
      expect(restored.programmes.length, 1);
      expect(restored.programmes.first.title, '节目');
    });
  });
}
