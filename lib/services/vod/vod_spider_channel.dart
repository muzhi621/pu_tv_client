import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// TVBox 爬虫（spider.jar）的 Android 宿主通道。
///
/// 与云端下发的站点配置配合使用：`api` 以 `csp_` 开头的站点，全部逻辑都在
/// 一个 dex jar 里，Android 侧用 DexClassLoader 加载后反射调用，Dart 侧只
/// 负责把方法名和参数递过去、把返回的原始 json 文本拿回来解析。
///
/// ## 为什么返回值不做异常抛
///
/// 这条链路的失败原因差异极大——jar 下不下来、类名对不对、宿主缺哪个依赖、
/// spider 自己抛了什么——在电视上用 toast 一个个试太慢。所以原生侧把失败
/// 归一成 `{ok:false, code, message, hint}`，这里原样带回给 UI，诊断页可以
/// 一次性把 code / hint / stack 都显示出来。
class VodSpiderChannel {
  VodSpiderChannel._();

  static const MethodChannel _channel = MethodChannel('pure_live/vod_spider');

  /// 非 Android 平台（含 `flutter test` 的宿主 VM）一律视为不支持，
  /// 上层据此隐藏影音板块的在线能力，而不是抛 MissingPluginException。
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// 宿主环境自检：Android 版本、ABI、宿主依赖类是否齐全、已缓存 jar。
  static Future<VodHostDiagnostics> diagnostics() async {
    final raw = await _invokeMap('diagnostics');
    if (raw == null) {
      return const VodHostDiagnostics(ok: false, hostClassesMissing: <String>[]);
    }
    return VodHostDiagnostics(
      ok: raw['ok'] == true,
      androidSdk: _asInt(raw['androidSdk']),
      androidRelease: raw['androidRelease']?.toString(),
      abis: _asStringList(raw['abis']),
      hostClassesMissing: _asStringList(raw['hostClassesMissing']),
      runtimeClassesMissing: _asStringList(raw['runtimeClassesMissing']),
      optionalClassesMissing: _asStringList(raw['optionalClassesMissing']),
      quickJs: VodQuickJsStatus.fromMap(
        (raw['quickjs'] as Map?)?.cast<Object?, Object?>(),
      ),
      cachedJars: _asMapList(raw['cachedJars'])
          .map(
            (item) => VodCachedJar(
              name: item['name']?.toString() ?? '',
              bytes: _asInt(item['bytes']),
              readOnly: item['readOnly'] == true,
            ),
          )
          .toList(growable: false),
    );
  }

  /// 下载并解析 jar，列出可用爬虫类名。
  ///
  /// 这是接入新源的第一个动作：先确认 jar 能下、能解压、里面到底有哪些
  /// `com.github.catvod.spider.*`，再去和配置里的 `api` 对名字。
  static Future<VodJarInspection> inspectJar({
    required String url,
    bool force = false,
  }) async {
    final raw = await _invokeMap('inspectJar', <String, dynamic>{
      'url': url,
      'force': force,
    });
    if (raw == null || raw['ok'] != true) {
      return VodJarInspection.failed(_failureOf(raw));
    }
    return VodJarInspection(
      failure: null,
      jarPath: raw['jarPath']?.toString(),
      bytes: _asInt(raw['bytes']),
      readOnly: raw['readOnly'] == true,
      dexCount: _asInt(raw['dexCount']),
      bundlesBaseClass: raw['bundlesBaseClass'] == true,
      spiders: _asStringList(raw['spiders']),
    );
  }

