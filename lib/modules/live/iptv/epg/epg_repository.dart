/// EPG 数据仓库：从云端下发的 epgUrl 拉取 XMLTV，解析后缓存到 Hive。
///
/// - 数据源 URL 来自 RemoteConfigStore.epgUrl（云端 sections.iptv.epgUrl）；
/// - 缓存用 HivePrefUtil 单键存 JSON，避免改动 drift/database.g.dart；
/// - 网络失败时返回上次缓存（离线可用），这是 TV 端的最佳实践。
library;

import 'dart:convert';

import 'package:pure_live/core/common/http_client.dart';
import 'package:pure_live/core/utils/hive_pref_util.dart';
import 'package:pure_live/services/remote_config/remote_config_store.dart';

import 'epg_model.dart';
import 'xmltv_parser.dart';

class EpgRepository {
  EpgRepository({HttpClient? http}) : _http = http ?? HttpClient.instance;

  final HttpClient _http;

  static const String _cacheKey = 'epgGuideCache';
  static const int _maxCachedBytes = 8 * 1024 * 1024; // 8 MiB XMLTV 上限

  /// 读取本地缓存（不联网）。
  EpgGuide? readCached() {
    final raw = HivePrefUtil.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return EpgGuide.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      // 缓存损坏就当没有，不影响联网重拉。
    }
    return null;
  }

  /// 云端是否下发了 EPG 源。
  bool get hasSource => RemoteConfigStore.epgUrl.isNotEmpty;

  /// 拉取并解析；成功写缓存并返回新数据。
  ///
  /// 失败抛异常，由调用方决定是否回退 [readCached]。
  Future<EpgGuide> fetch() async {
    final url = RemoteConfigStore.epgUrl.trim();
    if (url.isEmpty) throw const XmltvParseException('云端未下发 EPG 地址');

    final response = await _http.dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.string,
        headers: HttpClient.iptvHeaders(),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    final text = response.data ?? '';
    if (text.length > _maxCachedBytes) {
      throw const XmltvParseException('EPG 数据超过 8 MiB 上限');
    }
    final guide = parseXmltv(text);
    await _writeCache(guide);
    return guide;
  }

  Future<void> _writeCache(EpgGuide guide) async {
    await HivePrefUtil.setString(_cacheKey, jsonEncode(guide.toJson()));
  }
}
