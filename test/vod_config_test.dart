/// 云端 vod 节的数据模型与「HTTP / spider jar」分流规则回归网。
///
/// 这一层决定了站点走纯 Dart 的 TvboxHttpEngine 还是 Android DexClassLoader，
/// 判错就会直接报「该站点需要爬虫 jar」或把 http 接口当类名反射，
/// 所以单独固化，不依赖网络、不依赖平台通道。
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/services/vod/vod_config.dart';

Map<String, dynamic> _site({
  String id = 'src1:ali',
  String sourceId = 'src1',
  String name = '阿里',
  String api = 'https://example.com/api.php/provide/vod',
  String key = 'ali',
  String ext = '',
  String jar = '',
  String jarMd5 = '',
  int type = 1,
  Object? searchable = 1,
  Object? quickSearch = 0,
}) =>
    <String, dynamic>{
      'id': id,
      'sourceId': sourceId,
      'name': name,
      'api': api,
      'key': key,
      'ext': ext,
      'jar': jar,
      'jarMd5': jarMd5,
      'type': type,
      'searchable': searchable,
      'quickSearch': quickSearch,
    };

Map<String, dynamic> _source({
  String id = 'src1',
  String name = '测试源',
  String jar = '',
  String spiderFlavor = '',
}) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'jar': jar,
      'url': 'https://example.com/tvbox.json',
      'spiderFlavor': spiderFlavor,
    };