  /// 为一个站点建实例并完成 init。同一 `siteKey` 重复调用会复用已有实例，
  /// `force: true` 则销毁重建（换 ext 或 jar 更新后用）。
  static Future<VodSitePreparation> prepareSite({
    required String siteKey,
    required String jarUrl,
    required String api,
    String ext = '',
    bool force = false,
  }) async {
    final raw = await _invokeMap('prepareSite', <String, dynamic>{
      'siteKey': siteKey,
      'jarUrl': jarUrl,
      'api': api,
      'ext': ext,
      'force': force,
    });
    if (raw == null || raw['ok'] != true) {
      return VodSitePreparation.failed(_failureOf(raw));
    }
    return VodSitePreparation(
      failure: null,
      siteKey: raw['siteKey']?.toString() ?? siteKey,
      api: raw['api']?.toString() ?? api,
      className: raw['className']?.toString(),
      jarPath: raw['jarPath']?.toString(),
      mode: raw['mode']?.toString(),
      initModes: _asStringList(raw['initModes']),
    );
  }

  /// 首页内容。`filter` 传 true 表示「顺便把筛选项定义带回来」。
  static Future<VodSpiderCall> homeContent({
    required String siteKey,
    bool filter = true,
  }) =>
      _call(siteKey, 'homeContent', <String, dynamic>{'filter': filter});

  static Future<VodSpiderCall> homeVideoContent({required String siteKey}) =>
      _call(siteKey, 'homeVideoContent');

  /// 分类列表。`extend` 是筛选参数，键值都按字符串传。
  static Future<VodSpiderCall> categoryContent({
    required String siteKey,
    required String tid,
    String pg = '1',
    bool filter = true,
    Map<String, String> extend = const <String, String>{},
  }) =>
      _call(siteKey, 'categoryContent', <String, dynamic>{
        'tid': tid,
        'pg': pg,
        'filter': filter,
        'extend': extend,
      });

  /// 详情。`ids` 一般是 `[vodId]`，个别 spider 会要 `["vodId", "1"]`。
  static Future<VodSpiderCall> detailContent({
    required String siteKey,
    required List<String> ids,
  }) =>
      _call(siteKey, 'detailContent', <String, dynamic>{'ids': ids});

  static Future<VodSpiderCall> searchContent({
    required String siteKey,
    required String key,
    bool quick = false,
    String? pg,
  }) =>
      _call(siteKey, 'searchContent', <String, dynamic>{
        'key': key,
        'quick': quick,
        if (pg != null && pg.isNotEmpty) 'pg': pg,
      });

  /// 播放直链。`flag` 是详情页里的线路名，`id` 是该线路的地址。
  static Future<VodSpiderCall> playerContent({
    required String siteKey,
    required String flag,
    required String id,
    List<String> vipFlags = const <String>[],
  }) =>
      _call(siteKey, 'playerContent', <String, dynamic>{
        'flag': flag,
        'id': id,
        'vipFlags': vipFlags,
      });

  static Future<VodSpiderCall> action({
    required String siteKey,
    required String action,
  }) =>
      _call(siteKey, 'action', <String, dynamic>{'action': action});

  /// 释放实例。不传 `siteKey` 表示全量释放（切源、退出影音板块时用）。
  static Future<void> releaseSite({String? siteKey}) async {
    await _invokeMap('releaseSite', <String, dynamic>{'siteKey': siteKey ?? ''});
  }

  /// 清空 jar 与 dex 缓存；换源或调试加载失败时用。
  static Future<int> clearCache() async {
    final raw = await _invokeMap('clearCache');
    return _asInt(raw?['removed']);
  }

  // ------------------------------------------------------------------------

  static Future<VodSpiderCall> _call(
    String siteKey,
    String method, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final raw = await _invokeMap('invoke', <String, dynamic>{
      'siteKey': siteKey,
      'method': method,
      ...args,
    });
    if (raw == null || raw['ok'] != true) {
      return VodSpiderCall(
        ok: false,
        value: null,
        boolValue: null,
        elapsedMs: _asInt(raw?['elapsedMs']),
        failure: _failureOf(raw),
      );
    }
    return VodSpiderCall(
      ok: true,
      value: raw['value']?.toString(),
      boolValue: raw['boolValue'] is bool ? raw['boolValue'] as bool : null,
      elapsedMs: _asInt(raw['elapsedMs']),
      failure: null,
    );
  }

