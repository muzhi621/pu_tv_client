/// TVBox 解析层单测。
///
/// 这些用例不是凭空写的：每一条都对应真实配置里踩过的坑，Python 原型
/// （10 组样本）验证过之后才翻译过来，这里再把它们固化成回归网。
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/services/vod/tvbox_parser.dart';
import 'package:pure_live/services/vod/vod_models.dart';

void main() {
  group('选集解析', () {
    test('标准两线路', () {
      final lines = parsePlayLines(
        r'ffm3u8$$$ckm3u8',
        r'第1集$https://a.com/1.m3u8#第2集$https://a.com/2.m3u8'
        r'$$$第1集$https://b.com/1.m3u8',
      );
      expect(lines.length, 2);
      expect(lines[0].flag, 'ffm3u8');
      expect(lines[0].episodes.length, 2);
      expect(lines[0].episodes[1].name, '第2集');
      expect(lines[0].episodes[1].url, 'https://a.com/2.m3u8');
    });

    test('线路名为空时补「线路N」', () {
      final lines = parsePlayLines('', r'第1集$https://a.com/1.m3u8');
      expect(lines.length, 1);
      expect(lines[0].flag, '线路1');
      expect(lines[0].episodes.length, 1);
    });

    test('线路数多于实际分组时按位置取名', () {
      final lines = parsePlayLines(
        r'线路A$$$线路B$$$线路C',
        r'第1集$https://a.com/1.m3u8$$$第1集$https://b.com/1.m3u8',
      );
      expect(lines.length, 2);
      expect(lines[1].flag, '线路B');
    });

    test('地址在前、名字在后会自动换位', () {
      final lines = parsePlayLines('x', r'https://a.com/1.m3u8$第1集');
      expect(lines[0].episodes[0].name, '第1集');
      expect(lines[0].episodes[0].url, 'https://a.com/1.m3u8');
    });

    test('三段式只取前两段', () {
      final lines = parsePlayLines('x', r'第1集$https://a.com/1.m3u8$hd');
      expect(lines[0].episodes[0].url, 'https://a.com/1.m3u8');
      expect(lines[0].episodes[0].extra, 'hd');
    });

    test('只有地址时用序号兜底', () {
      final lines = parsePlayLines('x', 'https://a.com/1.m3u8');
      expect(lines[0].episodes[0].name, '1');
    });

    test('空输入不抛异常', () {
      expect(parsePlayLines(null, null), isEmpty);
      expect(parsePlayLines('', ''), isEmpty);
    });
  });

  group('站点配置解析', () {
    test('单仓：跳过缺 key 的条目并记录原因', () {
      final result = parseTvboxConfig('''
      {
        "spider": "https://x/spider.jar",
        "sites": [
          {"key":"a","name":"A站","type":1,"api":"https://a.com/api.php/provide/vod/","searchable":1},
          {"key":"b","name":"B站","type":3,"api":"csp_B","ext":{"a":1}},
          {"key":"","name":"坏站","api":"https://bad"}
        ]
      }
      ''', sourceJar: 'https://x/spider.jar');

      expect(result.sites.length, 2);
      expect(result.subConfigs, isEmpty);
      expect(result.sites[0].key, 'a');
      expect(result.sites[0].searchable, isTrue);
      expect(result.sites[0].needsSpider, isFalse);
      expect(result.sites[1].api, 'csp_B');
      expect(result.sites[1].needsSpider, isTrue);
      expect(result.sites[1].spiderKey, 'B');
      expect(result.sites[1].ext, '{"a":1}');
      expect(result.sites[1].jar, 'https://x/spider.jar');
      expect(result.errors, hasLength(1));
    });

    test('多仓：兼容字符串与 {url,name} 两种写法', () {
      final result = parseTvboxConfig(r'''
      {
        "urls": [
          {"url":"https://a/cfg.json","name":"仓A"},
          "https://b/cfg.json"
        ]
      }
      ''');
      expect(result.sites, isEmpty);
      expect(result.subConfigs.length, 2);
      expect(result.subConfigs[0].name, '仓A');
      expect(result.subConfigs[1].url, 'https://b/cfg.json');
    });

    test('整行注释会被剥离（真实配置几乎都带）', () {
      final result = parseTvboxConfig('''
      {
        // 这是整行注释
        "sites": [
          {"key":"a","name":"A","api":"https://a.com/api"}
        ]
      }
      ''');
      expect(result.sites, hasLength(1));
    });

    test('行内 // 不能被当成注释（https:// 会被截断）', () {
      final result = parseTvboxConfig('{"sites":[{"key":"a","name":"A","api":"https://a.com/api"}]}');
      expect(result.sites.single.api, 'https://a.com/api');
    });

    test('没写 type 时按 api 推断', () {
      final http = parseTvboxConfig('{"sites":[{"key":"a","name":"A","api":"https://a.com/api"}]}');
      expect(http.sites.single.type, 1);
      final spider = parseTvboxConfig('{"sites":[{"key":"b","name":"B","api":"csp_B"}]}');
      expect(spider.sites.single.type, 3);
    });

    test('api 的前导 ./ 会去掉', () {
      final result = parseTvboxConfig('{"sites":[{"key":"a","name":"A","api":"./api.php"}]}');
      expect(result.sites.single.api, 'api.php');
    });

    test('非法 JSON 返回 errors 而不抛异常', () {
      final result = parseTvboxConfig('{不是 json');
      expect(result.errors, isNotEmpty);
      expect(result.sites, isEmpty);
    });
  });

  group('spider 字段', () {
    test('拆出 jar 与 md5', () {
      final parsed = splitSpiderField('./fty.jar;md5;3d161697458ecbcd2651a749db761ba1');
      expect(parsed.jar, 'fty.jar');
      expect(parsed.md5, '3d161697458ecbcd2651a749db761ba1');
    });

    test('只有 ;md5 没有哈希时 md5 为空', () {
      expect(splitSpiderField('./fty.jar;md5').md5, '');
    });

    test('绝对地址原样返回', () {
      expect(splitSpiderField('https://cdn/x.jar').jar, 'https://cdn/x.jar');
    });

    test('空输入', () {
      expect(splitSpiderField('').jar, '');
      expect(splitSpiderField(null).jar, '');
    });
  });

  group('采集接口 URL 拼装', () {
    test('纯地址补 ?', () {
      expect(
        buildApiUrl('https://a.com/api.php/provide/vod/', {'ac': 'list'}),
        'https://a.com/api.php/provide/vod/?ac=list',
      );
    });

    test('已有参数保留，控制参数被替换', () {
      expect(
        buildApiUrl('https://a.com/api?token=1', {'ac': 'detail', 't': '1', 'pg': '2'}),
        'https://a.com/api?token=1&ac=detail&t=1&pg=2',
      );
    });

    test('api 自带 ac=list 时不会拼成两个 ac', () {
      final url = buildApiUrl('https://a.com/api.php/provide/vod/?ac=list', {'ac': 'detail'});
      expect(url, 'https://a.com/api.php/provide/vod/?ac=detail');
      expect('ac='.allMatches(url).length, 1);
    });

    test('尾随 ? 不会产生 &&', () {
      expect(buildApiUrl('https://a.com/api?', {'ac': 'list'}), 'https://a.com/api?ac=list');
    });

    test('中文关键字按 %XX 编码而非 +', () {
      final url = buildApiUrl('https://a.com/api', {'wd': '庆余年 第二季'});
      expect(url, contains('%E5%BA%86%E4%BD%99%E5%B9%B4'));
      expect(url, contains('%20'));
      expect(url, isNot(contains('+')));
    });

    test('空值参数被跳过', () {
      expect(
        buildApiUrl('https://a.com/api', {'ac': 'detail', 't': null, 'pg': ''}),
        'https://a.com/api?ac=detail',
      );
    });
  });

  group('结果模型解析', () {
    test('条目缺 id 或名称会被丢弃', () {
      final items = parseVodItems([
        {'vod_id': 1, 'vod_name': '正常的'},
        {'vod_name': '缺 id'},
        {'vod_id': 2},
      ]);
      expect(items, hasLength(1));
      expect(items.single.id, '1');
    });

    test('相对协议图片补全为 https', () {
      final items = parseVodItems([
        {'vod_id': 1, 'vod_name': 'x', 'vod_pic': '//img.a.com/1.jpg'},
      ]);
      expect(items.single.pic, 'https://img.a.com/1.jpg');
    });

    test('分类去重', () {
      final categories = parseVodCategories([
        {'type_id': 1, 'type_name': '电影'},
        {'type_id': 1, 'type_name': '电影'},
        {'type_id': 2, 'type_name': '剧集'},
      ]);
      expect(categories, hasLength(2));
    });

    test('详情解析出多线路并去掉 HTML', () {
      final detail = parseVodDetailNode({
        'vod_id': 9,
        'vod_name': '测试片',
        'vod_content': '<p>简介<br>第二行</p>',
        'vod_play_from': r'线路A$$$线路B',
        'vod_play_url': r'第1集$https://a/1.m3u8$$$第1集$https://b/1.m3u8',
      });
      expect(detail.name, '测试片');
      expect(detail.content, contains('第二行'));
      expect(detail.content, isNot(contains('<')));
      expect(detail.lines, hasLength(2));
      expect(detail.playable, isTrue);
      expect(detail.defaultLine!.flag, '线路A');
    });

    test('分页信封缺字段时用兜底值', () {
      final page = parseVodPageJson({'list': []}, fallbackPage: 3);
      expect(page.page, 3);
      expect(page.pageCount, 1);
      expect(page.hasMore, isFalse);
    });
  });
}