void main() {
  group('VodConfig 解析', () {
    test('空节返回空配置', () {
      expect(VodConfig.fromSection(<String, dynamic>{}).isEmpty, isTrue);
      expect(VodConfig.empty.managed, isFalse);
    });

    test('managed / 引用 id / 锁定快照都要读出', () {
      final config = VodConfig.fromSection(<String, dynamic>{
        'managed': true,
        'sourceIds': <String>['src1', ' src2 ', ''],
        'siteIds': <String>['src1:ali'],
        'lockLibrary': true,
        'libraryRevision': 7,
      });
      expect(config.managed, isTrue);
      expect(config.sourceIds, <String>['src1', 'src2']);
      expect(config.siteIds, <String>['src1:ali']);
      expect(config.lockLibrary, isTrue);
      expect(config.libraryRevision, 7);
    });

    test('revision 不是 int 时回退 0', () {
      final config = VodConfig.fromSection(<String, dynamic>{'libraryRevision': '3'});
      expect(config.libraryRevision, 0);
    });
  });

  group('站点分流（HTTP vs spider jar）', () {
    test('api 以 csp_ 开头才需要 jar', () {
      expect(VodSite.fromJson(_site(api: 'csp_Ali')).requiresSpiderJar, isTrue);
      expect(VodSite.fromJson(_site(api: 'https://example.com/vod')).requiresSpiderJar, isFalse);
      // VodSite 只做裸前缀判断：剥离 api 的前导 ./ 是云端解析层
      // (tvbox_parser.dart) 的职责，终端不该再猜一次。
      expect(VodSite.fromJson(_site(api: './csp_Bili')).requiresSpiderJar, isFalse);
      expect(VodSite.fromJson(_site()).requiresSpiderJar, isFalse);
    });

    test('spiderKey 去掉 csp_ 前缀', () {
      expect(VodSite.fromJson(_site(api: 'csp_Ali')).spiderKey, 'Ali');
      expect(VodSite.fromJson(_site()).spiderKey, 'https://example.com/api.php/provide/vod');
    });

    test('spiderSites / httpSites 互斥且覆盖全部站点', () {
      final config = VodConfig.fromSection(<String, dynamic>{
        'sites': <Map<String, dynamic>>[
          _site(id: 'src1:ali', api: 'csp_Ali', type: 3),
          _site(id: 'src1:json', key: 'json'),
          _site(id: 'src1:xml', key: 'xml', type: 0),
        ],
      });
      expect(config.spiderSites.map((s) => s.key), <String>['ali']);
      expect(config.httpSites.map((s) => s.key), <String>['json', 'xml']);
      expect(config.spiderSites.length + config.httpSites.length, config.sites.length);
    });

    test('searchable 兼容 1 / true / 0', () {
      expect(VodSite.fromJson(_site(searchable: 1)).searchable, isTrue);
      expect(VodSite.fromJson(_site(searchable: true)).searchable, isTrue);
      expect(VodSite.fromJson(_site(searchable: 0)).searchable, isFalse);
      expect(VodSite.fromJson(_site(quickSearch: true)).quickSearch, isTrue);
    });
  });

  group('源与站点关联', () {
    test('jarFor 按 sourceId 命中，无 jar 返回 null', () {
      final config = VodConfig.fromSection(<String, dynamic>{
        'sources': <Map<String, dynamic>>[
          _source(id: 'src1', jar: 'https://example.com/spider.jar'),
          _source(id: 'src2'),
        ],
        'sites': <Map<String, dynamic>>[
          _site(id: 'src1:ali', sourceId: 'src1', api: 'csp_Ali'),
          _site(id: 'src2:x', sourceId: 'src2', api: 'csp_X'),
          _site(id: 'orphan:x', sourceId: 'missing', api: 'csp_X'),
        ],
      });
      expect(config.jarFor(config.sites[0]), 'https://example.com/spider.jar');
      expect(config.jarFor(config.sites[1]), isNull);
      expect(config.jarFor(config.sites[2]), isNull);
      expect(config.sources[0].hasJar, isTrue);
      expect(config.sources[1].hasJar, isFalse);
    });

    test('站点级 jar 优先于源级 jar，md5 同步切换', () {
      // 聚合配置里各族站点靠站点级 jar 指向自己的爬虫包，用源级 jar 会
      // 「在 jar 里找不到类」。
      final config = VodConfig.fromSection(<String, dynamic>{
        'sources': <Map<String, dynamic>>[
          _source(id: 'src1', jar: 'https://example.com/main.jar'),
        ],
        'sites': <Map<String, dynamic>>[
          _site(
            id: 'src1:wex',
            api: 'csp_WexmuouggGuard',
            jar: 'https://family.example.com/wex.jar',
            jarMd5: 'fam0123456789abcdef',
          ),
          _site(id: 'src1:plain', api: 'csp_Ali'),
        ],
      });
      expect(config.jarFor(config.sites[0]), 'https://family.example.com/wex.jar');
      expect(config.spiderMd5For(config.sites[0]), 'fam0123456789abcdef');
      expect(config.jarFor(config.sites[1]), 'https://example.com/main.jar');
      // 站点没带 md5 时不要张冠李戴拿源级 jar 的 md5 去校验别的包。
      expect(config.spiderMd5For(config.sites[1]), isNull);
    });

    test('spiderFlavor 空值回退 fongmi，tvboxos 单独可辨', () {
      expect(VodSource.fromJson(_source()).isFongmi, isTrue);
      expect(VodSource.fromJson(_source(spiderFlavor: 'tvboxos')).isFongmi, isFalse);
      expect(VodSource.fromJson(_source(spiderFlavor: 'tvboxos')).spiderFlavor, 'tvboxos');
    });

    test('groupedSites 按源分组，站点不会串到别的源', () {
      final config = VodConfig.fromSection(<String, dynamic>{
        'sources': <Map<String, dynamic>>[_source(id: 'a'), _source(id: 'b')],
        'sites': <Map<String, dynamic>>[
          _site(id: 'a:1', sourceId: 'a', key: '1'),
          _site(id: 'a:2', sourceId: 'a', key: '2'),
          _site(id: 'b:1', sourceId: 'b', key: '1'),
        ],
      });
      final grouped = config.groupedSites;
      expect(grouped.length, 2);
      expect(grouped[config.sources[0]]!.map((s) => s.id), <String>['a:1', 'a:2']);
      expect(grouped[config.sources[1]]!.map((s) => s.id), <String>['b:1']);
    });
  });
}
