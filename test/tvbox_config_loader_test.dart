/// TVBox 配置「终端直连」解析层回归网（纯 Dart，不发网络、不碰平台通道）。
///
/// 这里锁住双轨下发的 url 模式：源标记为 url 时终端自己把配置解析成站点，
/// 解析失败必须原样保留云端已展开的 sites，不能让影音板块变空。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/services/vod/tvbox_config_loader.dart';
import 'package:pure_live/services/vod/vod_config.dart';

const String _base = 'https://example.com/tv/config.json';

Map<String, dynamic> _rawSite(
  String key,
  String api, {
  String ext = '',
  int type = 1,
}) =>
    <String, dynamic>{
      'key': key,
      'name': '站点$key',
      'api': api,
      'ext': ext,
      'type': type,
      'searchable': 1,
      'quickSearch': 0,
    };

VodSite _cloudSite(String sourceId, String key) => VodSite(
      id: '$sourceId:$key',
      sourceId: sourceId,
      name: '云端$key',
      api: 'https://cloud.example.com/$key',
      key: key,
    );

VodConfig _config() => VodConfig(
      managed: true,
      sources: <VodSource>[
        const VodSource(id: 'vs_a', name: 'A', url: _base, mode: 'url'),
        const VodSource(id: 'vs_b', name: 'B', url: 'https://b.example.com/tv'),
      ],
      sites: <VodSite>[_cloudSite('vs_a', 'old'), _cloudSite('vs_b', 'keep')],
      sourceIds: const <String>['vs_a', 'vs_b'],
    );