  /// 通道本身不可用时（非 Android、通道未注册）也要给一份结构化失败，
  /// 否则调用方得同时处理 null 和异常两种缺省。
  static Future<Map<String, dynamic>?> _invokeMap(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    if (!isSupported) {
      return <String, dynamic>{
        'ok': false,
        'code': 'unsupported_platform',
        'message': '当前平台不支持 TVBox 爬虫宿主（仅 Android）。',
      };
    }
    try {
      return await _channel.invokeMapMethod<String, dynamic>(method, args);
    } on MissingPluginException catch (error) {
      return <String, dynamic>{
        'ok': false,
        'code': 'channel_missing',
        'message': '原生桥接未注册：${error.message ?? 'pure_live/vod_spider'}',
        'hint': '确认安装的是 v3.0.15 及之后的 APK。',
      };
    } on PlatformException catch (error) {
      return <String, dynamic>{
        'ok': false,
        'code': error.code,
        'message': error.message ?? '原生调用失败',
        'exception': error.details?.toString(),
      };
    }
  }

  static VodSpiderFailure? _failureOf(Map<String, dynamic>? raw) {
    if (raw == null) {
      return const VodSpiderFailure(
        code: 'no_response',
        message: '原生侧没有返回任何内容。',
      );
    }
    if (raw['ok'] == true) return null;
    return VodSpiderFailure(
      code: raw['code']?.toString() ?? 'unknown',
      message: raw['message']?.toString() ?? '未知错误',
      hint: raw['hint']?.toString(),
      exception: raw['exception']?.toString(),
      stack: raw['stack']?.toString(),
    );
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static List<String> _asStringList(Object? value) {
    if (value is! List) return const <String>[];
    return value.map((item) => item?.toString() ?? '').toList(growable: false);
  }

  static List<Map<dynamic, dynamic>> _asMapList(Object? value) {
    if (value is! List) return const <Map<dynamic, dynamic>>[];
    return value.whereType<Map<dynamic, dynamic>>().toList(growable: false);
  }
}

class VodSpiderFailure {
  const VodSpiderFailure({
    required this.code,
    required this.message,
    this.hint,
    this.exception,
    this.stack,
  });

  final String code;
  final String message;
  final String? hint;
  final String? exception;
  final String? stack;

  /// 给界面用的一行摘要：错误码 + 人话 + 修复建议。
  String get summary {
    final buffer = StringBuffer('[$code] $message');
    if (hint != null && hint!.isNotEmpty) buffer.write('\n$hint');
    return buffer.toString();
  }

  @override
  String toString() => summary;
}

class VodCachedJar {
  const VodCachedJar({
    required this.name,
    required this.bytes,
    required this.readOnly,
  });

  final String name;
  final int bytes;
  final bool readOnly;
}

class VodHostDiagnostics {
  const VodHostDiagnostics({
    required this.ok,
    required this.hostClassesMissing,
    this.androidSdk = 0,
    this.androidRelease,
    this.abis = const <String>[],
    this.cachedJars = const <VodCachedJar>[],
    this.runtimeClassesMissing = const <String>[],
    this.optionalClassesMissing = const <String>[],
    this.quickJs = const VodQuickJsStatus(),
  });

  final bool ok;
  final int androidSdk;
  final String? androidRelease;
  final List<String> abis;

  /// 基础契约类缺失：会导致 csp_ 链路整体不可用。
  final List<String> hostClassesMissing;

  /// 由宿主源码提供的运行时实现类缺失（OkHttp / OkDns / Auth / logger 等）。
  /// 缺了同样致命 —— spider 一调 safeDns 或 Decoder 就 NoClassDefFoundError，
  /// 因此与 [hostClassesMissing] 一起计入 [ok]。
  final List<String> runtimeClassesMissing;

  /// 可选能力缺失，例如尚未内置的 Python / Node.js 运行时。不参与 [ok] 判定。
  final List<String> optionalClassesMissing;

  /// QuickJS 是否真的可用（#63）。看类是否存在没用，必须真求值一次。
  final VodQuickJsStatus quickJs;

