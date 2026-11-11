import 'dart:convert';

import 'package:pure_live/core/utils/hive_pref_util.dart';
import 'package:uuid/uuid.dart';
import 'remote_config_model.dart';

/// 云端配置相关的 Hive 键（全部为新键，不与既有设置键冲突）。
class RemoteConfigKeys {
  static const String endpoint = 'remoteConfigEndpoint';
  static const String token = 'remoteConfigToken';
  static const String document = 'remoteConfigDocument';
  static const String etag = 'remoteConfigEtag';
  static const String lastSyncAt = 'remoteConfigLastSyncAt';
  static const String localSnapshot = 'remoteConfigLocalSnapshot';
  static const String navigationManaged = 'remoteConfigNavigationManaged';
  static const String agreementAcceptedVersion = 'agreementAcceptedVersion';
  static const String noticeShownRevision = 'noticeShownRevision';
  static const String lastUpdateCheckAt = 'remoteConfigLastUpdateCheckAt';
  static const String deviceId = 'remoteConfigDeviceId';
  static const String lastIptvStamp = 'remoteConfigLastIptvStamp';

  const RemoteConfigKeys._();
}

/// 本地持久化层。云端不可用时，这里就是唯一的配置来源。
class RemoteConfigStore {
  /// 云端地址默认值：正式部署的 EdgeOne 配置服务。
  ///
  /// 需要换环境时用编译期覆盖，不鼓励改这里：
  /// flutter build apk --dart-define=PURE_LIVE_CONFIG_URL=https://... \
  ///                   --dart-define=PURE_LIVE_CONFIG_TOKEN=...
  ///
  /// 令牌默认为空：服务端若把 `CONFIG_READ_TOKEN` 留空即为公开读（推荐，配置本身
  /// 不含敏感信息），这样 APK 开箱即用；需要读鉴权时再用 dart-define 注入。
  static const String defaultEndpoint = 'https://tv.1008618.xyz';
  static const String compiledEndpoint =
      String.fromEnvironment('PURE_LIVE_CONFIG_URL', defaultValue: defaultEndpoint);
  static const String compiledToken =
      String.fromEnvironment('PURE_LIVE_CONFIG_TOKEN', defaultValue: '');

  const RemoteConfigStore._();

  /// 留空 = 完全离线运行，不发任何请求，也不改动任何本地设置。
  static String get endpoint {
    final stored = HivePrefUtil.getString(RemoteConfigKeys.endpoint)?.trim() ?? '';
    return stored.isNotEmpty ? stored : compiledEndpoint.trim();
  }

  static String get token {
    final stored = HivePrefUtil.getString(RemoteConfigKeys.token)?.trim() ?? '';
    return stored.isNotEmpty ? stored : compiledToken.trim();
  }


  /// 终端身份：首次启动生成 UUID v4 并持久化，之后每次拉配置都带上。
  /// 云端据此为每台终端保存一份完整独立的配置文档。
  static String get deviceId {
    final saved = HivePrefUtil.getString(RemoteConfigKeys.deviceId)?.trim() ?? '';
    if (saved.isNotEmpty) return saved;
    final generated = const Uuid().v4();
    // 与项目既有写法一致：Hive put 立即可读，无需 await。
    HivePrefUtil.setString(RemoteConfigKeys.deviceId, generated);
    return generated;
  }

  /// IPTV 导入幂等标记（deviceId:revision:channelCount）。
  static String get iptvStamp =>
      HivePrefUtil.getString(RemoteConfigKeys.lastIptvStamp) ?? '';

  static Future<void> setIptvStamp(String value) async {
    await HivePrefUtil.setString(RemoteConfigKeys.lastIptvStamp, value);
  }

  static RemoteConfigDocument? readDocument() {
    final raw = HivePrefUtil.getString(RemoteConfigKeys.document);
    if (raw == null || raw.isEmpty) return null;
    return RemoteConfigDocument.tryDecode(raw);
  }

  static int get revision => readDocument()?.revision ?? 0;

  static int get lastSyncAt => HivePrefUtil.getInt(RemoteConfigKeys.lastSyncAt) ?? 0;

  static Future<void> saveDocument(RemoteConfigDocument document, {String? etag}) async {
    await HivePrefUtil.setString(RemoteConfigKeys.document, document.encode());
    await HivePrefUtil.setInt(RemoteConfigKeys.lastSyncAt, DateTime.now().millisecondsSinceEpoch);
    if (etag != null && etag.isNotEmpty) {
      await HivePrefUtil.setString(RemoteConfigKeys.etag, etag);
    }
  }

  static bool get navigationManaged =>
      HivePrefUtil.getBool(RemoteConfigKeys.navigationManaged) ?? false;

  static Future<void> setNavigationManaged(bool value) async {
    await HivePrefUtil.setBool(RemoteConfigKeys.navigationManaged, value);
  }

  static int get agreementAcceptedVersion =>
      HivePrefUtil.getInt(RemoteConfigKeys.agreementAcceptedVersion) ?? 0;

  static Future<void> setAgreementAcceptedVersion(int value) async {
    await HivePrefUtil.setInt(RemoteConfigKeys.agreementAcceptedVersion, value);
  }

  static int get noticeShownRevision =>
      HivePrefUtil.getInt(RemoteConfigKeys.noticeShownRevision) ?? -1;

  static Future<void> setNoticeShownRevision(int value) async {
    await HivePrefUtil.setInt(RemoteConfigKeys.noticeShownRevision, value);
  }

  static int get lastUpdateCheckAt =>
      HivePrefUtil.getInt(RemoteConfigKeys.lastUpdateCheckAt) ?? 0;

  static Future<void> setLastUpdateCheckAt(int value) async {
    await HivePrefUtil.setInt(RemoteConfigKeys.lastUpdateCheckAt, value);
  }

  /// 首次被云端接管时，把本地用户设置快照存一份；当所有节都回到
  /// managed:false 时用于恢复，避免用户被云端配置「锁死」。
  static void saveLocalSnapshotOnce(Map<String, dynamic> snapshot) {
    final existing = HivePrefUtil.getString(RemoteConfigKeys.localSnapshot);
    if (existing != null && existing.isNotEmpty) return;
    // 与项目既有 *_persist() 一致：Hive 的 put 立即可读，不必 await。
    HivePrefUtil.setString(RemoteConfigKeys.localSnapshot, jsonEncode(snapshot));
  }

  static Map<String, dynamic>? consumeLocalSnapshot() {
    final raw = HivePrefUtil.getString(RemoteConfigKeys.localSnapshot);
    if (raw == null || raw.isEmpty) return null;
    HivePrefUtil.remove(RemoteConfigKeys.localSnapshot);
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}