void main() {
  group('VodSource 双轨模式', () {
    test('老云端不带 mode 时默认 parsed，行为与升级前一致', () {
      final source = VodSource.fromJson(<String, dynamic>{
        'id': 'vs_a',
        'name': 'A',
        'url': _base,
      });
      expect(source.mode, 'parsed');
      expect(source.isUrlMode, isFalse);
    });

    test('mode=url 且 url 非空才启用直连', () {
      final on = VodSource.fromJson(<String, dynamic>{
        'id': 'vs_a',
        'url': _base,
        'mode': 'url',
      });
      expect(on.mode, 'url');
      expect(on.isUrlMode, isTrue);
      final noUrl = VodSource.fromJson(<String, dynamic>{
        'id': 'vs_a',
        'mode': 'url',
      });
      expect(noUrl.isUrlMode, isFalse);
    });

    test('脏 mode 回退 parsed', () {
      final source = VodSource.fromJson(<String, dynamic>{
        'id': 'vs_a',
        'mode': 'bogus',
      });
      expect(source.mode, 'parsed');
    });
  });

  group('TvboxConfigParser 纯解析', () {
    test('BOM / 整行注释 / 尾部逗号', () {
      final text = '\uFEFF// 仓库注释\n'
          '{"sites":[{"key":"a1","name":"A1","api":"https://a/api.php"},]}';
      final result =
          TvboxConfigParser.parse(text, sourceId: 'vs_a', baseUrl: _base);
      expect(result.sites.length, 1);
      expect(result.sites.first.id, 'vs_a:a1');
      expect(result.sites.first.api, 'https://a/api.php');
    });

    test('base64 封装', () {
      final json = jsonEncode(<String, dynamic>{
        'sites': <dynamic>[_rawSite('a1', 'https://a/api.php')],
      });
      final encoded = base64Encode(utf8.encode(json));
      final result =
          TvboxConfigParser.parse(encoded, sourceId: 'vs_a', baseUrl: _base);
      expect(result.sites.length, 1);
      expect(result.sites.first.name, '站点a1');
    });

    test('顶层站点数组', () {
      final json = jsonEncode(<dynamic>[
        _rawSite('a1', 'csp_Ali', type: 3),
        _rawSite('a2', 'https://a/api.php'),
      ]);
      final result =
          TvboxConfigParser.parse(json, sourceId: 'vs_a', baseUrl: _base);
      expect(result.sites.length, 2);
      expect(result.sites.first.type, 3);
      expect(result.sites.first.requiresSpiderJar, isTrue);
    });

    test('相对 api / ext 按配置地址解析，spider 拆出 jar 与 md5', () {
      final json = jsonEncode(<String, dynamic>{
        'spider': './jar/fty.jar;md5;abcdef0123456789',
        'sites': <dynamic>[
          _rawSite('a1', './api.php/provide/vod', ext: './ext/token.json'),
          _rawSite('a2', 'csp_Ali', type: 3),
        ],
      });
      final result =
          TvboxConfigParser.parse(json, sourceId: 'vs_a', baseUrl: _base);
      expect(result.jar, 'https://example.com/tv/jar/fty.jar');
      expect(result.spiderMd5, 'abcdef0123456789');
      expect(result.sites[0].api, 'https://example.com/tv/api.php/provide/vod');
      expect(result.sites[0].ext, 'https://example.com/tv/ext/token.json');
      expect(result.sites[1].api, 'csp_Ali');
    });

    test('多仓 urls：字符串与 {url,name} 都收，按当前配置解析相对路径', () {
      final json = jsonEncode(<String, dynamic>{
        'sites': <dynamic>[_rawSite('a1', 'https://a/api.php')],
        'urls': <dynamic>[
          './sub1.json',
          <String, dynamic>{'url': 'https://other.example.com/sub2.json', 'name': '子仓'},
          'ftp://bad/x.json',
        ],
      });
      final result =
          TvboxConfigParser.parse(json, sourceId: 'vs_a', baseUrl: _base);
      expect(result.subUrls, <String>[
        'https://example.com/tv/sub1.json',
        'https://other.example.com/sub2.json',
      ]);
    });

    test('非法 api / 缺 key / 重复 key 被跳过，id 非法字符清洗', () {
      final json = jsonEncode(<String, dynamic>{
        'sites': <dynamic>[
          _rawSite('a1', 'ftp://bad/x'),
          <String, dynamic>{'name': '没 key', 'api': 'https://a/x'},
          _rawSite('a1', 'https://a/ok'),
          _rawSite('a1', 'https://a/dup'),
          _rawSite('a.b/c', 'https://a/x'),
        ],
      });
      final result =
          TvboxConfigParser.parse(json, sourceId: 'vs_a', baseUrl: _base);
      expect(result.sites.length, 2);
      expect(result.sites.first.id, 'vs_a:a1');
      expect(result.sites.last.id, 'vs_a:a_b_c');
    });

    test('非配置内容返回空结果（由调用方回退云端 sites）', () {
      final result = TvboxConfigParser.parse('<html>不是配置</html>',
          sourceId: 'vs_a', baseUrl: _base);
      expect(result.hasSites, isFalse);
    });
  });

  group('站点级 jar 与族 jar（聚合配置找得到类的前提）', () {
    test('站点自带 jar 字段（url;md5;hash、相对路径）保留在站点上', () {
      final json = jsonEncode(<String, dynamic>{
        'spider': 'https://jar.example.com/main.jar',
        'sites': <dynamic>[
          <String, dynamic>{
            ..._rawSite('wex', 'csp_WexmuouggGuard', type: 3),
            'jar': './libs/other.jar;md5;00112233445566778899aabbccddeeff',
          },
        ],
      });
      final result =
          TvboxConfigParser.parse(json, sourceId: 'vs_a', baseUrl: _base);
      expect(result.sites.single.jar, 'https://example.com/tv/libs/other.jar');
      expect(result.sites.single.jarMd5, '00112233445566778899aabbccddeeff');
    });

    test('csp_ 站点无站点级 jar 时继承本配置 spider（族 jar）；http 站点不冲压', () {
      final json = jsonEncode(<String, dynamic>{
        'spider': 'https://family.example.com/wex.jar;md5;11223344556677889900aabbccddeeff',
        'sites': <dynamic>[
          _rawSite('guard', 'csp_WexmuouggGuard', type: 3),
          _rawSite('http', 'https://a/api.php'),
        ],
      });
      final result =
          TvboxConfigParser.parse(json, sourceId: 'vs_a', baseUrl: _base);
      expect(result.sites[0].jar, 'https://family.example.com/wex.jar');
      expect(result.sites[0].jarMd5, '11223344556677889900aabbccddeeff');
      // http/采集站点不用 jar，不冲压省流量。
      expect(result.sites[1].jar, isEmpty);
    });

    test('多配置文本里各族站点拿各自 spider，不串包', () {
      // 聚合配置把多个源的 sites 并进一份文本：每个配置对象的 spider 就是
      // 该族的 jar。源级 jar 只记第一个，族 jar 必须落在站点上。
      final json = jsonEncode(<dynamic>[
        <String, dynamic>{
          'spider': 'https://jar.example.com/main.jar',
          'sites': <dynamic>[_rawSite('a1', 'csp_Ali', type: 3)],
        },
        <String, dynamic>{
          'spider': 'https://family.example.com/wex.jar',
          'sites': <dynamic>[_rawSite('w1', 'csp_WexmuouggGuard', type: 3)],
        },
      ]);
      final result =
          TvboxConfigParser.parse(json, sourceId: 'vs_a', baseUrl: _base);
      expect(result.jar, 'https://jar.example.com/main.jar');
      expect(result.sites[0].jar, 'https://jar.example.com/main.jar');
      expect(result.sites[1].jar, 'https://family.example.com/wex.jar');
    });

    test('dedupeJarAgainstSource：与源级 jar 相同清空，族 jar 保留', () {
      final json = jsonEncode(<dynamic>[
        <String, dynamic>{
          'spider': 'https://jar.example.com/main.jar',
          'sites': <dynamic>[
            _rawSite('a1', 'csp_Ali', type: 3),
            <String, dynamic>{
              ..._rawSite('own', 'csp_Own', type: 3),
              'jar': 'https://other.example.com/own.jar',
            },
          ],
        },
        <String, dynamic>{
          'spider': 'https://family.example.com/wex.jar',
          'sites': <dynamic>[_rawSite('w1', 'csp_WexmuouggGuard', type: 3)],
        },
      ]);
      final result = TvboxConfigParser.parse(
        json,
        sourceId: 'vs_a',
        baseUrl: _base,
      ).dedupeJarAgainstSource();
      // 与源级 jar 相同 → 清空（终端 jarFor 回退到源 jar，语义不变）。
      expect(result.sites[0].jar, isEmpty);
      expect(result.sites[0].jarMd5, isEmpty);
      // 站点级 jar 与族 jar 与源级 jar 不同 → 必须保留。
      expect(result.sites[1].jar, 'https://other.example.com/own.jar');
      expect(result.sites[2].jar, 'https://family.example.com/wex.jar');
    });

    test('VodConfig.jarFor 优先站点级 jar，源级 jar 兜底', () {
      final parsed = TvboxConfigParser.parse(
        jsonEncode(<dynamic>[
          <String, dynamic>{
            'spider': 'https://jar.example.com/main.jar',
            'sites': <dynamic>[
              _rawSite('a1', 'csp_Ali', type: 3),
              <String, dynamic>{
                ..._rawSite('own', 'csp_Own', type: 3),
                'jar': 'https://other.example.com/own.jar',
              },
            ],
          },
        ]),
        sourceId: 'vs_a',
        baseUrl: _base,
      );
      final config = TvboxConfigLoader.apply(VodConfig(
        managed: true,
        sources: <VodSource>[
          VodSource(id: 'vs_a', name: 'A', jar: parsed.jar, url: _base),
        ],
      ), <String, TvboxConfigResult>{'vs_a': parsed});
      expect(config.jarFor(parsed.sites[0]), parsed.jar);
      expect(config.jarFor(parsed.sites[1]), 'https://other.example.com/own.jar');
    });
  });

  group('TvboxConfigLoader.apply 兜底', () {
    test('解析成功只替换该源的站点，其它源保持云端数据', () {
      final parsed = TvboxConfigParser.parse(
        jsonEncode(<String, dynamic>{
          'sites': <dynamic>[_rawSite('a1', 'https://a/api.php')],
        }),
        sourceId: 'vs_a',
        baseUrl: _base,
      );
      final out = TvboxConfigLoader.apply(
          _config(), <String, TvboxConfigResult>{'vs_a': parsed});
      expect(out.sites.length, 2);
      expect(out.sites.first.id, 'vs_a:a1');
      expect(out.sites.first.api, 'https://a/api.php');
      expect(out.sites.last.id, 'vs_b:keep');
      expect(out.sources.length, 2);
      expect(out.managed, isTrue);
    });

    test('解析失败 / 无结果时原样保留云端站点', () {
      final base = _config();
      final unchanged = TvboxConfigLoader.apply(
          base, <String, TvboxConfigResult>{});
      expect(identical(unchanged, base), isTrue);
      final failed = TvboxConfigLoader.apply(base,
          <String, TvboxConfigResult>{'vs_a': const TvboxConfigResult()});
      expect(failed.sites.map((s) => s.id),
          <String>['vs_a:old', 'vs_b:keep']);
    });

    test('只下发 URL 的零站点源：配置里的 spider jar 写回源', () {
      // 云端没解析过，sources[].jar 为空；csp_ 站点全靠配置里的 spider 字段。
      final config = VodConfig(
        managed: true,
        sources: const <VodSource>[
          VodSource(id: 'vs_a', name: 'A', url: _base, mode: 'url'),
        ],
        sites: const <VodSite>[],
        sourceIds: const <String>['vs_a'],
      );
      final parsed = TvboxConfigParser.parse(
        jsonEncode(<String, dynamic>{
          'spider': './spider.jar;md5;a1b2c3d4e5f60718',
          'sites': <dynamic>[_rawSite('csp', 'csp_X')],
        }),
        sourceId: 'vs_a',
        baseUrl: _base,
      );
      expect(parsed.jar, isNotEmpty);
      expect(parsed.spiderMd5, 'a1b2c3d4e5f60718');
      final out = TvboxConfigLoader.apply(
          config, <String, TvboxConfigResult>{'vs_a': parsed});
      expect(out.sites.length, 1);
      expect(out.sources.single.jar, parsed.jar);
      expect(out.sources.single.spiderMd5, parsed.spiderMd5);
      expect(out.sources.single.hasJar, isTrue);
    });

    test('解析结果没有 jar 时保留云端已有的 jar', () {
      final config = VodConfig(
        managed: true,
        sources: const <VodSource>[
          VodSource(
            id: 'vs_a',
            name: 'A',
            url: _base,
            mode: 'url',
            jar: 'https://cloud.example.com/spider.jar',
            spiderMd5: 'cloud',
          ),
        ],
      );
      final parsed = TvboxConfigParser.parse(
        jsonEncode(<String, dynamic>{
          'sites': <dynamic>[_rawSite('a1', 'https://a/api.php')],
        }),
        sourceId: 'vs_a',
        baseUrl: _base,
      );
      final out = TvboxConfigLoader.apply(
          config, <String, TvboxConfigResult>{'vs_a': parsed});
      expect(out.sources.single.jar, 'https://cloud.example.com/spider.jar');
      expect(out.sources.single.spiderMd5, 'cloud');
    });
  });
}