  final List<VodCachedJar> cachedJars;
}

/// QuickJS 运行时状态。
///
/// [installed] 表示当前 ABI 的 `libquickjs-wrapper.so` 已随 APK 解压到
/// nativeLibraryDir；[checked] 表示宿主真的跑通了一次 `6 * 7`。
/// 两者都为真才算 JS 引擎可用 —— 只看类存在会被「.so 漏打进某个 ABI」骗过去。
class VodQuickJsStatus {
  const VodQuickJsStatus({
    this.installed = false,
    this.checked = false,
    this.error,
    this.compatibilityId,
  });

  factory VodQuickJsStatus.fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) return const VodQuickJsStatus();
    return VodQuickJsStatus(
      installed: raw['installed'] == true,
      checked: raw['checked'] == true,
      error: raw['error']?.toString(),
      compatibilityId: raw['compatibilityId']?.toString(),
    );
  }

  final bool installed;
  final bool checked;
  final String? error;
  final String? compatibilityId;

  bool get available => installed && checked;
}

class VodJarInspection {
  const VodJarInspection({
    required this.failure,
    this.jarPath,
    this.bytes = 0,
    this.readOnly = false,
    this.dexCount = 0,
    this.bundlesBaseClass = false,
    this.spiders = const <String>[],
  });

  factory VodJarInspection.failed(VodSpiderFailure? failure) =>
      VodJarInspection(
        failure: failure ??
            const VodSpiderFailure(code: 'unknown', message: 'jar 解析失败'),
      );

  final VodSpiderFailure? failure;
  final String? jarPath;
  final int bytes;
  final bool readOnly;
  final int dexCount;

  /// jar 是否自带 `com.github.catvod.crawler.Spider`。
  /// 为 false 是正常情况（依赖宿主提供），为 true 说明是自包含 jar。
  final bool bundlesBaseClass;

  /// 可直接填进站点 `api` 字段的短类名（已去掉包路径）。
  final List<String> spiders;

  bool get ok => failure == null;
}

class VodSitePreparation {
  const VodSitePreparation({
    required this.failure,
    this.siteKey = '',
    this.api = '',
    this.className,
    this.jarPath,
    this.mode,
    this.initModes = const <String>[],
  });

  factory VodSitePreparation.failed(VodSpiderFailure? failure) =>
      VodSitePreparation(
        failure: failure ??
            const VodSpiderFailure(code: 'unknown', message: '站点准备失败'),
      );

  final VodSpiderFailure? failure;
  final String siteKey;
  final String api;
  final String? className;
  final String? jarPath;

  /// `created` 或 `reused`。
  final String? mode;

  /// 实际调用了哪些 init 重载，用于排查「初始化静默不生效」。
  final List<String> initModes;

  bool get ok => failure == null;
}

class VodSpiderCall {
  const VodSpiderCall({
    required this.ok,
    required this.value,
    required this.boolValue,
    required this.elapsedMs,
    required this.failure,
  });

  final bool ok;

  /// spider 返回的原始 json 文本，未做任何改写。
  final String? value;
  final bool? boolValue;
  final int elapsedMs;
  final VodSpiderFailure? failure;

  /// 把 `value` 按 json 对象解析；解析不了返回 null（部分站点返回数组）。
  Map<String, dynamic>? get jsonObject {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      return null;
    }
    return null;
  }

  /// 解析成列表，兼容 `{list: [...]}` 与直接数组两种返回。
  List<Map<String, dynamic>> jsonList([String key = 'list']) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(text);
      final rawList = switch (decoded) {
        List<dynamic> list => list,
        Map<dynamic, dynamic> map when map[key] is List => map[key] as List<dynamic>,
        _ => const <dynamic>[],
      };
      return rawList
          .whereType<Map<dynamic, dynamic>>()
          .map((item) => item.map((k, v) => MapEntry(k.toString(), v)))
          .toList(growable: false);
    } on FormatException {
      return const <Map<String, dynamic>>[];
    }
  }
}
